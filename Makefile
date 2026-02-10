# Makefile for NixOS Configuration Testing

.PHONY: help vm-sam-main vm-framework13 vm-aiserver build-sam-main build-framework13 build-aiserver clean

# Default target
help:
	@echo "Available targets:"
	@echo "  vm-sam-main      - Build and run a VM for sam-main"
	@echo "  vm-framework13   - Build and run a VM for framework13"
	@echo "  vm-aiserver      - Build and run a VM for AIServer"
	@echo "  build-sam-main   - Dry-run build for sam-main (checks syntax/deps)"
	@echo "  build-framework13- Dry-run build for framework13"
	@echo "  build-aiserver   - Dry-run build for AIServer"
	@echo "  clean            - Remove 'result' symlinks"

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

# Build Targets (Dry Run)
build-sam-main:
	nixos-rebuild build --flake .#sam-main

build-framework13:
	nixos-rebuild build --flake .#framework13

build-aiserver:
	nixos-rebuild build --flake .#AIServer

# Cleanup
clean:
	rm -f result
