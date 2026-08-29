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

  audioSwitchUtil = pkgs.writeShellScriptBin "audio-switch" ''
    CMD="''${1:-status}"

    get_sink_id() {
      PATTERN="$1"
      ${pkgs.wireplumber}/bin/wpctl status 2>/dev/null | \
        sed -n '/Sinks:/,/Sources:/p' | \
        grep -iE "$PATTERN" | \
        head -n 1 | \
        grep -oE '[0-9]+\.' | \
        head -n 1 | \
        tr -d '.'
    }

    get_source_id() {
      PATTERN="$1"
      ${pkgs.wireplumber}/bin/wpctl status 2>/dev/null | \
        sed -n '/Sources:/,/Filters:/p' | \
        grep -iE "$PATTERN" | \
        head -n 1 | \
        grep -oE '[0-9]+\.' | \
        head -n 1 | \
        tr -d '.'
    }

    case "$CMD" in
      status|list|"")
        echo "=== Audio Devices & Current Routing ==="
        ${pkgs.wireplumber}/bin/wpctl status
        ;;

      speaker|spk|internal)
        ID=$(get_sink_id "Speaker|Built-in")
        if [ -n "$ID" ]; then
          ${pkgs.wireplumber}/bin/wpctl set-default "$ID"
          echo "Default output switched to Internal Speaker (ID: $ID)"
        else
          echo "Error: Internal speaker sink not found."
          exit 1
        fi
        ;;

      bluetooth|bt|headphones|headset)
        ID=$(get_sink_id "bluez|headphone|headset|wireless|shokz")
        if [ -n "$ID" ]; then
          ${pkgs.wireplumber}/bin/wpctl set-default "$ID"
          echo "Default output switched to Bluetooth Audio (ID: $ID)"
        else
          echo "Error: No Bluetooth audio output device found. Make sure headphones are connected."
          exit 1
        fi
        ;;

      mic-internal|mic-builtin)
        ID=$(get_source_id "Internal Microphone|Built-in.*Microphone|Mic")
        if [ -n "$ID" ]; then
          ${pkgs.wireplumber}/bin/wpctl set-default "$ID"
          echo "Default input switched to Internal Microphone (ID: $ID)"
        else
          echo "Error: Internal microphone not found."
          exit 1
        fi
        ;;

      mic-bt|mic-headset)
        ID=$(get_source_id "bluez|headset|wireless|shokz")
        if [ -n "$ID" ]; then
          ${pkgs.wireplumber}/bin/wpctl set-default "$ID"
          echo "Default input switched to Bluetooth Microphone (ID: $ID)"
        else
          echo "Error: Bluetooth microphone not found."
          exit 1
        fi
        ;;

      set)
        TARGET="$2"
        if [ -z "$TARGET" ]; then
          echo "Usage: audio-switch set <id>"
          exit 1
        fi
        ${pkgs.wireplumber}/bin/wpctl set-default "$TARGET"
        echo "Default device set to $TARGET"
        ;;

      vol)
        LEVEL="''${2:-50%}"
        TARGET="''${3:-@DEFAULT_AUDIO_SINK@}"
        ${pkgs.wireplumber}/bin/wpctl set-volume "$TARGET" "$LEVEL"
        echo "Volume set to $LEVEL on $TARGET"
        ;;

      mute)
        TARGET="''${2:-@DEFAULT_AUDIO_SINK@}"
        ${pkgs.wireplumber}/bin/wpctl set-mute "$TARGET" toggle
        echo "Toggled mute on $TARGET"
        ;;

      *)
        echo "Usage: audio-switch [status|speaker|bluetooth|mic-internal|mic-bt|set <id>|vol <level>|mute]"
        echo ""
        echo "Commands:"
        echo "  status         - Show current audio devices and routing"
        echo "  speaker        - Switch audio output to internal speaker"
        echo "  bluetooth      - Switch audio output to connected Bluetooth headphones"
        echo "  mic-internal   - Switch audio input to internal microphone"
        echo "  mic-bt         - Switch audio input to Bluetooth headset microphone"
        echo "  set <id>       - Set default sink/source by numeric ID"
        echo "  vol <level>    - Set volume (e.g. 80%, 0.5, 100%+)"
        echo "  mute           - Toggle mute on default sink"
        exit 1
        ;;
    esac
  '';

  torchUtil = pkgs.runCommandCC "torch" { } ''
    mkdir -p $out/bin
    $CC -O2 -x c - -o $out/bin/torch << 'EOF'
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/ioctl.h>
#include <linux/videodev2.h>

