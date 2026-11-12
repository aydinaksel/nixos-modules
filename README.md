# NixOS Modules

NixOS modules shared across my infrastructure repositories. Each one is
generic: no secrets, hostnames, or client-specific configuration live here.

Consume a tagged release:

```nix
inputs.nixos-modules.url = "github:aydinaksel/nixos-modules/v0.1.0";
```

## Observability Shipper

`nixosModules.observability-shipper` runs Grafana Alloy to ship the systemd
journal to Loki and machine metrics to Prometheus on argus, labelled with the
host and its organization. When host-proxy is enabled, its metrics are scraped
and shipped too.

```nix
{ config, nixos-modules, ... }:

{
  imports = [ nixos-modules.nixosModules.observability-shipper ];

  sops.secrets."argus-logs-metrics-ingest-token".restartUnits = [ "alloy.service" ];

  services.observabilityShipper = {
    enable = true;
    organization = "chichek";
    tokenFile = config.sops.secrets."argus-logs-metrics-ingest-token".path;
  };
}
```

Argus accepts a host once the SHA-256 digest of its token is listed on its
ingest routes. Compute it with `printf %s "$token" | sha256sum`.

## Checks

`nix flake check` renders the Alloy configuration for a remote host and for
argus shipping over loopback, and runs `alloy validate` on both.
