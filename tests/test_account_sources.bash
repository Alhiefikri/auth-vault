#!/bin/bash
# Tests for lib/account-sources.sh — account source reader functions
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/test_helpers.sh"

# Source the libraries under test
source "$PROJECT_DIR/lib/jwt-helpers.sh"
source "$PROJECT_DIR/lib/account-sources.sh"

# === FIXTURE SETUP ===
TEST_HOME=$(mktemp -d)
trap 'rm -rf "$TEST_HOME"' EXIT

# Create a valid JWT for fixtures
HEADER="eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCJ9"
FUTURE_EXP=$(( $(date +%s) + 86400 * 30 ))
PAYLOAD=$(echo -n "{\"https://api.openai.com/profile\":{\"email\":\"fixture@example.com\"},\"https://api.openai.com/auth\":{\"chatgpt_plan_type\":\"plus\"},\"exp\":${FUTURE_EXP},\"iat\":1735689600}" | base64 -w0 | tr '/+' '_-' | tr -d '=')
FIXTURE_TOKEN="${HEADER}.${PAYLOAD}.fakesig"
FIXTURE_EXP_MS=$(( FUTURE_EXP * 1000 ))

# === OpenCode fixture ===
OPENCODE_DIR="$TEST_HOME/.local/share/opencode"
mkdir -p "$OPENCODE_DIR"
cat > "$OPENCODE_DIR/auth.json" <<EOF
{
  "openai": {
    "access": "$FIXTURE_TOKEN",
    "refresh": "oc-refresh-token-123",
    "expires": "1767225600000",
    "accountId": "oc-acct-456"
  }
}
EOF

# === Codex fixture ===
CODEX_DIR="$TEST_HOME/.codex"
mkdir -p "$CODEX_DIR"
cat > "$CODEX_DIR/auth.json" <<EOF
{
  "tokens": {
    "access_token": "$FIXTURE_TOKEN",
    "refresh_token": "codex-refresh-789",
    "account_id": "codex-acct-012"
  }
}
EOF

# === Cockpit fixture ===
COCKPIT_DIR="$TEST_HOME/.antigravity_cockpit"
COCKPIT_CODEX_DIR="$COCKPIT_DIR/codex_accounts"
mkdir -p "$COCKPIT_CODEX_DIR"
cat > "$COCKPIT_DIR/provider_current_accounts.json" <<'EOF'
{
  "current_accounts": {
    "codex": "codex_active_id"
  }
}
EOF
cat > "$COCKPIT_CODEX_DIR/codex_active_id.json" <<EOF
{
  "email": "cockpit@example.com",
  "account_id": "cockpit-acct-345",
  "tokens": {
    "access_token": "$FIXTURE_TOKEN",
    "refresh_token": "cockpit-refresh-678"
  }
}
EOF

# Override paths for all readers
OPENCODE_AUTH="$OPENCODE_DIR/auth.json"
CODEX_AUTH="$CODEX_DIR/auth.json"
COCKPIT_CURRENT="$COCKPIT_DIR/provider_current_accounts.json"
COCKPIT_CODEX_ACCOUNTS="$COCKPIT_CODEX_DIR"

# === read_source_opencode ===
test_start "read_source_opencode: sets ACCESS_TOKEN from auth.json"
read_source_opencode
assert_equal "0" "$?"
assert_equal "$FIXTURE_TOKEN" "$ACCESS_TOKEN"
test_end

test_start "read_source_opencode: sets REFRESH_TOKEN"
assert_equal "oc-refresh-token-123" "$REFRESH_TOKEN"
test_end

test_start "read_source_opencode: sets EXPIRES from file"
assert_equal "1767225600000" "$EXPIRES"
test_end

test_start "read_source_opencode: sets ACCOUNT_ID"
assert_equal "oc-acct-456" "$ACCOUNT_ID"
test_end

test_start "read_source_opencode: sets EMAIL from JWT"
assert_equal "fixture@example.com" "$EMAIL"
test_end

test_start "read_source_opencode: sets SOURCE"
assert_equal "OpenCode" "$SOURCE"
test_end

