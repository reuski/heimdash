self:
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.heimdash;

  configFile = (pkgs.formats.json { }).generate "heimdash.json" {
    inherit (cfg) listen mounts services;
  };
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
  };

  config = lib.mkIf cfg.enable {
    systemd.services.heimdash = {
      description = "heimdash home-server dashboard";
      after = [ "network.target" ];
      wantedBy = [ "multi-user.target" ];

      serviceConfig = {
        ExecStart = "${lib.getExe cfg.package} --config ${configFile}";
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
