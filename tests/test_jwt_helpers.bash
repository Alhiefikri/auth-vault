#!/bin/bash
# Tests for lib/jwt-helpers.sh — JWT decoding and claim extraction
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/test_helpers.sh"

# Source the library under test
source "$PROJECT_DIR/lib/jwt-helpers.sh"

# === FIXTURES ===
HEADER="eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCJ9"

# Valid token: email=test@example.com, plan=plus, exp=30 days from now
FUTURE_EXP=$(( $(date +%s) + 86400 * 30 ))
VALID_PAYLOAD=$(echo -n "{\"https://api.openai.com/profile\":{\"email\":\"test@example.com\"},\"https://api.openai.com/auth\":{\"chatgpt_plan_type\":\"plus\"},\"exp\":${FUTURE_EXP},\"iat\":1735689600}" | base64 -w0 | tr '/+' '_-' | tr -d '=')
VALID_TOKEN="${HEADER}.${VALID_PAYLOAD}.fakesig"

# Expired token: email=expired@example.com, plan=free, exp=2024-01-01
EXPIRED_PAYLOAD=$(echo -n '{"https://api.openai.com/profile":{"email":"expired@example.com"},"https://api.openai.com/auth":{"chatgpt_plan_type":"free"},"exp":1704067200,"iat":1672531200}' | base64 -w0 | tr '/+' '_-' | tr -d '=')
EXPIRED_TOKEN="${HEADER}.${EXPIRED_PAYLOAD}.fakesig"

# Minimal token: only exp claim, no email or plan
MINIMAL_PAYLOAD=$(echo -n "{\"exp\":${FUTURE_EXP}}" | base64 -w0 | tr '/+' '_-' | tr -d '=')
MINIMAL_TOKEN="${HEADER}.${MINIMAL_PAYLOAD}.fakesig"

MALFORMED_TOKEN="not-a-jwt"
EMPTY_TOKEN=""

# === jwt_decode ===
test_start "jwt_decode: decodes payload from valid token"
run jwt_decode "$VALID_TOKEN"
assert_success
assert_output_contains "test@example.com"
assert_output_contains "chatgpt_plan_type"
test_end

test_start "jwt_decode: handles malformed token gracefully"
run jwt_decode "$MALFORMED_TOKEN"
assert_success
test_end

test_start "jwt_decode: handles empty token gracefully"
run jwt_decode "$EMPTY_TOKEN"
assert_success
test_end

# === jwt_claim ===
test_start "jwt_claim: extracts arbitrary claim by key"
run jwt_claim "$VALID_TOKEN" '"https://api.openai.com/profile".email'
assert_success
assert_output_contains "test@example.com"
test_end

test_start "jwt_claim: returns ? for missing claim"
run jwt_claim "$VALID_TOKEN" '.nonexistent'
assert_success
assert_output_contains "?"
test_end

# === jwt_email ===
test_start "jwt_email: returns correct email from valid token"
run jwt_email "$VALID_TOKEN"
assert_success
assert_equal "test@example.com" "$_RUN_OUTPUT"
test_end

test_start "jwt_email: returns ? for token without email"
run jwt_email "$MINIMAL_TOKEN"
assert_success
assert_equal "?" "$_RUN_OUTPUT"
test_end

test_start "jwt_email: returns ? for malformed token"
run jwt_email "$MALFORMED_TOKEN"
assert_success
assert_equal "?" "$_RUN_OUTPUT"
test_end

test_start "jwt_email: returns ? for empty token"
run jwt_email "$EMPTY_TOKEN"
assert_success
assert_equal "?" "$_RUN_OUTPUT"
test_end

# === jwt_plan ===
test_start "jwt_plan: returns correct plan from valid token"
run jwt_plan "$VALID_TOKEN"
assert_success
assert_equal "plus" "$_RUN_OUTPUT"
test_end

