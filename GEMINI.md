# Gemini Context: NixOS Configurations

This repository contains the NixOS system configurations for my personal infrastructure, managed using **Nix Flakes**. It supports multiple hosts including a main workstation, a laptop, and an AI server.

## Project Structure

*   **`flake.nix`**: The entry point for the configuration. Defines the `nixosConfigurations` outputs for each host.
*   **`hosts/`**: Contains machine-specific configurations.
    *   `sam_main/`: Main workstation configuration (Hyprland, Plasma 6, NVIDIA).
    *   `AIServer/`: AI Server configuration (Headless/XRDP, GPU support).
    *   `framework13/`: Laptop configuration.
*   **`home_manager/`**: User environment configuration (Home Manager).
*   **`gpu_configs/`**: Reusable modules for different GPU vendors (AMD, Intel, NVIDIA).
*   **`docs/`**: Documentation and architectural diagrams (Mermaid).

## Key Commands

### System Management

*   **Apply Configuration:**
    ```bash
    # Replace <hostname> with the target host (e.g., sam-main, AIServer)
    sudo nixos-rebuild switch --flake .#<hostname>
    ```

*   **Update Dependencies:**
    ```bash
    nix flake update
    ```

*   **Garbage Collection:**
    ```bash
    nix-collect-garbage -d
    ```

## Hosts Overview

| Hostname | Role | Key Features |
| :--- | :--- | :--- |
| **sam-main** | Workstation | Hyprland, Plasma 6, NVIDIA GPU, Gaming (Steam, RetroArch), Dev Tools |
| **AIServer** | Server | XRDP, Plasma 6, Multi-GPU support (AMD/Intel/NVIDIA), Docker |
| **framework13** | Laptop | Framework 13 specific hardware config |

## Development Workflow

As documented in `docs/ops_workflow.mmd`, the general workflow is:

1.  Modify configuration on a **Dev Machine**.
2.  Push changes to **Git**.
3.  Pull and apply changes on the **Target Machine** using `nixos-rebuild`.

## Conventions

*   **Flakes:** This project relies on Nix Flakes. Ensure `nix-command` and `flakes` experimental features are enabled (configured in `configuration.nix`).
*   **Modular Config:** Common configurations (like GPUs) are extracted into shared files in `gpu_configs/` or imported as modules.
*   **Secrets:** _Note: Review how secrets are managed (e.g., `git-crypt`, `sops-nix`, or manual management) before committing sensitive data._
