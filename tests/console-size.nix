# The console's size follows the launcher's terminal (modules/console.nix,
# console-size.service; the launcher's side is tests/launcher-winsize.nix).
#
# QEMU's virtconsole tells the guest no size, so the console used to keep the
# one its login asked the terminal for at boot: a window resized afterwards
# left the agent laying out for the old width. Here the guest gets the port the
# launcher adds, org.agentvm.winsize, on a pipe the test writes to as the
# launcher's watcher does:
#
#   - the port appearing starts the service, with no unit wanting it;
#   - each "rows cols" line becomes the console's size, and a later one
#     replaces it, as a resize does;
#   - lines that are not a size (words, zeros, five digits, three fields) are
#     skipped, and the line after them still applies.
#   - a reader that dies is restarted, and a size sent while it was down
#     still applies.
#
# As in tests/single-console.nix, the driver keeps hvc0 and ttyS0, so the
# console is a UART of its own on ttyS1.
{ pkgs }:

pkgs.testers.runNixOSTest {
  name = "console-size";

  nodes.machine = { lib, ... }: {
    imports = [ ../modules/console.nix ];
    claude-vm.console = "ttyS1";
    # Long enough that the test can see the reader down, send, and see it still
    # down: the size must have waited for the next reader, not met this one.
    systemd.services.console-size.serviceConfig.RestartSec = lib.mkForce "10s";
    virtualisation.qemu.options = [
      "-chardev" "null,id=agent-console" "-device" "isa-serial,chardev=agent-console,index=1"
      # Relative: QEMU runs in the machine's state dir, where the test
      # creates winsize.in before the machine starts.
      "-chardev" "pipe,id=winsize,path=winsize"
      # A bus of its own: the driver adds its virtio-serial after these.
      "-device" "virtio-serial-pci,id=winsize-bus"
      "-device" "virtserialport,bus=winsize-bus.0,chardev=winsize,name=org.agentvm.winsize"
    ];
    users.users.agent = { isNormalUser = true; };
  };

  testScript = ''
    import os

    os.mkfifo(machine.state_dir / "winsize.in")
    os.symlink("/dev/null", machine.state_dir / "winsize.out")
    w = os.open(machine.state_dir / "winsize.in", os.O_RDWR)

    def send(line):
        os.write(w, (line + "\n").encode())

    def size_is(rows, cols):
        machine.wait_until_succeeds(
            f"[ \"$(stty -F /dev/ttyS1 size)\" = '{rows} {cols}' ]", timeout=30)

    machine.start()
    machine.wait_for_unit("multi-user.target")

    with subtest("the port starts the service"):
        machine.wait_for_unit("console-size.service")
        wanted = machine.succeed("systemctl show -p WantedBy --value console-size.service").split()
        assert wanted and all(u.strip('"').endswith(".device") for u in wanted), \
            f"expected only the port's device to want it: {wanted}"

    with subtest("a size becomes the console's, and a later one replaces it"):
        send("40 132")
        size_is(40, 132)
        send("50 100")
        size_is(50, 100)

    with subtest("what is not a size is skipped"):
        for junk in ["rows cols", "0 0", "30 0", "99999 80", "30 80 1", "-1 80", "30 8x0"]:
            send(junk)
        machine.sleep(2)
        size = machine.succeed("stty -F /dev/ttyS1 size").strip()
        assert size == "50 100", f"a line that is no size changed it: {size}"
        send("33 111")
        size_is(33, 111)
        assert machine.succeed("systemctl is-active console-size.service").strip() == "active"

    with subtest("a reader that dies comes back, and sizes sent meanwhile still apply"):
        def down():
            state = machine.succeed(
                "systemctl show -p SubState -p MainPID --value console-size.service").split()
            return sorted(state) == ["0", "auto-restart"]

        pid = machine.succeed("systemctl show -p MainPID --value console-size.service").strip()
        machine.succeed("systemctl kill --signal=KILL console-size.service")
        machine.wait_until_succeeds(
            "[ \"$(systemctl show -p SubState --value console-size.service)\" = auto-restart ]",
            timeout=30)
        send("44 144")
        machine.sleep(1)
        assert down(), "the reader was back before the size was sent"
        size = machine.succeed("stty -F /dev/ttyS1 size").strip()
        assert size == "33 111", f"something read the size while the reader was down: {size}"
        machine.wait_until_succeeds(
            f"p=$(systemctl show -p MainPID --value console-size.service); [ \"$p\" != 0 ] && [ \"$p\" != {pid} ]",
            timeout=30)
        size_is(44, 144)
  '';
}
