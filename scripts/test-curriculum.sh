#!/usr/bin/env bash
# Verify curriculum seeding: whatever is mounted at /opt/lab/curriculum lands in
# the student's home per the layout contract, nothing from any other curriculum
# leaks in, and a missing mount degrades loudly rather than looking fine.
#
# Runs the student image directly (no hub) so it is fast and isolates the seed
# logic. The hub's job -- mounting the right directory -- is covered separately
# by scripts/test-e2e.sh.
#
#   ./scripts/test-curriculum.sh [image]
set -uo pipefail

IMAGE="${1:-lab-student:latest}"
# The curriculum is mounted, not baked in, so the test has to supply one the
# same way the spawner does.
CURRICULA="$(cd "$(dirname "$0")/../curricula" && pwd)"
mount_for() { echo "-v" "${CURRICULA}/$1:/opt/lab/curriculum:ro"; }
fails=0
pass() { printf '    ok   %s\n' "$1"; }
fail() { printf '    FAIL %s\n' "$1"; fails=$((fails + 1)); }

# Run the seed inside a throwaway container with the named example curriculum
# mounted, and dump the resulting home.
seed() {
    docker run --rm $(mount_for "$1") \
        -e ANTHROPIC_API_KEY=sk-test-0123456789ABCDEFGHIJ \
        --entrypoint /bin/bash "$IMAGE" -c '
            /usr/local/bin/lab-seed-home 2>/tmp/seed.log
            echo "===FILES==="; find "$HOME" -maxdepth 3 \
                -not -path "*/.cache/*" -not -path "*/.npm/*" -not -path "*/.mamba/*" \
                -not -path "*/.local/*" -not -path "*/.jupyter/*" -not -path "*/.ipython/*" \
                | sed "s|$HOME|~|"
            echo "===MARKER==="; cat "$HOME/.lab-seeded" 2>/dev/null
            echo "===WELCOME==="; cat "$HOME/.lab-welcome" 2>/dev/null
            echo "===CLAUDEMD==="; cat "$HOME/CLAUDE.md" 2>/dev/null
            echo "===LOG==="; cat /tmp/seed.log
        ' 2>/dev/null
}

has() { grep -qF "$2" <<<"$1"; }

echo
echo "== curriculum: intro-agents =="
out="$(seed intro-agents)"
has "$out" '~/lessons/01-first-agent/README.md' && pass "lesson seeded" || fail "lesson missing"
has "$out" '~/.claude/skills/hello-lab'         && pass "skill seeded"  || fail "skill missing"
has "$out" 'Intro to AI Agents'                 && pass "welcome text"  || fail "welcome missing"
has "$out" 'new to AI agents'                   && pass "CLAUDE.md"     || fail "CLAUDE.md missing"
has "$out" 'seeded curriculum'                  && pass "logged seed"   || fail "no seed log"
has "$out" '~/lessons/01-what-is-mcp'           && fail "LEAKED other curriculum" || pass "no cross-contamination"

echo
echo "== curriculum: mcp-servers =="
out="$(seed mcp-servers)"
has "$out" '~/lessons/01-what-is-mcp/README.md' && pass "lesson seeded" || fail "lesson missing"
has "$out" '~/.claude/skills/mcp-probe'         && pass "skill seeded"  || fail "skill missing"
has "$out" 'Building MCP Servers'               && pass "welcome text"  || fail "welcome missing"
has "$out" 'Model Context Protocol'             && pass "CLAUDE.md"     || fail "CLAUDE.md missing"
has "$out" '~/lessons/01-first-agent'           && fail "LEAKED other curriculum" || pass "no cross-contamination"

echo
echo "== workspace contract =="
out="$(seed intro-agents)"
has "$out" '~/work'                         && pass "~/work exists"           || fail "~/work missing"
has "$out" 'Put every file you create here' && pass "CLAUDE.md names ~/work"  || fail "CLAUDE.md silent on output location"
has "$out" 'do not write into it'           && pass "lessons read-only"       || fail "lessons not marked read-only"
has "$out" 'Your work: ~/work'              && pass "banner names ~/work"     || fail "banner silent on ~/work"

echo
echo "== curriculum beats base skel =="
# Regression: skel is copied first, and with cp -rn a base file would silently
# win over the curriculum's own version of the same path.
cm="$(docker run --rm $(mount_for mcp-servers) --entrypoint /bin/bash "$IMAGE" \
      -c '/usr/local/bin/lab-seed-home 2>/dev/null; cat "$HOME/CLAUDE.md" 2>/dev/null' 2>/dev/null)"
grep -q 'Model Context Protocol' <<<"$cm" && pass "curriculum CLAUDE.md wins" \
                                          || fail "curriculum CLAUDE.md was shadowed"

