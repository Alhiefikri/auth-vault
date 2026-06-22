#!/bin/bash
# Tests for lib/openai-oauth.sh — OpenAI OAuth flows (3 methods)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/test_helpers.sh"

TEST_HOME="$(mktemp -d)"
export HOME="$TEST_HOME"
OPENAI_VAULT_DIR="$HOME/.auth-vault/openai"
SAVED_PATH="$PATH"

source "$PROJECT_DIR/lib/openai-oauth.sh"
trap 'rm -rf "$TEST_HOME"; PATH="$SAVED_PATH"' EXIT

# === PKCE generation ===

test_start "openai_oauth_generate_pkce: produces code_verifier and code_challenge"
openai_oauth_generate_pkce
[[ -n "${OPENAI_OAUTH_CODE_VERIFIER:-}" ]] || _fail "code_verifier is empty"
[[ -n "${OPENAI_OAUTH_CODE_CHALLENGE:-}" ]] || _fail "code_challenge is empty"
[[ ${#OPENAI_OAUTH_CODE_VERIFIER} -ge 43 ]] || _fail "code_verifier too short (${#OPENAI_OAUTH_CODE_VERIFIER})"
test_end

test_start "openai_oauth_generate_pkce: generates unique values each call"
openai_oauth_generate_pkce
_pkce_v1="$OPENAI_OAUTH_CODE_VERIFIER"
openai_oauth_generate_pkce
_pkce_v2="$OPENAI_OAUTH_CODE_VERIFIER"
if [[ "$_pkce_v1" == "$_pkce_v2" ]]; then
    _fail "two consecutive PKCE verifiers should differ"
fi
test_end

# === Auth URL building ===

test_start "openai_oauth_build_auth_url: builds correct URL with params"
OPENAI_OAUTH_CODE_VERIFIER="test_verifier_123456789012345678901234567890"
OPENAI_OAUTH_CODE_CHALLENGE="test_challenge_abc"
OPENAI_OAUTH_STATE="test_state_xyz"
url=$(openai_oauth_build_auth_url 1455)
echo "$url" | grep -q "auth.openai.com" || _fail "missing auth.openai.com"
echo "$url" | grep -q "code_challenge=test_challenge_abc" || _fail "missing code_challenge"
echo "$url" | grep -q "state=test_state_xyz" || _fail "missing state"
echo "$url" | grep -q "redirect_uri=http" || _fail "missing redirect_uri"
echo "$url" | grep -q "1455" || _fail "missing port 1455"
test_end

test_start "openai_oauth_build_auth_url: includes required scopes"
url=$(openai_oauth_build_auth_url 1455)
echo "$url" | grep -q "openid" || _fail "missing openid scope"
echo "$url" | grep -q "profile" || _fail "missing profile scope"
echo "$url" | grep -q "email" || _fail "missing email scope"
test_end

# === Code extraction from redirect URL ===

test_start "openai_oauth_extract_code: extracts code from redirect URL"
code=$(openai_oauth_extract_code "http://localhost:1455/callback?code=AUTH_CODE_123&state=xyz")
assert_equal "AUTH_CODE_123" "$code"
test_end

test_start "openai_oauth_extract_code: extracts code with extra params"
code=$(openai_oauth_extract_code "http://localhost:1455/callback?state=abc&code=MY_CODE&session=sess123")
assert_equal "MY_CODE" "$code"
test_end

test_start "openai_oauth_extract_code: returns empty when no code"
code=$(openai_oauth_extract_code "http://localhost:1455/callback?error=access_denied")
assert_equal "" "$code"
test_end

test_start "openai_oauth_extract_code: returns empty for empty input"
code=$(openai_oauth_extract_code "")
assert_equal "" "$code"
test_end

# === State generation ===

test_start "openai_oauth_generate_state: produces non-empty state"
state=$(openai_oauth_generate_state)
[[ -n "$state" ]] || _fail "state is empty"
[[ ${#state} -ge 8 ]] || _fail "state too short"
test_end

test_start "openai_oauth_generate_state: generates unique values"
s1=$(openai_oauth_generate_state)
s2=$(openai_oauth_generate_state)
if [[ "$s1" == "$s2" ]]; then
    _fail "two consecutive states should differ"
fi
test_end

# === Token exchange (mocked curl) ===

test_start "openai_oauth_exchange_code: parses token response from curl"
MOCK_BIN=$(mktemp -d)
cat > "$MOCK_BIN/curl" <<'MOCK'
#!/bin/bash
echo '{"access_token":"mock_access_jwt","refresh_token":"mock_refresh_tok","expires_in":3600,"token_type":"Bearer"}'
exit 0
MOCK
chmod +x "$MOCK_BIN/curl"
PATH="$MOCK_BIN:$SAVED_PATH"
OPENAI_OAUTH_CODE_VERIFIER="verifier123"
result=$(openai_oauth_exchange_code "my_code" 1455)
echo "$result" | grep -q "mock_access_jwt" || _fail "missing access_token in result"
echo "$result" | grep -q "mock_refresh_tok" || _fail "missing refresh_token in result"
PATH="$SAVED_PATH"
rm -rf "$MOCK_BIN"
test_end

test_start "openai_oauth_exchange_code: returns error JSON on curl failure"
MOCK_BIN=$(mktemp -d)
cat > "$MOCK_BIN/curl" <<'MOCK'
#!/bin/bash
echo '{"error":"invalid_grant","error_description":"Code expired"}' >&2
exit 1
MOCK
chmod +x "$MOCK_BIN/curl"
PATH="$MOCK_BIN:$SAVED_PATH"
OPENAI_OAUTH_CODE_VERIFIER="verifier123"
rc=0
result=$(openai_oauth_exchange_code "bad_code" 1455) || rc=$?
if [[ "$rc" -eq 0 ]]; then
    _fail "expected non-zero exit on curl failure"
fi
PATH="$SAVED_PATH"
rm -rf "$MOCK_BIN"
test_end

# === Method 2: Link flow (show URL, read pasted redirect) ===

test_start "openai_oauth_link: sets OPENAI_OAUTH_URL with auth URL"
openai_oauth_generate_pkce
OPENAI_OAUTH_STATE="link_test_state"
OPENAI_OAUTH_URL=""
openai_oauth_link_prepare_url 1455
[[ -n "${OPENAI_OAUTH_URL:-}" ]] || _fail "OPENAI_OAUTH_URL not set"
echo "$OPENAI_OAUTH_URL" | grep -q "auth.openai.com" || _fail "URL missing auth.openai.com"
test_end

# === Method 3: Localhost callback server ===

test_start "openai_oauth_parse_callback_response: extracts code from callback body"
code=$(openai_oauth_parse_callback_response "GET /callback?code=CALLBACK_CODE_999&state=st HTTP/1.1")
assert_equal "CALLBACK_CODE_999" "$code"
test_end

test_start "openai_oauth_parse_callback_response: returns empty for error callback"
code=$(openai_oauth_parse_callback_response "GET /callback?error=access_denied HTTP/1.1")
assert_equal "" "$code"
test_end

# === Method 1: Browser flow (mock xdg-open + callback) ===

test_start "openai_oauth_browser: detects xdg-open availability"
MOCK_BIN=$(mktemp -d)
cat > "$MOCK_BIN/xdg-open" <<'MOCK'
#!/bin/bash
exit 0
MOCK
chmod +x "$MOCK_BIN/xdg-open"
PATH="$MOCK_BIN:$SAVED_PATH"
if openai_oauth_has_browser; then
    :
else
    _fail "should detect xdg-open"
fi
PATH="$SAVED_PATH"
rm -rf "$MOCK_BIN"
test_end

test_start "openai_oauth_browser: reports no browser when xdg-open missing"
MOCK_BIN=$(mktemp -d)
PATH="$MOCK_BIN"
if openai_oauth_has_browser; then
    _fail "should not find browser"
fi
PATH="$SAVED_PATH"
rm -rf "$MOCK_BIN"
test_end

# === Additional edge-case scenarios ===

test_start "openai_oauth_generate_pkce: code_challenge uses base64url charset"
openai_oauth_generate_pkce
if echo "$OPENAI_OAUTH_CODE_CHALLENGE" | grep -qP '[+/=]'; then
    _fail "code_challenge contains non-base64url characters (+, /, or =)"
fi
test_end

test_start "openai_oauth_generate_pkce: code_verifier is hex (64 chars)"
openai_oauth_generate_pkce
if [[ ${#OPENAI_OAUTH_CODE_VERIFIER} -ne 64 ]]; then
    _fail "code_verifier should be 64 hex chars, got ${#OPENAI_OAUTH_CODE_VERIFIER}"
fi
if ! [[ "$OPENAI_OAUTH_CODE_VERIFIER" =~ ^[0-9a-f]+$ ]]; then
    _fail "code_verifier should be lowercase hex"
fi
test_end

test_start "openai_oauth_build_auth_url: uses custom port in redirect_uri"
OPENAI_OAUTH_CODE_CHALLENGE="ch"
OPENAI_OAUTH_STATE="st"
url=$(openai_oauth_build_auth_url 9999)
echo "$url" | grep -q "9999" || _fail "missing port 9999 in URL"
echo "$url" | grep -q "localhost%3A9999" || _fail "redirect_uri not properly encoded with port 9999"
test_end

test_start "openai_oauth_build_auth_url: includes code_challenge_method=S256"
OPENAI_OAUTH_CODE_CHALLENGE="ch"
OPENAI_OAUTH_STATE="st"
url=$(openai_oauth_build_auth_url 1455)
echo "$url" | grep -q "code_challenge_method=S256" || _fail "missing code_challenge_method=S256"
test_end

test_start "openai_oauth_build_auth_url: includes response_type=code"
url=$(openai_oauth_build_auth_url 1455)
echo "$url" | grep -q "response_type=code" || _fail "missing response_type=code"
test_end

test_start "openai_oauth_build_auth_url: includes client_id"
url=$(openai_oauth_build_auth_url 1455)
echo "$url" | grep -q "client_id=$OPENAI_OAUTH_CLIENT_ID" || _fail "missing client_id"
test_end

test_start "openai_oauth_link_prepare_url: auto-generates PKCE when empty"
OPENAI_OAUTH_CODE_VERIFIER=""
OPENAI_OAUTH_CODE_CHALLENGE=""
OPENAI_OAUTH_STATE=""
openai_oauth_link_prepare_url 1455
[[ -n "$OPENAI_OAUTH_CODE_VERIFIER" ]] || _fail "PKCE verifier not auto-generated"
[[ -n "$OPENAI_OAUTH_CODE_CHALLENGE" ]] || _fail "PKCE challenge not auto-generated"
[[ -n "$OPENAI_OAUTH_STATE" ]] || _fail "state not auto-generated"
[[ -n "$OPENAI_OAUTH_URL" ]] || _fail "URL not set"
test_end

test_start "openai_oauth_link_prepare_url: preserves existing PKCE"
OPENAI_OAUTH_CODE_VERIFIER="preset_verifier_1234567890123456789012345678901234567890"
OPENAI_OAUTH_CODE_CHALLENGE="preset_challenge"
OPENAI_OAUTH_STATE="preset_state"
openai_oauth_link_prepare_url 1455
if [[ "$OPENAI_OAUTH_STATE" != "preset_state" ]]; then
    _fail "state was overwritten: got $OPENAI_OAUTH_STATE"
fi
test_end

test_start "openai_oauth_parse_callback_response: returns empty for empty input"
code=$(openai_oauth_parse_callback_response "")
assert_equal "" "$code"
test_end

test_start "openai_oauth_parse_callback_response: returns empty for malformed HTTP"
code=$(openai_oauth_parse_callback_response "NOT_AN_HTTP_REQUEST")
assert_equal "" "$code"
test_end

test_start "openai_oauth_parse_callback_response: extracts code from POST-style path"
code=$(openai_oauth_parse_callback_response "GET /callback?code=POST_CODE&state=s HTTP/1.1")
assert_equal "POST_CODE" "$code"
test_end

test_start "openai_oauth_extract_code: handles URL-encoded code value"
code=$(openai_oauth_extract_code "http://localhost:1455/callback?code=abc%20def&state=x")
[[ -n "$code" ]] || _fail "should extract URL-encoded code"
test_end

test_start "openai_oauth_exchange_code: sends correct parameters to curl"
MOCK_BIN=$(mktemp -d)
cat > "$MOCK_BIN/curl" <<'MOCK'
#!/bin/bash
# Echo all arguments for verification
echo "ARGS: $@"
echo '{"access_token":"ok"}'
MOCK
chmod +x "$MOCK_BIN/curl"
PATH="$MOCK_BIN:$SAVED_PATH"
OPENAI_OAUTH_CODE_VERIFIER="my_verifier"
result=$(openai_oauth_exchange_code "test_code" 8888)
echo "$result" | grep -q "code=test_code" || _fail "missing code parameter"
echo "$result" | grep -q "code_verifier=my_verifier" || _fail "missing code_verifier"
echo "$result" | grep -q "redirect_uri=http://localhost:8888/callback" || _fail "wrong redirect_uri for port 8888"
echo "$result" | grep -q "grant_type=authorization_code" || _fail "missing grant_type"
PATH="$SAVED_PATH"
rm -rf "$MOCK_BIN"
test_end

test_start "openai_oauth env vars: custom AUTH_URL and TOKEN_URL respected"
_saved_auth="$OPENAI_OAUTH_AUTH_URL"
_saved_token="$OPENAI_OAUTH_TOKEN_URL"
OPENAI_OAUTH_AUTH_URL="https://custom-auth.example.com/authorize"
OPENAI_OAUTH_CODE_CHALLENGE="ch"
OPENAI_OAUTH_STATE="st"
url=$(openai_oauth_build_auth_url 1455)
echo "$url" | grep -q "custom-auth.example.com" || _fail "custom AUTH_URL not used"
OPENAI_OAUTH_AUTH_URL="$_saved_auth"
OPENAI_OAUTH_TOKEN_URL="$_saved_token"
test_end

test_start "openai_oauth_start_callback_server: returns a PID"
outfile=$(mktemp)
pid=$(openai_oauth_start_callback_server 19876 "$outfile")
[[ -n "$pid" ]] || _fail "no PID returned"
sleep 0.5
if kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null || true
    for _i in $(seq 1 10); do
        kill -0 "$pid" 2>/dev/null || break
        sleep 0.2
    done
    kill -9 "$pid" 2>/dev/null || true
fi
rm -f "$outfile"
test_end

test_summary
