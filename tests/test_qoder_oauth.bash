#!/bin/bash
# Tests for lib/qoder-oauth.sh — OAuth login flow helper
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/test_helpers.sh"

# Source the library under test
VAULT_DIR=$(mktemp -d)
QODER_AUTH="$VAULT_DIR/auth-user"
source "$PROJECT_DIR/lib/qoder-oauth.sh"
trap 'rm -rf "$VAULT_DIR"' EXIT

# === qoder_oauth_extract_url ===

test_start "qoder_oauth_extract_url: extracts https URL from output"
url=$(qoder_oauth_extract_url "Please visit https://qoder.com/device/selectAccounts?code=abc123 to continue")
assert_equal "https://qoder.com/device/selectAccounts?code=abc123" "$url"
test_end

test_start "qoder_oauth_extract_url: extracts URL with path"
url=$(qoder_oauth_extract_url "Open this: https://qoder.com/device/login")
assert_equal "https://qoder.com/device/login" "$url"
test_end

test_start "qoder_oauth_extract_url: extracts first URL when multiple present"
url=$(qoder_oauth_extract_url "Visit https://qoder.com/auth or https://other.com/help")
assert_equal "https://qoder.com/auth" "$url"
test_end

test_start "qoder_oauth_extract_url: returns empty for no URL"
url=$(qoder_oauth_extract_url "No URL here, just text")
assert_equal "" "$url"
test_end

test_start "qoder_oauth_extract_url: returns empty for empty input"
url=$(qoder_oauth_extract_url "")
assert_equal "" "$url"
test_end

test_start "qoder_oauth_extract_url: handles URL with complex query params"
url=$(qoder_oauth_extract_url "Go to https://qoder.com/device/selectAccounts?state=xyz&nonce=abc&redirect=http%3A%2F%2Flocalhost")
assert_equal "https://qoder.com/device/selectAccounts?state=xyz&nonce=abc&redirect=http%3A%2F%2Flocalhost" "$url"
test_end

# === qoder_oauth_login with mocked qodercli ===

SAVED_PATH="$PATH"

test_start "qoder_oauth_login: succeeds when auth file is created"
MOCK_BIN=$(mktemp -d)
printf '#!/bin/bash\necho "Starting login..."\necho "Please visit https://qoder.com/device/selectAccounts?code=test123"\nsleep 1\nmkdir -p "%s"\necho "encrypted-auth-data" > "%s"\necho "Login complete!"\nexit 0\n' "$(dirname "$QODER_AUTH")" "$QODER_AUTH" > "$MOCK_BIN/qodercli"
chmod +x "$MOCK_BIN/qodercli"
PATH="$MOCK_BIN:$SAVED_PATH"
QODER_OAUTH_TIMEOUT=10
qoder_oauth_login
assert_equal "0" "$QODER_OAUTH_RC"
assert_file_exists "$QODER_AUTH"
PATH="$SAVED_PATH"
rm -rf "$MOCK_BIN"
test_end

test_start "qoder_oauth_login: sets QODER_OAUTH_URL"
rm -f "$QODER_AUTH"
MOCK_BIN=$(mktemp -d)
printf '#!/bin/bash\necho "Visit https://qoder.com/device/login?code=url456"\nsleep 1\necho "encrypted-data" > "%s"\nexit 0\n' "$QODER_AUTH" > "$MOCK_BIN/qodercli"
chmod +x "$MOCK_BIN/qodercli"
PATH="$MOCK_BIN:$SAVED_PATH"
QODER_OAUTH_TIMEOUT=10
qoder_oauth_login
assert_equal "0" "$QODER_OAUTH_RC"
assert_equal "https://qoder.com/device/login?code=url456" "$QODER_OAUTH_URL"
PATH="$SAVED_PATH"
rm -rf "$MOCK_BIN"
test_end

test_start "qoder_oauth_login: detects updated existing auth file"
echo "old-data" > "$QODER_AUTH"
sleep 1
MOCK_BIN=$(mktemp -d)
printf '#!/bin/bash\necho "Visit https://qoder.com/device/auth"\nsleep 1\necho "new-encrypted-data" > "%s"\nexit 0\n' "$QODER_AUTH" > "$MOCK_BIN/qodercli"
chmod +x "$MOCK_BIN/qodercli"
PATH="$MOCK_BIN:$SAVED_PATH"
QODER_OAUTH_TIMEOUT=10
qoder_oauth_login
assert_equal "0" "$QODER_OAUTH_RC"
assert_file_contains "$QODER_AUTH" "new-encrypted-data"
PATH="$SAVED_PATH"
rm -rf "$MOCK_BIN"
test_end

test_start "qoder_oauth_login: sets QODER_OAUTH_RC=1 when qodercli fails"
rm -f "$QODER_AUTH"
MOCK_BIN=$(mktemp -d)
printf '#!/bin/bash\necho "Error: something went wrong" >&2\nexit 1\n' > "$MOCK_BIN/qodercli"
chmod +x "$MOCK_BIN/qodercli"
PATH="$MOCK_BIN:$SAVED_PATH"
QODER_OAUTH_TIMEOUT=5
qoder_oauth_login
assert_equal "1" "$QODER_OAUTH_RC"
PATH="$SAVED_PATH"
rm -rf "$MOCK_BIN"
test_end

test_summary