test_start "read_source_opencode: fails when file missing"
OPENCODE_AUTH_BAK="$OPENCODE_AUTH"
OPENCODE_AUTH="/nonexistent/auth.json"
read_source_opencode && status=0 || status=$?
assert_equal "1" "$status"
OPENCODE_AUTH="$OPENCODE_AUTH_BAK"
test_end

test_start "read_source_opencode: fails when openai key is null"
cat > "$OPENCODE_DIR/auth_empty.json" <<'EOF'
{ "openai": null }
EOF
OPENCODE_AUTH_BAK="$OPENCODE_AUTH"
OPENCODE_AUTH="$OPENCODE_DIR/auth_empty.json"
read_source_opencode && status=0 || status=$?
assert_equal "1" "$status"
OPENCODE_AUTH="$OPENCODE_AUTH_BAK"
test_end

# === read_source_codex ===
test_start "read_source_codex: sets ACCESS_TOKEN from auth.json"
read_source_codex
assert_equal "0" "$?"
assert_equal "$FIXTURE_TOKEN" "$ACCESS_TOKEN"
test_end

test_start "read_source_codex: sets REFRESH_TOKEN"
assert_equal "codex-refresh-789" "$REFRESH_TOKEN"
test_end

test_start "read_source_codex: sets EXPIRES from JWT exp_ms"
assert_equal "$FIXTURE_EXP_MS" "$EXPIRES"
test_end

test_start "read_source_codex: sets ACCOUNT_ID"
assert_equal "codex-acct-012" "$ACCOUNT_ID"
test_end

test_start "read_source_codex: sets EMAIL from JWT"
assert_equal "fixture@example.com" "$EMAIL"
test_end

test_start "read_source_codex: sets SOURCE"
assert_equal "Codex CLI" "$SOURCE"
test_end

test_start "read_source_codex: fails when file missing"
CODEX_AUTH_BAK="$CODEX_AUTH"
CODEX_AUTH="/nonexistent/auth.json"
read_source_codex && status=0 || status=$?
assert_equal "1" "$status"
CODEX_AUTH="$CODEX_AUTH_BAK"
test_end

# === read_source_cockpit ===
test_start "read_source_cockpit: sets ACCESS_TOKEN from active account"
read_source_cockpit
assert_equal "0" "$?"
assert_equal "$FIXTURE_TOKEN" "$ACCESS_TOKEN"
test_end

test_start "read_source_cockpit: sets REFRESH_TOKEN"
assert_equal "cockpit-refresh-678" "$REFRESH_TOKEN"
test_end

test_start "read_source_cockpit: sets EXPIRES from JWT exp_ms"
assert_equal "$FIXTURE_EXP_MS" "$EXPIRES"
test_end

test_start "read_source_cockpit: sets ACCOUNT_ID from file"
assert_equal "cockpit-acct-345" "$ACCOUNT_ID"
test_end

test_start "read_source_cockpit: sets EMAIL from file"
assert_equal "cockpit@example.com" "$EMAIL"
test_end

test_start "read_source_cockpit: sets SOURCE"
assert_equal "Cockpit Tools" "$SOURCE"
test_end

test_start "read_source_cockpit: fails when current file missing"
COCKPIT_CURRENT_BAK="$COCKPIT_CURRENT"
COCKPIT_CURRENT="/nonexistent/current.json"
read_source_cockpit && status=0 || status=$?
assert_equal "1" "$status"
COCKPIT_CURRENT="$COCKPIT_CURRENT_BAK"
test_end

test_start "read_source_cockpit: fails when no active codex account"
cat > "$COCKPIT_DIR/provider_current_accounts_empty.json" <<'EOF'
{ "current_accounts": {} }
EOF
COCKPIT_CURRENT_BAK="$COCKPIT_CURRENT"
COCKPIT_CURRENT="$COCKPIT_DIR/provider_current_accounts_empty.json"
read_source_cockpit && status=0 || status=$?
assert_equal "1" "$status"
COCKPIT_CURRENT="$COCKPIT_CURRENT_BAK"
test_end

test_summary
