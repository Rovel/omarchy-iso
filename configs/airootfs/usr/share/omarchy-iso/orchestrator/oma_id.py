"""OMA-ID managed-install staging (docs/p0/installer-enrollment.md).

Phase: reserve-then-activate staging. The configurator embeds the
reservation (server URL, device id, request id) and the device seed into the
config/credentials JSON the orchestrator reads at start — so a mid-install
/run wipe cannot strand the enrollment. This phase stages into the target:
the device seed (0600, inside LUKS), the choice, and then the full
agent/module/unit/PAM wiring via /opt/oma-id/bin/oma-id-provision-target.sh
(same file the pre-quattro flow used; §7.2 step 6).
"""
from __future__ import annotations

import json
import shutil
import subprocess
from pathlib import Path

from .ui import error, info


def _oma_config(ctx) -> dict:
    omarchy_install = (ctx.user_configuration or {}).get("omarchy_install") or {}
    oma = omarchy_install.get("oma_id") or {}
    return oma if oma.get("enabled") else {}


def stage_oma_id(ctx) -> None:
    oma = _oma_config(ctx)
    if not oma:
        info("› OMA-ID: personal install — nothing to stage")
        return

    target: Path = ctx.target
    server_url = oma.get("server_url") or ""
    device_id = oma.get("device_id") or "workstation-1"
    request_id = oma.get("request_id") or 0
    oma_creds = (ctx.user_credentials or {}).get("oma_id") or {}
    seed_hex = oma_creds.get("device_key_hex") or ""
    install_password = oma_creds.get("install_password") or ""

    if not server_url:
        error("OMA-ID: managed install missing server_url in the config — continuing UNMANAGED")
        return
    if len(seed_hex) != 64 or not all(c in "0123456789abcdef" for c in seed_hex.lower()):
        error("OMA-ID: managed install missing a valid 32-byte device key seed — continuing UNMANAGED")
        return

    target_oma = target / "etc" / "oma-id"
    target_oma.mkdir(parents=True, exist_ok=True)

    # The device seed: written here by the orchestrator (the configurator's
    # /run copy may not survive the install window), 0600, inside LUKS.
    seed_path = target / "var/lib/oma-id/device.key"
    seed_path.parent.mkdir(parents=True, exist_ok=True)
    seed_path.write_bytes(bytes.fromhex(seed_hex))
    seed_path.chmod(0o600)

    choice = {
        "mode": "work-school",
        "server": server_url,
        "note": "reservation registered at install (orchestrator staged)",
        "device": device_id,
    }
    (target_oma / "standin-choice.json").write_text(json.dumps(choice))
    (target_oma / "enrollment.json").write_text(json.dumps({"request_id": request_id}))

    # The operator-set local password (LUKS + localadmin + the OMA-ID account):
    # staged 0600 for the agent to apply at first-boot provisioning, then
    # deleted. Inside LUKS; never leaves the machine (§10).
    if install_password:
        pw_path = target_oma / "install-password"
        pw_path.write_text(install_password)
        pw_path.chmod(0o600)

    info("› OMA-ID: seed + choice staged into the target; running provision")

    provision = Path("/opt/oma-id/bin/oma-id-provision-target.sh")
    if not provision.exists():
        error("OMA-ID: provision script missing from the live ISO (/opt/oma-id) — continuing UNMANAGED")
        return

    result = subprocess.run(
        [str(provision), str(target), "", device_id],
        capture_output=True, text=True,
    )
    if result.stdout:
        for line in result.stdout.splitlines():
            info(f"  oma-id: {line}")
    if result.returncode != 0:
        error(f"OMA-ID: provision failed (rc={result.returncode}): {result.stderr[-800:]} — continuing UNMANAGED")
        return

    agent_bin = target / "usr/bin/oma-id-agent"
    module = target / "usr/lib/security/pam_oma_id.so"
    if not agent_bin.exists() or not module.exists():
        error("OMA-ID: hook exited 0 but agent/module missing in the target — continuing UNMANAGED")
        return

    # The provisioned account name (from the §8.4 mapping) for the login
    # phase (configure_oma_login) to set SDDM's last-user to.
    try:
        mapping = json.loads((Path("/opt/oma-id") / "provision-output.json").read_text()) \
            if (Path("/opt/oma-id") / "provision-output.json").exists() else {}
    except Exception:
        mapping = {}
    login_user = mapping.get("posix_username") or ""
    if login_user:
        (target / "etc/oma-id/login-username").write_text(login_user)

    info("› OMA-ID: staged (agent, module, config, first-boot unit, PAM wiring)")


def configure_oma_login(ctx) -> None:
    """Runs AFTER quattro's configure_login: managed installs boot to SDDM and
    log in with the OMA provisioned account (server-attributed password) —
    no localadmin autologin (which quattro's encrypted non-deferred path
    writes, landing the operator in a session our lock PAM would trap).
    """
    oma = _oma_config(ctx)
    if not oma:
        return

    # The provisioned username: the provision phase records it in
    # provision-output.json (login-username is the plain-text fallback).
    candidates = [
        ctx.target / "etc" / "oma-id" / "provision-output.json",
        ctx.target / "etc" / "oma-id" / "login-username",
    ]
    username = ""
    for uf in candidates:
        if not uf.exists():
            continue
        try:
            data = json.loads(uf.read_text())
            username = (data.get("posix_username") or "").strip()
        except Exception:
            username = uf.read_text().strip()
        if username:
            break
    if not username:
        info("› OMA-ID: provisioned username unknown — leaving quattro login config untouched")
        return

    sddm_dir = ctx.target / "etc" / "sddm.conf.d"
    autologin = sddm_dir / "autologin.conf"
    if autologin.exists():
        autologin.unlink()
        info("› OMA-ID: removed localadmin autologin (managed login = SDDM)")

    state_dir = ctx.target / "var" / "lib" / "sddm"
    state_dir.mkdir(parents=True, exist_ok=True)
    (state_dir / "state.conf").write_text(
        f"[Last]\nSession=omarchy.desktop\nUser={username}\n"
    )
    import subprocess
    subprocess.run(["arch-chroot", str(ctx.target), "chown", "sddm:sddm",
                    "/var/lib/sddm", "/var/lib/sddm/state.conf"],
                   check=False, capture_output=True)
    info(f"› OMA-ID: SDDM last-user set to the provisioned account ({username})")
