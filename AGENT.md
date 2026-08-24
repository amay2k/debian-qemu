# AGENT.md — Debian QEMU Project Requirements

## Project Goal
Manage a Debian Trixie QEMU virtual machine lifecycle via a Makefile.

## User Requirements

| Requirement | Value |
|---|---|
| Disk size | 192 GB (qcow2) |
| Debian version | Trixie (testing/13) |
| Install method | Headless, console-based, automated via preseed |
| ISO | Downloaded if not cached; headless netinst |
| Provisioned packages | tmux (+ openssh-server for remote access) |
| RAM | 8 GB |
| vCPUs | 8 |
| Network device | virtio-net |
| SSH access | Port-forward host:2222 → guest:22 |
| Firmware | BIOS/SeaBIOS (no UEFI) |
| Host detection | Auto-detect OS (macOS/Linux) and architecture (x86_64/arm64) |
| VM user | `user` |

## Makefile Targets

| Target | Description |
|---|---|
| `make init` | Create `disk.img` (qcow2, 192G). Idempotent — skips if already exists. |
| `make install` | Download Trixie netinst ISO (cached in `iso/`), serve preseed via local HTTP, run headless QEMU install. |
| `make start` | Start VM with 8 GB RAM, 8 vCPUs, virtio-net, SSH port-forward. PID saved to `qemu.pid`. |
| `make stop` | Graceful ACPI shutdown via QMP socket; falls back to SIGTERM on `qemu.pid`. |
| `make help` | Print usage summary. |

## Design Decisions

- **preseed.cfg**: Debian automated installer answers file; served via `python3 -m http.server` on localhost during install so no ISO repack is needed.
- **ISO caching**: ISO downloaded to `iso/` and verified by SHA256 before use.
- **QMP socket**: `qemu.mon` UNIX socket used for graceful shutdown via `system_powerdown`.
- **Architecture detection**: `uname -m` selects QEMU binary (`qemu-system-x86_64` or `qemu-system-aarch64`) and machine type (`pc` or `virt`).
- **No desktop**: Minimal install — standard system utilities + SSH + tmux only.

## Files

| File | Purpose |
|---|---|
| `Makefile` | Build targets for VM lifecycle management |
| `preseed.cfg` | Debian installer automation |
| `disk.img` | VM disk image (gitignored, created by `make init`) |
| `iso/` | Cached Debian ISO directory (gitignored) |
| `qemu.pid` | PID file for running QEMU process |
| `qemu.mon` | QMP UNIX socket for VM control |
| `AGENT.md` | This file — requirements and design tracking |

## Change Log

| Date | Change |
|---|---|
| 2026-08-24 | Initial project setup: Makefile, preseed.cfg, AGENT.md |
