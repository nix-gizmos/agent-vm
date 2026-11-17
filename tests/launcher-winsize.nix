# The launcher sends its terminal's size to the guest (flake.nix, "The
# terminal's size"; the guest's side is tests/console-size.nix). The built
# launcher runs on a pseudo-terminal, with systemd stubbed and QEMU replaced by
# a stub that stays up (tests/lib/stubbed-launcher.nix); the test resizes the
# terminal from outside, as a window manager does, and reads what reaches the
# pipe QEMU would hand to the guest:
#
#   - QEMU gets the port beside the console, on winsize.in, with the guest's
#     side of it going to /dev/null;
#   - the size at boot is sent, and each resize after it, at once (SIGWINCH);
#     a resize to the same size sends nothing, nor does a terminal with no
#     size ("0 0");
#   - when the VM has gone, so has the watcher: nothing holds the pipe open;
#   - a launch without a terminal adds no port and makes no pipe.
{ pkgs, lib, runner }:

let
  harness = import ./lib/stubbed-launcher.nix { inherit pkgs runner; };
in
pkgs.runCommand "launcher-winsize" { nativeBuildInputs = [ pkgs.socat pkgs.sqlite pkgs.util-linux ]; } ''
  fail=0
  ok ()  { echo "ok: $1"; }
  bad () { echo "FAIL: $1" >&2; fail=1; }

  ${harness.preamble}

  export XDG_DATA_HOME=$TMPDIR/data XDG_RUNTIME_DIR=$TMPDIR/rt HOME=$TMPDIR/home WORK_DIR=$TMPDIR/proj NO_PAUSE=1
  unset AGENT_HOME
  mkdir -p $XDG_DATA_HOME $XDG_RUNTIME_DIR $HOME $WORK_DIR
  export HOST_DB=$TMPDIR/host-db.sqlite
  sqlite3 $HOST_DB "CREATE TABLE ValidPaths (path TEXT);"
  waitfor () { for _ in $(seq 1 100); do eval "$1" && return 0; sleep 0.1; done; return 1; }

  # --- on a terminal --------------------------------------------------------------
  export LOG=$TMPDIR/tty; mkdir -p $LOG $TMPDIR/cwd
  # script's own stdin stays open (the sleep) for as long as the launch may take.
  ( sleep 60 ) | SHELL=${pkgs.bash}/bin/bash timeout 60 script -qfec \
      "stty rows 30 cols 90; tty > $LOG/tty; cd $TMPDIR/cwd && exec env HOLD=$TMPDIR/release ${harness.launcher}/bin/microvm-run" \
      $LOG/typescript >/dev/null 2>&1 &
  spid=$!
  waitfor '[ -e $LOG/started ]' || { bad "the stub QEMU never started"; cat $LOG/typescript >&2; exit 1; }
  pty=$(cat $LOG/tty)
  inst=$(dirname "$(cat $LOG/exported)")

  grep -qF -- "-device 'virtconsole,chardev=stdio' -chardev 'pipe,id=winsize,path=$inst/winsize' -device 'virtserialport,chardev=winsize,name=org.agentvm.winsize'" $LOG/qemu.sh \
    && ok "QEMU gets the port beside the console" || { bad "no port in QEMU's command line"; grep -o -- "-device 'virtconsole[^ ]*.\{0,200\}" $LOG/qemu.sh >&2; }
  [ -p "$inst/winsize.in" ] && [ "$(stat -c %a "$inst/winsize.in")" = 600 ] \
    && ok "...on a pipe in the instance dir, owner-only" || bad "winsize.in: $(stat -c '%F %a' "$inst/winsize.in" 2>&1)"
  [ "$(readlink "$inst/winsize.out")" = /dev/null ] \
    && ok "...with the guest's side going to /dev/null" || bad "winsize.out: $(ls -l "$inst/winsize.out" 2>&1)"

  # QEMU's end of the pipe, read as QEMU would.
  cat "$inst/winsize.in" > $LOG/sizes &
  cpid=$!
  waitfor 'grep -qx "30 90" $LOG/sizes' && ok "the size at boot is sent" || bad "boot size: $(cat $LOG/sizes)"

  stty -F "$pty" rows 40 cols 132
  waitfor 'grep -qx "40 132" $LOG/sizes' && ok "a resize is sent" || bad "after a resize: $(cat $LOG/sizes)"
  # The watcher looks at the lock once a second; a resize must not wait for that.
  t0=$(date +%s%3N)
  stty -F "$pty" rows 41 cols 132
  waitfor 'grep -qx "41 132" $LOG/sizes' || bad "the second resize never arrived"
  ms=$(( $(date +%s%3N) - t0 ))
  [ $ms -lt 700 ] && ok "...at once, not on the watcher's next round (''${ms}ms)" || bad "the resize took ''${ms}ms"
  stty -F "$pty" rows 41 cols 132      # the same again
  stty -F "$pty" rows 0 cols 0         # no size at all
  sleep 2
  stty -F "$pty" rows 25 cols 80
  waitfor 'grep -qx "25 80" $LOG/sizes'
  [ "$(cat $LOG/sizes | tr '\n' ,)" = "30 90,40 132,41 132,25 80," ] \
    && ok "the same size twice, or none, sends nothing" || bad "sent: $(cat $LOG/sizes | tr '\n' ,)"

  touch $TMPDIR/release
  wait $spid || true
  # cat ends when the last writer has closed the pipe: the watcher, and any
  # sleep it started.
  if waitfor '! kill -0 $cpid 2>/dev/null'; then ok "when the VM has gone, nothing holds the pipe"
  else bad "something still holds winsize.in open after the launch"; kill $cpid; fi
  [ ! -e "$inst" ] && ok "...and the instance dir has gone with it" || bad "left: $(ls -A "$inst")"

  # --- without a terminal ---------------------------------------------------------
  touch $TMPDIR/now
  launch notty HOLD=$TMPDIR/now
  if ! grep -q winsize $TMPDIR/notty/qemu.sh && ! grep -q winsize $TMPDIR/notty/instance-ls; then
    ok "a launch without a terminal adds no port and makes no pipe"
  else bad "without a terminal: $(grep -o 'winsize[^ ]*' $TMPDIR/notty/qemu.sh) / $(cat $TMPDIR/notty/instance-ls)"; fi

  [ $fail = 0 ] && touch $out
  exit $fail
''
