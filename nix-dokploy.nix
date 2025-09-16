{
  config,
  pkgs,
  lib,
  ...
}: let
  cfg = config.services.dokploy;
in {
  options.services.dokploy = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable Dokploy stack containers and Traefik container";
    };

    dataDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/dokploy";
      description = "Directory to store Dokploy data";
    };

    database = {
      password = lib.mkOption {
        type = lib.types.str;
        default = "amukds4wi9001583845717ad2";
        description = ''
          PostgreSQL database password for Dokploy.

          WARNING: This password is hardcoded in Dokploy's source code and cannot be changed
          without breaking the application. Dokploy does not currently support custom database
          passwords. This is a known security issue (see Dokploy/dokploy#595).

          The default value matches what Dokploy expects internally.
        '';
      };
    };

    traefik = {
      image = lib.mkOption {
        type = lib.types.str;
        default = "traefik:v3.1.2";
        description = ''
          Traefik Docker image to use.
          Default matches the version pinned in Dokploy's installation script.
          Changing this may cause compatibility issues with Dokploy.
        '';
      };
    };

    dokployImage = lib.mkOption {
      type = lib.types.str;
      default = "dokploy/dokploy:latest";
      description = ''
        Dokploy Docker image to use.
        Note: Check Dokploy's installation script for compatible Traefik versions
        when changing this.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = config.virtualisation.docker.enable;
        message = "Dokploy requires docker to be enabled";
      }
      {
        assertion = config.virtualisation.docker.daemon.settings.live-restore == false;
        message = "Dokploy stack requires Docker daemon setting: `live-restore = false`";
      }
      {
        assertion = !config.virtualisation.docker.rootless.enable;
        message = "Dokploy stack does not support rootless Docker";
      }
    ];

    systemd.tmpfiles.rules = [
      "d ${cfg.dataDir} 0777 root root -"
      "d ${cfg.dataDir}/traefik 0755 root root -"
      "d ${cfg.dataDir}/traefik/dynamic 0755 root root -"
    ];

    systemd.services.dokploy-stack = {
      description = "Dokploy Docker Swarm Stack";
      after = ["docker.service"];
      requires = ["docker.service"];

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;

        ExecStart = let
          script = pkgs.writeShellApplication {
            name = "dokploy-stack-start";
            runtimeInputs = [pkgs.curl pkgs.docker];
            text = ''
              advertise_addr="$(curl -s ifconfig.me)"

              # Initialize swarm if not already active
              if ! docker info | grep -q "Swarm: active"; then
                echo "Initializing Docker Swarm with advertise address $advertise_addr..."
                docker swarm init --advertise-addr "$advertise_addr"
              fi

              # Deploy Dokploy stack
              if docker stack ls --format '{{.Name}}' | grep -q '^dokploy$'; then
                echo "Dokploy stack already deployed, updating stack..."
              else
                echo "Deploying Dokploy stack..."
              fi
              ADVERTISE_ADDR="$advertise_addr" \
              POSTGRES_PASSWORD="${cfg.database.password}" \
              DOKPLOY_IMAGE="${cfg.dokployImage}" \
              DATA_DIR="${cfg.dataDir}" \
              docker stack deploy -c ${./dokploy.stack.yml} dokploy
            '';
          };
        in "${script}/bin/dokploy-stack-start";

        ExecStop = let
          script = pkgs.writeShellScript "dokploy-stack-stop" ''
            ${pkgs.docker}/bin/docker stack rm dokploy || true
          '';
        in "${script}";
      };

      wantedBy = ["multi-user.target"];
    };

    systemd.services.dokploy-traefik = {
      description = "Dokploy Traefik container";
      after = ["docker.service" "dokploy-stack.service"];
      requires = ["docker.service" "dokploy-stack.service"];

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;

        ExecStart = let
          script = pkgs.writeShellApplication {
            name = "dokploy-traefik-start";
            runtimeInputs = [pkgs.docker];
            text = ''
              if docker ps -a --format '{{.Names}}' | grep -q '^dokploy-traefik$'; then
                echo "Starting existing Traefik container..."
                docker start dokploy-traefik
              else
                echo "Creating and starting Traefik container..."
                docker run -d \
                  --name dokploy-traefik \
                  --network dokploy-network \
                  --restart=always \
                  -v /var/run/docker.sock:/var/run/docker.sock \
                  -v ${cfg.dataDir}/traefik/traefik.yml:/etc/traefik/traefik.yml \
                  -v ${cfg.dataDir}/traefik/dynamic:/etc/dokploy/traefik/dynamic \
                  -p 80:80/tcp \
                  -p 443:443/tcp \
                  -p 443:443/udp \
                  ${cfg.traefik.image}
              fi
            '';
          };
        in "${script}/bin/dokploy-traefik-start";

        ExecStop = let
          script = pkgs.writeShellScript "dokploy-traefik-stop" ''
            ${pkgs.docker}/bin/docker stop dokploy-traefik || true
          '';
        in "${script}";
        ExecStopPost = let
          script = pkgs.writeShellScript "dokploy-traefik-rm" ''
            ${pkgs.docker}/bin/docker rm dokploy-traefik || true
          '';
        in "${script}";
      };

      wantedBy = ["multi-user.target"];
    };
  };
}
