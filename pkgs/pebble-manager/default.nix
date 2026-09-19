{ lib, stdenvNoCC, makeWrapper, python3, coreutils, systemd, xdg-utils }:

stdenvNoCC.mkDerivation {
  pname = "pebble-manager";
  version = "1.0.0";

  src = ./.;
  nativeBuildInputs = [ makeWrapper ];

  installPhase = ''
    runHook preInstall

    install -Dm755 pebble_manager.py $out/libexec/pebble-manager/pebble_manager.py
    install -Dm644 dashboard.html $out/share/pebble-manager/dashboard.html
    install -Dm644 pebble-manager.desktop \
      $out/share/applications/pebble-manager.desktop

    makeWrapper ${python3}/bin/python3 $out/bin/pebble-manager \
      --add-flags "$out/libexec/pebble-manager/pebble_manager.py" \
      --set PEBBLE_MANAGER_ASSET_DIR "$out/share/pebble-manager" \
      --prefix PATH : ${lib.makeBinPath [ coreutils systemd xdg-utils ]}

    runHook postInstall
  '';

  meta = {
    description = "Pebble Smartwatch Manager and Sideloading Utility for PinePhone";
    license = lib.licenses.mit;
    platforms = lib.platforms.linux;
    mainProgram = "pebble-manager";
  };
}
