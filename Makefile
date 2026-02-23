# Makefile for NixOS Configuration Testing

.PHONY: help vm-sam-main vm-framework13 vm-aiserver build-sam-main build-framework13 build-aiserver clean

# Default target
help:
	@echo "Available targets:"
	@echo "  vm-sam-main      - Build and run a VM for sam-main"
	@echo "  vm-framework13   - Build and run a VM for framework13"
	@echo "  vm-aiserver      - Build and run a VM for AIServer"
	@echo "  vm-dad_nas       - Build and run a VM for dad_nas"
	@echo "  vm-asus_rog_1070 - Build and run a VM for asus_rog_1070"
	@echo "  build-sam-main   - Dry-run build for sam-main (checks syntax/deps)"
	@echo "  build-framework13- Dry-run build for framework13"
	@echo "  build-aiserver   - Dry-run build for AIServer"
	@echo "  build-dad_nas    - Dry-run build for dad_nas"
	@echo "  build-asus_rog_1070 - Dry-run build for asus_rog_1070"
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
