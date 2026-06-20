#!/bin/bash
# Tests for fetch_codex_quota() — live quota + reset query from OpenAI API
# Returns 4-tuple: h_used%|w_used%|h_reset|w_reset
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/test_helpers.sh"

source "$PROJECT_DIR/lib/jwt-helpers.sh"
source "$PROJECT_DIR/lib/ui-helpers.sh"

# fetch_codex_quota is defined in auth-vault; extract it
eval "$(sed -n '/^fetch_codex_quota()/,/^}/p' "$PROJECT_DIR/auth-vault")"

SAVED_PATH="$PATH"

# Helper: mock curl returning full OpenAI wham/usage payload
mock_curl_success() {
    local mock_bin="$1"
    local h_reset="$2"
    local w_reset="$3"
    local h_used="${4:-42}"
    local w_used="${5:-73}"
    cat > "$mock_bin/curl" <<MOCK
#!/bin/bash
echo '{"user_id":"user-123","account_id":"acct-123","email":"test@example.com","plan_type":"plus","rate_limit":{"allowed":true,"limit_reached":false,"primary_window":{"used_percent":${h_used},"limit_window_seconds":18000,"reset_after_seconds":18000,"reset_at":${h_reset}},"secondary_window":{"used_percent":${w_used},"limit_window_seconds":604800,"reset_after_seconds":429532,"reset_at":${w_reset}}},"code_review_rate_limit":null,"credits":{"has_credits":false}}'
exit 0
MOCK
    chmod +x "$mock_bin/curl"
}

echo "=== fetch_codex_quota Tests ==="
echo ""

NOW=$(date +%s)
H_RESET=$(( NOW + 18000 ))
W_RESET=$(( NOW + 604800 ))

# --- Success: returns all four fields from OpenAI response ---
test_start "fetch_codex_quota: returns h_used|w_used|h_reset|w_reset on success"
MOCK_BIN=$(mktemp -d)
mock_curl_success "$MOCK_BIN" "$H_RESET" "$W_RESET" 42 73
PATH="$MOCK_BIN:$SAVED_PATH"
result=$(fetch_codex_quota "fake-token" "acct-123")
PATH="$SAVED_PATH"
rm -rf "$MOCK_BIN"
assert_equal "42|73|${H_RESET}|${W_RESET}" "$result"
test_end

# --- Success with custom used_percent values (boundary: 0 and 100) ---
test_start "fetch_codex_quota: preserves boundary used_percent 0 and 100"
MOCK_BIN=$(mktemp -d)
mock_curl_success "$MOCK_BIN" "$H_RESET" "$W_RESET" 0 100
PATH="$MOCK_BIN:$SAVED_PATH"
result=$(fetch_codex_quota "fake-token" "acct-123")
PATH="$SAVED_PATH"
rm -rf "$MOCK_BIN"
assert_equal "0|100|${H_RESET}|${W_RESET}" "$result"
test_end

# --- Empty token → ?|?|?|? ---
test_start "fetch_codex_quota: returns ?|?|?|? when token is empty"
result=$(fetch_codex_quota "" "")
assert_equal "?|?|?|?" "$result"
test_end

# --- curl failure → ?|?|?|? ---
test_start "fetch_codex_quota: returns ?|?|?|? when curl fails"
MOCK_BIN=$(mktemp -d)
cat > "$MOCK_BIN/curl" <<'MOCK'
#!/bin/bash
echo "curl: (28) Connection timed out" >&2
exit 28
MOCK
chmod +x "$MOCK_BIN/curl"
PATH="$MOCK_BIN:$SAVED_PATH"
result=$(fetch_codex_quota "fake-token" "acct-123")
PATH="$SAVED_PATH"
rm -rf "$MOCK_BIN"
assert_equal "?|?|?|?" "$result"
test_end

# --- Invalid JSON → ?|?|?|? ---
test_start "fetch_codex_quota: returns ?|?|?|? when response is invalid JSON"
MOCK_BIN=$(mktemp -d)
cat > "$MOCK_BIN/curl" <<'MOCK'
#!/bin/bash
echo "not json at all"
exit 0
MOCK
chmod +x "$MOCK_BIN/curl"
PATH="$MOCK_BIN:$SAVED_PATH"
result=$(fetch_codex_quota "fake-token" "acct-123")
PATH="$SAVED_PATH"
rm -rf "$MOCK_BIN"
assert_equal "?|?|?|?" "$result"
test_end

# --- Missing rate_limit → ?|?|?|? ---
test_start "fetch_codex_quota: returns ?|?|?|? when rate_limit missing"
MOCK_BIN=$(mktemp -d)
cat > "$MOCK_BIN/curl" <<'MOCK'
#!/bin/bash
echo '{"user_id":"user-123","email":"test@example.com"}'
exit 0
MOCK
chmod +x "$MOCK_BIN/curl"
PATH="$MOCK_BIN:$SAVED_PATH"
result=$(fetch_codex_quota "fake-token" "acct-123")
PATH="$SAVED_PATH"
rm -rf "$MOCK_BIN"
assert_equal "?|?|?|?" "$result"
test_end

# --- chatgpt-account-id header is passed ---
test_start "fetch_codex_quota: passes chatgpt-account-id header"
MOCK_BIN=$(mktemp -d)
CURL_LOG="$MOCK_BIN/curl_args.log"
cat > "$MOCK_BIN/curl" <<MOCK
#!/bin/bash
echo "\$@" > "$CURL_LOG"
echo '{"rate_limit":{"primary_window":{"used_percent":5,"reset_at":1234567890},"secondary_window":{"used_percent":9,"reset_at":1234567891}}}'
exit 0
MOCK
chmod +x "$MOCK_BIN/curl"
PATH="$MOCK_BIN:$SAVED_PATH"
result=$(fetch_codex_quota "my-token" "my-acct-id")
PATH="$SAVED_PATH"
assert_equal "5|9|1234567890|1234567891" "$result"
if grep -q "my-acct-id" "$CURL_LOG" 2>/dev/null; then
    : # pass
else
    _fail "expected chatgpt-account-id in curl args, got: $(cat "$CURL_LOG" 2>/dev/null)"
fi
rm -rf "$MOCK_BIN"
test_end

test_summary
