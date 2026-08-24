# Makefile — Debian Trixie QEMU VM lifecycle management
# Targets: init, install, start, stop, help

SHELL := /bin/bash

# ──────────────────────────────────────────────
# Host detection
# ──────────────────────────────────────────────
HOST_OS   := $(shell uname -s)
HOST_ARCH := $(shell uname -m)

# Normalize arm64 (macOS) → aarch64
ifeq ($(HOST_ARCH),arm64)
  HOST_ARCH := aarch64
endif

# Select QEMU system binary and machine type
ifeq ($(HOST_ARCH),aarch64)
  QEMU_BIN    := qemu-system-aarch64
  MACHINE     := virt
  CPU         := max
  DEBIAN_ARCH := arm64
  INSTALL_DIR := install.a64
  CONSOLE     := ttyAMA0
else
  QEMU_BIN    := qemu-system-x86_64
  MACHINE     := pc
  CPU         := host
  DEBIAN_ARCH := amd64
  INSTALL_DIR := install.amd
  CONSOLE     := ttyS0
endif

# Accelerator: hvf on macOS, kvm on Linux
ifeq ($(HOST_OS),Darwin)
  ACCEL := hvf
  # EDK2 firmware path (installed by brew install qemu)
  EFI_CODE := $(firstword $(wildcard \
    /opt/homebrew/share/qemu/edk2-$(HOST_ARCH)-code.fd \
    /usr/local/share/qemu/edk2-$(HOST_ARCH)-code.fd))
else
  ACCEL := kvm
  EFI_CODE := $(firstword $(wildcard \
    /usr/share/qemu/OVMF_CODE.fd \
    /usr/share/OVMF/OVMF_CODE.fd \
    /usr/share/edk2/$(HOST_ARCH)/OVMF_CODE.fd))
endif

# EFI vars image (writable copy, created by init)
EFI_VARS := efi-vars.fd

# EFI flash args for start target (arm64 needs firmware; x86 uses SeaBIOS by default)
ifeq ($(HOST_ARCH),aarch64)
  EFI_ARGS = -drive if=pflash,format=raw,file=$(EFI_CODE),readonly=on \
             -drive if=pflash,format=raw,file=$(EFI_VARS)
else
  EFI_ARGS :=
endif

# ──────────────────────────────────────────────
# Configuration
# ──────────────────────────────────────────────
DISK_IMG     := disk.img
DISK_SIZE    := 192G
RAM          := 8G
CPUS         := 8
SSH_PORT     := 2222
ISO_DIR      := iso
PID_FILE     := qemu.pid
MON_SOCKET   := qemu.mon
PRESEED_PORT := 8765

# Debian Trixie latest stable release netinst ISO
ISO_BASE_URL := https://cdimage.debian.org/debian-cd/current/$(DEBIAN_ARCH)/iso-cd
ISO_SENTINEL := $(ISO_DIR)/.iso-downloaded
SHA256_FILE  := $(ISO_DIR)/SHA256SUMS
# Resolved at runtime after download
ISO_FILE      = $(shell ls $(ISO_DIR)/debian-*-netinst.iso 2>/dev/null | head -1)

# Temp files for kernel/initrd extracted from ISO
_VMLINUZ := /tmp/debian-qemu-vmlinuz
_INITRD  := /tmp/debian-qemu-initrd.gz

# ──────────────────────────────────────────────
# Common QEMU drive / network args (reused by install + start)
# ──────────────────────────────────────────────
QEMU_DRIVE := -drive file=$(DISK_IMG),format=qcow2,if=virtio
QEMU_NET   := -device virtio-net,netdev=net0 \
              -netdev user,id=net0,hostfwd=tcp::$(SSH_PORT)-:22

# ──────────────────────────────────────────────
.PHONY: help init install start stop kill _extract-iso

.DEFAULT_GOAL := help

help: ## Show this help message
	@echo ""
	@echo "Debian Trixie QEMU VM — available targets:"
	@echo ""
	@awk 'BEGIN {FS = ":.*##"} /^[a-zA-Z_-]+:.*##/ { printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2 }' $(MAKEFILE_LIST)
	@echo ""
	@echo "Detected: OS=$(HOST_OS)  ARCH=$(HOST_ARCH)  QEMU=$(QEMU_BIN)  ACCEL=$(ACCEL)"
	@if [ -n "$(EFI_CODE)" ]; then echo "EFI firmware: $(EFI_CODE)"; fi
	@echo ""

