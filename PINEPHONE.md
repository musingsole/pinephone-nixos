# PinePhone Pro Mobile NixOS Guide

This guide provides instructions for configuring, building, and flashing a Mobile NixOS Phosh image for the **PinePhone Pro** (`pine64-pinephonepro`).

## Battery monitoring and power profiles

The `pinephone.power` module can sample the RK818 fuel gauge and retain battery
history, but it is disabled in the stability image so it adds no services or
CPU/GPU policy writes to the generation-24 boot graph. Re-enable it only as an
isolated follow-up test after repeated boot and cable-transition testing.

Battery-flow watts are derived from the kernel's simultaneous `voltage_now`
and `current_now` readings because the RK818 driver does not export
`power_now`. Positive values are discharge and negative values are charging;
while plugged in this is net battery flow, not total wall power.

Phosh is launched through Mobile NixOS's direct `phosh.service` with seatd.
This is the same display-service topology as the last repeatedly bootable
image. A small post-start service marks its existing tty1 Wayland session active
in logind so the stock quick-settings brightness slider is authorized; no Phosh
source patch or writable backlight sysfs rule is used.

Set `headlessDiagnostic = true` near the top of `local.nix` to suppress the
Phosh/phoc session while retaining SSH, networking, modem support, and
power telemetry. This provides an A/B stability test that does not submit work
to Panfrost or tear down the DRM session at runtime. It is `false` by default.

The power button is handled by a small exclusive input service because native
DRM DPMS wake can hard-lock the PinePhone Pro's RK3399 DSI/VOP pipeline. A short
press locks through logind and writes panel brightness to 0 while leaving Phoc
and the DRM pipeline active. The next accepted press restores the saved
brightness. A 1.25-second debounce blocks the rapid off/on pairs found in the
failed-generation journals. A three-second press requests an orderly poweroff.

The mobile Chromium wrapper disables GPU compositing. GPU startup otherwise
matches generation 24's single performance-governor write; no adaptive profile
daemon changes devfreq while Phoc opens the DRM devices.

When the optional monitor is enabled, its default `auto` policy uses balanced
operation, powersave at 15%, and critical at 8%. Inspect or override it with:

```console
$ power-profile status
$ sudo power-profile gateway
$ sudo power-profile balanced
$ sudo power-profile powersave
$ sudo power-profile performance
$ sudo power-profile auto
```

The optional `gateway` profile is a reversible headless mode. It stops the direct
Phosh session, saves and turns off the backlight, and offlines the two RK3399
big cores. Bluetooth, Wi-Fi, USB host mode, the EG25 modem, NetworkManager,
ModemManager, SSH, Renurd, forwarding, and the firewall remain available.
Selecting `balanced`, `performance`, or `auto` on the next SSH command restores
both big cores, the interactive services, and the saved screen brightness.

To avoid the known low-charge lockup, the service requests an orderly poweroff
after three consecutive discharging samples at 5% or below. It also shuts down
at or below 3.4 V when charge is below 20%. Charging or reconnecting external
power immediately clears the confirmation counter. All thresholds and profile
frequency caps are options in `power-management.nix`.

---

## 1. Local Configuration (`local.nix`)

Mobile NixOS includes `./local.nix` automatically during evaluation. Our updated configuration imports Mobile NixOS's official `./examples/phosh/phosh.nix` module:

