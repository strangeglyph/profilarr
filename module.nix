{ pkgs, lib, config, ... }:
let
  inherit (lib) 
    mkOption
    mkPackageOption
    mkEnableOption
    mkIf
    types;
  inherit (builtins)
    elem
    head
    tail
    map
    filter
    length;

  cfg = config.services.profilarr;
in
{
  options = {
    services.profilarr= {
      enable = mkEnableOption { 
        description = "Profilarr"; 
      };
      
      package = mkPackageOption pkgs "Profilarr" { 
        default = [ "profilarr" ];
      };
      
      user = mkOption {
        description = "The user to run Profilarr as";
        type = types.str;
        default = "profilarr";
      };

      group = mkOption {
        description = "The group to run Profilarr as";
        type = types.str;
        default = "profilarr";
      };

      host = mkOption {
        description = "IP address to bind to";
        type = types.str;
        default = "[::1]";
        example = "0.0.0.0";
      };

      port = mkOption {
        description = "Port number to bind to";
        type = types.port;
        default = 8000;
      };

      stateDir = mkOption {
        description = "Directory to store runtime state in";
        type = types.path;
        default = "/var/lib/profilarr";
      };

      environmentFile = mkOption {
        description = ''
          Path to file storing environment variables to be passed to the service.
        '';
        type = types.nullOr types.path;
        default = null;
        example = "/run/secrets/media-manager.env";
      };
    };
  };

  config = mkIf cfg.enable {
    users.users = lib.optionalAttrs (cfg.user == "profilarr") {
      profilarr = {
        isSystemUser = true;
        group = cfg.group;
      };
    };

    users.groups = lib.optionalAttrs (cfg.group == "profilarr") { 
      profilarr = {};
    };

    systemd.tmpfiles.settings."10-profilarr" = {
      "${cfg.stateDir}".d = { 
        user = cfg.user;
        group = cfg.group;
        mode = "0700"; 
      };
    };

    systemd.services."profilarr" = {
      description = "Sync quality profiles to Sonarr and Radarr";

      wantedBy = [ "multi-user.target" ];
      after = [ "network.target" ];
      enable = true;

      enableStrictShellChecks = true;

      environment = {
        GIT_PYTHON_GIT_EXECUTABLE = lib.getExe pkgs.git;
        STATIC_DIR = "${cfg.package}/static";
      };

      script = ''
        ${cfg.package}/bin/python -m gunicorn \
          -b '${cfg.host}:${toString cfg.port}' \
          --timeout 600 \
          'app.main:create_app()'
      '';

      serviceConfig = {
        LogsDirectory = "profilarr";
        StateDirectory = "profilarr";
        EnvironmentFile = lib.optional (cfg.environmentFile != null) cfg.environmentFile;
        BindPaths = [
          "${cfg.stateDir}:/config"
        ];
        User = cfg.user;
        Group = cfg.group;
        #Restart = "always";
        #RestartSec = "5s";
        Type = "simple";
      };
    };
  };
}