# ──────────────────────────────────────────────
init: ## Create the VM disk image (192G qcow2). Skips if already exists.
	@if [ -f "$(DISK_IMG)" ]; then \
	  echo "$(DISK_IMG) already exists — skipping init."; \
	else \
	  echo "Creating $(DISK_IMG) ($(DISK_SIZE), qcow2)..."; \
	  qemu-img create -f qcow2 $(DISK_IMG) $(DISK_SIZE); \
	  echo "Done."; \
	fi
ifeq ($(HOST_ARCH),aarch64)
	@if [ ! -f "$(EFI_VARS)" ]; then \
	  if [ -z "$(EFI_CODE)" ]; then \
	    echo "ERROR: EDK2 firmware not found. Install: brew install qemu (macOS) or apt install ovmf (Linux)"; exit 1; \
	  fi; \
	  echo "Creating writable EFI vars image..."; \
	  cp "$(EFI_CODE)" "$(EFI_VARS)" && chmod +w "$(EFI_VARS)"; \
	  echo "Created $(EFI_VARS)."; \
	fi
endif
	@echo "Run 'make install' to install Debian."

# ──────────────────────────────────────────────
# Extract vmlinuz + initrd from ISO to temp files (platform-specific)
_extract-iso:
	@if [ -z "$(ISO_FILE)" ]; then echo "ERROR: No ISO found in $(ISO_DIR)/"; exit 1; fi
	@echo "Extracting kernel and initrd from $(ISO_FILE)..."
	@if command -v bsdtar &>/dev/null; then \
	  bsdtar -xf "$(ISO_FILE)" --include "$(INSTALL_DIR)/vmlinuz" -O > "$(_VMLINUZ)" && \
	  bsdtar -xf "$(ISO_FILE)" --include "$(INSTALL_DIR)/initrd.gz" -O > "$(_INITRD)"; \
	elif command -v xorriso &>/dev/null; then \
	  xorriso -osirrox on -indev "$(ISO_FILE)" \
	    -extract /$(INSTALL_DIR)/vmlinuz  "$(_VMLINUZ)" \
	    -extract /$(INSTALL_DIR)/initrd.gz "$(_INITRD)" -- 2>/dev/null; \
	elif command -v isoinfo &>/dev/null; then \
	  isoinfo -i "$(ISO_FILE)" -x /$(INSTALL_DIR)/VMLINUZ   > "$(_VMLINUZ)" && \
	  isoinfo -i "$(ISO_FILE)" -x /$(INSTALL_DIR)/INITRD.GZ > "$(_INITRD)"; \
	else \
	  echo "ERROR: No ISO extraction tool found. Install bsdtar, xorriso, or genisoimage."; exit 1; \
	fi
	@ls -lh "$(_VMLINUZ)" "$(_INITRD)"
	@echo "Extraction complete."

# ──────────────────────────────────────────────
install: $(DISK_IMG) $(ISO_SENTINEL) _extract-iso ## Install Debian Trixie (headless, automated via preseed).
	@echo "──────────────────────────────────────────"
	@echo " Starting Debian Trixie headless install"
	@echo " ISO: $(ISO_FILE)"
	@echo " Preseed HTTP server on port $(PRESEED_PORT)"
	@echo " Press Ctrl-A X to quit QEMU if needed."
	@echo "──────────────────────────────────────────"
	@python3 -m http.server $(PRESEED_PORT) --bind 127.0.0.1 &>/tmp/preseed-http.log & \
	  PRESEED_PID=$$!; \
	  trap "kill $$PRESEED_PID 2>/dev/null; exit" INT TERM EXIT; \
	  sleep 1; \
	  $(QEMU_BIN) \
	    -machine $(MACHINE) \
	    -cpu $(CPU) \
	    -accel $(ACCEL) \
	    -m $(RAM) \
	    -smp $(CPUS) \
	    $(QEMU_DRIVE) \
	    $(QEMU_NET) \
	    -cdrom "$(ISO_FILE)" \
	    -kernel "$(_VMLINUZ)" \
	    -initrd "$(_INITRD)" \
	    -append "auto=true priority=critical url=http://10.0.2.2:$(PRESEED_PORT)/preseed.cfg console=$(CONSOLE),115200n8" \
	    -display none \
	    -serial mon:stdio; \
	  kill $$PRESEED_PID 2>/dev/null || true
	@echo ""
	@echo "Installation complete. Run 'make start' to boot the VM."
	@echo "SSH: ssh -p $(SSH_PORT) user@localhost"

