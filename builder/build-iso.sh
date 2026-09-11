#!/bin/bash

set -e

# Note that these are packages installed to the Arch container used to build the ISO.
pacman-key --init
pacman --noconfirm -Sy archlinux-keyring
pacman --noconfirm -Sy archiso git sudo base-devel jq grub

# Pre-import the omarchy signing key so pacman can verify packages without a keyserver lookup
pacman-key --add /builder/omarchy.gpg
pacman-key --lsign-key 40DFB630FF42BCFFB047046CF0134EE680CAC571

# Install omarchy-keyring for package verification during build
pacman --config /configs/pacman-online-${OMARCHY_MIRROR}.conf --noconfirm -Sy omarchy-keyring
pacman-key --populate omarchy

# Setup build locations
build_cache_dir="/var/cache"
offline_mirror_dir="$build_cache_dir/airootfs/var/cache/omarchy/mirror/offline"
mkdir -p $build_cache_dir/
mkdir -p $offline_mirror_dir/

# We base our ISO on the official arch ISO (releng) config
cp -r /archiso/configs/releng/* $build_cache_dir/
rm "$build_cache_dir/airootfs/etc/motd"

# Avoid using reflector for mirror identification as we are relying on the global CDN
rm -rf "$build_cache_dir/airootfs/etc/systemd/system/multi-user.target.wants/reflector.service"
rm -rf "$build_cache_dir/airootfs/etc/systemd/system/reflector.service.d"
rm -rf "$build_cache_dir/airootfs/etc/xdg/reflector"

# Bring in our configs
cp -r /configs/* $build_cache_dir/

# Persist OMARCHY_MIRROR so it's available at install time
echo "$OMARCHY_MIRROR" > "$build_cache_dir/airootfs/root/omarchy_mirror"

# Setup Omarchy itself
if [[ -d /omarchy ]]; then
  cp -rp /omarchy "$build_cache_dir/airootfs/root/omarchy"
else
  git clone -b $OMARCHY_INSTALLER_REF https://github.com/$OMARCHY_INSTALLER_REPO.git "$build_cache_dir/airootfs/root/omarchy"
fi

# Make log uploader available in the ISO too
mkdir -p "$build_cache_dir/airootfs/usr/local/bin/"
cp "$build_cache_dir/airootfs/root/omarchy/bin/omarchy-upload-log" "$build_cache_dir/airootfs/usr/local/bin/omarchy-upload-log"

# Copy the Omarchy Plymouth theme to the ISO
mkdir -p "$build_cache_dir/airootfs/usr/share/plymouth/themes/omarchy"
cp -r "$build_cache_dir/airootfs/root/omarchy/default/plymouth/"* "$build_cache_dir/airootfs/usr/share/plymouth/themes/omarchy/"

# Download and verify Node.js binary for offline installation
NODE_DIST_URL="https://nodejs.org/dist/latest"

# Get checksums and parse filename and SHA
NODE_SHASUMS=$(curl -fsSL "$NODE_DIST_URL/SHASUMS256.txt")
NODE_FILENAME=$(echo "$NODE_SHASUMS" | grep "linux-x64.tar.gz" | awk '{print $2}')
NODE_SHA=$(echo "$NODE_SHASUMS" | grep "linux-x64.tar.gz" | awk '{print $1}')

# Download the tarball
curl -fsSL "$NODE_DIST_URL/$NODE_FILENAME" -o "/tmp/$NODE_FILENAME"

# Verify SHA256 checksum
echo "$NODE_SHA /tmp/$NODE_FILENAME" | sha256sum -c - || {
    echo "ERROR: Node.js checksum verification failed!"
    exit 1
}

# Copy to ISO
mkdir -p "$build_cache_dir/airootfs/opt/packages/"
cp "/tmp/$NODE_FILENAME" "$build_cache_dir/airootfs/opt/packages/"

# Add our additional packages to packages.x86_64
arch_packages=(linux-t2 git gum jq openssl plymouth tzupdate omarchy-keyring lvm2 cryptsetup parted)
printf '%s\n' "${arch_packages[@]}" >>"$build_cache_dir/packages.x86_64"

# Build list of all the packages needed for the offline mirror
all_packages=($(cat "$build_cache_dir/packages.x86_64"))
all_packages+=($(grep -v '^#' "$build_cache_dir/airootfs/root/omarchy/install/omarchy-base.packages" | grep -v '^$'))
all_packages+=($(grep -v '^#' "$build_cache_dir/airootfs/root/omarchy/install/omarchy-other.packages" | grep -v '^$'))
all_packages+=($(grep -v '^#' /builder/archinstall.packages | grep -v '^$'))

# Download all the packages to the offline mirror inside the ISO.
# Upstream package drift: the selected mirror may no longer carry a package
# referenced by an upstream list (e.g. broadcom-wl was removed from the
# Arch repos on 2026-09-09). Drop missing packages with a LOUD warning —
# never a silent skip — so the build stays reproducible against drift
# while the log records what was omitted.
mkdir -p /tmp/offlinedb
pacman --config /configs/pacman-online-${OMARCHY_MIRROR}.conf --noconfirm -Sy --dbpath /tmp/offlinedb >/dev/null 2>&1 || true
available_packages=()
dropped_packages=""
for pkg in "${all_packages[@]}"; do
  if pacman --config /configs/pacman-online-${OMARCHY_MIRROR}.conf --dbpath /tmp/offlinedb -Si "$pkg" >/dev/null 2>&1; then
    available_packages+=("$pkg")
  else
    echo "WARNING: package not in the ${OMARCHY_MIRROR} mirror, dropping: $pkg"
    dropped_packages+=" $pkg "
  fi
done
all_packages=("${available_packages[@]}")

# mkarchiso installs from packages.x86_64 against the offline mirror — the
# same drift must be filtered there, or the airootfs pacstrap fails with
# "target not found".
filtered_x86=()
for pkg in $(cat "$build_cache_dir/packages.x86_64"); do
  if [[ "$dropped_packages" != *" $pkg "* ]]; then
    filtered_x86+=("$pkg")
  else
    echo "WARNING: dropping $pkg from the mkarchiso install list (not in the mirror)"
  fi
done
printf '%s\n' "${filtered_x86[@]}" > "$build_cache_dir/packages.x86_64"

pacman --config /configs/pacman-online-${OMARCHY_MIRROR}.conf --noconfirm -Syw "${all_packages[@]}" --cachedir $offline_mirror_dir/ --dbpath /tmp/offlinedb
repo-add --new "$offline_mirror_dir/offline.db.tar.gz" "$offline_mirror_dir/"*.pkg.tar.zst

# Create a symlink to the offline mirror instead of duplicating it.
# mkarchiso needs packages at /var/cache/omarchy/mirror/offline in the container,
# but they're actually in $build_cache_dir/airootfs/var/cache/omarchy/mirror/offline
mkdir -p /var/cache/omarchy/mirror
ln -s "$offline_mirror_dir" "/var/cache/omarchy/mirror/offline"

# Copy the offline pacman.conf to the ISO's /etc directory so the live environment uses our
# same config when booted. 
cp $build_cache_dir/pacman-offline.conf "$build_cache_dir/airootfs/etc/pacman.conf"

# --- Optional disposable OMA-ID layer (no-op unless OMA_ID_SHA is set) ---
# Installs pam_oma_id.so + the real agent + systemd unit + §8.2 PAM service
# wiring into the airootfs; see builder/oma-id-layer.sh for the boundaries.
if [[ -n "${OMA_ID_SHA:-}" ]]; then
  AIROOTFS="$build_cache_dir/airootfs" \
    OMA_ID_SERVER_URL="${OMA_ID_SERVER_URL:-}" \
    OMA_ID_DEVICE_ID="${OMA_ID_DEVICE_ID:-}" \
    /builder/oma-id-layer.sh
fi

# --- Optional OMA-ID smoke on the installed live root (OMA_ID_SMOKE=1) ---
# mkarchiso installs packages.x86_64 into its work dir, overlays the
# airootfs/ customization files, and then runs
# airootfs/root/customize_airootfs.sh via arch-chroot INSIDE the fully
# installed live root (which ships zsh, not bash — releng packages) before
# packing. The generated hook below runs the 5-scenario real-libpam smoke
# there, gated by a marker file so plain OMA_ID_SHA builds ship the layer
# without the smoke. mkarchiso deletes the hook after running it. For CI
# use — keeps heavy verification off local disks; all PAM activity stays
# inside the build chroot.
if [[ -n "${OMA_ID_SHA:-}" ]]; then
  # mkarchiso strips modes when copying custom airootfs files (cp
  # --no-preserve=mode) and only restores those declared in the profile's
  # file_permissions map — extend it for the layer's executables.
  cat >>"$build_cache_dir/profiledef.sh" <<'PERMS'
file_permissions+=(
  ["/opt/oma-id/bin/fake_agent"]="0:0:755"
  ["/opt/oma-id/bin/pam-test-client"]="0:0:755"
  ["/opt/oma-id/bin/installer-choice"]="0:0:755"
  ["/opt/oma-id/bin/oma-id-provision-target.sh"]="0:0:755"
  ["/opt/oma-id/run-smoke.sh"]="0:0:755"
  ["/usr/bin/oma-id-agent"]="0:0:755"
  ["/usr/lib/systemd/system/oma-id-agent.service"]="0:0:644"
  ["/etc/oma-id-agent.json"]="0:0:644"
  ["/etc/pam.d/sddm"]="0:0:644"
  ["/etc/pam.d/omarchy-lock-password"]="0:0:644"
  ["/etc/pam.d/omarchy-lock-fingerprint"]="0:0:644"
)
PERMS
  echo "--- OMA-ID layer verification (files overlaid into the live root) ---"
  ls -la "$build_cache_dir/airootfs/usr/lib/security/pam_oma_id.so"
  ls -la "$build_cache_dir/airootfs/opt/oma-id/"
  cat "$build_cache_dir/airootfs/opt/oma-id/PROVENANCE"
  if [[ ! -e "$build_cache_dir/airootfs/root/customize_airootfs.sh" ]]; then
    cat >"$build_cache_dir/airootfs/root/customize_airootfs.sh" <<'HOOK'
#!/usr/bin/zsh
# Generated by build-iso.sh when OMA_ID_SHA is set. Runs inside the
# installed live root during mkarchiso (which deletes this file after it
# runs). All PAM activity stays inside this build chroot.
if [[ -f /opt/oma-id/run-smoke.sh && -f /opt/oma-id/.smoke-on-build ]]; then
  echo "--- OMA-ID smoke on the installed live root ---"
  /usr/bin/zsh /opt/oma-id/run-smoke.sh
  smoke_rc=$?
  rm -f /tmp/oma-id-smoke-results.tsv
  rm -rf /run/oma-id
  if [[ $smoke_rc -ne 0 ]]; then
    echo "oma-id smoke FAILED on the installed live root" >&2
    exit $smoke_rc
  fi
  echo "oma-id smoke passed on the installed live root"
fi
exit 0
HOOK
    chmod 0755 "$build_cache_dir/airootfs/root/customize_airootfs.sh"
  fi
  if [[ -n "${OMA_ID_SMOKE:-}" ]]; then
    : >"$build_cache_dir/airootfs/opt/oma-id/.smoke-on-build"
  fi
fi

# Finally, we assemble the entire ISO
mkarchiso -v -w "$build_cache_dir/work/" -o "/out/" "$build_cache_dir/"

# Fix ownership of output files to match host user
if [ -n "$HOST_UID" ] && [ -n "$HOST_GID" ]; then
    chown -R "$HOST_UID:$HOST_GID" /out/
fi
