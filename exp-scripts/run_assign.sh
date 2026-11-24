#!/bin/bash
# Server: run the assignment's fio job (run_one.sh workload "assign") on
# baseline and hotcold2, one after the other, then parse the results.
#
# usage (inside tmux; one run takes about 1h10m):
#   tmux new -s exp
#   ./run_assign.sh 2>&1 | tee run_assign.log
#   DRY=1 ./run_assign.sh          # check the builds and print the plan only
#
# sudo on the server allows only ~/FEMU/build-femu/qemu-system-x86_64, so each
# variant's build waits in ~/FEMU/build-femu-<variant> and is renamed to
# build-femu for its run. The variant in build-femu is recorded in
# build-femu/.variant; the first time, it is the one variant that has no
# build-femu-<variant> folder.
#
# env: VARIANTS="baseline hotcold2", REPS="1", FEMU_DIR=$HOME/FEMU,
#      RESULTS=$HOME/femu-results, DRY=1; RUNTIME, NJOBS, RUN, ... go to
#      run_one.sh.
set -uo pipefail
cd "$(dirname "$0")"

VARIANTS=${VARIANTS:-"baseline hotcold2"}
REPS=${REPS:-1}
FEMU_DIR=${FEMU_DIR:-$HOME/FEMU}
RESULTS=${RESULTS:-$HOME/femu-results}
DRY=${DRY:-0}
export RESULTS
ACTIVE=$FEMU_DIR/build-femu
WL=assign

die() { echo "run_assign: $*" >&2; exit 1; }

# which variant is in build-femu now
active_variant() {
    if [[ -f $ACTIVE/.variant ]]; then cat "$ACTIVE/.variant"; return; fi
    local v missing=()
    for v in $VARIANTS; do
        [[ -d $FEMU_DIR/build-femu-$v ]] || missing+=("$v")
    done
    [[ ${#missing[@]} -eq 1 ]] && echo "${missing[0]}"
}

# baseline has no hot counter; every hot/cold variant prints hot_write_pages
check_build() {
    local v=$1 dir=$2 hot=0
    [[ -x $dir/qemu-system-x86_64 ]] || die "$dir: no qemu-system-x86_64"
    [[ -f $dir/${RUN:-./run-blackbox-server.sh} ]] \
        || die "$dir: no ${RUN:-./run-blackbox-server.sh}"
    grep -qa hot_write_pages "$dir/qemu-system-x86_64" && hot=1
    if [[ $v == baseline && $hot == 1 ]]; then die "$dir is labelled baseline but has a hot counter"; fi
    if [[ $v != baseline && $hot == 0 ]]; then die "$dir is labelled $v but has no hot counter"; fi
}

# put variant $1 into build-femu
use_build() {
    local v=$1 cur
    cur=$(active_variant)
    [[ $cur == "$v" ]] && return 0
    [[ -d $FEMU_DIR/build-femu-$v ]] || die "no build for $v: $FEMU_DIR/build-femu-$v"
    [[ -e $FEMU_DIR/build-femu-$cur ]] && die "cannot park $cur: build-femu-$cur exists"
    mv "$ACTIVE" "$FEMU_DIR/build-femu-$cur" || die "mv build-femu -> build-femu-$cur failed"
    mv "$FEMU_DIR/build-femu-$v" "$ACTIVE" || die "mv build-femu-$v -> build-femu failed"
    echo "$v" > "$ACTIVE/.variant"
}

# --- checks before anything runs -------------------------------------------
cur=$(active_variant)
[[ -n $cur ]] || die "cannot tell which variant is in $ACTIVE; write its name to $ACTIVE/.variant"
check_build "$cur" "$ACTIVE"
[[ -f $ACTIVE/.variant ]] || [[ $DRY == 1 ]] || echo "$cur" > "$ACTIVE/.variant"
for v in $VARIANTS; do
    [[ $v == "$cur" ]] && continue
    check_build "$v" "$FEMU_DIR/build-femu-$v"
done
for r in $REPS; do
    for v in $VARIANTS; do
        [[ -e $RESULTS/$v/$WL/rep$r ]] && die "$RESULTS/$v/$WL/rep$r exists; move it or pick other REPS"
    done
done
pgrep -f '[F]EMU-BBSSD-VM' >/dev/null && die "a FEMU guest is already running"

echo "build-femu now: $cur"
for r in $REPS; do
    for v in $VARIANTS; do
        echo "plan: $v rep$r -> $RESULTS/$v/$WL/rep$r"
    done
done
[[ $DRY == 1 ]] && { echo "DRY=1: nothing run"; exit 0; }

# ask for the sudo password once and keep it fresh for the whole session
sudo -v || exit 1
while true; do sudo -n -v; sleep 60; done &
KEEPALIVE=$!
trap 'kill $KEEPALIVE 2>/dev/null' EXIT

# --- runs ------------------------------------------------------------------
for r in $REPS; do
    for v in $VARIANTS; do
        use_build "$v"
        echo "[$(date +%T)] === $v rep$r (build-femu = $(cat "$ACTIVE/.variant")) ==="
        WT_PREFIX="${FEMU_DIR%/*}/" LABEL=$v ./run_one.sh "${FEMU_DIR##*/}" "$WL" "$r" \
            || echo "FAILED: $v rep$r"
    done
done

# --- results ---------------------------------------------------------------
CSV=$RESULTS/results_assign.csv
python3 parse.py "$RESULTS" | awk -F, 'NR == 1 || $2 == "assign"' > "$CSV"
echo
echo "results -> $CSV"
cat "$CSV"
