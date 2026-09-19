{
  description = "Pebble Smartwatch Manager and Sideloading Utility for PinePhone";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = { self, nixpkgs }:
    let
      supportedSystems = [ "x86_64-linux" "aarch64-linux" ];
      forAllSystems = f: nixpkgs.lib.genAttrs supportedSystems (system: f (import nixpkgs { inherit system; }));
    in
    {
      packages = forAllSystems (pkgs: {
        default = pkgs.callPackage ./default.nix { };
        pebble-manager = pkgs.callPackage ./default.nix { };
      });

      apps = forAllSystems (pkgs: {
        default = {
          type = "app";
          program = "${self.packages.${pkgs.system}.default}/bin/pebble-manager";
        };
        pebble-manager = {
          type = "app";
          program = "${self.packages.${pkgs.system}.default}/bin/pebble-manager";
        };
      });

      # NixOS system module
      nixosModules = {
        default = self.nixosModules.pebble-manager;
        pebble-manager = import ./module.nix;
      };

      # Flake-parts module
      flakeModules = {
        default = self.flakeModules.pebble-manager;
        pebble-manager = { ... }: {
          perSystem = { config, self', pkgs, ... }: {
            packages.pebble-manager = pkgs.callPackage ./default.nix { };
          };
        };
      };
    };
}
