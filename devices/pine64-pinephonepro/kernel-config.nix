{ config, lib, pkgs, ... }:

{
  # Minimum driver hardware requirements
  mobile.kernel.structuredConfig = [
    (helpers: with helpers; {
      # eMMC
      MMC_SDHCI_OF_ARASAN = yes;

      # Display
      DRM_PANEL_HIMAX_HX8394 = yes;

      # Touch screen
      TOUCHSCREEN_GOODIX = yes;

      # General wireless
      WIRELESS = yes;

      # Bluetooth
      BT = yes;
      BT_HCIUART = yes;
      BT_HCIUART_BCM = yes;

      # Wifi
      WLAN = yes;
      WLAN_VENDOR_BROADCOM = yes;
      BRCMUTIL = module;
      BRCMFMAC = module;
      BRCMFMAC_SDIO = yes;
      BRCMSMAC = module;
      BRCM_TRACING = yes;
      BRCMDBG = yes;
      MAC80211 = module;

      # Sensors
      STK3310 = yes; # Light sensor

      # SPI Flash
      SPI = yes;
      SPI_ROCKCHIP = yes;
      MTD = yes;
      MTD_SPI_NOR = yes;

      # Keyboard
      IP5XXX_POWER = yes;
      KEYBOARD_PINEPHONE = yes;

      # Vibrate motor
      INPUT_GPIO_VIBRA = yes;

      # Audio (Realtek RT5640 Codec, ES8316 Codec, Rockchip I2S & Sound Cards)
      SOUND = yes;
      SND = yes;
      SND_SOC = yes;
      SND_SOC_ROCKCHIP_I2S = yes;
      SND_SOC_RL6231 = yes;
      SND_SOC_RT5640 = yes;
      SND_SOC_ES8316 = yes;
      SND_SIMPLE_CARD = yes;
      SND_AUDIO_GRAPH_CARD = yes;

      # Camera Sensors & Lens Actuators (DW9714 VCM, OV8858 front, IMX258 rear, Rockchip ISP1)
      VIDEO_IMX258 = module;
      VIDEO_OV8858 = module;
      VIDEO_DW9714 = module;
      VIDEO_ROCKCHIP_ISP1 = module;
    })
  ];
}
