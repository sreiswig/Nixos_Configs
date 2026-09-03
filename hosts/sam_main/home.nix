{ config, pkgs, ... }:

{
  # Link your existing config files
  # home.file.".config/lvim/config.lua".source = ../../program_configs/lvim/config.lua;

  programs.home-manager.enable = true;

  programs.kitty = {
    enable = true;
    settings = {
      background_opacity = "0.85";
      dynamic_background_opacity = "yes";
    };
  };
}
