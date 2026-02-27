{ pkgs, lib, config, ... }:

{
  # SDDM & Plasma 6
  services.displayManager.sddm = {
    enable = true;
    wayland.enable = true;
  };
  services.desktopManager.plasma6.enable = true;

  # XServer (X11 support for Plasma)
  services.xserver = {
    enable = true;
    xkb.layout = "us";
    xkb.variant = "";
  };

  # Fonts
  fonts.packages = with pkgs; [
    nerd-fonts.fira-code
    noto-fonts-cjk-sans
    noto-fonts-cjk-serif
  ];
  fonts.fontconfig.enable = true;

  # Common Desktop Apps
  programs.steam.enable = true;

  environment.systemPackages = with pkgs; [
    google-chrome
    discord
    obsidian
    kdePackages.kate
    kdePackages.dolphin
    kdePackages.konsole
    kdePackages.kcalc
    wl-clipboard
  ];
}
