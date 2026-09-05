{ config, lib, pkgs, ... }:

let
  inherit (lib) mkEnableOption mkIf mkOption types;
  cfg = config.pinephone.power;
  package = pkgs.callPackage ./pkgs/pinephone-power-monitor { };

  profileType = types.submodule {
    options = {
      cpuMaxPercent = mkOption {
        type = types.ints.between 10 100;
        description = "Maximum CPU frequency as a percentage of each policy's hardware maximum.";
      };
      cpuGovernor = mkOption {
        type = types.str;
        description = "Preferred CPU frequency governor; falls back safely when unavailable.";
      };
      gpuMaxPercent = mkOption {
        type = types.ints.between 10 100;
        description = "Maximum GPU frequency as a percentage of its hardware maximum.";
      };
      gpuGovernor = mkOption {
        type = types.str;
        description = "Preferred GPU devfreq governor; falls back safely when unavailable.";
      };
      headless = mkOption {
        type = types.bool;
        default = false;
        description = "Whether this profile disables the interactive display session.";
      };
      offlineCpus = mkOption {
        type = types.listOf (types.ints.between 1 255);
        default = [ ];
        description = "CPU indices to offline while this profile is active.";
      };
    };
  };

  monitorConfig = {
    inherit (cfg)
      batteryPath
      backlightPath
      criticalPercent
      defaultProfile
      interactiveBrightness
      interactiveServices
      listenAddress
      manageFrequencies
      port
      performanceOnExternalPower
      powerSavePercent
      retentionDays
      sampleInterval
      shutdownConfirmations
      shutdownPercent
      shutdownVoltageMicrovolts
      voltageGuardPercent
      warningPercent
      ;
    profiles = cfg.profiles;
  };
