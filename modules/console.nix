{ lib, config, pkgs, ... }:
let
  console = config.claude-vm.console;

  # The launcher's side of this is in flake.nix, "The terminal's size".
  winsizePort = "org.agentvm.winsize";
  applySize = pkgs.writeShellScript "console-size" ''
    set -u
    # One "rows cols" per line, from the launcher's terminal. Anything else is
    # skipped: the sender is the launcher, but a line that is not two sizes a
    # terminal could have is no size to set.
    while IFS=' ' read -r rows cols rest; do
      case "$rows" in ""|*[!0-9]*) continue ;; esac
      case "$cols" in ""|*[!0-9]*) continue ;; esac
      [ -z "$rest" ] && [ "''${#rows}" -le 4 ] && [ "''${#cols}" -le 4 ] || continue
      [ "$rows" -gt 0 ] && [ "$cols" -gt 0 ] || continue
      # The kernel signals the console's foreground process group (SIGWINCH)
      # when the size changes, so the agent redraws for the new width.
      ${pkgs.coreutils}/bin/stty -F /dev/${console} rows "$rows" cols "$cols" || true
    done < /dev/virtio-ports/${winsizePort}
    # QEMU holds its end open for the VM's life, so the port does not end;
    # if it ever does, fail, so that systemd restarts the reader.
    echo "console-size: the size channel closed" >&2
    exit 1
  '';
in
{
  options.claude-vm.console = lib.mkOption {
    type = lib.types.str;
    default = "hvc0";
    internal = true;
    description = ''
      The one terminal the agent user is logged in on, and so the one that
      starts the agent: every autologin runs the shell init, which launches
      the agent and powers the VM off when it exits. A second login would run
      a second agent, unseen, and its exit would take the VM down under the
      first.

      Only tests/single-console.nix and tests/console-size.nix set it, because
      the test driver keeps hvc0 for itself.
    '';
  };

  config = {
    boot.kernelParams = [ "console=${console}" ];

    # Autologin applies to every getty, so whatever starts a getty on another
    # terminal starts another agent there. The console's own comes from
    # systemd-getty-generator (console=); the two VT ones below are what NixOS
    # starts without being asked. getty@tty1 is the obvious one, but its
    # getty module also makes getty.target want autovt@tty1 — an alias of the
    # same template, which disabling getty@tty1 does not reach. Anything else
    # that turns up later is caught by tests/single-console.nix, which boots
    # this module and counts the logins rather than checking these names.
    services.getty.autologinUser = "agent";
    systemd.services."getty@tty1".enable = false;
    systemd.services."autovt@tty1".enable = false;

    # The console's size follows the launcher's terminal. QEMU's virtconsole
    # reports none, so without this the console keeps the size its login
    # asked the terminal for at boot, whatever happens to the window after.
    # The launcher sends each new size over a virtio-serial port of its own,
    # and only when it runs on a terminal; the port appearing is what starts
    # the service, so a launch without one runs nothing.
    services.udev.extraRules = ''
      SUBSYSTEM=="virtio-ports", ATTR{name}=="${winsizePort}", TAG+="systemd", ENV{SYSTEMD_WANTS}+="console-size.service"
    '';
    systemd.services.console-size = {
      description = "The console's size, from the launcher's terminal";
      serviceConfig = {
        ExecStart = applySize;
        # A reader that dies would leave every later resize unapplied.
        Restart = "on-failure";
        RestartSec = "1s";
        # Root without root's reach: stty needs only to open the console,
        # which is the agent's once it is logged in.
        CapabilityBoundingSet = [ "CAP_DAC_OVERRIDE" ];
        NoNewPrivileges = true;
        PrivateNetwork = true;
        PrivateTmp = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        RestrictAddressFamilies = [ "AF_UNIX" ];
        SystemCallArchitectures = "native";
      };
    };
  };
}
