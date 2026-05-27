self:
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.heimdash;

  percentType = lib.types.ints.between 0 100;

  thresholdType =
    defaultWarn: defaultCritical:
    lib.types.submodule {
      options = {
        warn = lib.mkOption {
          type = percentType;
          default = defaultWarn;
          description = "Warning threshold percent.";
        };
        critical = lib.mkOption {
          type = percentType;
          default = defaultCritical;
          description = "Critical threshold percent.";
        };
      };
    };

  diskThresholdType = lib.types.submodule {
    options = {
      mount = lib.mkOption {
        type = lib.types.str;
        description = "Mount point this threshold overrides.";
      };
      warn = lib.mkOption {
        type = percentType;
        default = 80;
        description = "Warning threshold percent.";
      };
      critical = lib.mkOption {
        type = percentType;
        default = 90;
        description = "Critical threshold percent.";
      };
    };
  };

  serviceNames = map (service: service.name) cfg.services;
  nonEmptyServiceNames = lib.filter (name: name != "") serviceNames;
  credentialNames = lib.attrNames cfg.credentials;
  referencedCredentialNames = lib.filter (name: name != null) (
    map (service: service.credential) cfg.services
  );
  credentialNameIsSafe = name: name != "" && builtins.match ".*[/:].*" name == null;
  referencedCredentialsExist = lib.all (name: lib.hasAttr name cfg.credentials) referencedCredentialNames;
  credentialNamesAreSafe = lib.all credentialNameIsSafe credentialNames;
  credentialPathsAreSet = lib.all (name: cfg.credentials.${name}.path != "") credentialNames;
  thresholdIsOrdered = threshold: threshold.warn < threshold.critical;
  thresholdsAreOrdered =
    cfg.thresholds == null
    || (
      thresholdIsOrdered cfg.thresholds.cpu
      && thresholdIsOrdered cfg.thresholds.memory
      && thresholdIsOrdered cfg.thresholds.disk
      && lib.all thresholdIsOrdered cfg.thresholds.disks
    );

  configFile = (pkgs.formats.json { }).generate "heimdash.json" (
    {
      inherit (cfg) listen mounts services;
    }
    // lib.optionalAttrs (cfg.thresholds != null) { inherit (cfg) thresholds; }
  );
