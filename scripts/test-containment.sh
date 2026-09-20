#!/usr/bin/env bash
# Containment: prove one student cannot end the class for everyone else.
#
# Every limit here exists because Claude Code runs with
# --dangerously-skip-permissions. Nothing between a student's prompt and the
# host asks "are you sure" -- these cgroup ceilings are the only thing that
# does. A limit nobody tests is a limit that silently stops being applied, so
# this asserts the kernel's own numbers rather than the config that set them.
#
# Deliberately NOT a fork bomb. The test spawns a bounded number of processes
# and asserts the cap refuses them: if the cap were missing, an actual fork
# bomb would take out the developer's Docker VM to tell us so.
#
#   ./scripts/test-containment.sh [code] [seat]
set -uo pipefail
cd "$(dirname "$0")/.."

CODE="${1:-blue-otter-42}"
SEAT="${2:-student01}"
C="jupyter-$SEAT"
BASE=http://localhost:8000
EXPECT_MEM_BYTES=$(( 2 * 1024 * 1024 * 1024 ))   # LAB_MEM_LIMIT default 2G
EXPECT_PIDS=512                                   # LAB_PIDS_LIMIT default
fails=0
pass() { printf '    ok   %s\n' "$1"; }
fail() { printf '    FAIL %s\n' "$1"; fails=$((fails + 1)); }
cg()   { docker exec "$C" cat "/sys/fs/cgroup/$1" 2>/dev/null; }

echo "== preparing per-seat storage =="
./scripts/dev-seats.sh setup 2 1 >/dev/null 2>&1 \
    || { echo "FATAL: could not prepare seat storage"; exit 1; }
./scripts/dev-seats.sh status | sed 's/^/    /'

echo
echo "== bringing up hub =="
make dev-reset >/dev/null 2>&1
make dev-up >/dev/null 2>&1
for _ in $(seq 1 40); do curl -sf "$BASE/hub/login" -o /dev/null && break; sleep 2; done

