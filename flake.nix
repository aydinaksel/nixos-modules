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
        observability-shipper-remote = validateAlloyConfiguration "remote" {
          organization = "check";
          tokenFile = "/run/secrets/argus-logs-metrics-ingest-token";
          hostProxyMetricsAddress = "127.0.0.1:9184";
        };
        observability-shipper-loopback = validateAlloyConfiguration "loopback" {
          organization = "check";
          tokenFile = null;
          logsEndpoint = "http://127.0.0.1:3100/loki/api/v1/push";
          metricsEndpoint = "http://127.0.0.1:9090/api/v1/write";
        };
      };

      formatter.${system} = pkgs.nixfmt-tree;

      devShells.${system}.default = pkgs.mkShell { packages = [ pkgs.nixfmt ]; };
    };
}
