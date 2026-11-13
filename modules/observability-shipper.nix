{ config, lib, ... }:

let
  shipper = config.services.observabilityShipper;

  tokenCredentialName = "ingest-token";
  tokenCredentialPath = "/run/credentials/alloy.service/${tokenCredentialName}";

  terminalColorPattern = ''(\x1b\[[0-9;]*m)'';
  tracingLinePattern =''^\d{4}-\d{2}-\d{2}T\S+Z\s+(?P<level>TRACE|DEBUG|INFO|WARN|ERROR)\s+(?P<message>.*)$'';

  scrapeTarget = name: address: ''
    prometheus.scrape "${name}" {
      targets         = [{ "__address__" = "${address}" }]
      forward_to      = [prometheus.remote_write.argus.receiver]
      scrape_interval = "${toString shipper.scrapeIntervalSeconds}s"
    }
  '';

  scrapeTargets =
    shipper.scrapeTargets
    // lib.optionalAttrs (shipper.hostProxyMetricsAddress != null) {
      host_proxy = shipper.hostProxyMetricsAddress;
    };

  alloyConfiguration = ''
    loki.relabel "journal" {
      forward_to = []

      rule {
        source_labels = ["__journal__systemd_unit"]
        target_label  = "unit"
      }
    }

    loki.source.journal "system" {
      forward_to    = [loki.process.tracing.receiver]
      relabel_rules = loki.relabel.journal.rules
      max_age       = "12h"
      labels        = { job = "systemd-journal" }
    }

    loki.process "tracing" {
      forward_to = [loki.write.argus.receiver]

      stage.replace {
        expression = `${terminalColorPattern}`
        replace    = ""
      }

      stage.regex {
        expression = `${tracingLinePattern}`
      }

      stage.structured_metadata {
        values = { level = "" }
      }

      stage.output {
        source = "message"
      }
    }

    loki.write "argus" {
      endpoint {
        url               = "${shipper.logsEndpoint}"
        bearer_token_file = "${tokenCredentialPath}"
      }
    }

    prometheus.exporter.unix "node" { }

    prometheus.scrape "node" {
      targets         = prometheus.exporter.unix.node.targets
      forward_to      = [prometheus.remote_write.argus.receiver]
      scrape_interval = "${toString shipper.scrapeIntervalSeconds}s"
    }

    ${lib.concatStrings (lib.mapAttrsToList scrapeTarget scrapeTargets)}
    prometheus.remote_write "argus" {
      endpoint {
        url               = "${shipper.metricsEndpoint}"
        bearer_token_file = "${tokenCredentialPath}"
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
    enable = lib.mkEnableOption "shipping this host's journal and metrics to argus with Grafana Alloy";

    tokenFile = lib.mkOption {
      type = lib.types.str;
      example = lib.literalExpression ''config.sops.secrets."argus-logs-metrics-ingest-token".path'';
      description = ''
        Path to this host's bearer token for the argus ingest endpoints. Argus
        maps the token to this host's tenant, so the token is the host's whole
        identity: nothing the host labels itself is trusted. systemd reads the
        file as root and hands it to Alloy as a credential, because Alloy runs
        under DynamicUser and cannot own it.
      '';
    };

    logsEndpoint = lib.mkOption {
      type = lib.types.str;
      default = "https://logs.aksel.biz/loki/api/v1/push";
      description = "Loki push endpoint on argus.";
    };

    metricsEndpoint = lib.mkOption {
      type = lib.types.str;
      default = "https://metrics.aksel.biz/api/v1/push";
      description = "Mimir remote-write endpoint on argus.";
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

    scrapeTargets = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      example = {
        hermes = "127.0.0.1:9185";
      };
      description = ''
        Local Prometheus endpoints to scrape and forward, keyed by a name made of
        letters, digits and underscores, such as an application serving its own
        metrics on loopback.
      '';
    };

    scrapeIntervalSeconds = lib.mkOption {
      type = lib.types.ints.positive;
      default = 30;
      description = "How often to scrape this host's metrics.";
    };
  };

  config = lib.mkIf shipper.enable {
    assertions = [
      {
        assertion =
          !(scrapeTargets ? node)
          && lib.all (name: builtins.match "[A-Za-z0-9_]+" name != null) (lib.attrNames scrapeTargets);
        message = "services.observabilityShipper.scrapeTargets names must be letters, digits and underscores, and not node, which names the machine metrics.";
      }
    ];

    services.alloy.enable = true;

    environment.etc."alloy/config.alloy".text = alloyConfiguration;

    systemd.services.alloy.serviceConfig.LoadCredential = [
      "${tokenCredentialName}:${shipper.tokenFile}"
    ];
  };
}
