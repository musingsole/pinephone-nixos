{ config, lib, pkgs, ... }:

let
  inherit (lib) mkEnableOption mkIf mkOption types;
  cfg = config.pinephone.pebble;
  package = pkgs.callPackage ./pkgs/pebble-manager { };
in
{
  imports = [
    ./pkgs/pebble-manager/module.nix
  ];

  options.pinephone.pebble = {
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
  };

  config = mkIf cfg.enable {
    services.pebble-manager = {
      enable = true;
      listenAddress = cfg.listenAddress;
      port = cfg.port;
      openFirewall = cfg.openFirewall;
      package = package;
    };
  };
}