echo
echo "== marker records that a curriculum was seeded =="
out="$(seed mcp-servers)"
marker="$(sed -n '/===MARKER===/,/===WELCOME===/p' <<<"$out" | sed '1d;$d')"
grep -q ' curriculum$' <<<"$marker" && pass "marker = $marker" || fail "marker = '$marker' (want '<timestamp> curriculum')"

echo
echo "== the curriculum is NOT baked into the image =="
# Regression guard. Material lived in the image once, which meant a one-line
# lesson fix cost a 20-minute AMI rebake. If a COPY comes back, catch it here
# rather than discovering it the morning of a workshop.
baked="$(docker run --rm --entrypoint /bin/bash "$IMAGE" \
         -c 'ls -A /opt/lab/curriculum /opt/lab/curricula 2>/dev/null' 2>/dev/null | tr -d '[:space:]')"
[ -z "$baked" ] && pass "image ships no curriculum" \
                || fail "a curriculum is baked into the image again: $baked"

# And with nothing mounted, the lab must degrade loudly rather than look fine.
nomount="$(docker run --rm --entrypoint /bin/bash "$IMAGE" \
           -c '/usr/local/bin/lab-seed-home 2>&1 >/dev/null; echo "===MARKER==="; cat "$HOME/.lab-seeded"' 2>/dev/null)"
grep -q 'ERROR: no curriculum mounted' <<<"$nomount" && pass "unmounted degrades loudly" \
                                                     || fail "unmounted lab was silent"
grep -q 'base-only' <<<"$nomount" && pass "marker says base-only" \
                                  || fail "marker does not record the missing curriculum"

echo
echo "== a student on a real seat reaches the banner and Claude Code =="

# Production mounts each home as a per-seat BIND mount (hub/jupyterhub_config.py
# -> scripts/seat-storage.sh). A bind mount does not copy image content the way a
# named volume does, so the home starts genuinely empty -- every dotfile the base
# image shipped is shadowed and gone.
#
# That matters because JupyterLab's terminal runs a LOGIN shell, which reads
# ~/.profile and never ~/.bashrc on its own. Seeding can therefore succeed in
# full -- lessons present, CLAUDE.md present, welcome text present -- while the
# student gets a bare prompt and no agent.
#
# Every other test in this repo runs the image with its own home, which has the
# base .profile in it, so this path is invisible to all of them. Mount an empty
# directory the way a seat does.
SEAT_HOME="$(mktemp -d)"
chmod 777 "$SEAT_HOME"

# banner_from <home-mount-args...> -- seed, then capture one login shell
banner_from() {
    docker run --rm $(mount_for intro-agents) "$@" \
        -e ANTHROPIC_API_KEY=sk-test-0123456789ABCDEFGHIJ \
        --entrypoint /bin/bash "$IMAGE" -c '
            /usr/local/bin/lab-seed-home >/dev/null 2>&1
            # "t" declines the Claude Code launch; without it the shell execs the
            # agent and the test would wait on a real API call.
            echo t | timeout 20 bash -l -i 2>&1
        ' 2>/dev/null
}

seat_out="$(banner_from -v "${SEAT_HOME}:/home/jovyan")"

has "$seat_out" "NOTHING HERE IS SAVED" \
    && pass "login shell on a bind-mounted seat renders the welcome banner" \
    || fail "bind-mounted seat: no banner -- .profile -> .bashrc -> .lab-bashrc is broken"
has "$seat_out" "Starting Claude Code" \
    && pass "login shell on a bind-mounted seat offers Claude Code" \
    || fail "bind-mounted seat: Claude Code never starts; student lands on a bare prompt"
has "$seat_out" "Intro to AI Agents" \
    && pass "the curriculum's own welcome text reaches the banner" \
    || fail "bind-mounted seat: banner did not include curriculum welcome text"

# Floor check: the assertions above must be detecting the mechanism, not some
# other path that happens to print a banner. Remove the one file the chain
# starts at and the same run must fail.
noprofile_out="$(docker run --rm $(mount_for intro-agents) -v "${SEAT_HOME}:/home/jovyan" \
    -e ANTHROPIC_API_KEY=sk-test-0123456789ABCDEFGHIJ \
    --entrypoint /bin/bash "$IMAGE" -c '
        /usr/local/bin/lab-seed-home >/dev/null 2>&1
        rm -f "$HOME/.profile" "$HOME/.bash_profile" "$HOME/.bash_login"
        echo t | timeout 20 bash -l -i 2>&1
    ' 2>/dev/null)"
has "$noprofile_out" "NOTHING HERE IS SAVED" \
    && fail "floor check: banner appeared with no .profile -- this test proves nothing" \
    || pass "floor check: removing .profile does break the banner"

find "$SEAT_HOME" -mindepth 1 -depth -delete 2>/dev/null
rmdir "$SEAT_HOME" 2>/dev/null

echo
if [ "$fails" -eq 0 ]; then
    echo "ALL CURRICULUM TESTS PASSED"
else
    echo "$fails CHECK(S) FAILED"
fi
exit "$fails"
