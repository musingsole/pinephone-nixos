{ lib, stdenvNoCC, makeWrapper, python3, systemd }:

stdenvNoCC.mkDerivation {
  pname = "pinephone-power-button";
  version = "1.0.0";

  src = ./.;
  nativeBuildInputs = [ makeWrapper ];

  installPhase = ''
    runHook preInstall

    install -Dm644 power_button.py $out/libexec/pinephone-power-button.py
    makeWrapper ${python3}/bin/python3 $out/bin/pinephone-power-button \
      --add-flags "$out/libexec/pinephone-power-button.py" \
      --prefix PATH : ${lib.makeBinPath [ systemd ]}

    runHook postInstall
  '';

  meta = {
    description = "Backlight-only PinePhone Pro power-button handler";
    license = lib.licenses.mit;
    platforms = lib.platforms.linux;
    mainProgram = "pinephone-power-button";
  };
}
