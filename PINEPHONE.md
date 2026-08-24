# PinePhone Pro Mobile NixOS Guide

This guide provides instructions for configuring, building, and flashing a Mobile NixOS Phosh image for the **PinePhone Pro** (`pine64-pinephonepro`).

---

## 1. Local Configuration (`local.nix`)

Mobile NixOS includes `./local.nix` automatically during evaluation. Our updated configuration imports Mobile NixOS's official `./examples/phosh/phosh.nix` module:

```nix
{ config, lib, pkgs, ... }:

let
  defaultUser = "pine";
in
{
  imports = [
    ./examples/phosh/phosh.nix
  ];

  # ---------------------------------------------------------------------------
  # System Identity
  # ---------------------------------------------------------------------------
  networking.hostName = "pinephone-pro";
  system.stateVersion = "26.11";

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

  # ---------------------------------------------------------------------------
  # USB Host Mode (Enable USB Keyboards, Mice, and USB-C Hubs)
  # ---------------------------------------------------------------------------
  systemd.services.enable-usb-host-mode = {
    description = "Enable USB Type-C Host Mode for Keyboards and Hubs";
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = pkgs.writeShellScript "enable-usb-host" ''
        for u in /sys/kernel/config/usb_gadget/*/UDC; do
          if [ -f "$u" ]; then
            echo "" > "$u" 2>/dev/null || true
          fi
        done
        if [ -f /sys/class/usb_role/fe800000.usb-role-switch/role ]; then
          echo host > /sys/class/usb_role/fe800000.usb-role-switch/role 2>/dev/null || true
        fi
      '';
    };
  };

  # ---------------------------------------------------------------------------
  # Desktop Schemas & DConf (For On-Screen Keyboard & GNOME Settings)
  # ---------------------------------------------------------------------------
  programs.dconf = {
    enable = true;
    profiles.user.databases = [
      {
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
        };
      }
    ];
  };
  environment.pathsToLink = [ "/share/gsettings-schemas" ];

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

## 2. Building the Image

### Method A: Build root `local.nix` (Recommended)

```bash
nix-build --argstr device pine64-pinephonepro --argstr system aarch64-linux -A outputs.disk-image
```

### Method B: Direct `examples/phosh` Build

Alternatively, Mobile NixOS includes a prepackaged `examples/phosh` target:

```bash
nix-build examples/phosh --argstr device pine64-pinephonepro --argstr system aarch64-linux -A outputs.disk-image
```

---

## 3. Syncing to Remote Builder (`nixos@h4x0r.local`)

```bash
rsync -avz --exclude='.git' /home/musengdir/mobile-nixos/ nixos@h4x0r.local:~/mobile-nixos/
ssh nixos@h4x0r.local "cd ~/mobile-nixos && nix-build --argstr device pine64-pinephonepro --argstr system aarch64-linux -A outputs.disk-image"
```
