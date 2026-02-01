{ configs, pkgs, ... };
{
  home.username = "sam";
  home.homeDirectory = "/home/sam";

  home.stateVersion = "25.11";
  programs.home-manager.enable = true;
}
