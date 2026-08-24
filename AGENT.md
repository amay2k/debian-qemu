# AGENT.md — Debian QEMU project source of truth

This file is the **canonical project guide and decision log** for this repository.
When implementation decisions change, update this file in the same change.

## Project goal

Manage a Debian Trixie QEMU VM lifecycle via Make targets (`init`, `install`, `start`, `console`, `stop`, `kill`).

## Runtime profile

| Requirement | Value |
|---|---|
| Disk size | 192 GB (`qcow2`) |
| Debian version | Trixie (current stable netinst image for selected arch) |
| Install method | Headless, console-based, automated via `preseed.cfg` |
| Provisioned packages | `openssh-server`, `tmux` (+ standard tasksel set) |
| SSH key auth | If `~/.ssh/id_ed25519.pub` exists on the host at install time, it's installed as an authorized key for `user`. |
| RAM / vCPUs | 8 GB / 8 |
| Network device | `virtio-net` |
| SSH access | Host `localhost:2222` -> guest `:22` |
| Firmware | `amd64`: BIOS default, `aarch64`: EDK2 UEFI (`pflash`) |
| Host detection | Auto-detect OS and architecture (`uname -s`, `uname -m`) |
| VM user | `user` (password `user` in preseed baseline) |

## Build, test, and lint commands

There is no separate build/test/lint framework. Validation is target-based through `make`.

| Command | Purpose |
|---|---|
| `make help` | Show target list and detected host/QEMU settings. |
| `make init` | Create/recreate `disk.img`; initialize EFI vars on `aarch64`. |
| `make install` | Download+verify ISO (cached), extract installer kernel/initrd, run unattended install. |
| `make start` | Boot installed VM in daemon mode. |
| `make console` | Attach to serial socket console. |
| `make ssh` | SSH into the running VM (`user@localhost:2222`). |
| `make stop` | Graceful ACPI shutdown via QMP (fallback `SIGTERM`). |
| `make kill` | Force-stop QEMU process from PID file. |

For a "single test", run the specific workflow target you changed (for example `make start` after touching runtime args, or `make install` after changing preseed/install args).

## High-level architecture

1. **Control plane in `Makefile`**  
   Host/arch detection selects QEMU binary, machine model, CPU, install directory (`install.a64`/`install.amd`), console device, accelerator (`hvf`/`kvm`), and firmware arguments.
2. **Installer policy in `preseed.cfg`**  
   Guest configuration (accounts, packages, partitioning, bootloader defaults) is declarative in preseed and injected via `INSTALL_APPEND` kernel args.
3. **Install pipeline (`make install`)**  
   `disk.img` + ISO cache + `_extract-iso` are prerequisites. The target serves preseed over local HTTP (`127.0.0.1:8765`) and boots installer kernel/initrd directly.
4. **Runtime pipeline (`make start`)**  
   VM boots from `disk.img` with user-mode networking/SSH forwarding and uses local control artifacts (`qemu.pid`, `qemu.mon`, `qemu.console`) for lifecycle commands.
5. **State artifacts**  
   `disk.img`, `efi-vars.fd`, ISO cache, sockets, pidfile, and extracted `/tmp` installer files are stateful operational artifacts, not source code.

## Key conventions

- Keep shared QEMU arguments in Make variables (`QEMU_DRIVE`, `QEMU_NET`, `EFI_ARGS`, `INSTALL_APPEND`) rather than duplicating CLI fragments.
- Preserve cross-architecture parity when editing install/start behavior (`amd64` and `aarch64` branches).
- Treat `preseed.cfg` as the source of guest baseline behavior; Makefile should transport, not duplicate, guest policy.
- Keep terminal/tmux restore handling intact in interactive targets (`install`, `console`).
- Record any new architectural or behavioral decision in **Decision log** below.

## Decision log

| Date | Decision |
|---|---|
| 2026-08-24 | Use unattended preseed install served by local HTTP rather than ISO repack. |
| 2026-08-24 | Cache ISO in `iso/` and verify checksums before install. |
| 2026-08-24 | Use QMP socket (`qemu.mon`) for graceful shutdown path. |
| 2026-08-24 | On `aarch64`, run both install and start with EDK2 UEFI pflash and writable `efi-vars.fd`. |
| 2026-08-24 | Force EFI/removable GRUB fallback in arm64 installer args to avoid UEFI shell on first boot when NVRAM entries are missing. |
| 2026-08-24 | `AGENT.md` is the canonical place to track future technical decisions for Copilot sessions. |

## Change log

| Date | Change |
|---|---|
| 2026-08-24 | Initial project setup: `Makefile`, `preseed.cfg`, `AGENT.md`. |
| 2026-08-24 | Added arm64 UEFI install/start fixes and removable EFI GRUB fallback. |
| 2026-08-24 | Consolidated Copilot guidance into `AGENT.md`; `copilot-instructions.md` now references this file. |
| 2026-08-24 | Added `make ssh` target to connect to the running VM; disables host key checking since `disk.img` is reprovisioned and regenerates SSH host keys. |
| 2026-08-24 | `make install` stages `~/.ssh/id_ed25519.pub` (if present) as `authorized_keys`, served by the preseed HTTP server; preseed's `late_command` fetches it into `/home/user/.ssh/authorized_keys` on the guest. Staged file is gitignored and removed after install. |
