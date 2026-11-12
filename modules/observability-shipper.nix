{ config, lib, ... }:

let
  shipper = config.services.observabilityShipper;

  tokenCredentialName = "ingest-token";
  tokenCredentialPath = "/run/credentials/alloy.service/${tokenCredentialName}";
  sendsToken = shipper.tokenFile != null;

  bearerTokenSetting = lib.optionalString sendsToken ''
    bearer_token_file = "${tokenCredentialPath}"
  '';

  hostProxyScrape = lib.optionalString (shipper.hostProxyMetricsAddress != null) ''
    prometheus.scrape "host_proxy" {
      targets = [{
        "__address__" = "${shipper.hostProxyMetricsAddress}",
        "job"         = "host-proxy",
      }]
      forward_to      = [prometheus.remote_write.argus.receiver]
      scrape_interval = "${toString shipper.scrapeIntervalSeconds}s"
    }
  '';

  alloyConfiguration = ''
    loki.relabel "journal" {
      forward_to = []

      rule {
        source_labels = ["__journal__systemd_unit"]
        target_label  = "unit"
      }
    }

    loki.source.journal "system" {
      forward_to    = [loki.write.argus.receiver]
      relabel_rules = loki.relabel.journal.rules
      max_age       = "12h"

      labels = {
        job          = "systemd-journal",
        host         = "${shipper.hostLabel}",
        organization = "${shipper.organization}",
      }
    }

    loki.write "argus" {
      endpoint {
        url = "${shipper.logsEndpoint}"
        ${bearerTokenSetting}
      }
    }

    prometheus.exporter.unix "node" { }

    prometheus.scrape "node" {
      targets         = prometheus.exporter.unix.node.targets
      forward_to      = [prometheus.remote_write.argus.receiver]
      scrape_interval = "${toString shipper.scrapeIntervalSeconds}s"
    }

    ${hostProxyScrape}

    prometheus.remote_write "argus" {
      endpoint {
        url = "${shipper.metricsEndpoint}"
        ${bearerTokenSetting}
      }

      external_labels = {
        host         = "${shipper.hostLabel}",
        organization = "${shipper.organization}",
      }
    }
  '';

  hostProxyMetricsAddress =
    if config.services.hostProxy.enable or false then
      config.services.hostProxy.metricsAddress
    else
      null;
in
{
  options.services.observabilityShipper = {
    enable = lib.mkEnableOption "shipping this host's journal and machine metrics to argus with Grafana Alloy";

    organization = lib.mkOption {
      type = lib.types.str;
      example = "chichek";
      description = ''
        Value of the organization label on every log line and metric. Argus
        keeps every host in one tenant, so this label separates them at query
        time.
      '';
    };

    tokenFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      example = lib.literalExpression ''config.sops.secrets."argus-logs-metrics-ingest-token".path'';
      description = ''
        Path to this host's bearer token for the argus ingest endpoints. systemd
        reads it as root and hands it to Alloy as a credential, because Alloy
        runs under DynamicUser and cannot own the file. Null sends no token,
        for argus shipping to its own Loki and Prometheus over loopback.
      '';
    };

    hostLabel = lib.mkOption {
      type = lib.types.str;
      default = config.networking.hostName;
      defaultText = lib.literalExpression "config.networking.hostName";
      description = "Value of the host label on every log line and metric.";
    };

    logsEndpoint = lib.mkOption {
      type = lib.types.str;
      default = "https://logs.aksel.biz/loki/api/v1/push";
      description = "Loki push endpoint on argus.";
    };

    metricsEndpoint = lib.mkOption {
      type = lib.types.str;
      default = "https://metrics.aksel.biz/api/v1/write";
      description = "Prometheus remote-write endpoint on argus.";
    };

    hostProxyMetricsAddress = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = hostProxyMetricsAddress;
      defaultText = lib.literalMD "`services.hostProxy.metricsAddress` when host-proxy is enabled, otherwise null";
      example = "127.0.0.1:9184";
      description = ''
        Address of the local host-proxy metrics endpoint to scrape and forward
        alongside the machine metrics. Null skips it.
      '';
    };

    scrapeIntervalSeconds = lib.mkOption {
      type = lib.types.ints.positive;
      default = 30;
      description = "How often to scrape this host's metrics.";
    };
  };

  config = lib.mkIf shipper.enable {
    services.alloy.enable = true;

    environment.etc."alloy/config.alloy".text = alloyConfiguration;

    systemd.services.alloy.serviceConfig.LoadCredential = lib.mkIf sendsToken [
      "${tokenCredentialName}:${shipper.tokenFile}"
    ];
  };
}
