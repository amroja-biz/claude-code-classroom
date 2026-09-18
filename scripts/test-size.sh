#!/usr/bin/env bash
# Verify instance sizing is derived correctly from cohort size, that memory per
# seat is itself a parameter, and that there is no hidden default cohort size.
set -uo pipefail
cd "$(dirname "$0")/.."
. scripts/lib-size.sh

fails=0
pass() { printf '    ok   %s\n' "$1"; }
fail() { printf '    FAIL %s\n' "$1"; fails=$((fails + 1)); }

# expect <students> <gib-per-seat> <expected-type>
expect() {
    local got
    got="$(lab_pick_instance "$1" "$2" 2>/dev/null | awk '{print $1}')"
    [ "$got" = "$3" ] && pass "$1 students @ ${2}GiB -> $got" \
                      || fail "$1 students @ ${2}GiB -> '$got', wanted '$3'"
}

echo
echo "== boundaries at 2 GiB/seat (4 GiB host overhead) =="
expect 1   2 r7i.large       # 6 GiB
expect 6   2 r7i.large       # 16 GiB - exactly fills large
expect 7   2 r7i.xlarge      # 18 GiB - first over
expect 14  2 r7i.xlarge      # 32 GiB - exactly fills xlarge
expect 15  2 r7i.2xlarge     # 34 GiB
expect 30  2 r7i.2xlarge     # 64 GiB - exactly fills 2xlarge
expect 31  2 r7i.4xlarge     # 66 GiB
expect 62  2 r7i.4xlarge     # 128 GiB - exactly fills 4xlarge
expect 63  2 r7i.8xlarge     # 130 GiB
expect 126 2 r7i.8xlarge     # 256 GiB - exactly fills 8xlarge
expect 127 2 r7i.12xlarge    # 258 GiB

echo
echo "== memory per seat is a parameter, not a constant =="
expect 20 1 r7i.xlarge       # 24 GiB  - fits smaller box at 1 GiB/seat
expect 20 2 r7i.2xlarge      # 44 GiB
expect 20 4 r7i.4xlarge      # 84 GiB  - same cohort, bigger box
expect 20 8 r7i.8xlarge      # 164 GiB

echo
echo "== oversized cohort is refused, not silently truncated =="
if lab_pick_instance 300 2 >/dev/null 2>&1; then
    fail "300 students should not fit any single instance"
else
    pass "300 students refused"
fi
err="$(lab_pick_instance 300 2 2>&1 >/dev/null)"
grep -q 'multiple independent stacks' <<<"$err" && pass "suggests the workaround" \
                                                || fail "no guidance in error"

echo
echo "== no default cohort size anywhere =="
out="$(./scripts/workshop size 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && pass "'size' without --students exits nonzero" || fail "ran without --students"
grep -q 'there is no default cohort size' <<<"$out" && pass "explains why" || fail "unhelpful error"

out="$(./scripts/workshop up --curriculum intro-agents 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && pass "'up' without --students exits nonzero" || fail "ran without --students"

out="$(./scripts/workshop size --students 0 2>&1)"
grep -q 'positive integer' <<<"$out" && pass "rejects zero" || fail "accepted 0 students"
out="$(./scripts/workshop size --students abc 2>&1)"
grep -q 'positive integer' <<<"$out" && pass "rejects non-numeric" || fail "accepted 'abc'"

grep -rqE '^\s*STUDENTS="?[0-9]' scripts/ && fail "a default cohort size crept in" \
                                          || pass "no hardcoded cohort size in scripts/"

echo
[ "$fails" -eq 0 ] && echo "ALL SIZING TESTS PASSED" || echo "$fails CHECK(S) FAILED"
exit "$fails"