JAR="$(mktemp)"; LOGIN="$(mktemp)"
curl -sS -c "$JAR" -b "$JAR" "$BASE/hub/login" -o "$LOGIN"
xsrf="$(grep -o 'name="_xsrf" value="[^"]*"' "$LOGIN" | sed 's/.*value="//; s/"//')"
curl -sS -c "$JAR" -b "$JAR" -X POST "$BASE/hub/login" \
    --data-urlencode "_xsrf=$xsrf" --data-urlencode "username=code" \
    --data-urlencode "password=$CODE" -o /dev/null
curl -sS -c "$JAR" -b "$JAR" -L --max-redirs 20 --max-time 180 "$BASE/hub/spawn" -o /dev/null
for _ in $(seq 1 60); do
    docker ps --filter "name=$C" --format '{{.Status}}' | grep -q Up && break; sleep 3
done
docker ps --filter "name=$C" --format '{{.Status}}' | grep -q Up \
    || { echo "FATAL: $C never started"; exit 1; }

echo
echo "== limits are actually applied (kernel's numbers, not the config's) =="
mem="$(cg memory.max)"
[ "$mem" = "$EXPECT_MEM_BYTES" ] \
    && pass "memory.max = $mem" || fail "memory.max = $mem, wanted $EXPECT_MEM_BYTES"

swap="$(cg memory.swap.max)"
[ "$swap" = "0" ] \
    && pass "memory.swap.max = 0 (cannot escape into host swap)" \
    || fail "memory.swap.max = $swap, wanted 0"

pids="$(cg pids.max)"
[ "$pids" = "$EXPECT_PIDS" ] \
    && pass "pids.max = $pids" || fail "pids.max = $pids, wanted $EXPECT_PIDS"

cpu="$(cg cpu.max)"   # "<quota> <period>"; must not be "max"
quota="$(echo "$cpu" | awk '{print $1}')"
[ "$quota" != "max" ] && [ -n "$quota" ] \
    && pass "cpu.max = $cpu (hard quota, not unlimited)" \
    || fail "cpu.max = $cpu -- one student can take every core"

echo
echo "== PID exhaustion is refused, not absorbed =="
# Fork until the kernel says no, and count. Python because bash's `cmd &`
# does not report fork failure usefully.
#
# The assertion is "creation was REFUSED well short of the target", not
# "pids.peak <= cap". The pids controller enforces at fork() but lets tasks
# MIGRATED into a cgroup charge past the limit, so peak can legitimately sit a
# few above the cap. Asserting on peak fails a working cap.
TARGET=700
spawned="$(docker exec "$C" python3 -c '
import os, sys, time
n = 0
try:
    while n < '"$TARGET"':
        if os.fork() == 0:
            time.sleep(20); os._exit(0)
        n += 1
except OSError:
    pass
sys.stdout.write(str(n))
' 2>/dev/null | tail -1)"
peak="$(cg pids.peak)"
if [ -z "$spawned" ]; then
    fail "fork probe produced no count -- test did not run, result is meaningless"
elif [ "$spawned" -lt "$TARGET" ]; then
    pass "fork refused after $spawned of $TARGET (cap $EXPECT_PIDS, pids.peak $peak)"
else
    fail "reached all $TARGET processes with cap $EXPECT_PIDS -- cap not enforced"
fi

# Let the forked processes drain before anything else runs. While the table is
# full `docker exec` itself cannot get a PID, so the next test silently fails
# to start -- which is how the CPU check came back as 0.0 cores and, before the
# floor check existed, reported a pass.
for _ in $(seq 1 30); do
    cur="$(cg pids.current)"
    [ -n "$cur" ] && [ "$cur" -lt 50 ] && break
    sleep 2
done
pass "process table drained to $(cg pids.current) (exec is usable again)"

echo
echo "== the hub survived it =="
docker ps --filter "name=lab-hub" --format '{{.Status}}' | grep -q Up \
    && pass "lab-hub still running" || fail "lab-hub died"
curl -sf "$BASE/hub/login" -o /dev/null \
    && pass "hub still serving logins" || fail "hub stopped serving"

echo
echo "== CPU ceiling holds under a deliberate spin =="
ncpu="$(docker exec "$C" nproc 2>/dev/null)"
lim="$(echo "$cpu" | awk '{printf "%.2f", $1/$2}')"
# Spin on every visible core, so the container WOULD use ncpu cores if nothing
# stopped it. Run it attached-but-backgrounded from here: `docker exec -d` with
# nested subshells returned before the spinners existed, and the check then
# "passed" against 0.01 cores of usage -- a test that proves nothing while
# reporting success.
docker exec "$C" bash -c 'for i in $(seq 1 '"$ncpu"'); do timeout 14 bash -c "while :; do :; done" & done; wait' >/dev/null 2>&1 &
SPIN=$!
sleep 2                                   # let them all get going
u0="$(cg cpu.stat | awk '/^usage_usec/{print $2}')"
sleep 10
u1="$(cg cpu.stat | awk '/^usage_usec/{print $2}')"
wait $SPIN 2>/dev/null
used="$(python3 -c "print(round(($u1-$u0)/1e6/10, 2))")"
# Floor check first: if the spinners never ran, the ceiling was never tested
# and a low number must not be read as compliance.
if [ "$(python3 -c "print('yes' if $used < 0.5 else 'no')")" = "yes" ]; then
    fail "only ${used} cores of load generated -- spinners never ran, ceiling untested"
elif [ "$(python3 -c "print('yes' if $used <= $lim*1.25 else 'no')")" = "yes" ]; then
    pass "held to ${used} cores against a ${lim}-core ceiling while spinning on ${ncpu}"
else
    fail "used ${used} cores against a ${lim}-core ceiling -- quota not holding"
fi

echo
echo "== memory ceiling kills the offender, not the box =="
oom0="$(cg memory.events | awk '/^oom_kill/{print $2}')"
docker exec "$C" bash -c 'python3 -c "
b=[]
try:
    while True: b.append(bytearray(64*1024*1024))
except MemoryError: pass
"' >/dev/null 2>&1
oom1="$(cg memory.events | awk '/^oom_kill/{print $2}')"
if [ "${oom1:-0}" -gt "${oom0:-0}" ]; then
    pass "allocation past the cap was OOM-killed in-cgroup ($oom0 -> $oom1)"
else
    pass "allocation refused without needing the OOM killer (MemoryError)"
fi
docker ps --filter "name=$C" --format '{{.Status}}' | grep -q Up \
    && pass "student container survived (only the process died)" \
    || fail "student container died -- a student loses their whole session"
docker ps --filter "name=lab-hub" --format '{{.Status}}' | grep -q Up \
    && pass "lab-hub unaffected" || fail "lab-hub died from a student's memory use"

echo
echo "== disk: a full seat is one student's problem, not the class's =="
homedev="$(docker exec "$C" sh -c 'df /home/jovyan | tail -1 | awk "{print \$1}"' 2>/dev/null)"
case "$homedev" in
    /dev/loop*) pass "home is a per-seat filesystem ($homedev)" ;;
    *) fail "home is on $homedev -- not a per-seat filesystem, there is no disk limit" ;;
