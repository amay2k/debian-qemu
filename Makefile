# Makefile — Debian Trixie QEMU VM lifecycle management
# Targets: init, install, start, stop, help

# ──────────────────────────────────────────────
# Host detection
# ──────────────────────────────────────────────
HOST_OS   := $(shell uname -s)
HOST_ARCH := $(shell uname -m)

# Normalize arm64 (macOS) → aarch64
ifeq ($(HOST_ARCH),arm64)
  HOST_ARCH := aarch64
endif

# Select QEMU system binary
ifeq ($(HOST_ARCH),aarch64)
  QEMU_BIN  := qemu-system-aarch64
  MACHINE   := virt
  CPU       := max
  BIOS_ARGS :=
  DEBIAN_ARCH := arm64
else
  QEMU_BIN  := qemu-system-x86_64
  MACHINE   := pc
  CPU       := host
  BIOS_ARGS :=
  DEBIAN_ARCH := amd64
endif

# On macOS use hvf accelerator; on Linux use kvm
ifeq ($(HOST_OS),Darwin)
  ACCEL := hvf
else
  ACCEL := kvm
endif

# ──────────────────────────────────────────────
# Configuration
# ──────────────────────────────────────────────
DISK_IMG    := disk.img
DISK_SIZE   := 192G
RAM         := 8G
CPUS        := 8
SSH_PORT    := 2222
ISO_DIR     := iso
PID_FILE    := qemu.pid
MON_SOCKET  := qemu.mon
PRESEED_PORT := 8765

# Debian Trixie daily netinst ISO
ISO_BASE_URL := https://cdimage.debian.org/cdimage/daily-builds/daily/arch-latest/$(DEBIAN_ARCH)/iso-cd
ISO_FILE     := $(ISO_DIR)/debian-trixie-netinst.iso
SHA256_FILE  := $(ISO_DIR)/SHA256SUMS

# ──────────────────────────────────────────────
# Common QEMU drive / network args (reused by install + start)
# ──────────────────────────────────────────────
QEMU_DRIVE  := -drive file=$(DISK_IMG),format=qcow2,if=virtio
QEMU_NET    := -device virtio-net,netdev=net0 \
               -netdev user,id=net0,hostfwd=tcp::$(SSH_PORT)-:22

# ──────────────────────────────────────────────
.PHONY: help init install start stop

.DEFAULT_GOAL := help

help: ## Show this help message
	@echo ""
	@echo "Debian Trixie QEMU VM — available targets:"
	@echo ""
	@awk 'BEGIN {FS = ":.*##"} /^[a-zA-Z_-]+:.*##/ { printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2 }' $(MAKEFILE_LIST)
	@echo ""
	@echo "Detected: OS=$(HOST_OS)  ARCH=$(HOST_ARCH)  QEMU=$(QEMU_BIN)  ACCEL=$(ACCEL)"
	@echo ""

# ──────────────────────────────────────────────
init: ## Create the VM disk image (192G qcow2). Skips if already exists.
	@if [ -f "$(DISK_IMG)" ]; then \
	  echo "$(DISK_IMG) already exists — skipping init."; \
	else \
	  echo "Creating $(DISK_IMG) ($(DISK_SIZE), qcow2)..."; \
	  qemu-img create -f qcow2 $(DISK_IMG) $(DISK_SIZE); \
	  echo "Done. Run 'make install' to install Debian."; \
	fi

# ──────────────────────────────────────────────
install: $(DISK_IMG) $(ISO_FILE) ## Install Debian Trixie (headless, automated via preseed).
	@echo "──────────────────────────────────────────"
	@echo " Starting Debian Trixie headless install"
	@echo " Preseed HTTP server on port $(PRESEED_PORT)"
	@echo " Press Ctrl-A X to quit QEMU if needed."
	@echo "──────────────────────────────────────────"
	@# Serve preseed.cfg via a background Python HTTP server
	@python3 -m http.server $(PRESEED_PORT) --bind 127.0.0.1 &> /tmp/preseed-http.log & \
	  PRESEED_PID=$$!; \
	  echo "preseed HTTP server PID: $$PRESEED_PID"; \
	  trap "kill $$PRESEED_PID 2>/dev/null" EXIT; \
	  sleep 1; \
	  $(QEMU_BIN) \
	    -machine $(MACHINE) \
	    -cpu $(CPU) \
	    -accel $(ACCEL) \
	    -m $(RAM) \
	    -smp $(CPUS) \
	    $(QEMU_DRIVE) \
	    $(QEMU_NET) \
	    -cdrom $(ISO_FILE) \
	    -boot order=d \
	    -kernel <(isoinfo -i $(ISO_FILE) -x /install.$(DEBIAN_ARCH)/vmlinuz 2>/dev/null || \
	              isoinfo -i $(ISO_FILE) -x /install/vmlinuz 2>/dev/null) \
	    -initrd <(isoinfo -i $(ISO_FILE) -x /install.$(DEBIAN_ARCH)/initrd.gz 2>/dev/null || \
	              isoinfo -i $(ISO_FILE) -x /install/initrd.gz 2>/dev/null) \
	    -append "auto=true priority=critical url=http://10.0.2.2:$(PRESEED_PORT)/preseed.cfg console=ttyS0,115200n8" \
	    -nographic \
	    -serial stdio; \
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
	@echo "Starting VM..."
	@$(QEMU_BIN) \
	  -machine $(MACHINE) \
	  -cpu $(CPU) \
	  -accel $(ACCEL) \
	  -m $(RAM) \
	  -smp $(CPUS) \
	  $(QEMU_DRIVE) \
	  $(QEMU_NET) \
	  -monitor unix:$(MON_SOCKET),server,nowait \
	  -nographic \
	  -serial stdio \
	  -pidfile $(PID_FILE) \
	  -daemonize
	@echo "VM started. PID: $$(cat $(PID_FILE))"
	@echo "SSH: ssh -p $(SSH_PORT) user@localhost"
	@echo "Stop: make stop"

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
# Implicit rules for prerequisites
# ──────────────────────────────────────────────
$(DISK_IMG):
	@$(MAKE) init

$(ISO_DIR):
	@mkdir -p $(ISO_DIR)

$(ISO_FILE): | $(ISO_DIR)
	@echo "Downloading Debian Trixie netinst ISO for $(DEBIAN_ARCH)..."
	@cd $(ISO_DIR) && \
	  ISO_NAME=$$(curl -fsSL "$(ISO_BASE_URL)/" | \
	    grep -oP 'debian-[^"]*netinst[^"]*\.iso' | head -1) && \
	  if [ -z "$$ISO_NAME" ]; then \
	    echo "ERROR: Could not find ISO filename at $(ISO_BASE_URL)/"; exit 1; \
	  fi && \
	  echo "Downloading $$ISO_NAME ..." && \
	  curl -fL --progress-bar -o "$(notdir $(ISO_FILE))" "$(ISO_BASE_URL)/$$ISO_NAME" && \
	  echo "Downloading SHA256SUMS..." && \
	  curl -fsSL -o SHA256SUMS "$(ISO_BASE_URL)/SHA256SUMS" && \
	  echo "Verifying checksum..." && \
	  grep "$$ISO_NAME" SHA256SUMS | sha256sum -c - && \
	  echo "ISO verified OK."
