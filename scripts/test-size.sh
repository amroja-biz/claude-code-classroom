#!/usr/bin/env bash
# Verify instance sizing is derived correctly from cohort size, that memory per
# seat is itself a parameter, and that there is no hidden default cohort size.
set -uo pipefail
cd "$(dirname "$0")/.."
. scripts/lib-size.sh

fails=0
pass() { printf '    ok   %s\n' "$1"; }
fail() { printf '    FAIL %s\n' "$1"; fails=$((fails + 1)); }

# expect <students> <peak-mib-per-seat> <expected-type>
expect() {
    local got
    got="$(lab_pick_instance "$1" "$2" 2>/dev/null | awk '{print $1}')"
    [ "$got" = "$3" ] && pass "$1 students @ ${2}MiB peak -> $got" \
                      || fail "$1 students @ ${2}MiB peak -> '$got', wanted '$3'"
}

# At the measured 1024 MiB peak, need = students + 4 GiB host. Usable memory is
# 95% of nominal: large 15, xlarge 30, 2xlarge 60, 4xlarge 121, 8xlarge 243.
echo
echo "== boundaries at the measured 1024 MiB peak (4 GiB host overhead) =="
expect 1   1024 r7i.large
expect 9   1024 r7i.large       # last that fits large with 10% slack
expect 10  1024 r7i.xlarge      # first over
expect 23  1024 r7i.xlarge
expect 24  1024 r7i.2xlarge
expect 50  1024 r7i.2xlarge
expect 51  1024 r7i.4xlarge
expect 106 1024 r7i.4xlarge
expect 107 1024 r7i.8xlarge
expect 216 1024 r7i.8xlarge
expect 217 1024 r7i.12xlarge

echo
echo "== peak per seat is a parameter, not a constant =="
# One cohort, four measured peaks, four different boxes.
expect 40 512  r7i.xlarge    # 24 GiB
expect 40 1024 r7i.2xlarge   # 44 GiB
expect 40 2048 r7i.4xlarge   # 84 GiB - same cohort, bigger box
expect 40 4096 r7i.8xlarge   # 164 GiB

echo
echo "== the chosen box always has real headroom =="
# Regression: the picker used to compare against NOMINAL memory, so a cohort
# needing exactly 64 GiB was given a "64 GiB" instance that reports less than
# that to Linux. Every choice must clear usable memory with room left.
tight=0
for n in 1 5 11 12 26 27 30 40 56 57 100 117 118 200; do
    read -r _ _ nominal _ <<<"$(lab_pick_instance "$n" 1024 2>/dev/null)"
    [ -n "$nominal" ] || continue
    need="$(lab_required_gib "$n" 1024)"
    usable="$(lab_usable_gib "$nominal")"
    # Must clear the requirement by the margin, not merely equal it.
    [ $(( usable * 100 )) -ge $(( need * (100 + LAB_HEADROOM_PERCENT) )) ] \
        || tight=$((tight + 1))
done
[ "$tight" -eq 0 ] && pass "no cohort size is given an exact fit" \
                   || fail "$tight cohort size(s) sized with no headroom"

echo
echo "== oversized cohort is refused, not silently truncated =="
if lab_pick_instance 500 1024 >/dev/null 2>&1; then
    fail "500 students should not fit any single instance"
else
    pass "500 students refused"
fi
err="$(lab_pick_instance 500 1024 2>&1 >/dev/null)"
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
echo "== the cap does not silently drive sizing, and is not silently ignored =="
# Regression. Sizing used to be a fixed percentage of the per-seat cap. That is
# only safe while the cap sits well above real usage: set --mem near true peak
# -- what a careful operator does -- and the same formula picked a box the
# cohort could exhaust, with nothing checking or saying so.

got="$(lab_effective_peak_mib 2)"
[ "$got" = "1024" ] && pass "default cap uses the measured peak (${got} MiB)" \
                    || fail "default cap sized from ${got} MiB, wanted 1024"

got="$(lab_effective_peak_mib 5)"
[ "$got" = "5120" ] && pass "raised cap with no measurement plans at the cap (${got} MiB)" \
                    || fail "raised cap sized from ${got} MiB, wanted 5120"

got="$(LAB_PEAK_MIB=4096; . scripts/lib-size.sh; lab_effective_peak_mib 5)"
[ "$got" = "4096" ] && pass "an explicit measurement wins over the cap (${got} MiB)" \
                    || fail "explicit LAB_PEAK_MIB gave ${got}, wanted 4096"

# The failure this prevents, concretely: 30 seats whose material really peaks
# at 4 GiB. The box chosen for a 5 GiB cap must survive that, and the old
# formula's r7i.4xlarge (121 GiB usable vs 124 GiB needed) did not.
read -r _ _ nominal _ <<<"$(lab_pick_instance 30 "$(lab_effective_peak_mib 5)")"
usable="$(lab_usable_gib "${nominal:-0}")"
honest=$(( 30 * 4 + LAB_HOST_OVERHEAD_GIB ))
[ -n "$nominal" ] && [ "$usable" -ge "$honest" ] \
    && pass "30 seats @ --mem 5 got ${nominal} GiB (${usable} usable >= ${honest} honest worst case)" \
    || fail "30 seats @ --mem 5 got ${nominal:-none} GiB -- ${usable} usable < ${honest} needed"

# Oversubscription must be stated, not left for the operator to infer.
out="$(./scripts/workshop size --students 30 2>&1)"
grep -q 'if all capped' <<<"$out" && pass "reports what happens if every seat pegs its cap" \
                                  || fail "oversubscription is not reported"

echo
[ "$fails" -eq 0 ] && echo "ALL SIZING TESTS PASSED" || echo "$fails CHECK(S) FAILED"
exit "$fails"
