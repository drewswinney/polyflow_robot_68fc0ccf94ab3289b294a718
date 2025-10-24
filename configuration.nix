{ config, pkgs, ros-pkgs, lib, ... }:

let
  user      = "admin";
  password  = "password";
  hostname  = "68fc0ccf94ab3289b294a718";
  repoName  = "polyflow_robot_${hostname}";
  homeDir   = "/home/${user}";
  wsDir     = "${homeDir}/${repoName}/workspace";

  # Python env for colcon builds (no ROS needed here)
  buildPy = pkgs.python3.withPackages (ps: [
    ps.setuptools
    ps.wheel
    ps.pyyaml
    ps."osrf_pycommon"
    ps."catkin_pkg"
    ps.empy
    ps.lark
  ]);

  # ROS Python env (what ros2/launch uses) — include setuptools here too
  rosPy     = ros-pkgs.python3;
  rosPyWith = rosPy.withPackages (ps: [
    ps.pyyaml
  ]);

  # Wrapper that preps env and launches your package
  webrtcLauncher = pkgs.writeShellScript "webrtc-launch.sh" ''
    #!/usr/bin/env bash
    set -eo pipefail

    # Keep Nix ROS Python plugins visible to ros2
    export PYTHONPATH="\
      ${ros-pkgs.rosPackages.humble.ros2cli}/${pkgs.python3.sitePackages}:\
      ${ros-pkgs.rosPackages.humble.ros2launch}/${pkgs.python3.sitePackages}:\
      ${ros-pkgs.rosPackages.humble.ros2pkg}/${pkgs.python3.sitePackages}:\
      ${ros-pkgs.rosPackages.humble.launch}/${pkgs.python3.sitePackages}:\
      ${ros-pkgs.rosPackages.humble.launch-ros}/${pkgs.python3.sitePackages}:\
      ${ros-pkgs.rosPackages.humble.ament-index-python}/${pkgs.python3.sitePackages}:\
      ${ros-pkgs.rosPackages.humble.ros-base}/${pkgs.python3.sitePackages}:\
      ''${PYTHONPATH:-}"

    # Add the combined ROS python env (includes setuptools, pyyaml, etc.)
    export PYTHONPATH="${rosPyWith}/${pkgs.python3.sitePackages}:$PYTHONPATH"

    # Ament prefix hints (non-strict, but helps some overlays)
    export AMENT_PREFIX_PATH="\
      ${ros-pkgs.rosPackages.humble.ros2launch}:\
      ${ros-pkgs.rosPackages.humble.launch}:\
      ${ros-pkgs.rosPackages.humble.launch-ros}:\
      ${ros-pkgs.rosPackages.humble.ros-base}:\
      ''${AMENT_PREFIX_PATH:-}"

    # Source your workspace overlay (POSIX script for systemd)
    if [ -f "${wsDir}/install/local_setup.sh" ]; then
      echo "[webrtc] Sourcing ${wsDir}/install/local_setup.sh"
      set +u
      . "${wsDir}/install/local_setup.sh"
      set -u
    else
      echo "[webrtc] Missing ${wsDir}/install/local_setup.sh; did build succeed?" >&2
      exit 1
    fi

    echo "[webrtc] Launching…"
    exec ${ros-pkgs.rosPackages.humble.ros2cli}/bin/ros2 launch webrtc launch/webrtc.launch.py
  '';
