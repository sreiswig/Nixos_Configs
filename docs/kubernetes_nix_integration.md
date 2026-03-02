# Kubernetes & Nix Integration Plan (nix2docker strategy)

This document outlines the strategy for using Nix to build container images and running them on the Kubernetes (K3s) cluster on the AI Server.

## 1. Kubernetes Setup

The AI Server is configured with **K3s**, a lightweight Kubernetes distribution.

-   **Role:** Single-node server.
-   **Container Runtime:** Docker (via `--docker` flag in K3s).
-   **Why Docker?** Using Docker as the runtime allows us to reuse the existing NVIDIA container toolkit configuration on the host, making GPU access from within Kubernetes pods straightforward.
-   **Ingress:** Traefik is disabled in favor of the existing Caddy reverse proxy, which provides TLS termination via Tailscale.

## 2. Nix-to-Docker Strategy (nix2docker)

To leverage Nix for building container images, we will use two primary approaches:

### A. `pkgs.dockerTools.buildImage` (Standard)
Nixpkgs provides a powerful set of tools to build OCI-compliant images without a Docker daemon.

Example Nix expression:
```nix
{ pkgs }:

pkgs.dockerTools.buildImage {
  name = "my-nix-app";
  tag = "latest";
  
  contents = [ pkgs.bash pkgs.coreutils ];
  
  config = {
    Cmd = [ "${pkgs.bash}/bin/bash" ];
  };
}
```

### B. `nix2container` (Performance)
For faster build times and smaller layers, we can use the `nix2container` project. It is more efficient than `dockerTools` for large images.

## 3. Deployment Workflow

### Step 1: Build the Image
```bash
nix build .#packages.x86_64-linux.my-container-image
```

### Step 2: Load into Kubernetes
Since K3s is configured to use Docker:
```bash
# Load the result (a tarball) into Docker
docker load < result

# K3s (using Docker) now sees the image
kubectl run test-app --image=my-nix-app:latest
```

### Step 3: CI/CD Integration
We can automate this process using GitHub Actions or a local Gitea Action.
1.  Nix build image.
2.  Push to Gitea Container Registry (on the AI Server).
3.  Kubernetes pulls image from Gitea.

## 4. Next Steps
- [ ] Configure Gitea Container Registry on AI Server.
- [ ] Implement a sample Nix-built container for an AI workload (e.g., a Python service with PyTorch).
- [ ] Set up Helm for managing complex deployments.