in
{
  options.services.heimdash = {
    enable = lib.mkEnableOption "heimdash dashboard";

    package = lib.mkOption {
      type = lib.types.package;
      default = self.packages.${pkgs.stdenv.hostPlatform.system}.default;
      defaultText = lib.literalExpression "heimdash.packages.\${system}.default";
      description = "The heimdash package to use.";
    };

    listen = lib.mkOption {
      type = lib.types.str;
      default = "127.0.0.1:8080";
      description = "Address and port the server binds to.";
    };

    mounts = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "/" ];
      example = [
        "/"
        "/home"
        "/mnt/data"
      ];
      description = "Filesystem mount points to report free space for.";
    };

    services = lib.mkOption {
      default = [ ];
      description = "Services to surface as link cards on the dashboard.";
      type = lib.types.listOf (
        lib.types.submodule {
          options = {
            name = lib.mkOption {
              type = lib.types.str;
              description = "Display name.";
            };
            url = lib.mkOption {
              type = lib.types.str;
              description = "URL the link card opens.";
            };
            check = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              description = "Optional URL to probe for reachability instead of url.";
            };
            kind = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              description = "Optional service kind used to select read-only summaries.";
            };
            credential = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              description = "Optional systemd credential name for read-only summaries.";
            };
          };
        }
      );
      example = [
        {
          name = "Jellyfin";
          url = "http://media.lan:8096";
          check = "http://media.lan:8096/health";
        }
        {
          name = "Nextcloud";
          url = "https://cloud.lan";
        }
      ];
    };

    credentials = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.submodule {
          options = {
            path = lib.mkOption {
              type = lib.types.str;
              description = "Path to the source file loaded as this systemd credential.";
            };
          };
        }
      );
      default = { };
      description = "Systemd credentials available to service summary adapters.";
      example = {
        sonarr-api-key.path = "/run/secrets/sonarr-api-key";
      };
    };

    thresholds = lib.mkOption {
      type = lib.types.nullOr (
        lib.types.submodule {
          options = {
            cpu = lib.mkOption {
              type = thresholdType 75 90;
              default = { };
              description = "CPU health thresholds.";
            };
            memory = lib.mkOption {
              type = thresholdType 80 90;
              default = { };
              description = "Memory health thresholds.";
            };
            disk = lib.mkOption {
              type = thresholdType 80 90;
              default = { };
              description = "Default disk health thresholds.";
            };
            disks = lib.mkOption {
              type = lib.types.listOf diskThresholdType;
              default = [ ];
              description = "Per-mount disk health threshold overrides.";
            };
          };
        }
      );
      default = null;
      example = {
        cpu = {
          warn = 70;
          critical = 90;
        };
        disks = [
          {
            mount = "/mnt/media";
            warn = 90;
            critical = 97;
          }
        ];
      };
      description = ''
        Optional metric health thresholds in percent. Keys: cpu, memory, disk,
        and disks (per-mount overrides). Omitted fields use built-in defaults
        (cpu 75/90, memory 80/90, disk 80/90).
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = lib.length nonEmptyServiceNames == lib.length (lib.unique nonEmptyServiceNames);
        message = "services.heimdash.services names must be unique.";
      }
      {
        assertion = lib.all (service: service.name != "") cfg.services;
        message = "services.heimdash.services entries must have a non-empty name.";
      }
      {
        assertion = lib.all (service: service.url != "") cfg.services;
        message = "services.heimdash.services entries must have a non-empty url.";
      }
      {
        assertion = lib.all (service: service.check == null || service.check != "") cfg.services;
        message = "services.heimdash.services entries with check set must use a non-empty check URL.";
      }
      {
        assertion = lib.all (service: service.kind == null || service.kind != "") cfg.services;
        message = "services.heimdash.services entries with kind set must use a non-empty kind.";
      }
      {
        assertion = lib.all (service: service.credential == null || service.credential != "") cfg.services;
        message = "services.heimdash.services entries with credential set must use a non-empty credential name.";
      }
      {
        assertion = credentialNamesAreSafe;
        message = "services.heimdash.credentials names must be non-empty and must not contain '/' or ':'.";
      }
      {
        assertion = referencedCredentialsExist;
        message = "services.heimdash.services credential values must reference services.heimdash.credentials entries.";
      }
      {
        assertion = credentialPathsAreSet;
        message = "services.heimdash.credentials paths must be non-empty.";
      }
      {
        assertion = thresholdsAreOrdered;
        message = "services.heimdash.thresholds warn values must be lower than critical values.";
      }
    ];

    systemd.services.heimdash = {
      description = "heimdash home-server dashboard";
      after = [ "network.target" ];
      wantedBy = [ "multi-user.target" ];

      serviceConfig = {
        ExecStart = "${lib.getExe cfg.package} --config ${configFile}";
        LoadCredential = lib.mapAttrsToList (name: value: "${name}:${value.path}") cfg.credentials;
        Restart = "on-failure";
        RestartSec = 5;

        DynamicUser = true;
        ProtectSystem = "strict";
        ProtectHome = "read-only";
        PrivateTmp = true;
        PrivateDevices = true;
        NoNewPrivileges = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectKernelLogs = true;
        ProtectControlGroups = true;
        ProtectClock = true;
        ProtectHostname = true;
        ProtectProc = "invisible";
        RestrictAddressFamilies = [
          "AF_UNIX"
          "AF_INET"
          "AF_INET6"
        ];
        RestrictNamespaces = true;
        RestrictRealtime = true;
        RestrictSUIDSGID = true;
        LockPersonality = true;
        MemoryDenyWriteExecute = true;
        SystemCallArchitectures = "native";
        SystemCallFilter = [
          "@system-service"
          "~@privileged"
          "~@resources"
        ];
        CapabilityBoundingSet = "";
        AmbientCapabilities = "";
      };
    };
  };
}