```nix
{ config, lib, pkgs, ... }:

let
  defaultUser = "pine";

  chromiumMobile = pkgs.runCommand "chromium-mobile" {
    nativeBuildInputs = [ pkgs.makeWrapper ];
  } ''
    mkdir -p $out/bin $out/share/applications $out/share/icons

    # Install full Chromium icon theme so Phosh can display the application logo
    if [ -d "${pkgs.chromium}/share/icons" ]; then
      cp -r ${pkgs.chromium}/share/icons/* $out/share/icons/
    fi

    # Launcher wrapper with mobile Wayland Ozone flags & mobile User-Agent
    makeWrapper ${pkgs.chromium}/bin/chromium $out/bin/chromium \
      --add-flags "--ozone-platform=wayland" \
      --add-flags "--enable-features=UseOzonePlatform" \
      --add-flags "--user-agent=\"Mozilla/5.0 (Linux; Android 14; Mobile) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Mobile Safari/537.36\""

    # Desktop entry targeting mobile form factors and Wayland WM class
    cat > $out/share/applications/chromium.desktop << 'EOF'
[Desktop Entry]
Type=Application
Version=1.0
Name=Chromium Web Browser
GenericName=Web Browser
Comment=Access the Internet
Exec=chromium %U
Icon=chromium
Terminal=false
StartupWMClass=chromium-browser
Categories=Network;WebBrowser;
MimeType=text/html;text/xml;application/xhtml+xml;x-scheme-handler/http;x-scheme-handler/https;
X-Purism-FormFactor=Workstation;Mobile;
EOF

    ln -s chromium.desktop $out/share/applications/chromium-browser.desktop
  '';

  scaleToFitUtil = pkgs.writeShellScriptBin "scale-to-fit" ''
    APP="$1"
    ACTION="''${2:-on}"

    if [ -z "$APP" ]; then
      echo "Usage: scale-to-fit <app-id> [on|off]"
      echo "Example: scale-to-fit chromium on"
      exit 1
    fi

    APP_PATH="''${APP//./-}"

    if [ "$ACTION" = "off" ] || [ "$ACTION" = "false" ]; then
      ${pkgs.glib}/bin/gsettings set sm.puri.phoc.application:/sm/puri/phoc/application/"$APP"/ scale-to-fit false 2>/dev/null || true
      ${pkgs.glib}/bin/gsettings set sm.puri.phoc.application:/sm/puri/phoc/application/"$APP_PATH"/ scale-to-fit false 2>/dev/null || true
      echo "Scale-to-fit disabled for $APP"
    else
      ${pkgs.glib}/bin/gsettings set sm.puri.phoc.application:/sm/puri/phoc/application/"$APP"/ scale-to-fit true 2>/dev/null || true
      ${pkgs.glib}/bin/gsettings set sm.puri.phoc.application:/sm/puri/phoc/application/"$APP_PATH"/ scale-to-fit true 2>/dev/null || true
      echo "Scale-to-fit enabled for $APP"
    fi
  '';
in
{
  imports = [
    ./examples/phosh/phosh.nix
  ];

  # ---------------------------------------------------------------------------
  # System Identity & Nix Settings
  # ---------------------------------------------------------------------------
  networking.hostName = "pinephone-pro";
  system.stateVersion = "26.11";
  nix.settings.trusted-users = [ "root" defaultUser "@wheel" ];

  # ---------------------------------------------------------------------------
  # Phosh Desktop Session User
  # ---------------------------------------------------------------------------
  services.xserver.desktopManager.phosh.user = defaultUser;

  # ---------------------------------------------------------------------------
  # User Account
  # ---------------------------------------------------------------------------
  users.users."${defaultUser}" = {
    isNormalUser = true;
    password = "1234";
    extraGroups = [
      "wheel"          # Sudo access
      "networkmanager" # Network management
      "video"          # Display access
      "render"         # GPU render node access (/dev/dri/renderD128)
      "input"          # Touchscreen & USB keyboard access (/dev/input/*)
      "audio"          # Audio playback/record
      "feedbackd"      # Haptics/vibration
      "dialout"        # Serial / modem access
      "seat"           # Seatd seat management access
      "tty"            # TTY console access
    ];
  };

  # ---------------------------------------------------------------------------
  # Seat Management (seatd allows non-root user to access DRM & VTs)
  # ---------------------------------------------------------------------------
  services.seatd.enable = true;

  # Phosh service environment & backend configuration
  systemd.services.phosh.environment = {
    LIBSEAT_BACKEND = "seatd";
    WLR_DRM_DEVICES = "/dev/dri/card1:/dev/dri/card0";
  };

  # ---------------------------------------------------------------------------
  # Power Management & Screen Blanking (Fix Power Button Sleep / Wakeup)
  # ---------------------------------------------------------------------------
  services.logind.settings.Login = {
    HandlePowerKey = "ignore";
    HandlePowerKeyLongPress = "poweroff";
    HandleSuspendKey = "ignore";
    HandleHibernateKey = "ignore";
    HandleLidSwitch = "ignore";
    IdleAction = "ignore";
  };
  systemd.targets.suspend.enable = false;
  systemd.targets.hibernate.enable = false;
  systemd.targets.hybrid-sleep.enable = false;
  systemd.targets.suspend-then-hibernate.enable = false;

  # Leave USB-C data and power roles under the Type-C controller. Forcing the
  # DWC3 role to host while a charger negotiates device mode can stall the
  # phone when the cable is removed.

  # ---------------------------------------------------------------------------
  # Desktop Schemas & DConf (For On-Screen Keyboard & GNOME Settings)
  # ---------------------------------------------------------------------------
  programs.dconf = {
    enable = true;
    profiles.user.databases = [
      {
        # Keep Phosh from powering down the RK3399 DSI/VOP pipeline. This is
        # locked because a pre-existing user dconf value overrides defaults.
        locks = [ "/org/gnome/desktop/session/idle-delay" ];
        settings = {
          "org/gnome/settings-daemon/plugins/media-keys" = {
            power = [ ];
            power-static = [ ];
          };
          "org/gnome/settings-daemon/plugins/power" = {
            idle-dim = false;
            sleep-inactive-battery-type = "nothing";
            sleep-inactive-ac-type = "nothing";
            power-button-action = "nothing";
          };
          "org/gnome/desktop/session" = {
            idle-delay = lib.gvariant.mkUint32 0;
          };
          "org/gnome/desktop/interface" = {
            gtk-im-module = "ibus";
          };
          "org/gnome/desktop/a11y/applications" = {
            screen-keyboard-enabled = true;
          };
          "sm/puri/phosh" = {
            osk-button = true;
            osk-unfold-delay = 0.5;
          };
          "mobi/phosh/shell" = {
            osk-unfold-delay = 0.5;
          };
          "sm/puri/phosh/osk" = {
            enabled = true;
          };
          "mobi/phosh/osk" = {
            enabled = true;
          };
          "sm/puri/phoc" = {
            auto-maximize = true;
            scale-to-fit = true;
          };
          "sm/puri/phoc/application/chromium" = {
            scale-to-fit = true;
          };
          "sm/puri/phoc/application/chromium-browser" = {
            scale-to-fit = true;
          };
          "sm/puri/phoc/application/org-chromium-Chromium" = {
            scale-to-fit = true;
          };
          "sm/puri/phoc/application/org.chromium.Chromium" = {
            scale-to-fit = true;
          };
        };
      }
    ];
  };
  environment.pathsToLink = [ "/share/gsettings-schemas" ];

  # ---------------------------------------------------------------------------
  # System Packages
  # ---------------------------------------------------------------------------
  environment.systemPackages = with pkgs; [
    alsa-utils
    wireplumber
    pulseaudio
    chromiumMobile
    scaleToFitUtil
  ];

  # ---------------------------------------------------------------------------
  # Hardware Graphics (Mesa / Panfrost GPU drivers for Wayland/Phosh)
  # ---------------------------------------------------------------------------
  hardware.graphics.enable = lib.mkDefault true;

  # ---------------------------------------------------------------------------
  # Networking, mDNS (pinephone-pro.local) & SSH Access
  # ---------------------------------------------------------------------------
  services.avahi = {
    enable = true;
    nssmdns4 = true;
    publish = {
      enable = true;
      addresses = true;
      workstation = true;
    };
  };
  networking.firewall.allowedUDPPorts = [ 5353 ]; # mDNS

  services.haveged.enable = true;
  networking.networkmanager.enable = true;
  services.openssh.enable = true;
  services.openssh.settings.PermitRootLogin = "yes";

  # Disable problematic sshd-keygen service and create key directly in sshd.preStart
  systemd.services.sshd-keygen.enable = false;
  systemd.services.sshd.preStart = lib.mkBefore ''
    if [ ! -f /etc/ssh/ssh_host_ed25519_key ]; then
      mkdir -p /etc/ssh
      ${pkgs.openssh}/bin/ssh-keygen -t ed25519 -f /etc/ssh/ssh_host_ed25519_key -N "" < /dev/null || true
    fi
  '';

  # Disable modem manager & calls temporarily during initial setup to avoid serial/modem hardware lockups
  services.eg25-manager.enable = lib.mkForce false;
  programs.calls.enable = lib.mkForce false;

  # Silence non-critical kernel warning log spam on screen
  boot.consoleLogLevel = 3;

  # Disable MAC address randomization in NetworkManager to prevent Broadcom brcmfmac failures
  mobile.quirks.wifi.disableMacAddressRandomization = true;

  # ---------------------------------------------------------------------------
  # Overlays / Workarounds
  # ---------------------------------------------------------------------------
  nixpkgs.overlays = [
    (final: super: {
      feedbackd-device-themes = super.feedbackd-device-themes.overrideAttrs (oldAttrs: {
        mesonFlags = (lib.lists.remove "-Dvalidate=enabled" (oldAttrs.mesonFlags or [])) ++ [
          (if final.stdenv.buildPlatform != final.stdenv.hostPlatform
           then "-Dvalidate=disabled"
           else "-Dvalidate=enabled")
        ];
      });

      systemd = super.systemd.overrideAttrs (oldAttrs: {
        mesonFlags = (oldAttrs.mesonFlags or []) ++ lib.optionals (final.stdenv.buildPlatform != final.stdenv.hostPlatform) [
          "-Dbpf-framework=disabled"
        ];
      });

      gupnp-av = super.gupnp-av.overrideAttrs (oldAttrs: {
        mesonFlags = (oldAttrs.mesonFlags or []) ++ lib.optionals (final.stdenv.buildPlatform != final.stdenv.hostPlatform) [
          "-Dgtk_doc=false"
        ];
      });
    })
  ];
}
```

