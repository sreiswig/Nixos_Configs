final: prev: {
  google-antigravity = final.stdenv.mkDerivation rec {
    pname = "google-antigravity";
    version = "2025.11.18"; # Use today's date or the version number from the filename

    # OPTION A: If you have a direct URL (e.g. dl.google.com/...)
    # src = final.fetchurl {
    #  url = "https://edgedl.me.gvt1.com/edgedl/release2/j0qc3/antigravity/stable/1.11.2-6251250307170304/linux-x64/Antigravity.tar.gz";
    #  sha256 = "sha256-0000000000000000000000000000000000000000000000000000";
    # Run the build once, copy the real hash from the error, and paste it above.
    # };

    # OPTION B: If you downloaded it manually (use this if the link expires/redirects)
    src = /home/sam/Documents/Antigravity.tar.gz;

    nativeBuildInputs = [
      final.autoPatchelfHook
      final.wrapGAppsHook3
      final.makeWrapper
      final.copyDesktopItems
    ];

    buildInputs = with final; [
      alsa-lib
      at-spi2-core
      cups
      dbus
      expat
      gdk-pixbuf
      glib
      gtk3
      libdrm
      libnotify
      libsecret
      mesa
      nspr
      nss
      pango
      systemd
      xorg.libX11
      xorg.libxcb
      xorg.libXcomposite
      xorg.libXdamage
      xorg.libXext
      xorg.libXfixes
      xorg.libXi
      xorg.libXrandr
      xorg.libXrender
      xorg.libXScrnSaver
      xorg.libXtst
      xorg.libxkbfile
      xdg-utils
    ];

    runtimeDependencies = [
      final.systemd
      final.libglvnd
      final.vulkan-loader
    ];

    installPhase = ''
      runHook preInstall

      mkdir -p $out/share/antigravity
      mkdir -p $out/bin

      # Copy all files from the tarball to the install directory
      # We use * to grab everything inside the top-level folder of the tarball
      cp -r ./* $out/share/antigravity/

      # Create the binary symlink
      # Note: Check if the binary inside is named 'antigravity' or 'code'
      ln -s $out/share/antigravity/antigravity $out/bin/antigravity

      # Install the Icon
      # Electron apps usually hide icons here:
      install -Dm644 resources/app/resources/linux/code.png $out/share/icons/hicolor/512x512/apps/antigravity.png || true

      runHook postInstall
    '';

    desktopItems = [
      (final.makeDesktopItem {
        name = "google-antigravity";
        desktopName = "Google Antigravity";
        comment = "Agentic Development Platform";
        exec = "antigravity %u";
        icon = "antigravity";
        categories = [
          "Development"
          "IDE"
        ];
        startupWMClass = "google-antigravity";
      })
    ];

    meta = with final.lib; {
      description = "Google Antigravity IDE";
      homepage = "https://antigravity.google/";
      license = licenses.unfree;
      platforms = [ "x86_64-linux" ];
      mainProgram = "antigravity";
    };
  };
}
