{
  description = "NixOS modules shared across Aydin's infrastructure repositories";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";

  outputs =
    { self, nixpkgs }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};

      alloyConfigurationFor =
        shipperSettings:
        (nixpkgs.lib.nixosSystem {
          inherit system;
          modules = [
            self.nixosModules.observability-shipper
            {
              networking.hostName = "check";
              system.stateVersion = "26.05";
              services.observabilityShipper = {
                enable = true;
              }
              // shipperSettings;
            }
          ];
        }).config.environment.etc."alloy/config.alloy".source;

      validateAlloyConfiguration =
        name: shipperSettings:
        pkgs.runCommand "observability-shipper-${name}" { nativeBuildInputs = [ pkgs.grafana-alloy ]; } ''
          cat ${alloyConfigurationFor shipperSettings}
          alloy validate ${alloyConfigurationFor shipperSettings}
          touch $out
        '';
    in
    {
      nixosModules.observability-shipper = ./modules/observability-shipper.nix;

      checks.${system} = {
        observability-shipper-minimal = validateAlloyConfiguration "minimal" {
          tokenFile = "/run/secrets/argus-logs-metrics-ingest-token";
        };
        observability-shipper-with-scrape-targets = validateAlloyConfiguration "with-scrape-targets" {
          tokenFile = "/run/secrets/argus-logs-metrics-ingest-token";
          hostProxyMetricsAddress = "127.0.0.1:9184";
          scrapeTargets.hermes = "127.0.0.1:9185";
        };
      };

      formatter.${system} = pkgs.nixfmt-tree;

      devShells.${system}.default = pkgs.mkShell { packages = [ pkgs.nixfmt ]; };
    };
}
