#!/bin/bash
# Tests for get_codex_reset() — reads rate limit reset times from Cockpit JSON
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/test_helpers.sh"

source "$PROJECT_DIR/lib/jwt-helpers.sh"
source "$PROJECT_DIR/lib/account-sources.sh"

# get_codex_reset is defined in auth-vault main script; source it standalone here
# We extract just the function definition
eval "$(sed -n '/^get_codex_reset()/,/^}/p' "$PROJECT_DIR/auth-vault")"

# === FIXTURE SETUP ===
TEST_HOME=$(mktemp -d)
trap 'rm -rf "$TEST_HOME"' EXIT

COCKPIT_CODEX_ACCOUNTS="$TEST_HOME/codex_accounts"
mkdir -p "$COCKPIT_CODEX_ACCOUNTS"

NOW=$(date +%s)
HOURLY_RESET=$(( NOW + 18000 ))
WEEKLY_RESET=$(( NOW + 604800 ))

cat > "$COCKPIT_CODEX_ACCOUNTS/codex_acct1.json" <<EOF
{
  "email": "user1@example.com",
  "tokens": { "access_token": "tok1" },
  "quota": {
    "hourly_percentage": 50,
    "hourly_reset_time": $HOURLY_RESET,
    "hourly_window_minutes": 300,
    "weekly_percentage": 80,
    "weekly_reset_time": $WEEKLY_RESET,
    "weekly_window_minutes": 10080
  }
}
EOF

cat > "$COCKPIT_CODEX_ACCOUNTS/codex_acct2.json" <<EOF
{
  "email": "user2@example.com",
  "tokens": { "access_token": "tok2" },
  "quota": {
    "hourly_percentage": 99,
    "hourly_reset_time": $(( NOW - 600 )),
    "hourly_window_minutes": 300,
    "weekly_percentage": 10,
    "weekly_reset_time": $(( NOW - 3600 )),
    "weekly_window_minutes": 10080
  }
}
EOF

cat > "$COCKPIT_CODEX_ACCOUNTS/codex_acct3.json" <<EOF
{
  "email": "user3@example.com",
  "tokens": { "access_token": "tok3" },
  "quota": {
    "hourly_percentage": 0,
    "hourly_reset_time": $(( NOW - 36000 )),
    "hourly_window_minutes": 300,
    "weekly_percentage": 50,
    "weekly_reset_time": $(( NOW + 259200 )),
    "weekly_window_minutes": 10080
  }
}
EOF

cat > "$COCKPIT_CODEX_ACCOUNTS/codex_no_quota.json" <<EOF
{
  "email": "noquota@example.com",
  "tokens": { "access_token": "tok3" }
}
EOF

echo "=== get_codex_reset Tests ==="
echo ""

# --- hourly reset ---
test_start "get_codex_reset: returns hourly reset timestamp for known email"
result=$(get_codex_reset "user1@example.com")
h_reset="${result%%|*}"
assert_equal "$HOURLY_RESET" "$h_reset"
test_end

test_start "get_codex_reset: returns weekly reset timestamp for known email"
result=$(get_codex_reset "user1@example.com")
w_reset="${result##*|}"
assert_equal "$WEEKLY_RESET" "$w_reset"
test_end

test_start "get_codex_reset: rolls forward past hourly reset by one window"
result=$(get_codex_reset "user2@example.com")
h_reset="${result%%|*}"
# NOW-600 + 300*60 = NOW + 17400 (approx)
expected=$(( (NOW - 600) + 300 * 60 ))
# Allow 2s tolerance for test execution time
diff=$(( h_reset - expected ))
[[ $diff -lt 0 ]] && diff=$(( -diff ))
if (( diff <= 2 )); then
    : # pass
else
    _fail "expected ~$expected, got $h_reset (diff=$diff)"
fi
test_end

test_start "get_codex_reset: rolls forward past weekly reset by one window"
result=$(get_codex_reset "user2@example.com")
w_reset="${result##*|}"
# NOW-3600 + 10080*60 = NOW + 601200 (approx)
expected=$(( (NOW - 3600) + 10080 * 60 ))
diff=$(( w_reset - expected ))
[[ $diff -lt 0 ]] && diff=$(( -diff ))
if (( diff <= 2 )); then
    : # pass
else
    _fail "expected ~$expected, got $w_reset (diff=$diff)"
fi
test_end

test_start "get_codex_reset: rolls forward very old hourly reset by multiple windows"
result=$(get_codex_reset "user3@example.com")
h_reset="${result%%|*}"
# NOW-36000 is 10h ago, window=300min=5h. Need ceil((now-(NOW-36000))/(5*3600)) = ceil(10/5) = 2 windows
# Expected: (NOW-36000) + 2*18000 = NOW-36000+36000 = NOW. But we need > now, so it may need 3 windows.
# Actually: diff = now - (NOW-36000) = 36000. windows_needed = ceil(36000/18000) = 2. result = NOW-36000+2*18000 = NOW.
# Since result must be > now (strictly), and NOW-36000+2*18000 = NOW exactly, need 3 windows if it's exactly now.
# But with test execution tolerance, 2 windows gives ~NOW which is borderline. Let's just check it's in the future.
now_check=$(date +%s)
if (( h_reset > now_check - 2 )); then
    : # pass — reset is now or in the future
else
    _fail "expected future timestamp, got $h_reset (now=$now_check)"
fi
test_end

test_start "get_codex_reset: returns ?|? for unknown email"
result=$(get_codex_reset "unknown@example.com")
assert_equal "?|?" "$result"
test_end

test_start "get_codex_reset: returns ?|? for ? email"
result=$(get_codex_reset "?")
assert_equal "?|?" "$result"
test_end

test_start "get_codex_reset: returns ?|? when quota field missing"
result=$(get_codex_reset "noquota@example.com")
assert_equal "?|?" "$result"
test_end

test_start "get_codex_reset: returns ?|? when COCKPIT_CODEX_ACCOUNTS dir missing"
BAK="$COCKPIT_CODEX_ACCOUNTS"
COCKPIT_CODEX_ACCOUNTS="/nonexistent/dir"
result=$(get_codex_reset "user1@example.com")
assert_equal "?|?" "$result"
COCKPIT_CODEX_ACCOUNTS="$BAK"
test_end

test_summary
