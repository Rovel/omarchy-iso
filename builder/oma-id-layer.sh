#!/bin/bash
# Disposable OMA-ID layer for the Omarchy ISO (P2 agent slice).
#
# Gated: build-iso.sh only invokes this when OMA_ID_SHA is set, so ordinary
# ISO builds are untouched. It clones oma-id at the pinned SHA, builds the
# artifacts, and installs them into the airootfs target directory:
#
#   $AIROOTFS/usr/lib/security/pam_oma_id.so   PAM module (standard search
#                                              path)
#   $AIROOTFS/usr/bin/oma-id-agent              the real endpoint agent
#   $AIROOTFS/usr/lib/systemd/system/oma-id-agent.service
#   $AIROOTFS/etc/oma-id-agent.json            agent config (from
#                                              OMA_ID_SERVER_URL /
#                                              OMA_ID_DEVICE_ID)
#   $AIROOTFS/etc/pam.d/sddm                    PAM service wiring (the §8.2
#   $AIROOTFS/etc/pam.d/omarchy-lock-password   feasibility surfaces)
#   $AIROOTFS/etc/pam.d/omarchy-lock-fingerprint
#   $AIROOTFS/opt/oma-id/bin/*                  test harnesses + selector
#   $AIROOTFS/opt/oma-id/PROVENANCE             pinned repo + SHA + hashes
#
# Boundary: this layer WIREs the PAM services (sddm + omarchy-lock-*) to
# pam_oma_id — the §8.2 feasibility wiring. The live ISO boots the agent
# (oma-id-agent.service, enabled); the agent fails closed until its config
# points at a reachable OMA-ID server and the printed device public key is
# registered out-of-band. No login or offline gate is claimed by shipping
# these files: the §8.2 matrix (real SDDM/TTY/lock consumer evidence) is
# the remaining gate.
set -e

: "${OMA_ID_SHA:?OMA_ID_SHA must be set to the pinned oma-id commit}"
: "${AIROOTFS:?AIROOTFS must point at the airootfs target directory (use / for in-container smoke runs)}"
OMA_ID_REPO="${OMA_ID_REPO:-https://github.com/Rovel/oma-id.git}"
OMA_ID_SERVER_URL="${OMA_ID_SERVER_URL:-}"
OMA_ID_DEVICE_ID="${OMA_ID_DEVICE_ID:-workstation-1}"

src=/tmp/oma-id-src
rm -rf "$src"
pacman --noconfirm -Sy rust cargo git gcc pam libxcrypt
git clone -q "$OMA_ID_REPO" "$src"
git -C "$src" checkout --detach -q "$OMA_ID_SHA"
commit_subject=$(git -C "$src" log -1 --format=%s)

(cd "$src/native" && cargo build --locked --release -p oma-id-pam-module -p oma-id-agent-daemon -p oma-id-agent)
gcc -O2 -Wall -o "$src/pam-test-client" "$src/tests/arch-pam/pam-test-client.c" -lpam

module="$src/native/target/release/libpam_oma_id.so"
fake_agent="$src/native/target/release/fake_agent"
real_agent="$src/native/target/release/oma-id-agent"
client="$src/pam-test-client"
for f in "$module" "$fake_agent" "$real_agent" "$client"; do
  [[ -f "$f" ]] || { echo "oma-id layer: missing built artifact $f" >&2; exit 1; }
done

install -D -m 0755 "$module" "$AIROOTFS/usr/lib/security/pam_oma_id.so"
install -D -m 0755 "$fake_agent" "$AIROOTFS/opt/oma-id/bin/fake_agent"
install -D -m 0755 "$client" "$AIROOTFS/opt/oma-id/bin/pam-test-client"
install -D -m 0755 "$src/tests/iso-smoke/run-smoke.sh" "$AIROOTFS/opt/oma-id/run-smoke.sh"
# Installer work/school selector (plan §6.1/§6.2): invoked by the configurator
# when the layer is present; personal installs never see it.
install -D -m 0755 "$src/tests/iso-smoke/installer-choice.sh" "$AIROOTFS/opt/oma-id/bin/installer-choice"

# The real endpoint agent (§11.1/§11.2) + its unit (packaging/arch).
install -D -m 0755 "$real_agent" "$AIROOTFS/usr/bin/oma-id-agent"
install -D -m 0644 "$src/packaging/arch/oma-id-agent.service" \
  "$AIROOTFS/usr/lib/systemd/system/oma-id-agent.service"
# Enable in the live environment (the standard archiso mechanism).
mkdir -p "$AIROOTFS/etc/systemd/system/multi-user.target.wants"
ln -sfn /usr/lib/systemd/system/oma-id-agent.service \
  "$AIROOTFS/etc/systemd/system/multi-user.target.wants/oma-id-agent.service"

# Agent configuration (per-deployment data). An empty server URL keeps the
# agent fail-closed at boot with an explicit journal message — the operator
# sets it (or rebuilds with OMA_ID_SERVER_URL) before the demo.
mkdir -p "$AIROOTFS/etc"
cat >"$AIROOTFS/etc/oma-id-agent.json" <<CONFIG
{
  "server_url": "${OMA_ID_SERVER_URL:-UNCONFIGURED}",
  "device_id": "$OMA_ID_DEVICE_ID",
  "state_dir": "/var/lib/oma-id",
  "socket_path": "/run/oma-id/agent.sock",
  "check_in_interval_seconds": 300
}
CONFIG
chmod 0644 "$AIROOTFS/etc/oma-id-agent.json"

# §8.2 feasibility wiring: the PAM services route through pam_oma_id.
# sddm: auth (credential + lease) and account (lease) on the login path.
# omarchy-lock-*: the Quickshell lockers (§2.2 source correction).
for service in sddm omarchy-lock-password omarchy-lock-fingerprint; do
  mkdir -p "$AIROOTFS/etc/pam.d"
  printf 'auth\trequired\t/usr/lib/security/pam_oma_id.so\naccount\trequired\t/usr/lib/security/pam_oma_id.so\n' \
    >"$AIROOTFS/etc/pam.d/$service"
done

{
  echo "repo:     $OMA_ID_REPO"
  echo "commit:   $OMA_ID_SHA"
  echo "subject:  $commit_subject"
  echo "built:    $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "rustc:    $(rustc --version)"
  echo "server:   ${OMA_ID_SERVER_URL:-UNCONFIGURED}"
  echo "device:   $OMA_ID_DEVICE_ID"
  sha256sum "$module" "$fake_agent" "$real_agent" "$client" | sed "s|$src/||"
} >"$AIROOTFS/opt/oma-id/PROVENANCE"

echo "oma-id layer installed at $OMA_ID_SHA (agent + PAM wiring; provenance in /opt/oma-id/PROVENANCE)"
