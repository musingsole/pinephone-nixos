{ config, lib, pkgs, ... }:

let
  kernel = pkgs.callPackage ./kernel { };

  # The external pmaports config installs compressed modules but does not
  # generate the indexes modprobe needs.  Add them without rebuilding the
  # kernel itself; makeModulesClosure will consume this modules output while
  # the boot image continues to use the original kernel output.
  indexedKernelModules = pkgs.runCommand "${kernel.name}-indexed-modules" {
    nativeBuildInputs = [ pkgs.kmod ];
  } ''
    mkdir -p "$out/lib"
    cp -a --reflink=auto "${kernel}/lib/modules" "$out/lib/"
    chmod -R u+w "$out/lib/modules"
    depmod -b "$out" "${kernel.modDirVersion}"
  '';

  kernelWithIndexedModules = kernel // {
    modules = indexedKernelModules;
  };
in
{
  imports = [
    ./kernel-config.nix
  ];

  mobile.device.name = "pine64-pinephonepro";
  mobile.device.identity = {
    name = "Pinephone Pro";
    manufacturer = "Pine64";
  };
  mobile.device.supportLevel = "supported";

  mobile.hardware = {
    soc = "rockchip-rk3399s";
    ram = 1024 * 4;
    screen = {
      width = 720; height = 1440;
    };
  };

  mobile.boot.stage-1 = {
    kernel = {
      package = kernelWithIndexedModules;

      # The pmaports kernel configuration builds USB gadget support as
      # modules.  Stage 1 must therefore carry its requested module closure;
      # otherwise it gets an empty /lib/modules and cannot create the USB
      # ConfigFS gadget used for recovery, installation, and RNDIS access.
      modular = true;
    };
  };

  # NixOS' stage 2 obtains its module tree from the kernel derivation's
  # "modules" output, not from the passthru attribute consumed above by
  # Mobile NixOS.  The pmaports kernel has a single output, so point stage 2
  # at the indexed copy explicitly.  Without this, udev cannot resolve any
  # modalias: Wi-Fi stays absent and rockchip-isp1 never initializes DSI1 as
  # the camera PHY, leaving the Rockchip DRM aggregate device incomplete.
  system.modulesTree = lib.mkForce [ indexedKernelModules ];

  # The second DSI controller doubles as a camera PHY.  Rockchip DRM waits for
  # it as a component, so make its ISP consumer deterministic instead of
  # depending on udev cold-plug timing before Phoc starts.
  boot.kernelModules = [ "rockchip-isp1" ];

  # The U-Boot filesystem contains the kernel and DTBs twice: once for normal
  # boot and once for recovery.  Linux 7.2's DTB set no longer fits in the
  # generic 128 MiB default, so leave enough room for this and future updates.
  mobile.generatedFilesystems.boot.size = lib.mkForce (pkgs.image-builder.helpers.size.MiB 256);

  boot.kernelParams = [
    "earlycon=uart8250,mmio32,0xff1a0000"
  ];

  # Serial console on ttyS2, using the serial headphone adapter.
  mobile.boot.serialConsole = "ttyS2,115200";

  mobile.system.type = "u-boot";

  mobile.usb.mode = "gadgetfs";


  # It seems Pine64 does not have an idVendor...
  mobile.usb.idVendor = "1209";  # http://pid.codes/1209/
  mobile.usb.idProduct = "0069"; # "common tasks, such as testing, generic USB-CDC devices, etc."

  # Mainline gadgetfs functions
  mobile.usb.gadgetfs.functions = {
    rndis = "rndis.usb0";
    mass_storage = "mass_storage.0";
    adb = "ffs.adb";
  };

  mobile.boot.stage-1.bootConfig = {
    # Used by target-disk-mode to share the internal drive
    storage.internal = "/dev/disk/by-path/platform-fe330000.mmc";
  };

  mobile.device.firmware = pkgs.callPackage ./firmware {};
  mobile.boot.stage-1.firmware = [
    config.mobile.device.firmware
  ];
  hardware.firmware = [
    config.mobile.device.firmware
  ];

  # Modem service
  services.eg25-manager.enable = lib.mkDefault true;

  # Alsa UCM profiles
  mobile.quirks.audio.alsa-ucm-meld = true;
  environment.systemPackages = [ pkgs.mobile-nixos.pine64-alsa-ucm ];

  mobile.boot.stage-1.tasks = [ ./usb_role_switch_task.rb ];

  mobile.documentation.hydraOutputs = [
    ["installer.@device@" "Installer image"]
  ];
}
