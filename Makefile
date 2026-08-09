# Makefile for NixOS Configuration Testing

.PHONY: help switch upgrade current-host \
	vm-sam-main vm-framework13 vm-aiserver vm-dad_nas vm-asus_rog_1070 \
	build-sam-main build-framework13 build-aiserver build-dad_nas build-asus_rog_1070 \
	clean

# Map networking.hostName / hostname(1) to flake attribute names in flake.nix
# (they don't always match — e.g. sam_nixos → sam-main)
CURRENT_HOSTNAME := $(shell cat /etc/hostname 2>/dev/null || hostname)
HOST_FLAKE := $(shell \
	h="$(CURRENT_HOSTNAME)"; \
	if [ "$$h" = "sam_nixos" ] || [ "$$h" = "samnixos" ] || [ "$$h" = "sam-main" ] || [ "$$h" = "sam_main" ]; then echo sam-main; \
	elif [ "$$h" = "framework13" ]; then echo framework13; \
	elif [ "$$h" = "AI_Server" ] || [ "$$h" = "AIServer" ] || [ "$$h" = "ai_server" ]; then echo AIServer; \
	elif [ "$$h" = "queennas" ] || [ "$$h" = "dad_nas" ]; then echo dad_nas; \
	elif [ "$$h" = "asus-rog-1070" ] || [ "$$h" = "asus_rog_1070" ]; then echo asus_rog_1070; \
	fi)

# Default target
help:
	@echo "Available targets:"
	@echo "  switch           - Apply this flake to the current host (nixos-rebuild switch)"
	@echo "  upgrade          - Update flake inputs, then switch the current host"
	@echo "  current-host     - Show detected hostname → flake attribute mapping"
	@echo "  vm-sam-main      - Build and run a VM for sam-main"
	@echo "  vm-framework13   - Build and run a VM for framework13"
	@echo "  vm-aiserver      - Build and run a VM for AIServer"
	@echo "  vm-dad_nas       - Build and run a VM for dad_nas"
	@echo "  vm-asus_rog_1070 - Build and run a VM for asus_rog_1070"
	@echo "  build-sam-main   - Build for sam-main (checks syntax/deps)"
	@echo "  build-framework13- Build for framework13"
	@echo "  build-aiserver   - Build for AIServer"
	@echo "  build-dad_nas    - Build for dad_nas"
	@echo "  build-asus_rog_1070 - Build for asus_rog_1070"
	@echo "  clean            - Remove 'result' symlinks"

# Resolve flake attr for this machine (fails clearly if unknown)
define require-host-flake
	@if [ -z "$(HOST_FLAKE)" ]; then \
		echo "error: unknown host '$(CURRENT_HOSTNAME)' — add a mapping in the Makefile"; \
		echo "  known flake attrs: sam-main framework13 AIServer dad_nas asus_rog_1070"; \
		exit 1; \
	fi
	@echo "host: $(CURRENT_HOSTNAME) → flake: .#$(HOST_FLAKE)"
endef

current-host:
	$(require-host-flake)

# Apply current locked inputs to this machine
switch:
	$(require-host-flake)
	sudo nixos-rebuild switch --flake .#$(HOST_FLAKE)

# Bump flake.lock, then apply to this machine
upgrade:
	$(require-host-flake)
	nix flake update
	sudo nixos-rebuild switch --flake .#$(HOST_FLAKE)

# VM Targets
vm-sam-main:
	nixos-rebuild build-vm --flake .#sam-main
	./result/bin/run-sam_main-vm

vm-framework13:
	nixos-rebuild build-vm --flake .#framework13
	./result/bin/run-framework13-vm

vm-aiserver:
	nixos-rebuild build-vm --flake .#AIServer
	./result/bin/run-AIServer-vm

vm-dad_nas:
	nixos-rebuild build-vm --flake .#dad_nas
	./result/bin/run-queennas-vm

vm-asus_rog_1070:
	nixos-rebuild build-vm --flake .#asus_rog_1070
	./result/bin/run-asus-rog-1070-vm

# Build Targets (Dry Run)
build-sam-main:
	nixos-rebuild build --flake .#sam-main

build-framework13:
	nixos-rebuild build --flake .#framework13

build-aiserver:
	nixos-rebuild build --flake .#AIServer

build-dad_nas:
	nixos-rebuild build --flake .#dad_nas

build-asus_rog_1070:
	nixos-rebuild build --flake .#asus_rog_1070

# Cleanup
clean:
	rm -f result
