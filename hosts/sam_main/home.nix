{ config, pkgs, ... }:

{
  # Link your existing config files
  # home.file.".config/lvim/config.lua".source = ../../program_configs/lvim/config.lua;

  programs.home-manager.enable = true;

  # Kitty removed (escape-sequence RCE advisories, e.g. GHSA-w98g-hpvr-r332 /
  # CVE-2026-42851 and related). Use Konsole from modules/desktop instead.
}