int main(int argc, char **argv) {
    int fd = open("/dev/v4l-subdev11", O_RDWR);
    if (fd < 0) { perror("open /dev/v4l-subdev11"); return 1; }
    struct v4l2_control ctrl = { .id = 0x009c0901 };
    if (ioctl(fd, VIDIOC_G_CTRL, &ctrl) < 0) {
        ctrl.value = 0;
    }
    int target = 0;
    if (argc < 2 || strcmp(argv[1], "toggle") == 0) {
        target = (ctrl.value == 2) ? 0 : 2;
    } else if (strcmp(argv[1], "on") == 0 || strcmp(argv[1], "1") == 0) {
        target = 2;
    } else if (strcmp(argv[1], "off") == 0 || strcmp(argv[1], "0") == 0) {
        target = 0;
    } else if (strcmp(argv[1], "status") == 0) {
        printf("%s\n", (ctrl.value == 2) ? "on" : "off");
        close(fd);
        return 0;
    } else {
        fprintf(stderr, "Usage: torch [on|off|toggle|status]\n");
        close(fd);
        return 1;
    }
    ctrl.value = target;
    if (ioctl(fd, VIDIOC_S_CTRL, &ctrl) < 0) {
        perror("VIDIOC_S_CTRL");
        close(fd);
        return 1;
    }
    printf("Flashlight %s\n", (target == 2) ? "ON" : "OFF");
    close(fd);
    return 0;
}
EOF
  '';

  flashlightApp = pkgs.runCommand "flashlight-app" { } ''
    mkdir -p $out/share/applications
    cat > $out/share/applications/flashlight.desktop << 'EOF'
