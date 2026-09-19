{ config, lib, pkgs, ... }:

let
  inherit (lib) mkEnableOption mkIf mkOption types;
  cfg = config.services.pebble-manager;
in
{
  options.services.pebble-manager = {
    enable = mkEnableOption "Pebble Smartwatch web manager and sideloading daemon";

    listenAddress = mkOption {
      type = types.str;
      default = "127.0.0.1";
      description = "Listen address for the Pebble Manager web portal.";
    };

    port = mkOption {
      type = types.port;
      default = 9096;
      description = "TCP port for the Pebble Manager web portal.";
    };

    openFirewall = mkOption {
      type = types.bool;
      default = false;
      description = "Whether to open the web portal port in the firewall.";
    };

    package = mkOption {
      type = types.package;
      default = pkgs.callPackage ./default.nix { };
      description = "The pebble-manager package to use.";
    };
  };

  config = mkIf cfg.enable {
    networking.firewall.allowedTCPPorts = lib.optionals cfg.openFirewall [ cfg.port ];

    environment.systemPackages = [ cfg.package ];

    systemd.user.services.pebble-manager = {
      description = "Pebble Smartwatch Manager and Sideloading Web Portal";
      wantedBy = [ "default.target" ];
      after = [ "libpebble3d.service" ];
      wants = [ "libpebble3d.service" ];
      serviceConfig = {
        ExecStart = "${cfg.package}/bin/pebble-manager serve --listen ${cfg.listenAddress} --port ${toString cfg.port}";
        Restart = "always";
        RestartSec = 5;
      };
    };
  };
}