---

## 2. Managing Scale-to-Fit (`scale-to-fit` utility)

Phoc (the Wayland compositor used by Phosh) manages window fitting for applications that exceed the narrow mobile viewport (e.g. Chromium's ~500px minimum desktop window width on a 360px portrait screen).

A CLI helper script `scale-to-fit` is installed on the system:

- **Enable scaling for an app**:
  ```bash
  scale-to-fit chromium on
  # or
  scale-to-fit <app-id> on
  ```
- **Disable scaling for an app**:
  ```bash
  scale-to-fit chromium off
  ```

Under the hood, this sets the GSettings schema path:
`sm.puri.phoc.application:/sm/puri/phoc/application/<app-id>/ scale-to-fit true|false`

*(Note: Phoc queries `/sm/puri/phoc/application/` [singular]. Do not use `/applications/` [plural].)*

---

## 3. Building the Image

### Method A: Build root `local.nix` (Recommended)

```bash
nix-build --argstr device pine64-pinephonepro --argstr system aarch64-linux -A outputs.disk-image
```

### Method B: Direct `examples/phosh` Build

Alternatively, Mobile NixOS includes a prepackaged `examples/phosh` target:

```bash
nix-build examples/phosh --argstr device pine64-pinephonepro --argstr system aarch64-linux -A outputs.disk-image
```

### Example build script

```bash
#!/usr/bin/env bash
set -euo pipefail
echo "==> 1. Syncing local source code to builder..."
rsync -avz --exclude='.git' /home/musengdir/mobile-nixos/ nixos@h4x0r.local:~/mobile-nixos/
echo "==> 2. Building full disk image on builder..."
ssh nixos@h4x0r.local "cd ~/mobile-nixos && nix-build --argstr device pine64-pinephonepro --argstr system aarch64-linux -A outputs.disk-image"
```

---

## 4. Syncing to Remote Builder (`nixos@h4x0r.local`)

```bash
#!/usr/bin/env bash
set -euo pipefail

echo "==> 1. Syncing local source code to builder..."
rsync -avz --exclude='.git' /home/musengdir/pinephone-nixos/ nixos@h4x0r.local:~/pinephone-nixos/

echo "==> 2. Building toplevel system derivation on builder..."
ssh nixos@h4x0r.local "cd ~/pinephone-nixos && nix-build --argstr device pine64-pinephonepro --argstr system aarch64-linux -A config.system.build.toplevel --out-link result-toplevel"

echo "==> 3. Copying system closure from builder to PinePhone Pro..."
ssh nixos@h4x0r.local "cd ~/pinephone-nixos && export NIX_SSHOPTS='-o StrictHostKeyChecking=no' && nix-copy-closure --to pine@pinephone-pro.local result-toplevel"

echo "==> 4. Setting system profile and switching configuration on PinePhone Pro..."
STORE_PATH=$(ssh nixos@h4x0r.local "readlink -f ~/pinephone-nixos/result-toplevel")
ssh pine@pinephone-pro.local "echo 1234 | sudo -S nix-env -p /nix/var/nix/profiles/system --set $STORE_PATH && echo 1234 | sudo -S /nix/var/nix/profiles/system/bin/switch-to-configuration switch"

echo "==> Done! System is live and set as default boot target."
```
