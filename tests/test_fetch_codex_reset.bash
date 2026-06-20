#!/bin/bash
# Tests for fetch_codex_reset() — live rate limit query from OpenAI API
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/test_helpers.sh"

source "$PROJECT_DIR/lib/jwt-helpers.sh"
source "$PROJECT_DIR/lib/ui-helpers.sh"

# fetch_codex_reset is defined in auth-vault; extract it
eval "$(sed -n '/^fetch_codex_reset()/,/^}/p' "$PROJECT_DIR/auth-vault")"

SAVED_PATH="$PATH"

# Helper: create a mock curl that returns a fixed JSON body
mock_curl_success() {
    local mock_bin="$1"
    local h_reset="$2"
    local w_reset="$3"
    local h_used="${4:-10}"
    local w_used="${5:-34}"
    cat > "$mock_bin/curl" <<MOCK
#!/bin/bash
echo '{"user_id":"user-123","account_id":"user-123","email":"test@example.com","plan_type":"plus","rate_limit":{"allowed":true,"limit_reached":false,"primary_window":{"used_percent":${h_used},"limit_window_seconds":18000,"reset_after_seconds":18000,"reset_at":${h_reset}},"secondary_window":{"used_percent":${w_used},"limit_window_seconds":604800,"reset_after_seconds":429532,"reset_at":${w_reset}}},"code_review_rate_limit":null,"additional_rate_limits":null,"credits":{"has_credits":false,"unlimited":false,"overage_limit_reached":false,"balance":"0","approx_local_messages":[0,0],"approx_cloud_messages":[0,0]},"spend_control":{"reached":false,"individual_limit":null},"rate_limit_reached_type":null,"promo":null,"referral_beacon":null,"rate_limit_reset_credits":{"available_count":2}}'
exit 0
MOCK
    chmod +x "$mock_bin/curl"
}

echo "=== fetch_codex_reset Tests ==="
echo ""

# --- Success cases ---
NOW=$(date +%s)
H_RESET=$(( NOW + 18000 ))
W_RESET=$(( NOW + 604800 ))

test_start "fetch_codex_reset: returns h_reset|w_reset on success"
MOCK_BIN=$(mktemp -d)
mock_curl_success "$MOCK_BIN" "$H_RESET" "$W_RESET"
PATH="$MOCK_BIN:$SAVED_PATH"
result=$(fetch_codex_reset "fake-token" "acct-123")
PATH="$SAVED_PATH"
rm -rf "$MOCK_BIN"
h="${result%%|*}"
w="${result##*|}"
assert_equal "$H_RESET" "$h"
assert_equal "$W_RESET" "$w"
test_end

test_start "fetch_codex_reset: returns ?|? when token is empty"
result=$(fetch_codex_reset "" "")
assert_equal "?|?" "$result"
test_end

test_start "fetch_codex_reset: returns ?|? when curl fails"
MOCK_BIN=$(mktemp -d)
cat > "$MOCK_BIN/curl" <<'MOCK'
#!/bin/bash
echo "curl: (28) Connection timed out" >&2
exit 28
MOCK
chmod +x "$MOCK_BIN/curl"
PATH="$MOCK_BIN:$SAVED_PATH"
result=$(fetch_codex_reset "fake-token" "acct-123")
PATH="$SAVED_PATH"
rm -rf "$MOCK_BIN"
assert_equal "?|?" "$result"
test_end

test_start "fetch_codex_reset: returns ?|? when response is invalid JSON"
MOCK_BIN=$(mktemp -d)
cat > "$MOCK_BIN/curl" <<'MOCK'
#!/bin/bash
echo "not json at all"
exit 0
MOCK
chmod +x "$MOCK_BIN/curl"
PATH="$MOCK_BIN:$SAVED_PATH"
result=$(fetch_codex_reset "fake-token" "acct-123")
PATH="$SAVED_PATH"
rm -rf "$MOCK_BIN"
assert_equal "?|?" "$result"
test_end

test_start "fetch_codex_reset: returns ?|? when rate_limit missing"
MOCK_BIN=$(mktemp -d)
cat > "$MOCK_BIN/curl" <<'MOCK'
#!/bin/bash
echo '{"user_id":"user-123","email":"test@example.com"}'
exit 0
MOCK
chmod +x "$MOCK_BIN/curl"
PATH="$MOCK_BIN:$SAVED_PATH"
result=$(fetch_codex_reset "fake-token" "acct-123")
PATH="$SAVED_PATH"
rm -rf "$MOCK_BIN"
assert_equal "?|?" "$result"
test_end

test_start "fetch_codex_reset: passes chatgpt-account-id header"
MOCK_BIN=$(mktemp -d)
CURL_LOG="$MOCK_BIN/curl_args.log"
cat > "$MOCK_BIN/curl" <<MOCK
#!/bin/bash
echo "\$@" > "$CURL_LOG"
echo '{"rate_limit":{"primary_window":{"reset_at":1234567890},"secondary_window":{"reset_at":1234567890}}}'
exit 0
MOCK
chmod +x "$MOCK_BIN/curl"
PATH="$MOCK_BIN:$SAVED_PATH"
result=$(fetch_codex_reset "my-token" "my-acct-id")
PATH="$SAVED_PATH"
assert_equal "1234567890|1234567890" "$result"
if grep -q "my-acct-id" "$CURL_LOG" 2>/dev/null; then
    : # pass — account-id header was passed
else
    _fail "expected chatgpt-account-id in curl args, got: $(cat "$CURL_LOG" 2>/dev/null)"
fi
rm -rf "$MOCK_BIN"
test_end

test_summary
