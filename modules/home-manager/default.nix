{ config, pkgs, ... }:

{
  home.username = "sam";
  home.homeDirectory = "/home/sam";

  home.stateVersion = "24.11"; # Keeping it compatible with recent stable
  
  programs.starship = {
    enable = true;
    enableBashIntegration = true;
  };

  programs.zoxide = {
    enable = true;
    enableBashIntegration = true;
  };

  programs.direnv = {
    enable = true;
    nix-direnv.enable = true;
    enableBashIntegration = true;
  };

  programs.bash = {
    enable = true;
    shellAliases = {
      sl = "ls";
    };
    initExtra = ''
      echo "* * * * * * =================================="
      echo " * * * * *  =================================="
      echo "* * * * * * =================================="
      echo " * * * * *  =================================="
      echo "* * * * * * =================================="
      echo " * * * * *  =================================="
      echo "* * * * * * =================================="
      echo "=============================================="
      echo "=============================================="
      echo "=============================================="
      echo "=============================================="
      echo "=============================================="
      echo "=============================================="
    '';
  };

  programs.home-manager.enable = true;
}