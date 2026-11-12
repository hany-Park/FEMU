#!/bin/bash
# Every variant x workload x repetition, one run at a time.
#
# usage (on the server, inside tmux so a dropped ssh does not stop it):
#   tmux new -s exp
#   ./run_all.sh 2>&1 | tee run_all.log
#
# env: VARIANTS, WORKLOADS, REPS override the lists below; the rest is
# passed through to run_one.sh (RUN, CAP, WT_PREFIX, RESULTS).
set -uo pipefail
cd "$(dirname "$0")"

VARIANTS=${VARIANTS:-"baseline hotcold1"}
WORKLOADS=${WORKLOADS:-"uniform zone80 zone95"}
REPS=${REPS:-"1 2 3"}

# Ask for the sudo password once, then keep the credential fresh so a run
# that lasts longer than the sudo timeout does not stall.
sudo -v || exit 1
while true; do sudo -n -v; sleep 60; done &
KEEPALIVE=$!
trap 'kill $KEEPALIVE 2>/dev/null' EXIT

# Repetitions outermost: drift in the host over the night is spread across
# variants instead of landing on one of them.
for rep in $REPS; do
    for wl in $WORKLOADS; do
        for v in $VARIANTS; do
            ./run_one.sh "$v" "$wl" "$rep" || echo "FAILED: $v $wl rep$rep"
        done
    done
done
