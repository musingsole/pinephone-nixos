{ lib, stdenvNoCC, makeWrapper, python3, coreutils, systemd, xdg-utils }:

stdenvNoCC.mkDerivation {
  pname = "pinephone-power-monitor";
  version = "1.1.0";

  src = ./.;
  nativeBuildInputs = [ makeWrapper ];

  installPhase = ''
    runHook preInstall

    install -Dm644 power_monitor.py $out/libexec/pinephone-power-monitor/power_monitor.py
    install -Dm644 dashboard.html $out/share/pinephone-power-monitor/dashboard.html
    install -Dm644 pinephone-power-monitor.desktop \
      $out/share/applications/pinephone-power-monitor.desktop

    makeWrapper ${python3}/bin/python3 $out/bin/pinephone-power-monitor \
      --add-flags "$out/libexec/pinephone-power-monitor/power_monitor.py" \
      --set POWER_MONITOR_ASSET_DIR "$out/share/pinephone-power-monitor" \
      --prefix PATH : ${lib.makeBinPath [ coreutils systemd xdg-utils ]}

    makeWrapper ${python3}/bin/python3 $out/bin/power-profile \
      --add-flags "$out/libexec/pinephone-power-monitor/power_monitor.py" \
      --add-flags "profile" \
      --set POWER_MONITOR_ASSET_DIR "$out/share/pinephone-power-monitor" \
      --prefix PATH : ${lib.makeBinPath [ coreutils systemd ]}

    runHook postInstall
  '';

  meta = {
    description = "Battery telemetry, safety guard, and power profiles for PinePhone";
    license = lib.licenses.mit;
    platforms = lib.platforms.linux;
    mainProgram = "pinephone-power-monitor";
  };
}
