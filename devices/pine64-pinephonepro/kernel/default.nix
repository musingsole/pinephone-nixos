{
  mobile-nixos,
  fetchzip,
  ...
}:

let
  # Keep the kernel, configuration, and patch queue on the same pmaports
  # revision. In particular, the later USB/Type-C patches are an ordered
  # series and must not be selected independently.
  pmaportsRevision = "aeb8717ee45d9baf68701ddc40e058a41aaf733a";
  pmaports = fetchzip {
    url = "https://gitlab.postmarketos.org/postmarketOS/pmaports/-/archive/${pmaportsRevision}/pmaports-${pmaportsRevision}.tar.gz";
    hash = "sha256-4ZxD2l0WpFFMd3Qq3UF0ytazCgg+kz0QZbCDXcniOdk=";
  };
  pinephoneProDir = "${pmaports}/device/community/linux-pine64-pinephonepro";
  patchNames = [
    "0001-media-imx258-Add-i2c-supply.patch"
    "0002-media-imx258-Add-reset-gpio.patch"
    "0003-media-imx258-Drop-interface-speed-to-1224-mbps.patch"
    "0004-media-imx258-Add-debug-register-access.patch"
    "0005-ASoC-codecs-rt5640-Fix-output-mixer-input-channel-li.patch"
    "0006-ASoC-codecs-rt5640-Fix-hpout-restore-when-lout-is-en.patch"
    "0007-ASoC-codecs-rt5640-Add-input-mixer-input-volume-cont.patch"
    "0008-ASoC-codecs-rt5640-Allow-to-control-single-ended-dif.patch"
    "0009-ASoC-codecs-rt5640-Keep-the-codec-enabled-when-idle.patch"
    "0010-ASoC-codecs-rt5640-Add-support-for-power-supplies.patch"
    "0011-ASoC-rockchip-Fix-doubling-of-playback-speed-after-s.patch"
    "0012-power-supply-Add-support-for-USB_BC_ENABLED-and-USB_.patch"
    "0013-mfd-rk8xx-Enable-rk808-clkout2-function.patch"
    "0014-power-supply-rk818_battery-Add-battery-charger-drive.patch"
    "0015-power-supply-rk818_battery-Add-code-docs-for-the-HW-.patch"
    "0016-power-supply-rk818_battery-Don-t-override-configured.patch"
    "0017-power-supply-rk818_battery-Scale-charge-current-by-t.patch"
    "0018-power-supply-rk818_battery-Scale-termination-current.patch"
    "0019-power-supply-rk818_battery-Compensate-for-IR-drop-wh.patch"
    "0020-power-supply-rk818_battery-Rework-the-low-voltage-mo.patch"
    "0021-Revert-usb-typec-tcpm-unregister-existing-source-cap.patch"
    "0022-usb-typec-altmodes-displayport-Respect-DP_CAP_RECEPT.patch"
    "0023-usb-typec-tcpm-Unregister-altmodes-before-registerin.patch"
    "0024-usb-typec-tcpm-Fix-PD-devices-capabilities-registrat.patch"
    "0025-usb-typec-fusb302-Slightly-increase-wait-time-for-BC.patch"
    "0026-usb-typec-fusb302-Set-the-current-before-enabling-pu.patch"
    "0027-usb-typec-fusb302-Retry-reading-of-CC-pins-status-if.patch"
    "0028-usb-typec-fusb302-Update-VBUS-state-even-if-VBUS-int.patch"
    "0029-usb-typec-fusb302-Add-OF-extcon-support.patch"
    "0030-usb-typec-fusb302-Fix-register-definitions.patch"
    "0031-usb-typec-fusb302-Clear-interrupts-before-we-start-t.patch"
    "0032-usb-typec-fusb302-Turn-off-VBUS-and-VCONN-on-shutdow.patch"
    "0033-thermal-rockchip-Add-support-for-RV1106-SoC.patch"
    "0034-soc-rockchip-Add-support-for-power-monitoring-driver.patch"
    "0035-rtc-rockchip-Add-support-for-RTC-present-in-RV1106-S.patch"
    "0036-thermal-rockchip-Add-support-for-RK3506.patch"
    "0037-arm64-dts-rockchip-rk3399-Disable-debug-nodes.patch"
    "0038-arm64-dts-rockchip-rk3399-Add-reboot-mode-driver.patch"
    "0039-arm64-dts-rockchip-rk3399-Power-cycle-the-USB3-PHY-o.patch"
    "0040-arm64-dts-rockchip-rk3399-Add-dmc_opp_table.patch"
    "0041-arm64-dts-rockchip-rk3399-s-Add-DMC-table.patch"
    "0042-arm64-dts-rockchip-rk3399-Number-the-CDN-DP-ports.patch"
    "0043-arm64-dts-rockchip-rk3399-pinephone-pro-Add-Type-C-p.patch"
    "0044-arm64-dts-rockchip-rk3399-pinephone-pro-Add-internal.patch"
    "0045-arm64-dts-rockchip-rk3399-pinephone-pro-Add-battery-.patch"
    "0046-arm64-dts-rockchip-rk3399-pinephone-pro-Add-sound-su.patch"
    "0047-arm64-dts-rockchip-rk3399-pinephone-pro-Add-modem-su.patch"
    "0048-arm64-dts-rockchip-rk3399-pinephone-pro-Change-modem.patch"
    "0049-arm64-dts-rockchip-rk3399-pinephone-pro-Add-light-pr.patch"
    "0050-arm64-dts-rockchip-rk3399-pinephone-pro-Add-I2C-supp.patch"
    "0051-arm64-dts-rockchip-rk3399-pinephone-pro-Add-magnetom.patch"
    "0052-arm64-dts-rockchip-rk3399-pinephone-pro-Add-mount-ma.patch"
    "0053-arm64-dts-rockchip-rk3399-pinephone-pro-Enable-POGO-.patch"
    "0054-arm64-dts-rockchip-rk3399-pinephone-pro-Add-pinephon.patch"
    "0055-arm64-dts-rockchip-rk3399-pinephone-pro-Switch-LED-b.patch"
    "0056-arm64-dts-rockchip-rk3399-pinephone-pro-Pre-configur.patch"
    "0057-arm64-dts-rockchip-rk3399-pinephone-pro-Improve-SPI-.patch"
    "0058-arm64-dts-rockchip-rk3399-pinephone-pro-Assign-power.patch"
    "0059-arm64-dts-rockchip-rk3399-pinephone-pro-Add-camera-f.patch"
    "0060-arm64-dts-rockchip-rk3399-pinephone-pro-Disable-inte.patch"
    "0061-Revert-usb-dwc3-Abort-suspend-on-soft-disconnect-fai.patch"
    "0062-phy-rockchip-inno-usb2-Add-support-for-RV1106-RV1103.patch"
    "0063-phy-rockchip-inno-usb2-Add-support-for-RK3506.patch"
    "0064-phy-rockchip-inno-usb2-Add-PHY-tuning-for-rk3566-rk3.patch"
    "0065-drm-rockchip-cdn-dp-Disable-CDN-DP-on-disconnect.patch"
    "0066-phy-rockchip-inno-usb2-Decrease-delay-between-port-i.patch"
    "0067-phy-rockchip-inno-usb2-More-robust-charger-detection.patch"
    "0068-usb-dwc3-Track-the-power-state-of-usb3_generic_phy.patch"
    "0069-usb-dwc3-Always-disable-SUSPHY-when-entering-a-role.patch"
    "0070-usb-dwc3-Track-cable-connection-state-separately-fro.patch"
    "0071-usb-dwc3-Power-cycle-USB3-PHY-on-role-connection-cha.patch"
    "0072-usb-dwc3-Register-the-role-even-when-no-cable-is-con.patch"
    "0073-phy-rockchip-inno-usb2-Set-up-charger-detection-mode.patch"
    "0074-usb-dwc3-Do-not-re-register-the-gadget-on-cable-even.patch"
    "0075-phy-rockchip-typec-Support-a-Type-C-orientation-swit.patch"
    "0076-phy-rockchip-typec-Support-a-Type-C-mode-mux.patch"
    "0077-phy-rockchip-typec-Publish-the-DP-lane-count.patch"
    "0078-drm-rockchip-cdn-dp-Support-ports-driven-by-a-Type-C.patch"
    "0079-phy-rockchip-inno-usb2-Learn-the-host-role-from-phy_.patch"
    "0080-usb-dwc3-Tell-the-UDC-core-when-there-is-no-cable.patch"
    "0081-phy-rockchip-inno-usb2-Do-not-run-charger-detection-.patch"
    "0082-usb-dwc3-Set-the-PHY-mode-before-starting-the-host.patch"
    "0083-usb-dwc3-Do-not-connect-the-gadget-while-no-cable-is.patch"
    "0084-phy-rockchip-inno-usb2-Power-the-PHY-up-before-the-h.patch"
    "0085-usb-dwc3-Require-MPS-aligned-OUT-buffers.patch"
    "0086-usb-typec-displayport-Update-the-mux-before-signalli.patch"
    "0087-mtd-spi-nor-gigadevice-Add-support-for-gd25lq128e.patch"
    "0088-clk-rk3399-Export-SCLK_CIF_OUT_SRC-to-device-tree.patch"
    "0089-clk-rockchip-rk3399-Don-t-allow-to-reparent-dclk_vop.patch"
  ];
in
mobile-nixos.kernel-builder {
  version = "7.2.0";
  configfile = "${pinephoneProDir}/config-pine64-pinephonepro.aarch64";

  src = fetchzip {
    url = "https://cdn.kernel.org/pub/linux/kernel/v7.x/linux-7.2.tar.xz";
    hash = "sha256-GAjLGXXJiU42En31XWWx31IRT63G2pNsDN4ifNGtHis=";
  };

  patches =
    map (name: "${pinephoneProDir}/megi_patches/${name}") patchNames
    ++ [ "${pinephoneProDir}/0001-arm64-dts-rk3399-pinephone-pro-Keep-modem-regulators.patch" ];

  postInstall = ''
    echo ":: Installing FDTs"
    mkdir -p $out/dtbs/rockchip
    cp -v "$buildRoot/arch/arm64/boot/dts/rockchip/rk3399-pinephone-pro.dtb" "$out/dtbs/rockchip/"
  '';

  isModular = true;
  isCompressed = false;
}
