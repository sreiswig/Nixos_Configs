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

# Test dad_nas
make vm-dad_nas

# Test asus_rog_1070
make vm-asus_rog_1070
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

## Post-Consolidation Verification Checklist

After applying changes, use this checklist to ensure all components are functional and correctly centralized.

### 1. Common Services (All Hosts)
- **Tailscale**: Run `tailscale status`. You should see your mesh network nodes.
- **OpenSSH**: 
  - Try `ssh localhost`. It should prompt for your key/password (based on your config).
  - Verify security settings: `sshd -T | grep -E "passwordauthentication|permitrootlogin"`.

### 2. Common CLI Tools (All Hosts)
Verify the following tools are available in your PATH:
```bash
# Core Tools
vault --version
yazi --version
zellij --version
gh --version
lazygit --version

# Env Check
echo $EDITOR        # Should be 'lvim'
echo $VAULT_ADDR    # Should be 'https://aiserver.tail93ec7d.ts.net/vault'
```

### 3. Secret Management (Vault)
- **Connectivity**: Run `vault status`. It should return the status of the server on `AIServer`.
- **Authentication**: Run `vault login` to verify you can authenticate using your preferred method.

### 4. Host-Specific Verification

#### sam-main / framework13 (Desktop)
- **Graphical Apps**: Verify `discord`, `obsidian`, and `google-chrome` are available in the application launcher.
- **Gaming**: Run `steam` to ensure the program starts.
- **Dev Tools**: Verify `vscode` (via `code`) and `hugo` are available.

#### AIServer (Services)
- **Web Entry**: Visit `https://aiserver.tail93ec7d.ts.net` (requires Tailscale).
- **Service Status**: Check systemd units for key services:
  ```bash
  systemctl status caddy
  systemctl status vault
  systemctl status gitea
  systemctl status n8n
  systemctl status neo4j
  ```

## Advanced / Automated Testing

### CI/CD (GitHub Actions)
We have configured a GitHub Actions workflow (`.github/workflows/ci.yml`) that automatically tests your configuration on every push and pull request to `main`.

It performs the following checks:
1.  **Flake Check:** Verifies syntax and dependency resolution (with a committed `flake.lock`).
2.  **Dry Build:** Compiles the system configuration for a **three-host matrix**: `sam-main`, `framework13`, and `AIServer` (`fail-fast: false` so one host failure does not cancel the others).

`asus_rog_1070` and `dad_nas` remain in the flake but are **intentionally excluded** from the CI matrix for now.

You can view the status of these checks in the "Actions" tab of your GitHub repository.
