#!/bin/bash
# Disposable OMA-ID P0 stand-in layer for the Omarchy ISO.
#
# Gated: build-iso.sh only invokes this when OMA_ID_SHA is set, so ordinary
# ISO builds are untouched. It clones oma-id at the pinned SHA, builds the
# P0 artifacts, and installs them into the airootfs target directory:
#
#   $AIROOTFS/usr/lib/security/pam_oma_id.so   PAM module (standard search
#                                              path; only services that
#                                              explicitly name it use it)
#   $AIROOTFS/opt/oma-id/bin/fake_agent        P0 test-harness agent
#   $AIROOTFS/opt/oma-id/bin/pam-test-client   C consumer harness
#   $AIROOTFS/opt/oma-id/run-smoke.sh          5-scenario smoke matrix
#   $AIROOTFS/opt/oma-id/PROVENANCE            pinned repo + SHA + hashes
#
# P0 scope: this is a protocol stand-in. No PAM service on the ISO is
# modified — no login or offline gate is claimed by this layer.
set -e

: "${OMA_ID_SHA:?OMA_ID_SHA must be set to the pinned oma-id commit}"
: "${AIROOTFS:?AIROOTFS must point at the airootfs target directory (use / for in-container smoke runs)}"
OMA_ID_REPO="${OMA_ID_REPO:-https://github.com/Rovel/oma-id.git}"

src=/tmp/oma-id-src
rm -rf "$src"
pacman --noconfirm -Sy rust cargo git gcc pam
git clone -q "$OMA_ID_REPO" "$src"
git -C "$src" checkout --detach -q "$OMA_ID_SHA"
commit_subject=$(git -C "$src" log -1 --format=%s)

(cd "$src/native" && cargo build --locked --release -p oma-id-pam-module -p oma-id-agent-daemon)
gcc -O2 -Wall -o "$src/pam-test-client" "$src/tests/arch-pam/pam-test-client.c" -lpam

module="$src/native/target/release/libpam_oma_id.so"
agent="$src/native/target/release/fake_agent"
client="$src/pam-test-client"
for f in "$module" "$agent" "$client"; do
  [[ -f "$f" ]] || { echo "oma-id layer: missing built artifact $f" >&2; exit 1; }
done

install -D -m 0755 "$module" "$AIROOTFS/usr/lib/security/pam_oma_id.so"
install -D -m 0755 "$agent" "$AIROOTFS/opt/oma-id/bin/fake_agent"
install -D -m 0755 "$client" "$AIROOTFS/opt/oma-id/bin/pam-test-client"
install -D -m 0755 "$src/tests/iso-smoke/run-smoke.sh" "$AIROOTFS/opt/oma-id/run-smoke.sh"
# Installer work/school selector (plan §6.1/§6.2): invoked by the configurator
# when the layer is present; personal installs never see it.
install -D -m 0755 "$src/tests/iso-smoke/installer-choice.sh" "$AIROOTFS/opt/oma-id/bin/installer-choice"

{
  echo "repo:     $OMA_ID_REPO"
  echo "commit:   $OMA_ID_SHA"
  echo "subject:  $commit_subject"
  echo "built:    $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "rustc:    $(rustc --version)"
  sha256sum "$module" "$agent" "$client" | sed "s|$src/||"
} >"$AIROOTFS/opt/oma-id/PROVENANCE"

echo "oma-id layer installed at $OMA_ID_SHA (provenance in /opt/oma-id/PROVENANCE)"
