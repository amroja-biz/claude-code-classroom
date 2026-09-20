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

# At a 2 GiB cap planned at 50%, need = students + 4 GiB host. Usable memory is
# 95% of nominal: large 15, xlarge 30, 2xlarge 60, 4xlarge 121, 8xlarge 243.
echo
echo "== boundaries at 2 GiB/seat (4 GiB host overhead) =="
expect 1   2 r7i.large
expect 9   2 r7i.large       # last that fits large with 10% slack
expect 10  2 r7i.xlarge      # first over
expect 23  2 r7i.xlarge
expect 24  2 r7i.2xlarge
expect 50  2 r7i.2xlarge
expect 51  2 r7i.4xlarge
expect 106 2 r7i.4xlarge
expect 107 2 r7i.8xlarge
expect 216 2 r7i.8xlarge
expect 217 2 r7i.12xlarge

echo
echo "== memory per seat is a parameter, not a constant =="
# One cohort, four caps, four different boxes.
expect 40 1 r7i.xlarge       # 24 GiB - fits a smaller box at 1 GiB/seat
expect 40 2 r7i.2xlarge      # 44 GiB
expect 40 4 r7i.4xlarge      # 84 GiB - same cohort, bigger box
expect 40 8 r7i.8xlarge      # 164 GiB

echo
echo "== the chosen box always has real headroom =="
# Regression: the picker used to compare against NOMINAL memory, so a cohort
# needing exactly 64 GiB was given a "64 GiB" instance that reports less than
# that to Linux. Every choice must clear usable memory with room left.
tight=0
for n in 1 5 11 12 26 27 30 40 56 57 100 117 118 200; do
    read -r _ _ nominal _ <<<"$(lab_pick_instance "$n" 2 2>/dev/null)"
    [ -n "$nominal" ] || continue
    need="$(lab_required_gib "$n" 2)"
    usable="$(lab_usable_gib "$nominal")"
    # Must clear the requirement by the margin, not merely equal it.
    [ $(( usable * 100 )) -ge $(( need * (100 + LAB_HEADROOM_PERCENT) )) ] \
        || tight=$((tight + 1))
done
[ "$tight" -eq 0 ] && pass "no cohort size is given an exact fit" \
                   || fail "$tight cohort size(s) sized with no headroom"

echo
echo "== oversized cohort is refused, not silently truncated =="
if lab_pick_instance 500 2 >/dev/null 2>&1; then
    fail "500 students should not fit any single instance"
else
    pass "500 students refused"
fi
err="$(lab_pick_instance 500 2 2>&1 >/dev/null)"
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