[Desktop Entry]
Type=Application
Version=1.0
Name=Flashlight
GenericName=Torch
Comment=Toggle the camera flashlight
Exec=torch toggle
Icon=flashlight-symbolic
Terminal=false
Categories=Utility;
X-Purism-FormFactor=Workstation;Mobile;
EOF
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
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIE/BuDgBr/8UNugbE+XpWcrPGPsDH4LZwbiiguvCI0ot remagic@harmony"
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGjyB1hrun7glFf5FkG3wlB06yywnhUSbR+Ztpt+eFij nixos@h4x0r"
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
  # GPU Performance Governor (Mali-T860 → 600MHz for smooth camera debayer)
  # ---------------------------------------------------------------------------
  systemd.services.gpu-performance = {
    description = "Set Mali-T860 GPU to performance governor";
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = pkgs.writeShellScript "gpu-perf" ''
        echo performance > /sys/class/devfreq/ff9a0000.gpu/governor 2>/dev/null || true
      '';
      ExecStop = pkgs.writeShellScript "gpu-ondemand" ''
        echo simple_ondemand > /sys/class/devfreq/ff9a0000.gpu/governor 2>/dev/null || true
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
          "sm/puri/phoc/application/pavucontrol" = {
            scale-to-fit = true;
          };
          "sm/puri/phoc/application/org-pulseaudio-pavucontrol" = {
            scale-to-fit = true;
          };
          "sm/puri/phoc/application/gnome-control-center" = {
            scale-to-fit = true;
          };
          "mobi/phosh/osk" = {
            enabled = true;
          };
        };
      }
    ];
  };
  # ---------------------------------------------------------------------------
  # Sound & Audio (PipeWire, WirePlumber, ALSA & PulseAudio Compatibility)
  # ---------------------------------------------------------------------------
  security.rtkit.enable = true;
  services.pipewire = {
    enable = true;
    alsa.enable = true;
    alsa.support32Bit = true;
    pulse.enable = true;
    wireplumber.extraConfig = {
      "50-disable-seat-monitoring" = {
        "wireplumber.profiles" = {
          main = {
            "monitor.bluez.seat-monitoring" = "disabled";
          };
        };
      };
    };
  };
  services.pulseaudio.enable = false;

  environment.gnome.excludePackages = with pkgs; [
    epiphany
  ];

  environment.systemPackages = with pkgs; [
    alsa-utils
    wireplumber
    pulseaudio
    pavucontrol
    audioSwitchUtil
    chromiumMobile
    scaleToFitUtil
    torchUtil
    flashlightApp
    chatty
    dnsmasq
    iptables
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
  # Megapixels Camera Pipeline Configuration for PinePhone Pro
  # ---------------------------------------------------------------------------
  environment.etc."megapixels/config/pine64,pinephone-pro.conf" = {
    mode = "0644";
    text = ''
      Version = 1;
      Make: "PINE64";
      Model: "PinePhone Pro";

      Rear: {
          SensorDriver: "imx258";
          BridgeDriver: "rkisp1";

           Modes: (
              {
                  Width: 4208;
                  Height: 3120;
                  Rate: 30;
                  Format: "RGGB8";
                  Rotate: 270;
                  FocalLength: 3.33;
                  FNumber: 3.0;

                  Pipeline: (
                      {Type: "Link", From: "imx258", FromPad: 0, To: "rkisp1_csi", ToPad: 0},
                      {Type: "Link", From: "rkisp1_csi", FromPad: 1, To: "rkisp1_isp", ToPad: 0},
                      {Type: "Link", From: "rkisp1_isp", FromPad: 2, To: "rkisp1_resizer_mainpath", ToPad: 0},
                      {Type: "Mode", Entity: "imx258", Format: "RGGB10P"},
                      {Type: "Mode", Entity: "rkisp1_csi"},
                      {Type: "Mode", Entity: "rkisp1_isp"},
                      {Type: "Mode", Entity: "rkisp1_isp", Pad: 2, Format: "RGGB8", SkipTry: true},
                      {Type: "Mode", Entity: "rkisp1_resizer_mainpath"},
                      {Type: "Mode", Entity: "rkisp1_resizer_mainpath", Pad: 1},
                      {Type: "Crop", Entity: "rkisp1_isp"},
                      {Type: "Crop", Entity: "rkisp1_isp", Pad: 2},
                      {Type: "Crop", Entity: "rkisp1_resizer_mainpath"}
                  );
              },
              {
                  Width: 1048;
                  Height: 780;
                  Rate: 30;
                  Format: "RGGB8";
                  Rotate: 270;
                  FocalLength: 3.33;
                  FNumber: 3.0;

                  Pipeline: (
                      {Type: "Link", From: "imx258", FromPad: 0, To: "rkisp1_csi", ToPad: 0},
                      {Type: "Link", From: "rkisp1_csi", FromPad: 1, To: "rkisp1_isp", ToPad: 0},
                      {Type: "Link", From: "rkisp1_isp", FromPad: 2, To: "rkisp1_resizer_mainpath", ToPad: 0},
                      {Type: "Mode", Entity: "imx258", Format: "RGGB10P"},
                      {Type: "Mode", Entity: "rkisp1_csi"},
                      {Type: "Mode", Entity: "rkisp1_isp"},
                      {Type: "Mode", Entity: "rkisp1_isp", Pad: 2, Format: "RGGB8", SkipTry: true},
                      {Type: "Mode", Entity: "rkisp1_resizer_mainpath"},
                      {Type: "Mode", Entity: "rkisp1_resizer_mainpath", Pad: 1},
                      {Type: "Crop", Entity: "rkisp1_isp"},
                      {Type: "Crop", Entity: "rkisp1_isp", Pad: 2},
                      {Type: "Crop", Entity: "rkisp1_resizer_mainpath"}
                  );
              }
          );
      };

      Front: {
          SensorDriver: "ov8858";
          BridgeDriver: "rkisp1";
          FlashDisplay: true;

          Modes: (
              {
                  Width: 3264;
                  Height: 2448;
                  Rate: 30;
                  Format: "BGGR8";
                  Rotate: 90;
                  FocalLength: 3.33;
                  FNumber: 3.0;
                  Mirror: true;

                  Pipeline: (
                      {Type: "Link", From: "ov8858", FromPad: 0, To: "rkisp1_csi", ToPad: 0},
                      {Type: "Link", From: "rkisp1_csi", FromPad: 1, To: "rkisp1_isp", ToPad: 0},
                      {Type: "Link", From: "rkisp1_isp", FromPad: 2, To: "rkisp1_resizer_mainpath", ToPad: 0},
                      {Type: "Mode", Entity: "ov8858", Format: "BGGR10"},
                      {Type: "Mode", Entity: "rkisp1_csi"},
                      {Type: "Mode", Entity: "rkisp1_isp"},
                      {Type: "Mode", Entity: "rkisp1_isp", Pad: 2, Format: "BGGR8", SkipTry: true},
                      {Type: "Mode", Entity: "rkisp1_resizer_mainpath"},
                      {Type: "Mode", Entity: "rkisp1_resizer_mainpath", Pad: 1},
                      {Type: "Crop", Entity: "rkisp1_isp"},
                      {Type: "Crop", Entity: "rkisp1_isp", Pad: 2},
                      {Type: "Crop", Entity: "rkisp1_resizer_mainpath"}
                  );
              },
              {
                  Width: 1048;
                  Height: 780;
                  Rate: 30;
                  Format: "BGGR8";
                  Rotate: 90;
                  FocalLength: 3.33;
                  FNumber: 3.0;
                  Mirror: true;

                  Pipeline: (
                      {Type: "Link", From: "ov8858", FromPad: 0, To: "rkisp1_csi", ToPad: 0},
                      {Type: "Link", From: "rkisp1_csi", FromPad: 1, To: "rkisp1_isp", ToPad: 0},
                      {Type: "Link", From: "rkisp1_isp", FromPad: 2, To: "rkisp1_resizer_mainpath", ToPad: 0},
                      {Type: "Mode", Entity: "ov8858", Format: "BGGR10", Width: 1632, Height: 1224},
                      {Type: "Mode", Entity: "rkisp1_csi"},
                      {Type: "Mode", Entity: "rkisp1_isp"},
                      {Type: "Mode", Entity: "rkisp1_isp", Pad: 2, Format: "BGGR8", Width: 1048, Height: 780, SkipTry: true},
                      {Type: "Mode", Entity: "rkisp1_resizer_mainpath"},
                      {Type: "Mode", Entity: "rkisp1_resizer_mainpath", Pad: 1},
                      {Type: "Crop", Entity: "rkisp1_isp"},
                      {Type: "Crop", Entity: "rkisp1_isp", Pad: 2},
                      {Type: "Crop", Entity: "rkisp1_resizer_mainpath"}
                  );
              }
          );
      };
    '';
  };
  # ---------------------------------------------------------------------------
  # Hardware Graphics & Bluetooth (Mesa / Panfrost GPU & AP6255 Broadcom BT)
  # ---------------------------------------------------------------------------
  hardware.graphics.enable = lib.mkDefault true;
  hardware.bluetooth = {
    enable = true;
    powerOnBoot = true;
    settings = {
      General = {
        Experimental = true;
        AutoEnable = true;
        MultiProfile = "multiple";
        FastConnectable = true;
      };
    };
  };
  hardware.enableRedistributableFirmware = true;
  hardware.firmware = with pkgs; [ linux-firmware ];

  environment.etc."pinephone-bluetooth-setup.sh" = {
    mode = "0755";
    text = ''
      #!/bin/sh
      chmod 666 /dev/rfkill 2>/dev/null || true
      for i in $(seq 1 10); do
        if [ -d /sys/class/bluetooth/hci0 ]; then
          break
        fi
        sleep 1
      done

      rfkill unblock bluetooth 2>/dev/null || true
      ADDR=$(hciconfig hci0 2>/dev/null | grep "BD Address" | awk '{print $3}' || true)
      if [ "$ADDR" = "AA:AA:AA:AA:AA:AA" ] || [ -z "$ADDR" ]; then
        MAC="02:45:67:$(printf '%02x:%02x:%02x' $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256)))"
        hciconfig hci0 down 2>/dev/null || true
        btmgmt -i hci0 public-addr "$MAC" 2>/dev/null || true
        hciconfig hci0 up 2>/dev/null || true
        systemctl restart bluetooth 2>/dev/null || true
        sleep 1
      fi
      bluetoothctl power on 2>/dev/null || true
      bluetoothctl discoverable on 2>/dev/null || true
      bluetoothctl pairable on 2>/dev/null || true
    '';
  };

  systemd.services.pinephone-bluetooth-setup = {
    description = "Initialize PinePhone Pro Bluetooth & RFKill Permissions";
    wantedBy = [ "multi-user.target" ];
    after = [ "bluetooth.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = "/etc/pinephone-bluetooth-setup.sh";
    };
  };

  environment.etc."pinephone-audio-setup.sh" = {
    mode = "0755";
    text = ''
      #!/bin/sh
      if ! grep -q "PinePhonePro" /proc/asound/cards 2>/dev/null; then
        echo 1-001c > /sys/bus/i2c/drivers_probe 2>/dev/null || true
        sleep 1
      fi

      amixer -c PinePhonePro sset "SPOL MIX SPKVOL L" on 2>/dev/null || true
      amixer -c PinePhonePro sset "SPOR MIX SPKVOL R" on 2>/dev/null || true
      amixer -c PinePhonePro sset "Speaker Channel" on 2>/dev/null || true
      amixer -c PinePhonePro sset "Speaker L" on 2>/dev/null || true
      amixer -c PinePhonePro sset "Speaker R" on 2>/dev/null || true
      amixer -c PinePhonePro sset "Speaker" 100% 2>/dev/null || true
      amixer -c PinePhonePro sset "Internal Speaker" on 2>/dev/null || true
      alsactl store 2>/dev/null || true
    '';
  };

  systemd.services.pinephone-audio-setup = {
    description = "Initialize PinePhone Pro Audio Codec & ALSA Mixer Switches";
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = "/etc/pinephone-audio-setup.sh";
    };
  };

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
  networking.firewall = {
    enable = true;
    allowedUDPPorts = [ 53 67 68 5353 ]; # DNS (53), DHCP Server/Client (67/68), mDNS (5353)
    allowedTCPPorts = [ 53 22 ];
    checkReversePath = false;
    extraCommands = ''
      # Allow hotspot DHCP and DNS traffic
      iptables -A nixos-fw -p udp --dport 67:68 --sport 67:68 -j ACCEPT 2>/dev/null || true
      iptables -A nixos-fw -p udp --dport 53 -j ACCEPT 2>/dev/null || true
      iptables -A nixos-fw -p tcp --dport 53 -j ACCEPT 2>/dev/null || true
    '';
  };

  # Enable IPv4 & IPv6 forwarding for Hotspot / Tethering to cellular
  boot.kernel.sysctl = {
    "net.ipv4.ip_forward" = 1;
    "net.ipv6.conf.all.forwarding" = 1;
  };

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

  # Enable Bluetooth Blueman Manager and Modem (eg25-manager & calls) for PinePhone Pro
  services.blueman.enable = true;

  services.eg25-manager.enable = true;
  programs.calls.enable = true;
  networking.modemmanager.enable = true;

  # Mint Mobile GSM data APN (T-Mobile MVNO, apn=wholesale)
  environment.etc."NetworkManager/system-connections/Mint.nmconnection" = {
    text = ''
      [connection]
      id=Mint
      uuid=ac25f14b-32d8-457f-b56d-f8c2fa8e1a38
      type=gsm

      [gsm]
      apn=wholesale
      home-only=true
      sim-id=8901240517129720516

      [ipv4]
      dns-priority=120
      method=auto
      route-metric=1050

      [ipv6]
      addr-gen-mode=default
      method=auto
    '';
    mode = "0600";
  };

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

  # chatty (SMS client) depends on olm for E2E encryption support
  nixpkgs.config.permittedInsecurePackages = [ "olm-3.2.16" ];

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

      epiphany = super.emptyDirectory;
    })
  ];
}
