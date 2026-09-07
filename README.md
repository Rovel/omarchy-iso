# Omarchy ISO

The Omarchy ISO streamlines [the installation of Omarchy](https://learn.omacom.io/2/the-omarchy-manual/50/getting-started). It includes the Omarchy Configurator as a front-end to archinstall and automatically launches the [Omarchy Installer](https://github.com/basecamp/omarchy) after base arch has been setup.

## Downloading the latest ISO

See the ISO link on [omarchy.org](https://omarchy.org).

## Creating the ISO

Run `./bin/omarchy-iso-make` and the output goes into `./release`. You can build from your local `$OMARCHY_PATH` for testing with `--local-source`, from the dev branch with `--dev`, or from the quattro branch with `--quattro`. The dev and quattro builds use the edge package mirror.

### Environment Variables

You can customize the repositories used during the build process by passing in variables:

- `OMARCHY_INSTALLER_REPO` - GitHub repository for the installer (default: `basecamp/omarchy`)
- `OMARCHY_INSTALLER_REF` - Git ref (branch/tag) for the installer (default: `master`)

Example usage:
```bash
OMARCHY_INSTALLER_REPO="myuser/omarchy-fork" OMARCHY_INSTALLER_REF="some-feature" ./bin/omarchy-iso-make
```

## Testing the ISO

Run `./bin/omarchy-iso-boot [release/omarchy.iso]`.

## OMA-ID P0 stand-in layer (disposable)

This branch can embed the OMA-ID P0 stand-in — the `pam_oma_id` PAM module,
the fake agent, and a smoke matrix — into the built ISO. It is **off by
default**: ordinary ISO builds are unchanged. Opt in by setting `OMA_ID_SHA`
to a pinned oma-id commit (oma-id is not on crates.io, so it is built from
a git checkout at that SHA):

```bash
OMA_ID_SHA=<oma-id-commit> ./bin/omarchy-iso-make --no-boot-offer
```

The layer installs `pam_oma_id.so` into the standard module search path and
the harness binaries under `/opt/oma-id/`, with a `PROVENANCE` file recording
the pinned repo, SHA, and artifact hashes. **No PAM service on the ISO is
modified** — this is a P0 protocol stand-in; no login or offline gate is
claimed. Inside the booted live environment, `bash /opt/oma-id/run-smoke.sh`
runs the 5-scenario matrix (valid / wrong / expired / down / unmapped).

CI: pushes to this branch run the layer build plus the installed-path smoke
in a disposable Arch container (`packaging-smoke`); a full ISO build with
the layer embedded is available via manual dispatch (`iso-build`), which
also runs the smoke against the assembled airootfs (chroot, before
`mkarchiso` packs it). Set `OMA_ID_SMOKE=1` locally for the same behavior.

> **Do not download the ~8 GB ISO artifact for local verification on
> WSL/Windows.** The WSL vhdx grows dynamically and can exhaust the host
> disk. The CI pre-pack smoke verifies the same content; for a
> booted-live-environment run, burn the ISO to USB and run
> `bash /opt/oma-id/run-smoke.sh` in the live session.

## Signing the ISO

Run `./bin/omarchy-iso-sign [release/omarchy.iso]`. The signing key is retrieved from the shared Omarchy vault with the 1Password CLI.

## Uploading the ISO

Run `./bin/omarchy-iso-upload [release/omarchy.iso]`. This requires you've configured rclone (use `rclone config`).

## Full release of the ISO

Run `./bin/omarchy-iso-release VERSION` to create, test, sign, and upload the ISO in one flow. Add `--rc` to release an RC build instead.
