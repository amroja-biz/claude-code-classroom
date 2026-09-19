#!/usr/bin/env bash
# Verify a LIVE workshop deployment end to end, the way a student meets it:
# over HTTPS, at the real hostname, with a real code.
#
#   ./scripts/test-live.sh <domain> <code> [seat] [--insecure]
#
# Pass --insecure when the workshop was brought up with `--staging`, since Let's
# Encrypt staging certificates are deliberately untrusted.
set -uo pipefail

DOMAIN="${1:?usage: test-live.sh <domain> <code> [seat] [--insecure]}"
CODE="${2:?need a login code}"
SEAT="${3:-student01}"
INSECURE=""
[ "${4:-}" = "--insecure" ] || [ "${3:-}" = "--insecure" ] && INSECURE="-k"
[ "${3:-}" = "--insecure" ] && SEAT="student01"

BASE="https://$DOMAIN"
JAR="$(mktemp)"
fails=0
pass() { printf '    ok   %s\n' "$1"; }
fail() { printf '    FAIL %s\n' "$1"; fails=$((fails + 1)); }

echo
echo "== DNS =="
ip="$(dig +short A "$DOMAIN" @8.8.8.8 2>/dev/null | tail -1)"
[ -n "$ip" ] && pass "$DOMAIN -> $ip" || fail "$DOMAIN does not resolve"

echo
echo "== TLS =="
if [ -z "$INSECURE" ]; then
    curl -sS --max-time 20 "$BASE/hub/login" -o /dev/null 2>/dev/null \
        && pass "certificate trusted" || fail "certificate not trusted (staging? pass --insecure)"
else
    echo "    --  skipped (staging certificate)"
fi

echo
echo "== login page =="
code="$(curl -sS $INSECURE --max-time 20 -c "$JAR" -b "$JAR" "$BASE/hub/login" \
        -o /tmp/live-login.html -w '%{http_code}' 2>/dev/null)"
[ "$code" = "200" ] && pass "HTTP 200" || fail "HTTP $code"
grep -q 'Claude Code Classroom' /tmp/live-login.html && pass "custom template served" || fail "stock template"
grep -q 'Enter the code from your handout' /tmp/live-login.html \
    && pass "single-field login" || fail "wrong login form"

echo
echo "== hub port is not exposed =="
if [ -n "$ip" ]; then
    if timeout 6 bash -c "</dev/tcp/$ip/8000" 2>/dev/null; then
        fail "port 8000 reachable from the internet"
    else
        pass "port 8000 closed"
    fi
fi

echo
echo "== login and spawn =="
xsrf="$(grep -o 'name="_xsrf" value="[^"]*"' /tmp/live-login.html | sed 's/.*value="//; s/"//')"
code="$(curl -sS $INSECURE --max-time 30 -c "$JAR" -b "$JAR" -X POST "$BASE/hub/login" \
        --data-urlencode "_xsrf=$xsrf" --data-urlencode "username=code" \
        --data-urlencode "password=$CODE" -o /dev/null -w '%{http_code}' 2>/dev/null)"
[ "$code" = "302" ] && pass "code accepted" || fail "login returned $code"

curl -sS $INSECURE -c "$JAR" -b "$JAR" -L --max-redirs 20 --max-time 180 \
    "$BASE/hub/spawn" -o /dev/null 2>/dev/null

for _ in $(seq 1 30); do
    curl -sS $INSECURE -b "$JAR" -c "$JAR" -L --max-redirs 20 --max-time 30 \
        "$BASE/user/$SEAT/lab" -o /tmp/live-lab.html 2>/dev/null
    grep -q '<title>JupyterLab</title>' /tmp/live-lab.html && break
    sleep 6
done
grep -q '<title>JupyterLab</title>' /tmp/live-lab.html \
    && pass "JupyterLab served over HTTPS" || fail "JupyterLab never appeared"

rm -f "$JAR"
echo
[ "$fails" -eq 0 ] && echo "LIVE DEPLOYMENT PASSED ($DOMAIN)" || echo "$fails CHECK(S) FAILED"
exit "$fails"
