# NixOS Modules

NixOS modules shared across my infrastructure repositories. Each one is
generic: no secrets, hostnames, or client-specific configuration live here.

Consume a tagged release:

```nix
inputs.nixos-modules.url = "github:aydinaksel/nixos-modules/v0.2.0";
```

## Observability Shipper

`nixosModules.observability-shipper` runs Grafana Alloy to ship the systemd
journal to Loki and machine metrics to Mimir on argus. When host-proxy is
enabled, its metrics are scraped and shipped too, as are any local endpoints
listed in `scrapeTargets`.

The host's token is its whole identity. Argus maps each token to a tenant such
as `fbrmarble.pan`, so a host can only ever write as itself, and its token
cannot read anything back. The host attaches no labels of its own beyond
`job` and the journal's `unit`.

Lines written by Rust's `tracing` formatter get their level as structured
metadata, and their leading timestamp dropped, since the journal already has
one. Other lines pass through unchanged.

```nix
{ config, nixos-modules, ... }:

{
  imports = [ nixos-modules.nixosModules.observability-shipper ];

  sops.secrets."argus-logs-metrics-ingest-token".restartUnits = [ "alloy.service" ];

  services.observabilityShipper = {
    enable = true;
    tokenFile = config.sops.secrets."argus-logs-metrics-ingest-token".path;
  };
}
```

Argus accepts a host once the SHA-256 digest of its token is listed against
its tenant. Compute the digest with `printf %s "$token" | sha256sum`.

## Checks

`nix flake check` renders the Alloy configuration with and without extra scrape
targets, and runs `alloy validate` on both.