esac

hostfree_before="$(docker exec "$C" sh -c 'df / | tail -1 | awk "{print \$4}"' 2>/dev/null)"
docker exec "$C" sh -c 'dd if=/dev/zero of=/home/jovyan/fill bs=1M count=4096' >/dev/null 2>&1
seatuse="$(docker exec "$C" sh -c 'df -h /home/jovyan | tail -1 | awk "{print \$5}"' 2>/dev/null)"
[ "$seatuse" = "100%" ] \
    && pass "seat filled to $seatuse and the write stopped (ENOSPC)" \
    || fail "seat at $seatuse after a 4 GiB write into a 1 GiB seat -- not contained"

# The whole point: the container's own root filesystem, which is shared with
# every other seat and with the hub, must be untouched by that.
hostfree_after="$(docker exec "$C" sh -c 'df / | tail -1 | awk "{print \$4}"' 2>/dev/null)"
drop="$(python3 -c "print(round((${hostfree_before:-0}-${hostfree_after:-0})/1048576.0, 2))")"
# Tight on purpose. A loose bound here passed a 0.93 GiB loss as "contained"
# when the seat image was sparse and the fill really was consuming shared
# space. Preallocated seats should cost the shared filesystem nothing.
[ "$(python3 -c "print('yes' if abs($drop) < 0.25 else 'no')")" = "yes" ] \
    && pass "shared filesystem lost only ${drop} GiB while a seat filled entirely" \
    || fail "shared filesystem lost ${drop} GiB -- seat is sparse, the fill escaped it"

other="$(docker run --rm -v "${LAB_DEV_SEAT_ROOT:-/var/lib/lab-seats}/home/student02":/h ubuntu:24.04 \
    sh -c 'dd if=/dev/zero of=/h/probe bs=1M count=64 >/dev/null 2>&1 && df -h /h | tail -1 | awk "{print \$4}"; rm -f /h/probe' 2>/dev/null | tail -1)"
[ -n "$other" ] \
    && pass "another seat still writable (${other} free) while student01 is full" \
    || fail "another seat could not be written while student01 is full"

docker ps --filter "name=lab-hub" --format '{{.Status}}' | grep -q Up \
    && pass "lab-hub unaffected by a full seat" || fail "lab-hub died from a full seat"
docker exec "$C" rm -f /home/jovyan/fill 2>/dev/null

echo
if [ "$fails" -eq 0 ]; then
    echo "containment: all checks passed"
else
    echo "containment: $fails FAILED"
fi
exit $(( fails > 0 ))
