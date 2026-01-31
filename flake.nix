{
  description = "iMac advanced fan control (auto-mapping + asymmetric hysteresis)";
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = { self, nixpkgs }: {
    nixosModules.imac-fan-control = import ./modules/imac-fan-control.nix;
    # Convenience: example NixOS configuration
    nixosConfigurations.example = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        self.nixosModules.imac-fan-control
        ({ config, ... }: {
          services.imacFanControl.enable = true;
        })
      ];
    };
  };
}



