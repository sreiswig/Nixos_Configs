{ config, pkgs, lib, ... }:

{
  # Link your existing config files
  # home.file.".config/lvim/config.lua".source = ../../program_configs/lvim/config.lua;

  programs.home-manager.enable = true;

  # Kitty removed (escape-sequence RCE advisories). Konsole is in modules/desktop.

  # Optional Hyprland session for sam_main.
  # Plasma 6 + SDDM (modules/desktop) stays the login default — this only supplies a
  # managed hyprland.lua so the SDDM Hyprland entry works on 0.56.x instead of a
  # broken unmanaged ~/.config/hypr/hyprland.conf.
  # package/portalPackage = null: NixOS programs.hyprland.enable already installs them.
  wayland.windowManager.hyprland = {
    enable = true;
    package = null;
    portalPackage = null;
    # Explicit lua: home.stateVersion is 24.11, which would default to hyprlang.
    configType = "lua";
    settings = {
      mod = {
        _var = "SUPER";
      };

      config = {
        general = {
          gaps_in = 5;
          gaps_out = 12;
          border_size = 2;
          layout = "dwindle";
        };
        decoration = {
          rounding = 8;
        };
        input = {
          kb_layout = "us";
          follow_mouse = 1;
        };
        misc = {
          disable_hyprland_logo = true;
          force_default_wallpaper = 0;
        };
      };

      bind = [
        {
          _args = [
            (lib.generators.mkLuaInline "mod .. \" + Q\"")
            (lib.generators.mkLuaInline "hl.dsp.window.close()")
          ];
        }
        {
          _args = [
            (lib.generators.mkLuaInline "mod .. \" + SHIFT + E\"")
            (lib.generators.mkLuaInline "hl.dsp.exit()")
          ];
        }
        {
          _args = [
            (lib.generators.mkLuaInline "mod .. \" + RETURN\"")
            (lib.generators.mkLuaInline "hl.dsp.exec_cmd(\"konsole\")")
          ];
        }
        {
          _args = [
            (lib.generators.mkLuaInline "mod .. \" + V\"")
            (lib.generators.mkLuaInline "hl.dsp.window.float({ action = \"toggle\" })")
          ];
        }
      ];
    };
  };
}
