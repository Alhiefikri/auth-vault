#!/bin/bash
# Tests for fetch_codex_quota_cached() — TTL-aware cache wrapper
# Returns same 4-tuple as fetch_codex_quota: h_used%|w_used%|h_reset|w_reset
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/test_helpers.sh"

source "$PROJECT_DIR/lib/jwt-helpers.sh"
source "$PROJECT_DIR/lib/ui-helpers.sh"

# Extract both functions (cached depends on uncached)
eval "$(sed -n '/^fetch_codex_quota()/,/^}/p' "$PROJECT_DIR/auth-vault")"
eval "$(sed -n '/^fetch_codex_quota_cached()/,/^}/p' "$PROJECT_DIR/auth-vault")"

SAVED_PATH="$PATH"

# Per-test sandbox: isolated CACHE_DIR, counter file, short TTL
setup_sandbox() {
    SANDBOX=$(mktemp -d)
    export AUTH_VAULT_CACHE_DIR="$SANDBOX/cache"
    mkdir -p "$AUTH_VAULT_CACHE_DIR"
    CURL_LOG="$SANDBOX/curl_calls"
    : > "$CURL_LOG"
    # Override TTL via env (function reads AUTH_VAULT_QUOTA_TTL, default 60)
    export AUTH_VAULT_QUOTA_TTL=2
}

teardown_sandbox() {
    PATH="$SAVED_PATH"
    rm -rf "$SANDBOX"
    unset AUTH_VAULT_CACHE_DIR AUTH_VAULT_QUOTA_TTL
}

# Mock curl: logs each invocation to $CURL_LOG, returns canned response
install_mock_curl() {
    local h_used="${1:-42}" w_used="${2:-73}" h_reset="${3:-1700000000}" w_reset="${4:-1700604800}"
    local mock_bin="$SANDBOX/bin"
    mkdir -p "$mock_bin"
    cat > "$mock_bin/curl" <<MOCK
#!/bin/bash
echo "\$@" >> "$CURL_LOG"
echo '{"rate_limit":{"primary_window":{"used_percent":${h_used},"reset_at":${h_reset}},"secondary_window":{"used_percent":${w_used},"reset_at":${w_reset}}}}'
exit 0
MOCK
    chmod +x "$mock_bin/curl"
    PATH="$mock_bin:$SAVED_PATH"
}

install_mock_curl_failing() {
    local mock_bin="$SANDBOX/bin"
    mkdir -p "$mock_bin"
    cat > "$mock_bin/curl" <<'MOCK'
#!/bin/bash
echo "curl: (28) timed out" >&2
exit 28
MOCK
    chmod +x "$mock_bin/curl"
    PATH="$mock_bin:$SAVED_PATH"
}

curl_call_count() {
    if [[ -s "$CURL_LOG" ]]; then wc -l < "$CURL_LOG" | tr -d ' '; else echo 0; fi
}

echo "=== fetch_codex_quota_cached Tests ==="
echo ""

# --- 1. Cache miss: fetches + writes cache ---
test_start "cache miss: fetches from API and writes cache file"
setup_sandbox
install_mock_curl 42 73
result=$(fetch_codex_quota_cached "tok-A" "acct-A")
calls=$(curl_call_count)
teardown_sandbox
assert_equal "42|73|1700000000|1700604800" "$result"
assert_equal "1" "$calls"
test_end

# --- 2. Cache hit: returns cached data without curl ---
test_start "cache hit (fresh): returns cached value, no curl call"
setup_sandbox
install_mock_curl 42 73
# Prime the cache
_=$(fetch_codex_quota_cached "tok-A" "acct-A")
# Install a different mock (different values) — should NOT be used
install_mock_curl 99 99 1 2
result=$(fetch_codex_quota_cached "tok-A" "acct-A")
calls=$(curl_call_count)
teardown_sandbox
assert_equal "42|73|1700000000|1700604800" "$result"
assert_equal "1" "$calls"
test_end

# --- 3. Cache stale: re-fetches ---
test_start "cache stale (TTL expired): re-fetches from API"
setup_sandbox
install_mock_curl 42 73
# Prime
_=$(fetch_codex_quota_cached "tok-A" "acct-A")
# Force mtime to 10 seconds ago (older than TTL=2)
cache_file=$(ls "$AUTH_VAULT_CACHE_DIR"/quota_*.json 2>/dev/null | head -1)
touch -d "10 seconds ago" "$cache_file"
# Install new mock with different values
install_mock_curl 55 66 1700000100 1700604900
result=$(fetch_codex_quota_cached "tok-A" "acct-A")
calls=$(curl_call_count)
teardown_sandbox
assert_equal "55|66|1700000100|1700604900" "$result"
assert_equal "2" "$calls"
test_end

# --- 4. Cache corrupt: re-fetches ---
test_start "cache corrupt JSON: treats as miss, re-fetches"
setup_sandbox
# Pre-write corrupt cache file with correct key
key=$(printf '%s' "tok-A|acct-A" | md5sum | cut -d' ' -f1)
mkdir -p "$AUTH_VAULT_CACHE_DIR"
echo "not valid json {{{" > "$AUTH_VAULT_CACHE_DIR/quota_${key}.json"
install_mock_curl 42 73
result=$(fetch_codex_quota_cached "tok-A" "acct-A")
calls=$(curl_call_count)
teardown_sandbox
assert_equal "42|73|1700000000|1700604800" "$result"
assert_equal "1" "$calls"
test_end

# --- 5. API fail + stale cache: graceful degradation ---
test_start "API fail + stale cache available: returns stale cache"
setup_sandbox
install_mock_curl 42 73
# Prime
_=$(fetch_codex_quota_cached "tok-A" "acct-A")
# Stale it
cache_file=$(ls "$AUTH_VAULT_CACHE_DIR"/quota_*.json 2>/dev/null | head -1)
touch -d "10 seconds ago" "$cache_file"
# Now curl fails
install_mock_curl_failing
result=$(fetch_codex_quota_cached "tok-A" "acct-A")
teardown_sandbox
assert_equal "42|73|1700000000|1700604800" "$result"
test_end

# --- 6. API fail + no cache: returns ?|?|?|? ---
test_start "API fail + no cache: returns ?|?|?|?"
setup_sandbox
install_mock_curl_failing
result=$(fetch_codex_quota_cached "tok-A" "acct-A")
teardown_sandbox
assert_equal "?|?|?|?" "$result"
test_end

# --- 7. Empty token + no cache: returns ?|?|?|? ---
test_start "empty token + no cache: returns ?|?|?|?"
setup_sandbox
result=$(fetch_codex_quota_cached "" "")
teardown_sandbox
assert_equal "?|?|?|?" "$result"
test_end

# --- 8. Different accounts produce separate cache files ---
test_start "separate cache entries per (token, account_id) pair"
setup_sandbox
install_mock_curl 10 20
_=$(fetch_codex_quota_cached "tok-A" "acct-A")
install_mock_curl 80 90
_=$(fetch_codex_quota_cached "tok-B" "acct-B")
count=$(ls "$AUTH_VAULT_CACHE_DIR"/quota_*.json 2>/dev/null | wc -l)
teardown_sandbox
assert_equal "2" "$count"
test_end

test_summary
