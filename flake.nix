{
  description = "A NixOS module that runs Dokploy (a self-hosted PaaS) using declarative systemd units";

  inputs = {};

  outputs = { self }:
    {
      nixosModules = {
        default = import ./nix-dokploy.nix;
        dokploy = import ./nix-dokploy.nix;
      };

      # For backwards compatibility
      nixosModule = self.nixosModules.default;
    };
}