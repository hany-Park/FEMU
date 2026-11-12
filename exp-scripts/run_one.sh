#!/bin/bash
# One FEMU run: fresh boot -> fill -> warmup -> measure, with an FTL stats
# snapshot (flip command 8) after each phase.
#
# usage: run_one.sh <variant> <workload> <rep>
#   variant  : worktree suffix, built in $WT_PREFIX<variant>/build-femu
#              (baseline, hotcold1, ...)
#   workload : uniform | zone80 | zone95
#   rep      : repetition label (1, 2, 3, ...)
#
# env:
#   RUN=./run-blackbox-server.sh   run script inside build-femu
#                                  (./run-nosudo.sh once the account is in kvm)
#   CAP=48g                        bytes written by warmup and by measure
#                                  (server exposes 48GB; local debug: CAP=1g)
#   WT_PREFIX=$HOME/femu-          worktree path prefix
#   RESULTS=$HOME/femu-results     where results go
#
# The run script must start the guest with "-name FEMU-BBSSD-VM..." and
# forward guest ssh to localhost:8080; the guest needs key login for femu,
# passwordless sudo, fio and nvme-cli.
set -euo pipefail

VARIANT=$1; WL=$2; REP=$3
RUN=${RUN:-./run-blackbox-server.sh}
CAP=${CAP:-48g}
WT_PREFIX=${WT_PREFIX:-$HOME/femu-}
RESULTS=${RESULTS:-$HOME/femu-results}

BUILD=$WT_PREFIX$VARIANT/build-femu
OUT=$RESULTS/$VARIANT/$WL/rep$REP
# matches "-name FEMU-BBSSD-VM-..." on the QEMU command line; the brackets
# keep pkill/pgrep (and the sudo running them) from matching themselves
VM_PAT='[F]EMU-BBSSD-VM'

SSH="ssh -p 8080 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR femu@localhost"
DEV=/dev/nvme0n1

case $WL in
uniform) DIST="--random_distribution=random" ;;
zone80)  DIST="--random_distribution=zoned:80/20:20/80" ;;
zone95)  DIST="--random_distribution=zoned:95/5:5/95" ;;
*) echo "unknown workload: $WL" >&2; exit 1 ;;
esac

FIO="sudo fio --filename=$DEV --direct=1 --ioengine=libaio --group_reporting --output-format=json"
# --norandommap: without it fio writes every block exactly once per pass,
# which is not random overwriting
RAND="--rw=randwrite --bs=4k --iodepth=32 --size=100% --io_size=$CAP --norandommap --randrepeat=1 --randseed=1234 $DIST"

log() { echo "[$(date +%T)] $VARIANT $WL rep$REP: $*"; }
snap() { $SSH "sudo nvme admin-passthru /dev/nvme0 --opcode=0xef --cdw10=8" >/dev/null; }
femu_running() { pgrep -f "$VM_PAT" >/dev/null; }

stop_femu() {
    $SSH "sudo poweroff" >/dev/null 2>&1 || true
    for _ in $(seq 60); do femu_running || return 0; sleep 2; done
    log "guest did not power off, killing QEMU"
    sudo pkill -f "$VM_PAT" || true
    while femu_running; do sleep 1; done
}

# on success and on failure: stop the guest, keep the FEMU output
cleanup() {
    log "shutdown"
    stop_femu
    # the run script tees QEMU output to build-femu/log, overwritten each run
    cp "$BUILD/log" "$OUT/femu.log" 2>/dev/null || true
}

[[ -x $BUILD/qemu-system-x86_64 ]] || { echo "not built: $BUILD" >&2; exit 1; }
if femu_running; then
    echo "a FEMU guest is already running; stop it first (port 8080 and the image are shared)" >&2
    exit 1
fi
if grep -q '^sudo' "$BUILD/$RUN"; then
    # cache sudo now: the background QEMU below cannot ask for the password
    sudo -v
fi

mkdir -p "$OUT"
log "start FEMU ($RUN)"
cd "$BUILD"
"$RUN" </dev/null >/dev/null 2>&1 &
trap cleanup EXIT

# wait for the guest to boot (up to 10 minutes)
for _ in $(seq 120); do
    $SSH true 2>/dev/null && break
    femu_running || { echo "FEMU exited during boot; see $BUILD/log" >&2; exit 1; }
    sleep 5
done
$SSH true

log "fill";    $SSH "$FIO --name=fill --rw=write --bs=1M --iodepth=32 --size=100%" > "$OUT/fill.json"
snap
log "warmup";  $SSH "$FIO --name=warmup $RAND" > "$OUT/warmup.json"
snap
log "measure"; $SSH "$FIO --name=measure $RAND" > "$OUT/measure.json"
snap

trap - EXIT
cleanup
log "done -> $OUT"
