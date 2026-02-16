# Testing NixOS Configurations

This document outlines how to test changes to the NixOS configurations in this repository before applying them to a live system.

## Manual Testing (Makefile)

We use a `Makefile` to simplify standard testing commands.

### 1. Virtual Machine (Recommended)
You can build and boot a lightweight QEMU virtual machine that runs your exact configuration. This is safe and does not affect your host system.

**Usage:**
```bash
# Test sam-main
make vm-sam-main

# Test framework13
make vm-framework13

# Test AIServer
make vm-aiserver
```
*Note: The VM usually opens in a new window. You can interact with it to verify boot, services, and UI.*

### 2. Build Check (Dry Run)
If you just want to verify that your code compiles and dependencies can be resolved:

**Usage:**
```bash
make build-sam-main
# or
make build-framework13
```

### 3. Cleaning Up
The build process creates a `result` symlink in the root directory. To remove it:
```bash
make clean
```

## Advanced / Automated Testing

### CI/CD (GitHub Actions)
We have configured a GitHub Actions workflow (`.github/workflows/ci.yml`) that automatically tests your configuration on every push.

It performs the following checks:
1.  **Flake Check:** Verifies syntax and dependency resolution.
2.  **Dry Build:** Compiles the system configuration for `sam-main`, `framework13`, and `AIServer` to ensure all modules and packages build correctly.

You can view the status of these checks in the "Actions" tab of your GitHub repository.

