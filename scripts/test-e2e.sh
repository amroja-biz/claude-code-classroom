#!/usr/bin/env bash
# End-to-end: bring up the hub with a chosen curriculum, log in with a code,
# spawn a student container, and assert the student actually got that
# curriculum's material. Covers the wiring the unit tests can't:
# Makefile -> compose -> hub env -> DockerSpawner.environment -> seed-home.
#
#   ./scripts/test-e2e.sh [curriculum] [code] [seat]
set -uo pipefail
cd "$(dirname "$0")/.."

CURRICULUM="${1:-mcp-servers}"
CODE="${2:-blue-otter-42}"
SEAT="${3:-student01}"
BASE=http://localhost:8000
JAR="$(mktemp)"
fails=0
pass() { printf '    ok   %s\n' "$1"; }
fail() { printf '    FAIL %s\n' "$1"; fails=$((fails + 1)); }

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
seeded="$(docker exec "jupyter-$SEAT" cat /home/jovyan/.lab-seeded 2>/dev/null | tr -d '[:space:]')"
[ "$seeded" = "$CURRICULUM" ] && pass "seeded '$seeded'" || fail "seeded '$seeded', wanted '$CURRICULUM'"

docker exec "jupyter-$SEAT" test -f /home/jovyan/CLAUDE.md 2>/dev/null \
    && pass "CLAUDE.md present" || fail "CLAUDE.md missing"
docker exec "jupyter-$SEAT" bash -c 'ls /home/jovyan/.claude/skills' 2>/dev/null | grep -q . \
    && pass "skills present" || fail "no skills"
docker exec "jupyter-$SEAT" bash -c 'claude --version' 2>/dev/null | grep -q 'Claude Code' \
    && pass "Claude Code runs" || fail "Claude Code broken (expected under QEMU on arm64)"
docker exec "jupyter-$SEAT" bash -c '[ -n "$ANTHROPIC_API_KEY" ]' 2>/dev/null \
    && pass "API key injected" || fail "no API key"

rm -f "$JAR"
echo
[ "$fails" -eq 0 ] && echo "E2E PASSED ($CURRICULUM)" || echo "$fails CHECK(S) FAILED"
exit "$fails"
