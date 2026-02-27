{ config, pkgs, ... }:

{
  # Link your existing config files
  # home.file.".config/lvim/config.lua".source = ../../program_configs/lvim/config.lua;

  programs.home-manager.enable = true;
}
