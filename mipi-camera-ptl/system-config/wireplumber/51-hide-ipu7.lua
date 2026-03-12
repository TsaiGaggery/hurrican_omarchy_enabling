-- Hide raw IPU7 V4L2 devices from PipeWire
-- Camera is provided via v4l2loopback + icamerasrc instead
v4l2_monitor.rules = {
  {
    matches = {
      {
        { "device.bus-path", "equals", "pci-0000:00:05.0" },
      },
    },
    apply_properties = {
      ["device.disabled"] = true,
    },
  },
}
