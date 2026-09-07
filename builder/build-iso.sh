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

# Download all the packages to the offline mirror inside the ISO
mkdir -p /tmp/offlinedb
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

# --- Optional disposable OMA-ID P0 stand-in layer (no-op unless OMA_ID_SHA is set) ---
# Installs pam_oma_id.so + the fake agent + smoke assets into the airootfs.
# No PAM service on the ISO is modified; see builder/oma-id-layer.sh.
if [[ -n "${OMA_ID_SHA:-}" ]]; then
  AIROOTFS="$build_cache_dir/airootfs" /builder/oma-id-layer.sh
fi

# --- Optional OMA-ID smoke on the assembled airootfs (OMA_ID_SMOKE=1) ---
# Runs the 5-scenario real-libpam smoke against the exact airootfs mkarchiso
# is about to pack, via chroot. For CI use — keeps heavy verification off
# local disks. All PAM activity stays inside the chroot.
if [[ -n "${OMA_ID_SHA:-}" && -n "${OMA_ID_SMOKE:-}" ]]; then
  smoke_root="$build_cache_dir/airootfs"
  echo "--- OMA-ID pre-pack verification (files as packed by mkarchiso) ---"
  ls -la "$smoke_root/usr/lib/security/pam_oma_id.so"
  ls -la "$smoke_root/opt/oma-id/"
  cat "$smoke_root/opt/oma-id/PROVENANCE"
  mkdir -p "$smoke_root/proc" "$smoke_root/sys" "$smoke_root/dev"
  mount --bind /dev "$smoke_root/dev"
  mount --bind /proc "$smoke_root/proc"
  mount --bind /sys "$smoke_root/sys"
  # The Omarchy live airootfs ships zsh, not bash — pick what exists.
  smoke_shell=""
  for candidate in /bin/bash /usr/bin/zsh /bin/zsh; do
    if [[ -x "$smoke_root$candidate" ]]; then smoke_shell="$candidate"; break; fi
  done
  if [[ -z "$smoke_shell" ]]; then
    echo "oma-id smoke: no known shell (bash/zsh) in the airootfs; /bin contains:" >&2
    ls -la "$smoke_root/bin/" >&2 || true
    umount "$smoke_root/sys" "$smoke_root/proc" "$smoke_root/dev" || true
    exit 1
  fi
  echo "oma-id smoke: chroot shell = $smoke_shell"
  smoke_status=0
  chroot "$smoke_root" "$smoke_shell" /opt/oma-id/run-smoke.sh || smoke_status=$?
  umount "$smoke_root/sys" "$smoke_root/proc" "$smoke_root/dev" || true
  # Keep the packed ISO clean of smoke residue (service files are already
  # removed by the smoke script's own exit trap).
  rm -f "$smoke_root/tmp/oma-id-smoke-results.tsv"
  rm -rf "$smoke_root/run/oma-id"
  if [[ $smoke_status -ne 0 ]]; then
    echo "oma-id smoke FAILED on the assembled airootfs" >&2
    exit 1
  fi
  echo "oma-id smoke passed on the assembled airootfs"
fi

# Finally, we assemble the entire ISO
mkarchiso -v -w "$build_cache_dir/work/" -o "/out/" "$build_cache_dir/"

# Fix ownership of output files to match host user
if [ -n "$HOST_UID" ] && [ -n "$HOST_GID" ]; then
    chown -R "$HOST_UID:$HOST_GID" /out/
fi
