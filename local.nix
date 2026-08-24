{ config, lib, pkgs, ... }:

let
  defaultUser = "pine";
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
  services.xserver.desktopManager.phosh = {
    user = defaultUser;
  };

  # ---------------------------------------------------------------------------
  # User Account
  # ---------------------------------------------------------------------------
  users.users."${defaultUser}" = {
    isNormalUser = true;
    password = "1234";
    extraGroups = [
      "wheel"
      "networkmanager"
      "video"
      "render"
      "input"
      "audio"
      "feedbackd"
      "dialout"
      "seat"
      "tty"
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
  # On PinePhone Pro (RK3399), deep kernel suspend (mem) breaks wake IRQs.
  # Instead, lock and turn off screen backlight on power button press.
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
  # Power Button Screen Lock & Wake Daemon
  # ---------------------------------------------------------------------------
  systemd.services.pinephone-power-toggle = {
    description = "PinePhone Pro Power Button Lock & Wake Service";
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      ExecStart = pkgs.writeShellScript "pinephone-power-toggle" ''
        KEY_DEV="/dev/input/by-path/platform-gpio-keys-event"
        DPMS_PATH="/sys/class/drm/card1-DSI-1/dpms"
        BL_PATH="/sys/class/backlight/backlight/brightness"

        while true; do
          if [ -e "$KEY_DEV" ]; then
            ${pkgs.coreutils}/bin/dd if="$KEY_DEV" bs=24 count=1 status=none 2>/dev/null || sleep 0.2
          else
            sleep 1
            continue
          fi

          STATE=$(${pkgs.coreutils}/bin/cat "$DPMS_PATH" 2>/dev/null || echo "On")
          BL=$(${pkgs.coreutils}/bin/cat "$BL_PATH" 2>/dev/null || echo "51")

          if [ "$STATE" = "Off" ] || [ "$BL" = "0" ]; then
            ${pkgs.sudo}/bin/sudo -u ${defaultUser} DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus ${pkgs.systemd}/bin/busctl --user set-property org.gnome.Mutter.DisplayConfig /org/gnome/Mutter/DisplayConfig org.gnome.Mutter.DisplayConfig PowerSaveMode i 0 2>/dev/null || true
            ${pkgs.sudo}/bin/sudo -u ${defaultUser} DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus ${pkgs.systemd}/bin/busctl --user call org.gnome.ScreenSaver /org/gnome/ScreenSaver org.gnome.ScreenSaver SetActive b false 2>/dev/null || true
            echo 51 > "$BL_PATH" 2>/dev/null || true
            /run/current-system/sw/bin/send-key-esc 2>/dev/null || true
          else
            ${pkgs.systemd}/bin/loginctl lock-session 2>/dev/null || true
            ${pkgs.sudo}/bin/sudo -u ${defaultUser} DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus ${pkgs.systemd}/bin/busctl --user set-property org.gnome.Mutter.DisplayConfig /org/gnome/Mutter/DisplayConfig org.gnome.Mutter.DisplayConfig PowerSaveMode i 3 2>/dev/null || true
            echo 0 > "$BL_PATH" 2>/dev/null || true
          fi
          sleep 0.3
        done
      '';
      Restart = "always";
    };
  };

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
        if [ -d /sys/bus/platform/drivers/dwc3 ]; then
          echo fe800000.usb > /sys/bus/platform/drivers/dwc3/unbind 2>/dev/null || true
          sleep 0.5
          echo fe800000.usb > /sys/bus/platform/drivers/dwc3/bind 2>/dev/null || true
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
            power = lib.gvariant.mkEmptyArray "s";
            power-static = lib.gvariant.mkEmptyArray "s";
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
          "org/gnome/desktop/screensaver" = {
            lock-enabled = true;
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
          "sm/puri/phosh/emergency-calls" = {
            enabled = false;
          };
          "mobi/phosh/emergency-calls" = {
            enabled = false;
          };
          "org/gnome/desktop/lockdown" = {
            disable-log-out = true;
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

  environment.systemPackages = with pkgs; [
    (pkgs.runCommandCC "send-key-esc" { } ''
      mkdir -p $out/bin
      $CC -O2 -x c - -o $out/bin/send-key-esc << 'EOF'
#include <linux/uinput.h>
#include <fcntl.h>
#include <unistd.h>
#include <string.h>
#include <sys/ioctl.h>

int main() {
    int fd = open("/dev/uinput", O_WRONLY | O_NONBLOCK);
    if (fd < 0) return 1;
    ioctl(fd, UI_SET_EVBIT, EV_KEY);
    ioctl(fd, UI_SET_KEYBIT, KEY_ESC);
    struct uinput_setup usetup;
    memset(&usetup, 0, sizeof(usetup));
    usetup.id.bustype = BUS_USB;
    usetup.id.vendor = 0x1;
    usetup.id.product = 0x1;
    strcpy(usetup.name, "virtual-esc-key");
    ioctl(fd, UI_DEV_SETUP, &usetup);
    ioctl(fd, UI_DEV_CREATE);
    usleep(50000);

    struct input_event ev[2];
    memset(ev, 0, sizeof(ev));
    ev[0].type = EV_KEY; ev[0].code = KEY_ESC; ev[0].value = 1;
    ev[1].type = EV_SYN; ev[1].code = SYN_REPORT; ev[1].value = 0;
    (void)write(fd, ev, sizeof(ev));
    usleep(20000);
    ev[0].value = 0;
    (void)write(fd, ev, sizeof(ev));
    usleep(20000);

    ioctl(fd, UI_DEV_DESTROY);
    close(fd);
    return 0;
}
EOF
    '')
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

  # Pre-configured WiFi connection so SSH is available on first boot
  environment.etc."NetworkManager/system-connections/noobiemcfoob.nmconnection" = {
    text = ''
      [connection]
      id=noobiemcfoob
      type=wifi
      autoconnect=true

      [wifi]
      ssid=noobiemcfoob
      mode=infrastructure

      [wifi-security]
      key-mgmt=wpa-psk
      psk=n00biemcfoob

      [ipv4]
      method=auto

      [ipv6]
      method=disabled
    '';
    mode = "0600";
  };

  # Static IP on the RNDIS USB gadget interface so we can SSH over USB cable
  # Connect phone to PC with USB-C, then on PC run:
  #   ip addr add 192.168.69.1/24 dev <usb-interface>
  # Then: ssh pine@192.168.69.100
  environment.etc."NetworkManager/system-connections/usb-rndis.nmconnection" = {
    text = ''
      [connection]
      id=usb-rndis
      type=ethernet
      autoconnect=true

      [ethernet]
      mac-address-blacklist=

      [match]
      interface-name=usb0;rndis0

      [ipv4]
      method=manual
      addresses=192.168.69.100/24
      never-default=true

      [ipv6]
      method=disabled
    '';
    mode = "0600";
  };

  # ---------------------------------------------------------------------------
  # Wi-Fi Quirk Fixes & Kernel Params
  # ---------------------------------------------------------------------------
  # Disable MAC address randomization to prevent brcmfmac chanspec failures (-52)
  mobile.quirks.wifi.disableMacAddressRandomization = true;

  # Silence non-critical kernel warning log spam on tty1 screen
  boot.consoleLogLevel = 3;

  # ---------------------------------------------------------------------------
  # Overlays / Workarounds
  # ---------------------------------------------------------------------------
  # Fix cross-compilation failures when building x86_64 -> aarch64 on h4x0r.local
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
