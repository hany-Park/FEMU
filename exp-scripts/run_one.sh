#!/bin/bash
# One FEMU run: fresh boot -> fill -> warmup -> measure, with an FTL stats
# snapshot (flip command 8) after each phase.
#
# usage: run_one.sh <variant> <workload> <rep>
#   variant  : worktree suffix, built in $WT_PREFIX<variant>/build-femu
#              (baseline, hotcold1, ...)
#   workload : uniform | zone80 | zone95     4k, QD32, whole device
#              zipf | zipf08 | zipf12        16k, QD128, 94% of the device
#              (zipf = the assignment's zipf:0.99; zipf08/zipf12 = theta
#              0.8/1.2 for a weaker/stronger skew. 94% ~ 45G of 48G, so
#              the never-written rest leaves free lines at GC 75)
#              assign                        the assignment's fio job as given:
#              zipf:0.99, 16k, QD128 x 32 jobs, size=45G, 1 hour, no fill
#              and no warmup (fresh device -> job -> done; snapshots
#              before and after the job)
#   rep      : repetition label (1, 2, 3, ...)
#
# env (workload defaults above; set any of these to override them):
#   DIST=zipf:0.99                 fio random_distribution
#   BS=16k                         block size of the random writes
#   FOOT=94%                       range that fill and the random writes cover
#                                  (fio size=; a whole percent or a size)
#   QD=128                         iodepth of the random writes
#   RUNTIME=3600  NJOBS=32         assign only: seconds and fio jobs
#
# env:
#   RUN=./run-blackbox-server.sh   run script inside build-femu
#                                  (./run-nosudo.sh once the account is in kvm)
#   CAP=48g                        bytes written by warmup and by measure
#                                  (server exposes 48GB; local debug: CAP=1g)
#   WT_PREFIX=$HOME/femu-          worktree path prefix
#   RESULTS=$HOME/femu-results     where results go
#   LABEL=<variant>                results folder name, if it should differ
#                                  from the build (the server builds every
#                                  variant into ~/FEMU/build-femu)
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
LABEL=${LABEL:-$VARIANT}

BUILD=$WT_PREFIX$VARIANT/build-femu
OUT=$RESULTS/$LABEL/$WL/rep$REP
# matches "-name FEMU-BBSSD-VM-..." on the QEMU command line; the brackets
# keep pkill/pgrep (and the sudo running them) from matching themselves
VM_PAT='[F]EMU-BBSSD-VM'

# ServerAliveInterval: the assign job keeps one ssh session open for an hour
SSH="ssh -p 8080 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ServerAliveInterval=60 femu@localhost"
DEV=/dev/nvme0n1

#        distribution          bs   range  iodepth
case $WL in
uniform) set -- random              4k  100%   32  ;;
zone80)  set -- zoned:80/20:20/80   4k  100%   32  ;;
zone95)  set -- zoned:95/5:5/95     4k  100%   32  ;;
zipf)    set -- zipf:0.99           16k 94%    128 ;;
zipf08)  set -- zipf:0.8            16k 94%    128 ;;
zipf12)  set -- zipf:1.2            16k 94%    128 ;;
assign)  set -- zipf:0.99           16k 45G    128 ;;
*) echo "unknown workload: $WL" >&2; exit 1 ;;
esac
DIST=${DIST:-$1}; BS=${BS:-$2}; FOOT=${FOOT:-$3}; QD=${QD:-$4}
RUNTIME=${RUNTIME:-3600}; NJOBS=${NJOBS:-32}

FIO="sudo fio --filename=$DEV --direct=1 --ioengine=libaio --group_reporting --output-format=json"
# --norandommap: without it fio writes every block exactly once per pass,
# which is not random overwriting
RAND="--rw=randwrite --bs=$BS --iodepth=$QD --size=$FOOT --io_size=$CAP --norandommap --randrepeat=1 --randseed=1234 --random_distribution=$DIST"

# the assignment's job file as options. Its group_reporting=0 only changes
# how fio prints the result; --group_reporting in $FIO sums the 32 jobs so
# parse.py reads totals. No randseed/norandommap: left at fio defaults.
ASSIGN="--name=test --time_based=1 --runtime=$RUNTIME --rw=randwrite --iodepth=$QD --numjobs=$NJOBS --size=$FOOT --bs=$BS --random_distribution=$DIST"

log() { echo "[$(date +%T)] $LABEL $WL rep$REP: $*"; }
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

# record what this run used, next to its results
printf 'variant=%s label=%s workload=%s rep=%s dist=%s bs=%s foot=%s qd=%s cap=%s run=%s\n' \
    "$VARIANT" "$LABEL" "$WL" "$REP" "$DIST" "$BS" "$FOOT" "$QD" "$CAP" "$RUN" > "$OUT/params.txt"

if [[ $WL == assign ]]; then
    echo "runtime=$RUNTIME numjobs=$NJOBS fio: $ASSIGN" >> "$OUT/params.txt"
    snap
    log "assignment job (${RUNTIME}s, $NJOBS jobs)"
    $SSH "$FIO $ASSIGN" > "$OUT/measure.json"
    snap
else
    # fill only the range the random writes will cover
    log "fill";    $SSH "$FIO --name=fill --rw=write --bs=1M --iodepth=32 --size=$FOOT" > "$OUT/fill.json"
    snap
    log "warmup";  $SSH "$FIO --name=warmup $RAND" > "$OUT/warmup.json"
    snap
    log "measure"; $SSH "$FIO --name=measure $RAND" > "$OUT/measure.json"
    snap
fi

trap - EXIT
cleanup
log "done -> $OUT"
