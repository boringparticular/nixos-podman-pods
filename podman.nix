/*
to run containers in separate namespaces

# create containers group
users.groups.containers = {};

# create containers user
users.users.containers = {
  isSystemUser = true;
  group = "containers";

# enable sub uid/gid mapping
  autoSubUidGidRange = true;
};

# set userns to auto in extra options of pod or containers
virtualisation.oci-containers.pods.<pod-name>.extraOptions = [
  "--userns auto"
];

# add U flag to mounted volumes for correct id mapping
virtualisation.oci-containers.containers.<container-name>.volumes = [
  "/var/lib/containers/storage:/var/lib/containers/storage:U"
];
*/
{
  config,
  lib,
  options,
  ...
}:
with lib; let
  cfg = config.virtualisation.oci-containers;
  podman = "${config.virtualisation.podman.package}/bin/podman";

  podOptions = {...}: {
    options = {
      hosts = mkOption {
        type = with types; listOf str;
        default = [];
        description = mkDoc "TODO";
        example = literalExpression ''
          [
              "host:127.0.0.1"
              "db:126.0.0.1"
          ]
        '';
      };

      ports = mkOption {
        type = with types; listOf str;
        default = [];
        description = mkDoc "TODO";
        example = literalExpression ''
          [
              "8080:80"
          ]
        '';
      };

      extraOptions = mkOption {
        type = with types; listOf str;
        default = [];
        description = mkDoc "TODO";
        example = literalExpression ''
          [
              "--share net"
              "--userns auto"
          ]
        '';
      };

      containers = options.virtualisation.oci-containers.containers;

      autoStart = mkOption {
        type = types.bool;
        default = true;
        description = mkDoc "TODO";
      };
    };
  };

  mkContainerService = name: container: podName: let
    escapedName = escapeShellArg name;
    cidFile = "%t/%n.ctr-id";
    podIdFile = "%t/pod-${podName}.pod-id";
    dependsOn = map (x: "container-${x}.service") container.dependsOn ++ ["pod-${podName}.service"];
  in {
    wantedBy = ["default.target"];
    wants = ["network-online.target"];
    after = ["network-online.target"] ++ dependsOn;
    bindsTo = dependsOn;
    serviceConfig = {
      Environment = "PODMAN_SYSTEMD_UNIT=%n";
      Restart =
        if container.autoStart
        then "always"
        else "on-failure";
      TimeoutStopSec = 70;
      Type = "notify";
      NotifyAccess = "all";
      ExecStart = concatStringsSep " \\\n " (
        [
          "${podman} run"
          "--cidfile=${cidFile}"
          "--log-driver=journald"
          "--cgroups=no-conmon"
          "--rm"
          "--pod-id-file ${podIdFile}"
          "--sdnotify=conmon"
          "-d"
          "--replace"
          "--name ${escapedName}"
        ]
        ++ map (r: "--requires ${escapeShellArg r}") container.dependsOn
        ++ optional (container.entrypoint != null) "--entrypoint=${escapeShellArg container.entrypoint}"
        ++ (mapAttrsToList (k: v: "-e ${escapeShellArg k}=${escapeShellArg v}") container.environment)
        ++ map (f: "--env-file ${escapeShellArg f}") container.environmentFiles
        ++ optional (container.user != null) "-u ${escapeShellArg container.user}"
        ++ map (v: "-v ${escapeShellArg v}") container.volumes
        ++ optional (container.workdir != null) "-w ${escapeShellArg container.workdir}"
        ++ map escapeShellArg container.extraOptions
        ++ [container.image]
        ++ map escapeShellArg container.cmd
      );
      ExecStop = "${podman} stop --ignore -t 10 --cidfile=${cidFile}";
      ExecStopPost = "${podman} rm -f --ignore -t 10 --cidfile=${cidFile}";
    };
  };

  mkPodService = name: pod: let
    escapedName = escapeShellArg name;
    containerServiceNames = mapAttrsToList (n: v: "container-${n}.service") pod.containers;
    pidFile = "%t/pod-${name}.pid";
    podIdFile = "%t/pod-${name}.pod-id";

    containerServices = mapAttrs' (n: v: nameValuePair "container-${n}" (mkContainerService n v name)) pod.containers;

    podService = {
      wantedBy = ["default.target"];
      after = ["network-online.target"];
      wants = ["network-online.target"] ++ containerServiceNames;
      before = containerServiceNames;
      serviceConfig = {
        Environment = "PODMAN_SYSTEMD_UNIT=%n";
        Restart =
          if pod.autoStart
          then "always"
          else "on-failure";
        TimeoutStopSec = 70;
        PIDFile = pidFile;
        Type = "forking";
        ExecStartPre = concatStringsSep " \\\n " (
          [
            "${podman} pod create"
            "--infra-conmon-pidfile ${pidFile}"
            "--pod-id-file ${podIdFile}"
            "--exit-policy=stop"
            "--name ${escapedName}"
            "--replace"
          ]
          ++ map escapeShellArg pod.extraOptions
          ++ map (p: "-p ${escapeShellArg p}") pod.ports
          ++ map (h: "--add-host ${escapeShellArg h}") pod.hosts
        );
        ExecStart = "${podman} pod start --pod-id-file ${podIdFile}";
        ExecStop = "${podman} pod stop --ignore -t 10 --pod-id-file ${podIdFile}";
        ExecStopPost = "${podman} pod rm --ignore --force --pod-id-file ${podIdFile}";
      };
    };
  in
    {"pod-${name}" = podService;} // containerServices;
in {
  imports = [];
  options.virtualisation.oci-containers = {
    pods = mkOption {
      default = {};
      type = types.attrsOf (types.submodule podOptions);
      description = mkDoc "TODO";
    };
  };

  config = {
    systemd.services = mkMerge (mapAttrsToList (n: v: (mkPodService n v)) cfg.pods);
  };
}
