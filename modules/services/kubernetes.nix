{ config, pkgs, lib, ... }:

with lib;

let
  cfg = config.services.my-k3s;
in
{
  options.services.my-k3s = {
    enable = mkEnableOption "K3s Kubernetes Service";
    
    role = mkOption {
      type = types.enum [ "server" "agent" ];
      default = "server";
      description = "K3s node role: server (master) or agent (worker)";
    };

    serverAddr = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "Server address for agents to join (e.g., https://master:6443)";
    };

    token = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "K3s cluster token (literal string or path to token file)";
    };

    clusterInit = mkOption {
      type = types.bool;
      default = false;
      description = "Whether to initialize a new HA cluster (required for the first server in a multi-master setup)";
    };

    disableTraefik = mkOption {
      type = types.bool;
      default = false;
      description = "Disable Traefik ingress controller (useful if using another ingress like Caddy)";
    };
    
    useDocker = mkOption {
      type = types.bool;
      default = false;
      description = "Use Docker as the container runtime for K3s (requires Docker to be enabled on the host)";
    };

    nvidiaSupport = mkOption {
      type = types.bool;
      default = false;
      description = "Enable NVIDIA GPU support for K3s workloads";
    };
  };

  config = mkIf cfg.enable {
    # Kubernetes tools
    environment.systemPackages = with pkgs; [
      kubectl
      kubernetes-helm
      k3s
    ];

    services.k3s = {
      enable = true;
      role = cfg.role;
      serverAddr = if cfg.role == "agent" then cfg.serverAddr else "";
      token = if cfg.token != null && !(lib.hasPrefix "/" cfg.token) then cfg.token else "";
      tokenFile = if cfg.token != null && (lib.hasPrefix "/" cfg.token) then cfg.token else null;
      
      extraFlags = (if cfg.clusterInit then "--cluster-init " else "") + 
                   (if cfg.disableTraefik then "--disable traefik " else "") +
                   (if cfg.useDocker then "--docker " else "") +
                   (if cfg.nvidiaSupport && !cfg.useDocker then "--container-runtime-endpoint unix:///run/containerd/containerd.sock " else ""); 
    };

    # Firewall rules for K3s
    networking.firewall.allowedTCPPorts = [
      6443 # k3s API
    ] ++ (if cfg.role == "server" then [ 2379 2380 ] else []); # etcd if HA
    
    networking.firewall.allowedUDPPorts = [
      8472 # flannel vxlan
    ];

    # K3s uses some kernel features that might need explicit enabling if not already
    boot.kernelModules = [ "overlay" "br_netfilter" ];
    boot.kernel.sysctl = {
      "net.bridge.bridge-nf-call-iptables" = 1;
      "net.ipv4.ip_forward" = 1;
      "net.bridge.bridge-nf-call-ip6tables" = 1;
    };

    # If useDocker is true, we assume Docker is enabled elsewhere (like in hosts/AIServer/docker.nix)
    # If not using Docker but needing NVIDIA, we use containerd with nvidia-container-toolkit.
    
    virtualisation.containerd = mkIf (cfg.nvidiaSupport && !cfg.useDocker) {
      enable = true;
      settings = {
        plugins."io.containerd.grpc.v1.cri".containerd.runtimes.nvidia = {
          runtime_type = "io.containerd.runtime.v1.linux";
          options.BinaryName = "${pkgs.nvidia-container-toolkit}/bin/nvidia-container-runtime";
        };
      };
    };
  };
}
