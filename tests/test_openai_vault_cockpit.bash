#!/bin/bash
# Tests for openai_vault_get_cockpit_active() — match OpenAI vault account
# against the currently active Cockpit Tools Codex account.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/test_helpers.sh"

TEST_HOME="$(mktemp -d)"
export HOME="$TEST_HOME"
trap 'rm -rf "$TEST_HOME"' EXIT

OPENAI_VAULT_DIR="$HOME/.auth-vault/openai"
COCKPIT_CURRENT="$HOME/.antigravity_cockpit/provider_current_accounts.json"
COCKPIT_CODEX_ACCOUNTS="$HOME/.antigravity_cockpit/codex_accounts"
export OPENAI_VAULT_DIR COCKPIT_CURRENT COCKPIT_CODEX_ACCOUNTS

source "$PROJECT_DIR/lib/jwt-helpers.sh"
source "$PROJECT_DIR/lib/openai-auth.sh"

# === JWT fixture (expires 30 days from now) ===
HEADER="eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCJ9"
FUTURE_EXP=$(( $(date +%s) + 86400 * 30 ))
PAYLOAD=$(echo -n "{\"https://api.openai.com/profile\":{\"email\":\"cockpit@example.com\"},\"https://api.openai.com/auth\":{\"chatgpt_plan_type\":\"plus\"},\"exp\":${FUTURE_EXP},\"iat\":1735689600}" | base64 -w0 | tr '/+' '_-' | tr -d '=')
FIXTURE_TOKEN="${HEADER}.${PAYLOAD}.fakesig"

# ---- helpers ----

setup_cockpit_only() {
    local email="$1" acct_id="${2:-codex_active_001}"
    mkdir -p "$COCKPIT_CODEX_ACCOUNTS"
    cat > "$COCKPIT_CURRENT" <<EOF
{
  "current_accounts": {
    "codex": "$acct_id"
  }
}
EOF
    cat > "$COCKPIT_CODEX_ACCOUNTS/${acct_id}.json" <<EOF
{
  "email": "$email",
  "account_id": "acct-123",
  "tokens": {
    "access_token": "$FIXTURE_TOKEN",
    "refresh_token": "cockpit-refresh"
  }
}
EOF
}

setup_vault_and_cockpit() {
    local vault_email="$1"
    local vault_name="${2:-akun-cockpit}"

    mkdir -p "$OPENAI_VAULT_DIR"
    openai_vault_save "$vault_name" "$vault_email" "$FIXTURE_TOKEN" "refresh-xyz" "acct-123"
    setup_cockpit_only "$vault_email"
}

# === openai_vault_get_cockpit_active ===

test_start "returns vault name when cockpit account matches vault email"
setup_vault_and_cockpit "cockpit@example.com" "akun-cockpit"
result=$(openai_vault_get_cockpit_active)
assert_equal "akun-cockpit" "$result"
test_end

test_start "returns empty when no vault account matches cockpit email"
rm -rf "$OPENAI_VAULT_DIR" "$HOME/.antigravity_cockpit"
openai_vault_save "akun-lain" "other@example.com" "$FIXTURE_TOKEN" "ref" "id"
setup_cockpit_only "cockpit@example.com"
rc=0; result=$(openai_vault_get_cockpit_active) || rc=$?
assert_equal "" "$result"
assert_equal "1" "$rc"
test_end

test_start "returns empty when cockpit current_accounts.json missing"
rm -rf "$HOME/.antigravity_cockpit"
mkdir -p "$OPENAI_VAULT_DIR"
openai_vault_save "my-acct" "me@test.com" "$FIXTURE_TOKEN" "ref" "id"
rc=0; result=$(openai_vault_get_cockpit_active) || rc=$?
assert_equal "" "$result"
assert_equal "1" "$rc"
test_end

test_start "returns empty when cockpit has no codex current account"
rm -rf "$HOME/.antigravity_cockpit"
mkdir -p "$COCKPIT_CODEX_ACCOUNTS"
cat > "$COCKPIT_CURRENT" <<'EOF'
{ "current_accounts": {} }
EOF
rc=0; result=$(openai_vault_get_cockpit_active) || rc=$?
assert_equal "" "$result"
assert_equal "1" "$rc"
test_end

test_start "returns empty when cockpit codex account file missing"
rm -rf "$HOME/.antigravity_cockpit"
mkdir -p "$COCKPIT_CODEX_ACCOUNTS"
cat > "$COCKPIT_CURRENT" <<'EOF'
{
  "current_accounts": {
    "codex": "nonexistent_id"
  }
}
EOF
rc=0; result=$(openai_vault_get_cockpit_active) || rc=$?
assert_equal "" "$result"
assert_equal "1" "$rc"
test_end

test_start "matches correct vault among multiple accounts"
rm -rf "$OPENAI_VAULT_DIR" "$HOME/.antigravity_cockpit"
openai_vault_save "akun-satu" "satu@test.com" "$FIXTURE_TOKEN" "ref1" "id1"
openai_vault_save "akun-dua" "dua@test.com" "$FIXTURE_TOKEN" "ref2" "id2"
openai_vault_save "akun-tiga" "cockpit@example.com" "$FIXTURE_TOKEN" "ref3" "id3"
setup_cockpit_only "cockpit@example.com"
result=$(openai_vault_get_cockpit_active)
assert_equal "akun-tiga" "$result"
test_end

test_summary
