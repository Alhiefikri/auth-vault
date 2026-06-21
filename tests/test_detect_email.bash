#!/bin/bash
# Tests for lib/detect-email.sh — _detect_email shared helper
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/test_helpers.sh"

VAULT_DIR=$(mktemp -d)
QODER_AUTH="$VAULT_DIR/auth-user"
SAVED_HOME="$HOME"
trap 'rm -rf "$VAULT_DIR"; export HOME="$SAVED_HOME"' EXIT

source "$PROJECT_DIR/lib/detect-email.sh"

SAVED_PATH="$PATH"

# === _detect_email: qodercli status takes priority ===

test_start "_detect_email: returns email from qodercli status"
MOCK_BIN=$(mktemp -d)
printf '#!/bin/bash\necho "Version: 1.0.11"\necho "Username: Test User"\necho "Email: realuser@gmail.com"\necho "Avatar: https://example.com/avatar"\n' > "$MOCK_BIN/qodercli"
chmod +x "$MOCK_BIN/qodercli"
PATH="$MOCK_BIN:$SAVED_PATH"
email=$(_detect_email)
assert_equal "realuser@gmail.com" "$email"
PATH="$SAVED_PATH"
rm -rf "$MOCK_BIN"
test_end

test_start "_detect_email: parses email with dots and subdomains"
MOCK_BIN=$(mktemp -d)
printf '#!/bin/bash\necho "Email: test.user14@admin.example.test"\n' > "$MOCK_BIN/qodercli"
chmod +x "$MOCK_BIN/qodercli"
PATH="$MOCK_BIN:$SAVED_PATH"
email=$(_detect_email)
assert_equal "test.user14@admin.example.test" "$email"
PATH="$SAVED_PATH"
rm -rf "$MOCK_BIN"
test_end

# === _detect_email: fallback to cockpit when qodercli unavailable ===

test_start "_detect_email: falls back to cockpit when qodercli not found"
export HOME="$VAULT_DIR"
mkdir -p "$VAULT_DIR/.antigravity_cockpit/qoder_accounts"
echo '{"current_accounts":{"qoder":"qid-123"}}' > "$VAULT_DIR/.antigravity_cockpit/provider_current_accounts.json"
echo '{"email":"cockpit-user@example.com"}' > "$VAULT_DIR/.antigravity_cockpit/qoder_accounts/qid-123.json"
COCKPIT_QODER_ACCOUNTS="$VAULT_DIR/.antigravity_cockpit/qoder_accounts"
MOCK_BIN=$(mktemp -d)
ln -s "$(command -v jq)" "$MOCK_BIN/jq"
ln -s "$(command -v cat)" "$MOCK_BIN/cat"
PATH="$MOCK_BIN"
email=$(_detect_email)
PATH="$SAVED_PATH"
assert_equal "cockpit-user@example.com" "$email"
rm -rf "$MOCK_BIN"
export HOME="$SAVED_HOME"
test_end

test_start "_detect_email: returns unknown when no source available"
export HOME="$VAULT_DIR"
rm -rf "$VAULT_DIR/.antigravity_cockpit"
COCKPIT_QODER_ACCOUNTS="$VAULT_DIR/.antigravity_cockpit/qoder_accounts"
MOCK_BIN=$(mktemp -d)
PATH="$MOCK_BIN"
email=$(_detect_email)
PATH="$SAVED_PATH"
assert_equal "unknown" "$email"
rm -rf "$MOCK_BIN"
export HOME="$SAVED_HOME"
test_end

# === _detect_email: qodercli status preferred over cockpit ===

test_start "_detect_email: prefers qodercli status over cockpit"
MOCK_BIN=$(mktemp -d)
printf '#!/bin/bash\necho "Email: qodercli-wins@gmail.com"\n' > "$MOCK_BIN/qodercli"
chmod +x "$MOCK_BIN/qodercli"
PATH="$MOCK_BIN:$SAVED_PATH"
export HOME="$VAULT_DIR"
mkdir -p "$VAULT_DIR/.antigravity_cockpit/qoder_accounts"
echo '{"current_accounts":{"qoder":"qid-456"}}' > "$VAULT_DIR/.antigravity_cockpit/provider_current_accounts.json"
echo '{"email":"cockpit-stale@example.com"}' > "$VAULT_DIR/.antigravity_cockpit/qoder_accounts/qid-456.json"
COCKPIT_QODER_ACCOUNTS="$VAULT_DIR/.antigravity_cockpit/qoder_accounts"
email=$(_detect_email)
assert_equal "qodercli-wins@gmail.com" "$email"
PATH="$SAVED_PATH"
rm -rf "$MOCK_BIN"
export HOME="$SAVED_HOME"
test_end

# === _detect_email: handles qodercli failure gracefully ===

test_start "_detect_email: falls back when qodercli returns error"
MOCK_BIN=$(mktemp -d)
printf '#!/bin/bash\necho "Error: not logged in" >&2\nexit 1\n' > "$MOCK_BIN/qodercli"
chmod +x "$MOCK_BIN/qodercli"
PATH="$MOCK_BIN:$SAVED_PATH"
export HOME="$VAULT_DIR"
mkdir -p "$VAULT_DIR/.antigravity_cockpit/qoder_accounts"
echo '{"current_accounts":{"qoder":"qid-789"}}' > "$VAULT_DIR/.antigravity_cockpit/provider_current_accounts.json"
echo '{"email":"fallback@example.com"}' > "$VAULT_DIR/.antigravity_cockpit/qoder_accounts/qid-789.json"
COCKPIT_QODER_ACCOUNTS="$VAULT_DIR/.antigravity_cockpit/qoder_accounts"
email=$(_detect_email)
assert_equal "fallback@example.com" "$email"
PATH="$SAVED_PATH"
rm -rf "$MOCK_BIN"
export HOME="$SAVED_HOME"
test_end

test_summary
