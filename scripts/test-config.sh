#!/usr/bin/env bash
# Verify that workshop.conf is authoritative over the ambient environment when
# resolving the AWS account, and that mutating commands name the account they
# are about to act on.
#
# This exists because the precedence was once backwards: an exported
# AWS_PROFILE from a shell profile overrode LAB_AWS_PROFILE, so `init` could
# deploy -- and `down` could destroy -- in an account the operator never chose,
# with nothing in the output to show it. See issue #1.
#
# No AWS calls: a stub `aws` on PATH reports what the script resolved.
set -uo pipefail
cd "$(dirname "$0")/.."

fails=0
pass() { printf '    ok   %s\n' "$1"; }
fail() { printf '    FAIL %s\n' "$1"; fails=$((fails + 1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/aws" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  *"sts get-caller-identity --query Account"*) echo "111122223333" ;;
  *"sts get-caller-identity"*) echo '{"Account":"111122223333"}' ;;
  *"configure list-profiles"*) printf 'default\nfrom-env\nfrom-conf\n' ;;
  *"--version"*) echo "aws-cli/2.0.0" ;;
  *) echo "[]" ;;
esac
STUB
chmod +x "$TMP/aws"

cat > "$TMP/workshop.conf" <<'CONF'
LAB_AWS_PROFILE=from-conf
LAB_AWS_REGION=us-west-2
LAB_DOMAIN=lab.example.com
LAB_VPC_ID=vpc-test
LAB_SSM_PARAM=/lab/test-key
CONF

# run <sub> -- the script with the stub on PATH and a hostile environment
run() { PATH="$TMP:$PATH" LAB_CONF="$TMP/workshop.conf" \
        AWS_PROFILE=from-env AWS_REGION=eu-west-1 ./scripts/workshop "$@" 2>&1; }

echo
echo "== workshop.conf beats the environment =="

out="$(run discover)"
grep -q '"profile": "from-conf"' <<<"$out" \
    && pass "LAB_AWS_PROFILE wins over an exported AWS_PROFILE" \
    || fail "resolved profile was not from-conf: $(grep '"profile"' <<<"$out")"
grep -q '"region": "us-west-2"' <<<"$out" \
    && pass "LAB_AWS_REGION wins over an exported AWS_REGION" \
    || fail "resolved region was not us-west-2: $(grep '"region"' <<<"$out")"

echo
echo "== a conflict is stated, not resolved silently =="

grep -q 'note:.*AWS_PROFILE=from-env.*LAB_AWS_PROFILE=from-conf' <<<"$out" \
    && pass "says which profile it ignored and which it used" \
    || fail "no note about the conflicting AWS_PROFILE"
grep -q 'note:.*AWS_REGION=eu-west-1.*LAB_AWS_REGION=us-west-2' <<<"$out" \
    && pass "says which region it ignored and which it used" \
    || fail "no note about the conflicting AWS_REGION"

# A note that fires when nothing conflicts is noise, and noise gets ignored.
agree="$(PATH="$TMP:$PATH" LAB_CONF="$TMP/workshop.conf" \
         AWS_PROFILE=from-conf AWS_REGION=us-west-2 ./scripts/workshop discover 2>&1)"
grep -q '^note:' <<<"$agree" \
    && fail "warned about a profile the environment agreed with" \
    || pass "silent when the environment and the config agree"

echo
echo "== the environment still applies where the config is silent =="

# A fresh clone has no workshop.conf; discover is how you find out what to put
# in one, so it must honour the profile the operator exported.
fresh="$(PATH="$TMP:$PATH" LAB_CONF="$TMP/absent.conf" \
         AWS_PROFILE=from-env ./scripts/workshop discover 2>&1)"
grep -q '"profile": "from-env"' <<<"$fresh" \
    && pass "no config -> exported AWS_PROFILE is used" \
    || fail "fresh clone ignored the exported profile: $(grep '"profile"' <<<"$fresh")"

echo
echo "== mutating commands name the account before anything moves =="

for sub in init build up down; do
    args=("$sub"); [ "$sub" = up ] && args=(up --students 5 --curriculum intro-agents)
    got="$(run "${args[@]}" | grep -m1 '==> profile')"
    [ "$got" = "==> profile from-conf -> account 111122223333, region us-west-2" ] \
        && pass "$sub announces profile, account and region" \
        || fail "$sub did not announce its target (got: '${got:-nothing}')"
done

# `size` is arithmetic and `discover` is read-only; neither should imply a
# target account, and size must keep working with no credentials at all.
for sub in discover size; do
    args=("$sub"); [ "$sub" = size ] && args=(size --students 10)
    run "${args[@]}" | grep -q '==> profile' \
        && fail "$sub announced a target it does not act on" \
        || pass "$sub does not announce a target"
done

echo
echo "== invalid credentials fail before resources move, not during =="

cat > "$TMP/aws" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  *"sts get-caller-identity"*)
      echo "Error loading SSO Token: Token has expired" >&2; exit 255 ;;
  *) echo "[]" ;;
esac
STUB
chmod +x "$TMP/aws"
bad="$(run down)"
grep -q "error: AWS credentials are not valid for profile 'from-conf'" <<<"$bad" \
    && pass "down stops on an expired token instead of proceeding" \
    || fail "down did not report invalid credentials (got: $(head -2 <<<"$bad" | tr '\n' ' '))"

echo
[ "$fails" -eq 0 ] && echo "ALL CONFIG TESTS PASSED" || echo "$fails CHECK(S) FAILED"
exit "$fails"
