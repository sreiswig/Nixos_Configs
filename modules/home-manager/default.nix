{ config, pkgs, ... }:

{
  imports = [
    ./neovim.nix
    ./plasma.nix
  ];

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
      if [[ $(( RANDOM % 2 )) -eq 0 ]]; then
        echo -e "\033[48;5;18;97m* * * * * * * *\033[0m \033[31m==============================\033[0m"
        echo -e "\033[48;5;18;97m * * * * * * * \033[0m \033[97m==============================\033[0m"
        echo -e "\033[48;5;18;97m* * * * * * * *\033[0m \033[31m==============================\033[0m"
        echo -e "\033[48;5;18;97m * * * * * * * \033[0m \033[97m==============================\033[0m"
        echo -e "\033[48;5;18;97m* * * * * * * *\033[0m \033[31m==============================\033[0m"
        echo -e "\033[48;5;18;97m * * * * * * * \033[0m \033[97m==============================\033[0m"
        echo -e "\033[48;5;18;97m* * * * * * * *\033[0m \033[31m==============================\033[0m"
        echo -e "\033[97m==============================================\033[0m"
        echo -e "\033[31m==============================================\033[0m"
        echo -e "\033[97m==============================================\033[0m"
        echo -e "\033[31m==============================================\033[0m"
        echo -e "\033[97m==============================================\033[0m"
        echo -e "\033[31m==============================================\033[0m"
        echo -e "\n                \033[1;97mSam's Homelab\033[0m"
      else
        echo -e "\033[1;33m         .---.         \033[0m"
        echo -e "\033[1;35m       /\\     /\\       \033[0m"
        echo -e "\033[1;35m      |  \\___/  |      \033[0m"
        echo -e "\033[1;35m     /           \\     \033[0m"
        echo -e "\033[1;35m    |   O     O   |    \033[0m"
        echo -e "\033[1;35m    |    \\___/    |    \033[0m"
        echo -e "\033[1;35m     \\           /     \033[0m"
        echo -e "\033[1;35m      '---------'      \033[0m"
        echo -e "\n                \033[1;35mWAH!\033[0m"
      fi
    '';
  };

  programs.home-manager.enable = true;
}