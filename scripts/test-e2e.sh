#!/usr/bin/env bash
# End-to-end: bring up the hub with a chosen curriculum, log in with a code,
# spawn a student container, and assert the student actually got that
# curriculum's material. Covers the wiring the unit tests can't:
# Makefile -> compose -> hub env -> DockerSpawner.environment -> seed-home.
#
# Runs on per-seat bind mounts, the topology `workshop up` produces, and sets
# them up if they are missing. The named-volume fallback is for casual local
# work only: a named volume copies the image's home into the seat, a bind mount
# starts empty, so a suite run on named volumes cannot see a missing dotfile.
# That is how a659e1d shipped with every check green (#4, #5).
#
#   ./scripts/test-e2e.sh [curriculum] [code] [seat]
set -uo pipefail
cd "$(dirname "$0")/.."

CURRICULUM="${1:-./curricula/mcp-servers}"
CODE="${2:-blue-otter-42}"
SEAT="${3:-student01}"
BASE=http://localhost:8000
JAR="$(mktemp)"
fails=0
pass() { printf '    ok   %s\n' "$1"; }
fail() { printf '    FAIL %s\n' "$1"; fails=$((fails + 1)); }

echo "== seat storage =="
if ! ./scripts/dev-seats.sh status 2>/dev/null | grep -q ' yes '; then
    make dev-seats >/dev/null 2>&1 \
        || { echo "    FAIL could not set up seat storage (make dev-seats); refusing to test on named volumes"; exit 1; }
fi
pass "per-seat storage mounted"

echo "== bringing up hub with curriculum '$CURRICULUM' =="
make dev-reset >/dev/null 2>&1
make dev-up CURRICULUM="$CURRICULUM" >/dev/null 2>&1
for _ in $(seq 1 30); do
    curl -sf "$BASE/hub/login" -o /dev/null 2>/dev/null && break
    sleep 2
done

echo "== login =="
curl -sS -c "$JAR" -b "$JAR" "$BASE/hub/login" -o /tmp/login.html 2>/dev/null
xsrf="$(grep -o 'name="_xsrf" value="[^"]*"' /tmp/login.html | sed 's/.*value="//; s/"//')"
code="$(curl -sS -c "$JAR" -b "$JAR" -X POST "$BASE/hub/login" \
    --data-urlencode "_xsrf=$xsrf" --data-urlencode "username=code" \
    --data-urlencode "password=$CODE" -o /dev/null -w '%{http_code}' 2>/dev/null)"
[ "$code" = "302" ] && pass "code '$CODE' accepted" || fail "login returned $code"

echo "== spawn =="
curl -sS -c "$JAR" -b "$JAR" -L --max-redirs 20 --max-time 120 \
    "$BASE/hub/spawn" -o /dev/null 2>/dev/null
for _ in $(seq 1 40); do
    docker ps --filter "name=jupyter-$SEAT" --format '{{.Status}}' | grep -q Up && break
    sleep 3
done
docker ps --filter "name=jupyter-$SEAT" --format '{{.Status}}' | grep -q Up \
    && pass "container running" || fail "container never started"

# Everything below is only evidence about a real seat if the home is mounted
# the way the box mounts it.
home_mount="$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/home/jovyan"}}{{.Type}}{{end}}{{end}}' \
    "jupyter-$SEAT" 2>/dev/null)"
[ "$home_mount" = "bind" ] \
    && pass "home is a bind mount, as on the box" \
    || fail "home is a '${home_mount:-missing}' mount, not bind -- this run says nothing about a real seat"

echo "== JupyterLab serving =="
for _ in $(seq 1 25); do
    curl -sS -b "$JAR" -c "$JAR" -L --max-redirs 20 --max-time 30 \
        "$BASE/user/$SEAT/lab" -o /tmp/lab.html 2>/dev/null
    grep -q '<title>JupyterLab</title>' /tmp/lab.html && break
    sleep 5
done
grep -q '<title>JupyterLab</title>' /tmp/lab.html \
    && pass "JupyterLab reachable" || fail "JupyterLab never served"