in
{
  options.pinephone.power = {
    enable = mkEnableOption "PinePhone battery telemetry and low-charge protection";

    batteryPath = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "/sys/class/power_supply/rk817-battery";
      description = "Battery sysfs directory, or null to discover the system battery by type.";
    };

    backlightPath = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "/sys/class/backlight/backlight";
      description = "Backlight sysfs directory, or null to discover the first backlight.";
    };

    interactiveBrightness = mkOption {
      type = types.ints.unsigned;
      default = 51;
      description = "Fallback brightness restored when leaving a headless profile.";
    };

    interactiveServices = mkOption {
      type = types.listOf types.str;
      default = [ "phosh.service" ];
      description = "Services stopped in headless profiles and started in interactive profiles.";
    };

    sampleInterval = mkOption {
      type = types.ints.positive;
      default = 30;
      description = "Seconds between battery samples.";
    };

    retentionDays = mkOption {
      type = types.ints.positive;
      default = 30;
      description = "Number of days of CSV telemetry to retain.";
    };

    listenAddress = mkOption {
      type = types.str;
      default = "127.0.0.1";
      description = "Address for the read-only battery dashboard.";
    };

    port = mkOption {
      type = types.port;
      default = 9095;
      description = "TCP port for the read-only battery dashboard.";
    };

    warningPercent = mkOption {
      type = types.ints.between 1 100;
      default = 20;
      description = "Capacity at which a low-battery warning is logged.";
    };

    powerSavePercent = mkOption {
      type = types.ints.between 1 100;
      default = 15;
      description = "Capacity at which auto mode selects the powersave profile.";
    };

    performanceOnExternalPower = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Whether auto mode should force the performance profile while external
        power is connected. Disabled by default to reduce charging heat.
      '';
    };

    manageFrequencies = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Whether profile changes write CPU cpufreq and GPU devfreq controls.
        Disable this to retain telemetry and safety protection without changing
        performance policy during display-server startup.
      '';
    };

    criticalPercent = mkOption {
      type = types.ints.between 1 100;
      default = 8;
      description = "Capacity at which auto mode selects the critical profile.";
    };

    shutdownPercent = mkOption {
      type = types.ints.between 1 100;
      default = 5;
      description = ''
        Discharging capacity at which an orderly poweroff is requested. When
        voltage shutdown is configured, low voltage must corroborate this
        percentage so transient RK818 0% readings cannot cause a boot loop.
      '';
    };

    shutdownVoltageMicrovolts = mkOption {
      type = types.nullOr types.ints.positive;
      default = 3400000;
      description = ''
        Discharging battery voltage that triggers an orderly poweroff. The
        voltage guard is only active below voltageGuardPercent. Set null to
        disable voltage-based shutdown.
      '';
    };

    voltageGuardPercent = mkOption {
      type = types.ints.between 1 100;
      default = 20;
      description = "Maximum capacity at which the low-voltage shutdown guard may trigger.";
    };

    shutdownConfirmations = mkOption {
      type = types.ints.positive;
      default = 3;
      description = "Consecutive unsafe discharging samples required before poweroff.";
    };

    defaultProfile = mkOption {
      type = types.enum [ "auto" "performance" "balanced" "gateway" "powersave" "critical" ];
      default = "auto";
      description = "Initial power profile. It can later be changed with power-profile.";
    };

    profiles = mkOption {
      type = types.attrsOf profileType;
      default = {
        performance = {
          cpuMaxPercent = 100;
          cpuGovernor = "performance";
          gpuMaxPercent = 100;
          gpuGovernor = "performance";
        };
        balanced = {
          cpuMaxPercent = 75;
          cpuGovernor = "schedutil";
          # 67% selects the RK3399 GPU's exact 400 MHz OPP.  Higher Panfrost
          # clocks have coincided with unrecoverable UI/system stalls.
          gpuMaxPercent = 67;
          gpuGovernor = "simple_ondemand";
        };
        gateway = {
          # 81% selects the RK3399's exact 816 MHz OPP on the little cluster.
          cpuMaxPercent = 81;
          cpuGovernor = "schedutil";
          gpuMaxPercent = 100;
          gpuGovernor = "simple_ondemand";
          headless = true;
          offlineCpus = [ 4 5 ];
        };
        powersave = {
          cpuMaxPercent = 50;
          cpuGovernor = "schedutil";
          gpuMaxPercent = 50;
          gpuGovernor = "simple_ondemand";
        };
        critical = {
          cpuMaxPercent = 35;
          cpuGovernor = "powersave";
          gpuMaxPercent = 35;
          gpuGovernor = "powersave";
        };
      };
      description = "CPU and GPU limits applied by each selectable profile.";
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.shutdownPercent < cfg.criticalPercent
          && cfg.criticalPercent <= cfg.powerSavePercent
          && cfg.powerSavePercent <= cfg.warningPercent;
        message = "PinePhone battery thresholds must satisfy shutdown < critical <= powersave <= warning.";
      }
      {
        assertion = builtins.all
          (name: builtins.hasAttr name cfg.profiles)
          [ "performance" "balanced" "gateway" "powersave" "critical" ];
        message = "pinephone.power.profiles must define performance, balanced, gateway, powersave, and critical.";
      }
    ];

    environment.etc."pinephone-power-monitor.json".text = builtins.toJSON monitorConfig;
    environment.systemPackages = [ package ];

    systemd.services.pinephone-power-monitor = {
      description = "PinePhone battery telemetry and low-charge protection";
      wantedBy = [ "multi-user.target" ];
      after = [ "systemd-udev-settle.service" ];
      serviceConfig = {
        Type = "simple";
        ExecStart = "${package}/bin/pinephone-power-monitor --config /etc/pinephone-power-monitor.json daemon";
        Restart = "always";
        RestartSec = 5;
        StateDirectory = "pinephone-power-monitor";
        StateDirectoryMode = "0755";
        UMask = "0022";
        Nice = 10;
        IOSchedulingClass = "idle";
        NoNewPrivileges = true;
        ProtectHome = true;
        ProtectSystem = "strict";
        PrivateTmp = true;
        ReadWritePaths = [ "/var/lib/pinephone-power-monitor" ];
      };
    };
  };
}
