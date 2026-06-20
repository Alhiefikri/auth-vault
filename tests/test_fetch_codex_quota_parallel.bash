#!/bin/bash
# Tests for fetch_codex_quota_parallel() — parallelizes N fetch_codex_quota_cached calls
# Interface: fetch_codex_quota_parallel OUTFILE TOKEN1 ACCT1 TOKEN2 ACCT2 ...
# Writes one 4-tuple per line, preserving input order.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/test_helpers.sh"

source "$PROJECT_DIR/lib/jwt-helpers.sh"
source "$PROJECT_DIR/lib/ui-helpers.sh"

eval "$(sed -n '/^fetch_codex_quota()/,/^}/p' "$PROJECT_DIR/auth-vault")"
eval "$(sed -n '/^fetch_codex_quota_cached()/,/^}/p' "$PROJECT_DIR/auth-vault")"
eval "$(sed -n '/^fetch_codex_quota_parallel()/,/^}/p' "$PROJECT_DIR/auth-vault")"

SAVED_PATH="$PATH"

echo "=== fetch_codex_quota_parallel Tests ==="
echo ""

# Shared setup: one sandbox, one dispatcher mock curl, installed ONCE.
# The dispatcher reads $BODIES (path in env) keyed by bearer token.
# BODIES file format: token|<json>
setup() {
    SANDBOX=$(mktemp -d)
    export AUTH_VAULT_CACHE_DIR="$SANDBOX/cache"
    mkdir -p "$AUTH_VAULT_CACHE_DIR"
    export AUTH_VAULT_QUOTA_TTL=0
    export BODIES="$SANDBOX/bodies"
    : > "$BODIES"
    MOCK_BIN="$SANDBOX/bin"
    mkdir -p "$MOCK_BIN"
    cat > "$MOCK_BIN/curl" <<'MOCK'
#!/bin/bash
# Parse bearer token from -H "Authorization: Bearer <tok>"
tok=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        -H) shift; [[ "$1" == "Authorization: Bearer "* ]] && tok="${1#Authorization: Bearer }" ;;
    esac
    shift 2>/dev/null || shift || true
done
# Optional latency from $CURL_SLEEP (seconds, default 0)
[[ -n "${CURL_SLEEP:-}" ]] && sleep "$CURL_SLEEP"
# Lookup body
body=""
if [[ -n "$tok" && -f "$BODIES" ]]; then
    body=$(grep -F -m1 "${tok}|" "$BODIES" | cut -d'|' -f2-)
fi
# Optional fail mode: if $FAIL_TOKENS contains this token, exit 28
if [[ -n "${FAIL_TOKENS:-}" && " $FAIL_TOKENS " == *" $tok "* ]]; then
    echo "curl: (28) timeout" >&2
    exit 28
fi
if [[ -z "$body" ]]; then
    echo '{"rate_limit":{"primary_window":{"used_percent":0,"reset_at":1},"secondary_window":{"used_percent":0,"reset_at":1}}}'
else
    echo "$body"
fi
exit 0
MOCK
    chmod +x "$MOCK_BIN/curl"
    PATH="$MOCK_BIN:$SAVED_PATH"
    export PATH
}

teardown() {
    PATH="$SAVED_PATH"
    rm -rf "$SANDBOX"
    unset AUTH_VAULT_CACHE_DIR AUTH_VAULT_QUOTA_TTL BODIES FAIL_TOKENS CURL_SLEEP
}

# --- 1. Parallel timing: 4 accounts × 0.2s sleep should complete < 0.5s ---
test_start "parallel: 4 accounts with 0.2s latency complete in < 0.5s"
setup
cat >> "$BODIES" <<'EOF'
t1|{"rate_limit":{"primary_window":{"used_percent":10,"reset_at":1000},"secondary_window":{"used_percent":20,"reset_at":2000}}}
t2|{"rate_limit":{"primary_window":{"used_percent":30,"reset_at":3000},"secondary_window":{"used_percent":40,"reset_at":4000}}}
t3|{"rate_limit":{"primary_window":{"used_percent":50,"reset_at":5000},"secondary_window":{"used_percent":60,"reset_at":6000}}}
t4|{"rate_limit":{"primary_window":{"used_percent":70,"reset_at":7000},"secondary_window":{"used_percent":80,"reset_at":8000}}}
EOF
export CURL_SLEEP=0.2
OUTFILE="$SANDBOX/out"
start_ns=$(date +%s%N)
fetch_codex_quota_parallel "$OUTFILE" "t1" "a1" "t2" "a2" "t3" "a3" "t4" "a4"
end_ns=$(date +%s%N)
elapsed_ms=$(( (end_ns - start_ns) / 1000000 ))
teardown
# Parallel should be ~200ms; sequential would be ~800ms. Threshold: 600ms.
if (( elapsed_ms < 600 )); then
    :
else
    _fail "expected < 600ms, got ${elapsed_ms}ms (likely not parallel)"
fi
test_end

# --- 2. Order preserved: output line i corresponds to input pair i ---
test_start "parallel: output lines preserve input order"
setup
cat >> "$BODIES" <<'EOF'
t1|{"rate_limit":{"primary_window":{"used_percent":11,"reset_at":1001},"secondary_window":{"used_percent":21,"reset_at":2001}}}
t2|{"rate_limit":{"primary_window":{"used_percent":33,"reset_at":3003},"secondary_window":{"used_percent":44,"reset_at":4004}}}
t3|{"rate_limit":{"primary_window":{"used_percent":55,"reset_at":5005},"secondary_window":{"used_percent":66,"reset_at":6006}}}
EOF
OUTFILE="$SANDBOX/out"
fetch_codex_quota_parallel "$OUTFILE" "t1" "a1" "t2" "a2" "t3" "a3"
line_count=$(wc -l < "$OUTFILE" | tr -d ' ')
line1=$(sed -n '1p' "$OUTFILE")
line2=$(sed -n '2p' "$OUTFILE")
line3=$(sed -n '3p' "$OUTFILE")
teardown
assert_equal "3" "$line_count"
assert_equal "11|21|1001|2001" "$line1"
assert_equal "33|44|3003|4004" "$line2"
assert_equal "55|66|5005|6006" "$line3"
test_end

# --- 3. Empty input: no output, no error ---
test_start "parallel: no accounts produces empty output file"
setup
OUTFILE="$SANDBOX/out"
fetch_codex_quota_parallel "$OUTFILE"
count=$(wc -l < "$OUTFILE" 2>/dev/null | tr -d ' ' || echo 0)
teardown
assert_equal "0" "$count"
test_end

# --- 4. Mixed failures: per-account fail yields ?|?|?|? for that slot ---
test_start "parallel: per-account API failure yields ?|?|?|? for that slot"
setup
cat >> "$BODIES" <<'EOF'
t1|{"rate_limit":{"primary_window":{"used_percent":10,"reset_at":100},"secondary_window":{"used_percent":20,"reset_at":200}}}
t3|{"rate_limit":{"primary_window":{"used_percent":70,"reset_at":700},"secondary_window":{"used_percent":80,"reset_at":800}}}
EOF
export FAIL_TOKENS="t2"
OUTFILE="$SANDBOX/out"
fetch_codex_quota_parallel "$OUTFILE" "t1" "a1" "t2" "a2" "t3" "a3"
line1=$(sed -n '1p' "$OUTFILE")
line2=$(sed -n '2p' "$OUTFILE")
line3=$(sed -n '3p' "$OUTFILE")
teardown
assert_equal "10|20|100|200" "$line1"
assert_equal "?|?|?|?" "$line2"
assert_equal "70|80|700|800" "$line3"
test_end

test_summary