echo "== student got the right curriculum =="
docker exec "jupyter-$SEAT" test -f /home/jovyan/.lab-seeded 2>/dev/null \
    && pass "seed marker present" || fail "seed marker missing: seed-home never ran"
# The lesson directories in the student's home must be exactly the ones in the
# curriculum that was passed in; a wrong or missing mount shows up here.
want="$(ls "$CURRICULUM/lessons" | sort | tr '\n' ' ')"
got="$(docker exec "jupyter-$SEAT" bash -c 'ls /home/jovyan/lessons' 2>/dev/null | sort | tr '\n' ' ')"
[ -n "$got" ] && [ "$got" = "$want" ] \
    && pass "lessons match $CURRICULUM: $got" \
    || fail "lessons are '$got', wanted '$want'"

docker exec "jupyter-$SEAT" test -f /home/jovyan/CLAUDE.md 2>/dev/null \
    && pass "CLAUDE.md present" || fail "CLAUDE.md missing"
docker exec "jupyter-$SEAT" bash -c 'ls /home/jovyan/.claude/skills' 2>/dev/null | grep -q . \
    && pass "skills present" || fail "no skills"
docker exec "jupyter-$SEAT" bash -c 'claude --version' 2>/dev/null | grep -q 'Claude Code' \
    && pass "Claude Code runs" || fail "Claude Code broken (expected under QEMU on arm64)"
docker exec "jupyter-$SEAT" bash -c '[ -n "$ANTHROPIC_API_KEY" ]' 2>/dev/null \
    && pass "API key injected" || fail "no API key"

echo "== opening a terminal starts Claude Code =="
# What a student does: click Terminal in JupyterLab. That is a POST to the
# single-user server's terminals API, which starts the same login shell a
# browser gets. The shell shows the banner, waits 10s for "t", then execs
# claude -- so a running claude with the flag, and no one typing, is the proof.
#
# The pattern is bracketed so the grep never matches its own command line.
count_agents() {
    local n
    n="$(docker exec "jupyter-$SEAT" bash -c \
        'for f in /proc/[0-9]*/cmdline; do tr "\0" " " < "$f" 2>/dev/null; echo; done \
         | grep -c "dangerous[l]y-skip-permissions" || true' 2>/dev/null)"
    echo "${n:-0}"
}
open_terminal() {
    curl -sS -b "$JAR" -c "$JAR" -X POST -H "X-XSRFToken: $xsrf_user" \
        "$BASE/user/$SEAT/api/terminals" -o /dev/null -w '%{http_code}' 2>/dev/null
}
xsrf_user="$(awk -v p="/user/$SEAT/" '$6 == "_xsrf" && $3 == p { v = $7 } END { print v }' "$JAR")"
if [ -z "$xsrf_user" ]; then
    fail "no _xsrf cookie for /user/$SEAT/ -- cannot open a terminal"
else
    before="$(count_agents)"
    status="$(open_terminal)"
    [ "$status" = "200" ] && pass "terminal opened" || fail "terminals API returned $status"
    after="$before"
    for _ in $(seq 1 20); do
        after="$(count_agents)"
        [ "$after" -gt "$before" ] && break
        sleep 2
    done
    [ "$after" -gt "$before" ] \
        && pass "claude --dangerously-skip-permissions started with no one typing" \
        || fail "terminal stayed a bare prompt: Claude Code never started (the #5 bug)"

    # Floor check: take away the file the chain starts at and the same action
    # must NOT start the agent, or the check above is not detecting anything.
    docker exec -u jovyan "jupyter-$SEAT" rm -f /home/jovyan/.profile
    before="$(count_agents)"
    open_terminal >/dev/null
    sleep 20
    after="$(count_agents)"
    [ "$after" -le "$before" ] \
        && pass "floor check: with no .profile the terminal does not start Claude Code" \
        || fail "floor check: Claude Code started without .profile -- the check above proves nothing"
    docker exec -u jovyan "jupyter-$SEAT" cp /opt/lab/skel/.profile /home/jovyan/.profile 2>/dev/null || true
fi

rm -f "$JAR"
echo
[ "$fails" -eq 0 ] && echo "E2E PASSED ($CURRICULUM)" || echo "$fails CHECK(S) FAILED"
exit "$fails"