# ──────────────────────────────────────────────
start: $(DISK_IMG) ## Start the VM (8 GB RAM, 8 vCPUs, virtio-net, SSH on port 2222).
	@if [ -f "$(PID_FILE)" ] && kill -0 $$(cat $(PID_FILE)) 2>/dev/null; then \
	  echo "VM is already running (PID $$(cat $(PID_FILE)))."; \
	  exit 1; \
	fi
ifeq ($(HOST_ARCH),aarch64)
	@if [ -z "$(EFI_CODE)" ] || [ ! -f "$(EFI_VARS)" ]; then \
	  echo "ERROR: EFI firmware missing. Run 'make init' first."; exit 1; \
	fi
endif
	@echo "Starting VM..."
	@$(QEMU_BIN) \
	  -machine $(MACHINE) \
	  -cpu $(CPU) \
	  -accel $(ACCEL) \
	  -m $(RAM) \
	  -smp $(CPUS) \
	  $(QEMU_DRIVE) \
	  $(QEMU_NET) \
	  $(EFI_ARGS) \
	  -monitor unix:$(MON_SOCKET),server,nowait \
	  -display none \
	  -serial none \
	  -daemonize \
	  -pidfile $(PID_FILE)
	@echo "VM started. PID: $$(cat $(PID_FILE))"
	@echo "SSH:  ssh -p $(SSH_PORT) user@localhost"
	@echo "Stop: make stop  (graceful ACPI)"
	@echo "Kill: make kill  (force)"

# ──────────────────────────────────────────────
stop: ## Gracefully shut down the VM via ACPI (falls back to SIGTERM).
	@if [ -S "$(MON_SOCKET)" ]; then \
	  echo "Sending ACPI power-down via QMP..."; \
	  echo '{"execute":"qmp_capabilities"}{"execute":"system_powerdown"}' | \
	    socat - UNIX-CONNECT:$(MON_SOCKET) > /dev/null 2>&1 && \
	    echo "Shutdown signal sent." || true; \
	elif [ -f "$(PID_FILE)" ]; then \
	  PID=$$(cat $(PID_FILE)); \
	  if kill -0 $$PID 2>/dev/null; then \
	    echo "QMP socket not found — sending SIGTERM to PID $$PID..."; \
	    kill $$PID; \
	  else \
	    echo "VM is not running."; \
	  fi; \
	else \
	  echo "No running VM found (no $(MON_SOCKET) or $(PID_FILE))."; \
	fi
	@rm -f $(MON_SOCKET) $(PID_FILE)

# ──────────────────────────────────────────────
kill: ## Force-kill the VM immediately (SIGKILL via qemu.pid).
	@if [ ! -f "$(PID_FILE)" ]; then \
	  echo "No PID file found ($(PID_FILE)). Is the VM running?"; exit 1; \
	fi
	@PID=$$(cat $(PID_FILE)); \
	  if kill -0 $$PID 2>/dev/null; then \
	    echo "Force-killing QEMU PID $$PID..."; \
	    kill -9 $$PID && echo "Killed." || echo "Failed to kill PID $$PID."; \
	  else \
	    echo "PID $$PID is not running."; \
	  fi
	@rm -f $(PID_FILE) $(MON_SOCKET)

# ──────────────────────────────────────────────
# Implicit rules for prerequisites
# ──────────────────────────────────────────────
$(DISK_IMG):
	@$(MAKE) init

$(ISO_DIR):
	@mkdir -p $(ISO_DIR)

$(ISO_SENTINEL): | $(ISO_DIR)
	@echo "Downloading Debian Trixie netinst ISO for $(DEBIAN_ARCH)..."
	@cd $(ISO_DIR) && \
	  ISO_NAME=$$(curl -fsSL "$(ISO_BASE_URL)/" | \
	    grep -oE 'debian-[0-9]+\.[0-9]+\.[0-9]+-$(DEBIAN_ARCH)-netinst\.iso' | head -1) && \
	  if [ -z "$$ISO_NAME" ]; then \
	    echo "ERROR: Could not find ISO filename at $(ISO_BASE_URL)/"; exit 1; \
	  fi && \
	  echo "Downloading $$ISO_NAME ..." && \
	  curl -fL --progress-bar -o "$$ISO_NAME" "$(ISO_BASE_URL)/$$ISO_NAME" && \
	  echo "Downloading SHA256SUMS..." && \
	  curl -fsSL -o SHA256SUMS "$(ISO_BASE_URL)/SHA256SUMS" && \
	  echo "Verifying checksum..." && \
	  grep "$$ISO_NAME" SHA256SUMS | sha256sum -c - && \
	  echo "ISO verified OK." && \
	  touch .iso-downloaded

