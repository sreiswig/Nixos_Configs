{ config, pkgs, ... }:

{
  # Link your existing config files
  home.file.".config/lvim/config.lua".source = ../../program_configs/lvim/config.lua;

  # Plasma Configuration
  programs.plasma = {
    enable = true;
    
    # Example: Set your workspace theme
    workspace = {
      lookAndFeel = "org.kde.breezedark.desktop";
      cursorTheme = "Breeze_Snow";
      iconTheme = "Papirus-Dark";
      wallpaper = "${pkgs.kdePackages.plasma-workspace-wallpapers}/share/wallpapers/Patak/contents/images/1920x1080.jpg";
    };

    # Example: Set some shortcuts
    shortcuts = {
      "kwin" = {
        "Window Maximize" = "Meta+Up";
        "Window Minimize" = "Meta+Down";
      };
    };

    # Example: Configure the panels
    panels = [
      {
        location = "bottom";
        widgets = [
          "org.kde.plasma.kickoff"
          "org.kde.plasma.pager"
          "org.kde.plasma.taskmanager"
          "org.kde.plasma.systemtray"
          "org.kde.plasma.digitalclock"
        ];
      }
    ];
  };

  # Packages needed for these configs
  home.packages = with pkgs; [
    papirus-icon-theme
  ];

  programs.home-manager.enable = true;
}
