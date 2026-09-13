{
  lib,
  stdenv,
  fetchurl,
  dpkg,
  file,
  makeWrapper,
  alsa-lib,
  at-spi2-atk,
  at-spi2-core,
  atk,
  bubblewrap,
  cairo,
  cups,
  dbus,
  expat,
  gdk-pixbuf,
  gitMinimal,
  glib,
  gtk3,
  libGL,
  libdrm,
  libgbm,
  libnotify,
  libusb1,
  libxcb,
  libxkbcommon,
  nspr,
  nss,
  pango,
  systemd,
  wayland,
  xdg-utils,
  libx11,
  libxcomposite,
  libxdamage,
  libxext,
  libxfixes,
  libxrandr,
}:

stdenv.mkDerivation rec {
  pname = "chatgpt";
  version = "26.901.51231";

  src = fetchurl {
    url = "https://persistent.oaistatic.com/codex-app-prod/linux/deb/pool/main/c/chatgpt/chatgpt_${version}_arm64.deb";
    hash = "sha256-AqL1xstpUJxiq8vdE8drE5zbLKnt3nU3I53d4CQHfqA=";
  };

  rpath = lib.makeLibraryPath [
    alsa-lib
    at-spi2-atk
    at-spi2-core
    atk
    cairo
    cups
    dbus
    expat
    gdk-pixbuf
    glib
    gtk3
    libGL
    libdrm
    libgbm
    libnotify
    libusb1
    libxcb
    libxkbcommon
    nspr
    nss
    pango
    stdenv.cc.cc
    systemd
    wayland
    libx11
    libxcomposite
    libxdamage
    libxext
    libxfixes
    libxrandr
  ];

  nativeBuildInputs = [
    dpkg
    file
    makeWrapper
  ];

  buildInputs = [
    gtk3
  ];

  dontUnpack = true;
  dontBuild = true;
  dontPatchELF = true;
  dontStrip = true;

  installPhase = ''
    runHook preInstall

    dpkg --fsys-tarfile "$src" | tar --extract
    mkdir -p "$out"
    mv usr/* "$out"
    chmod -R g-w "$out"

    # Patch only the ARM64 payload. The upstream bundle also contains unused
    # prebuilt modules for other Linux and Android architectures.
    dynamic_linker="$(cat "$NIX_CC/nix-support/dynamic-linker")"
    while IFS= read -r -d $'\0' candidate; do
      if file "$candidate" | grep -q 'ELF 64-bit.*ARM aarch64'; then
        patchelf --add-rpath "${rpath}:$out/lib/chatgpt" "$candidate" || true
        if patchelf --print-interpreter "$candidate" >/dev/null 2>&1; then
          patchelf --set-interpreter "$dynamic_linker" "$candidate"
        fi
      fi
    done < <(find "$out/lib/chatgpt" -type f \
      \( -perm /0111 -o -name '*.so*' -o -name '*.node' \) -print0)

    # Replace the Debian symlink with a Nix-aware mobile launcher. Software
    # rendering avoids the PinePhone Pro's unstable Panfrost/DSI path, while
    # native Wayland and IME support allow Phosh's on-screen keyboard to work.
    rm "$out/bin/chatgpt"
    makeWrapper "$out/lib/chatgpt/ChatGPT" "$out/bin/chatgpt" \
      --prefix LD_LIBRARY_PATH : "${rpath}" \
      --prefix PATH : "${lib.makeBinPath [ bubblewrap gitMinimal xdg-utils ]}" \
      --prefix XDG_DATA_DIRS : "$GSETTINGS_SCHEMAS_PATH" \
      --add-flags "--ozone-platform=wayland" \
      --add-flags "--enable-wayland-ime" \
      --add-flags "--disable-gpu" \
      --add-flags "--disable-gpu-compositing"

    install -Dm644 "$out/share/pixmaps/chatgpt.png" \
      "$out/share/icons/hicolor/512x512/apps/chatgpt.png"
    substituteInPlace "$out/share/applications/chatgpt.desktop" \
      --replace-fail "Categories=Utility;Development;" \
        $'Categories=Utility;Development;\nStartupWMClass=ChatGPT\nX-Purism-FormFactor=Workstation;Mobile;'

    runHook postInstall
  '';

  meta = {
    description = "Official ChatGPT desktop app with Codex for ARM64 Linux";
    homepage = "https://learn.chatgpt.com/docs/linux/linux-app";
    license = lib.licenses.unfree;
    sourceProvenance = with lib.sourceTypes; [ binaryNativeCode ];
    platforms = [ "aarch64-linux" ];
    mainProgram = "chatgpt";
  };
}
