{
  lib,
  stdenv,
  dpkg,
  autoPatchelfHook,
  makeWrapper,
  wrapGAppsHook3,
  alsa-lib,
  at-spi2-atk,
  at-spi2-core,
  atk,
  cairo,
  cups,
  dbus,
  expat,
  glib,
  gtk3,
  libdrm,
  libgbm,
  libnotify,
  libsecret,
  libuuid,
  libx11,
  libxcomposite,
  libxdamage,
  libxext,
  libxfixes,
  libxkbcommon,
  libxrandr,
  libxscrnsaver,
  libxtst,
  libxcb,
  nss,
  nspr,
  pango,
  systemd,
  udev,
  xdg-utils,
}:

stdenv.mkDerivation (finalAttrs: {
  pname = "grok-bot";
  version = "0.58.0";

  # Local vendor .deb checked into the flake root
  src = ../../grok-bot_0.58.0_amd64.deb;

  nativeBuildInputs = [
    dpkg
    autoPatchelfHook
    makeWrapper
    wrapGAppsHook3
  ];

  buildInputs = [
    alsa-lib
    at-spi2-atk
    at-spi2-core
    atk
    cairo
    cups
    dbus
    expat
    glib
    gtk3
    libdrm
    libgbm
    libnotify
    libsecret
    libuuid
    libx11
    libxcomposite
    libxdamage
    libxext
    libxfixes
    libxkbcommon
    libxrandr
    libxscrnsaver
    libxtst
    libxcb
    nss
    nspr
    pango
    systemd
    udev
  ];

  # Needed so Chromium can find libudev / libsystemd at runtime
  runtimeDependencies = [
    systemd
    udev
  ];

  autoPatchelfIgnoreMissingDeps = [
    # Native modules may ship musl builds that are unused on glibc hosts
    "libc.musl-*.so.*"
  ];

  unpackPhase = ''
    runHook preUnpack
    dpkg-deb -x "$src" .
    runHook postUnpack
  '';

  installPhase = ''
    runHook preInstall

    mkdir -p "$out/opt/grok-bot" "$out/bin" "$out/share/applications" \
      "$out/share/icons"

    # Normalize the space-containing vendor path
    cp -a "opt/Grok Bot/." "$out/opt/grok-bot/"

    # 0.58.0 desktop entry already uses Exec=grok-bot %U
    cp usr/share/applications/grok-bot.desktop \
      "$out/share/applications/grok-bot.desktop"

    # Icons ship as multiple hicolor sizes (no 1024x1024 in 0.58.0)
    cp -a usr/share/icons/hicolor "$out/share/icons/"

    # chrome-sandbox cannot be setuid in the Nix store; use --no-sandbox
    makeWrapper "$out/opt/grok-bot/grok-bot" "$out/bin/grok-bot" \
      --prefix LD_LIBRARY_PATH : "$out/opt/grok-bot" \
      --prefix PATH : "${lib.makeBinPath [ xdg-utils ]}" \
      --add-flags "--no-sandbox" \
      --add-flags "\''${NIXOS_OZONE_WL:+\''${WAYLAND_DISPLAY:+--ozone-platform-hint=auto --enable-features=WaylandWindowDecorations --enable-wayland-ime=true}}"

    runHook postInstall
  '';

  meta = {
    description = "Grok Bot desktop agent";
    homepage = "https://x.ai/bot";
    license = lib.licenses.unfree;
    platforms = [ "x86_64-linux" ];
    mainProgram = "grok-bot";
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
  };
})
