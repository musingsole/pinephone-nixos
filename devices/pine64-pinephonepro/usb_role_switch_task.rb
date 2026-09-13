class Tasks::UsbRoleSwitchTask < SingletonTask
  def initialize()
    Tasks::SetupGadgetMode.instance.add_dependency(:Task, self)
    add_dependency(:Mount, "/sys")
  end

  def run()
    features = Configuration["boot"]["usb"]["features"]

    # With no stage-1 gadget functions requested, preserve the role negotiated
    # by the Type-C controller.  In particular, do not bounce an attached hub
    # through host -> device during every boot.
    return if features.empty?

    role_path = "/sys/class/usb_role/fe800000.usb-role-switch/role"
    return unless File.exist?(role_path)

    # Linux 7.2 keeps the UDC registered even without a cable, so the old
    # host -> device toggle is unnecessary and races gadget setup against the
    # asynchronous xHCI teardown.  Select device mode directly and wait until
    # both the role switch and UDC are ready before SetupGadgetMode proceeds.
    System.write(role_path, "device")

    50.times do
      role_ready = File.read(role_path).strip == "device"
      udc_ready = Dir.exist?("/sys/class/udc") && !Dir.children("/sys/class/udc").empty?
      return if role_ready && udc_ready
      sleep(0.1)
    end

    raise "USB device role did not settle or expose a UDC within 5 seconds"
  end
end

class Tasks::UsbGadgetConnectTask < SingletonTask
  def initialize()
    add_dependency(:Mount, "/sys")
    add_dependency(:Task, Tasks::SetupGadgetMode.instance)
    Targets[:SwitchRoot].add_dependency(:Task, self)
  end

  def run()
    return if Configuration["boot"]["usb"]["features"].empty?

    udc = Dir.children("/sys/class/udc").first
    return unless udc

    soft_connect_path = File.join("/sys/class/udc", udc, "soft_connect")
    return unless File.exist?(soft_connect_path)

    # When the cable is already attached at boot, the 7.2 DWC3 driver can
    # finish binding the ConfigFS gadget with its software-connect state
    # already set but without the host seeing a pull-up transition.  Pulse
    # only the gadget connection after SetupGadgetMode has bound g1.  This
    # makes the host enumerate it without bouncing the controller through
    # host mode and racing the asynchronous xHCI teardown.
    System.write(soft_connect_path, "disconnect")
    sleep(0.5)
    System.write(soft_connect_path, "connect")
  end
end