test_start "jwt_plan: returns ? for token without plan"
run jwt_plan "$MINIMAL_TOKEN"
assert_success
assert_equal "?" "$_RUN_OUTPUT"
test_end

test_start "jwt_plan: returns ? for malformed token"
run jwt_plan "$MALFORMED_TOKEN"
assert_success
assert_equal "?" "$_RUN_OUTPUT"
test_end

# === jwt_exp_days ===
test_start "jwt_exp_days: returns Xd for valid future token"
run jwt_exp_days "$VALID_TOKEN"
assert_success
# Should be ~30d (29d or 30d depending on timing)
if [[ "$_RUN_OUTPUT" =~ ^[0-9]+d$ ]]; then
    days="${_RUN_OUTPUT%d}"
    if [[ "$days" -ge 29 && "$days" -le 31 ]]; then
        : # pass
    else
        printf '  \033[0;31m✗\033[0m %s\n' "jwt_exp_days: expected ~30d, got ${_RUN_OUTPUT}"
        _TEST_FAILED=true
        _TEST_FAIL=$(( _TEST_FAIL + 1 ))
    fi
else
    printf '  \033[0;31m✗\033[0m %s\n' "jwt_exp_days: expected Xd format, got ${_RUN_OUTPUT}"
    _TEST_FAILED=true
    _TEST_FAIL=$(( _TEST_FAIL + 1 ))
fi
test_end

test_start "jwt_exp_days: returns 'expired' for expired token"
run jwt_exp_days "$EXPIRED_TOKEN"
assert_success
assert_equal "expired" "$_RUN_OUTPUT"
test_end

test_start "jwt_exp_days: returns 'expired' for malformed token"
run jwt_exp_days "$MALFORMED_TOKEN"
assert_success
# Malformed should not crash; returns "expired" since exp defaults to 0
assert_equal "expired" "$_RUN_OUTPUT"
test_end

# === jwt_exp_ms ===
test_start "jwt_exp_ms: returns correct milliseconds for valid token"
run jwt_exp_ms "$VALID_TOKEN"
assert_success
expected_ms=$(( FUTURE_EXP * 1000 ))
assert_equal "$expected_ms" "$_RUN_OUTPUT"
test_end

test_start "jwt_exp_ms: returns milliseconds for expired token"
run jwt_exp_ms "$EXPIRED_TOKEN"
assert_success
assert_equal "1704067200000" "$_RUN_OUTPUT"
test_end

test_start "jwt_exp_ms: returns 0 for malformed token"
run jwt_exp_ms "$MALFORMED_TOKEN"
assert_success
assert_equal "0" "$_RUN_OUTPUT"
test_end

# === jwt_info ===
test_start "jwt_info: returns 'email|plan|Xd' for valid token"
run jwt_info "$VALID_TOKEN"
assert_success
# Should be pipe-delimited: test@example.com|plus|30d (approximately)
if [[ "$_RUN_OUTPUT" == test@example.com\|plus\|*d ]]; then
    : # pass
else
    printf '  \033[0;31m✗\033[0m %s\n' "jwt_info: expected 'test@example.com|plus|Xd', got '${_RUN_OUTPUT}'"
    _TEST_FAILED=true
    _TEST_FAIL=$(( _TEST_FAIL + 1 ))
fi
test_end

test_start "jwt_info: returns 'email|plan|expired' for expired token"
run jwt_info "$EXPIRED_TOKEN"
assert_success
assert_equal "expired@example.com|free|expired" "$_RUN_OUTPUT"
test_end

test_start "jwt_info: returns '???|???|???' for empty token"
run jwt_info "$EMPTY_TOKEN"
assert_success
assert_equal "???|???|???" "$_RUN_OUTPUT"
test_end

test_start "jwt_info: returns '???|???|???' for malformed token"
run jwt_info "$MALFORMED_TOKEN"
assert_success
assert_equal "???|???|???" "$_RUN_OUTPUT"
test_end

test_summary
