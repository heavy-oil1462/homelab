{
  # Generic single-disk VM layout for disko: GPT with a BIOS boot partition
  # and an ext4 root filling the rest. Requires the disko NixOS module in the
  # consumer's flake.
  disko.devices = {
    disk = {
      main = {
        type = "disk";
        device = "/dev/sda";
        content = {
          type = "gpt";
          partitions = {
            boot = {
              priority = 1;
              name = "boot";
              start = "1M";
              end = "2M";
              type = "EF02";
            };
            root = {
              size = "100%";
              content = {
                type = "filesystem";
                format = "ext4";
                mountpoint = "/";
              };
            };
          };
        };
      };
    };
  };
}