in
{
  nixpkgs.overlays = [
    (final: super: {
      makeModulesClosure = x: super.makeModulesClosure (x // { allowMissing = true; });
    })
  ];

  imports = [
    "${builtins.fetchGit {
      url = "https://github.com/NixOS/nixos-hardware.git";
      rev = "26ed7a0d4b8741fe1ef1ee6fa64453ca056ce113";
    }}/raspberry-pi/4"
  ];

  boot = {
    kernelPackages = ros-pkgs.linuxKernel.packages.linux_rpi4;
    initrd.availableKernelModules = [ "xhci_pci" "usbhid" "usb_storage" ];
    loader = {
      grub.enable = false;
      generic-extlinux-compatible.enable = true;
    };
  };

  fileSystems."/" = {
    device = "/dev/disk/by-label/NIXOS_SD";
    fsType = "ext4";
    options = [ "noatime" ];
  };

  system.autoUpgrade.flags = [ "--max-jobs" "1" "--cores" "1" ];

  networking = {
    hostName = hostname;
    networkmanager.enable = true;
    nftables.enable = true;
  };

  services.openssh.enable = true;
  services.timesyncd.enable = true;
  services.timesyncd.servers = [ "pool.ntp.org" ];
  systemd.additionalUpstreamSystemUnits = [ "systemd-time-wait-sync.service" ];
  systemd.services.systemd-time-wait-sync.wantedBy = [ "multi-user.target" ];

  nix.settings.experimental-features = [ "nix-command" "flakes" ];
  hardware.enableRedistributableFirmware = true;
  system.stateVersion = "23.11";

  environment.etc."nixos/configuration.nix" = {
    source = ./configuration.nix;
    mode = "0644";
  };

  users.mutableUsers = false;
  users.users.${user} = {
    isNormalUser = true;
    password = password;
    extraGroups = [ "wheel" ];
    home = homeDir;
  };
  security.sudo.wheelNeedsPassword = false;

  environment.systemPackages =
    [ rosPyWith ] ++
    (with ros-pkgs; with rosPackages.humble; [
      pkgs.git
      pkgs.colcon
      ros2cli
      ros2launch
      ros2pkg
      launch
      launch-ros
      ros-base
      ament-index-python
    ]);

  # 1 Setup: clone/pull + build just your package (path-based selection)
  systemd.services.polyflow-setup = {
    description = "Clone/update Polyflow robot repo and colcon build";
    wantedBy = [ "multi-user.target" ];
    after = [ "network-online.target" "time-sync.target" ];
    wants = [ "network-online.target" "time-sync.target" ];

    path = [ buildPy ] ++
      (with pkgs; [ git colcon python3 ]) ++
      (with ros-pkgs.rosPackages.humble; [ ros2cli ros2launch launch launch-ros ros-base ]);

    serviceConfig = {
      Type = "oneshot";
      User = user;
      Group = "users";
      WorkingDirectory = homeDir;
      StateDirectory = "polyflow";
      StandardOutput = "journal";
      StandardError  = "journal";
    };

    script = ''
      set -eo pipefail
      export HOME=${homeDir}

      if [ -d "${homeDir}/${repoName}" ]; then
        echo "[setup] Repo exists; pulling latest…"
        cd "${homeDir}/${repoName}"
        git pull --ff-only
      else
        echo "[setup] Cloning repo…"
        git config --global --unset https.proxy || true
        git clone "https://github.com/drewswinney/${repoName}.git" "${homeDir}/${repoName}"
        chown -R ${user}:users "${homeDir}/${repoName}"
      fi

      echo "[setup] Building with colcon…"
      cd "${wsDir}"
      colcon build --paths src/webrtc --symlink-install

      echo "[setup] Done."
    '';
  };

  # 2 Runtime: `ros2 launch` your package
  systemd.services.polyflow-webrtc = {
    description = "Run Polyflow WebRTC launch with ros2 launch";
    wantedBy = [ "multi-user.target" ];
    after    = [ "polyflow-setup.service" "network-online.target" ];
    wants    = [ "polyflow-setup.service" "network-online.target" ];

    path = [ rosPyWith ] ++
      (with ros-pkgs.rosPackages.humble; [ ros2cli ros2launch ros2pkg launch launch-ros ament-index-python ros-base ]);

    environment = {
      ROS_DOMAIN_ID = "0";
      LANG = "en_US.UTF-8";
      LC_ALL = "en_US.UTF-8";
    };

    serviceConfig = {
      User             = user;
      Group            = "users";
      WorkingDirectory = wsDir;
      StateDirectory   = "polyflow";
      StandardOutput   = "journal";
      StandardError    = "journal";
      Restart          = "always";
      RestartSec       = "3s";
      ExecStart        = webrtcLauncher;
    };
  };
}
