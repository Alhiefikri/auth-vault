#!/bin/bash
# lib/openai-oauth.sh - OpenAI OAuth flows (3 methods)
#
# Method 1 (browser): Opens browser, starts local callback server, captures token
# Method 2 (link): Shows auth URL for copy, user pastes redirect URL back
# Method 3 (localhost): Like link but captures localhost callback automatically
#
# Globals set by functions:
#   OPENAI_OAUTH_CODE_VERIFIER  - PKCE verifier
#   OPENAI_OAUTH_CODE_CHALLENGE - PKCE challenge (S256)
#   OPENAI_OAUTH_STATE          - CSRF state parameter
#   OPENAI_OAUTH_URL            - Authorization URL
#   OPENAI_OAUTH_RC             - Result code (0=ok, 1=fail)

OPENAI_OAUTH_AUTH_URL="${OPENAI_OAUTH_AUTH_URL:-https://auth.openai.com/oauth/authorize}"
OPENAI_OAUTH_TOKEN_URL="${OPENAI_OAUTH_TOKEN_URL:-https://auth.openai.com/oauth/token}"
OPENAI_OAUTH_CLIENT_ID="${OPENAI_OAUTH_CLIENT_ID:-app_EMoamEEZ73f0CkXaXp7hrann}"
OPENAI_OAUTH_SCOPE="${OPENAI_OAUTH_SCOPE:-openid profile email}"
OPENAI_OAUTH_TIMEOUT="${OPENAI_OAUTH_TIMEOUT:-120}"

OPENAI_OAUTH_CODE_VERIFIER=""
OPENAI_OAUTH_CODE_CHALLENGE=""
OPENAI_OAUTH_STATE=""
OPENAI_OAUTH_URL=""
OPENAI_OAUTH_RC=1
OPENAI_OAUTH_CODE=""

_base64url() {
    openssl base64 -A | tr '+/' '-_' | tr -d '='
}

openai_oauth_generate_pkce() {
    OPENAI_OAUTH_CODE_VERIFIER=$(openssl rand -hex 32)
    OPENAI_OAUTH_CODE_CHALLENGE=$(printf '%s' "$OPENAI_OAUTH_CODE_VERIFIER" \
        | openssl dgst -sha256 -binary | _base64url)
}

openai_oauth_generate_state() {
    openssl rand -hex 16
}

openai_oauth_build_auth_url() {
    local port="${1:-1455}"
    local redirect_uri
    redirect_uri=$(printf 'http://localhost:%s/callback' "$port")
    local encoded_redirect
    encoded_redirect=$(printf '%s' "$redirect_uri" | python3 -c "import sys,urllib.parse; print(urllib.parse.quote(sys.stdin.read(), safe=''))")

    printf '%s?response_type=code&client_id=%s&redirect_uri=%s&scope=%s&state=%s&code_challenge=%s&code_challenge_method=S256' \
        "$OPENAI_OAUTH_AUTH_URL" \
        "$OPENAI_OAUTH_CLIENT_ID" \
        "$encoded_redirect" \
        "$(printf '%s' "$OPENAI_OAUTH_SCOPE" | python3 -c "import sys,urllib.parse; print(urllib.parse.quote(sys.stdin.read(), safe=''))")" \
        "$OPENAI_OAUTH_STATE" \
        "$OPENAI_OAUTH_CODE_CHALLENGE"
}

openai_oauth_extract_code() {
    local url="$1"
    local code
    code=$(echo "$url" | grep -oP '(?<=[?&])code=\K[^&]+' | head -1) || true
    echo "${code:-}"
}

openai_oauth_exchange_code() {
    local code="$1"
    local port="${2:-1455}"
    local redirect_uri="http://localhost:${port}/callback"

    curl -sS -X POST "$OPENAI_OAUTH_TOKEN_URL" \
        -H "Content-Type: application/x-www-form-urlencoded" \
        -d "grant_type=authorization_code" \
        -d "code=${code}" \
        -d "redirect_uri=${redirect_uri}" \
        -d "client_id=${OPENAI_OAUTH_CLIENT_ID}" \
        -d "code_verifier=${OPENAI_OAUTH_CODE_VERIFIER}"
}

openai_oauth_link_prepare_url() {
    local port="${1:-1455}"
    if [[ -z "$OPENAI_OAUTH_CODE_VERIFIER" ]]; then
        openai_oauth_generate_pkce
    fi
    if [[ -z "$OPENAI_OAUTH_STATE" ]]; then
        OPENAI_OAUTH_STATE=$(openai_oauth_generate_state)
    fi
    OPENAI_OAUTH_URL=$(openai_oauth_build_auth_url "$port")
}

openai_oauth_parse_callback_response() {
    local http_request="$1"
    local url_part
    url_part=$(echo "$http_request" | grep -oP 'GET \K[^ ]+' | head -1) || true
    if [[ -z "$url_part" ]]; then
        echo ""
        return 0
    fi
    openai_oauth_extract_code "$url_part"
}

openai_oauth_has_browser() {
    command -v xdg-open &>/dev/null
}

openai_oauth_start_callback_server() {
    local port="${1:-1455}"
    local outfile="${2:-}"

    python3 -c "
import http.server, socketserver, sys, urllib.parse

class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        code = ''
        qs = urllib.parse.urlparse(self.path).query
        params = urllib.parse.parse_qs(qs)
        if 'code' in params:
            code = params['code'][0]
        self.send_response(200)
        self.send_header('Content-Type', 'text/html')
        self.end_headers()
        if code:
            self.wfile.write(b'<h1>Login berhasil!</h1><p>Tab ini bisa ditutup.</p>')
        else:
            self.wfile.write(b'<h1>Login gagal.</h1>')
        print(code, file=sys.stderr, flush=True)
        raise KeyboardInterrupt

    def log_message(self, format, *args):
        pass

try:
    socketserver.TCPServer.allow_reuse_address = True
    with socketserver.TCPServer(('localhost', ${port}), Handler) as httpd:
        httpd.timeout = ${OPENAI_OAUTH_TIMEOUT}
        httpd.handle_request()
except Exception:
    pass
" 1>/dev/null 2>"${outfile:-/dev/null}" &
    echo $!
}

openai_oauth_browser_login() {
    local port="${1:-1455}"
    OPENAI_OAUTH_RC=1

    openai_oauth_generate_pkce
    OPENAI_OAUTH_STATE=$(openai_oauth_generate_state)
    OPENAI_OAUTH_URL=$(openai_oauth_build_auth_url "$port")

    if ! openai_oauth_has_browser; then
        return 0
    fi

    local code_file
    code_file=$(mktemp)

    local server_pid
    server_pid=$(openai_oauth_start_callback_server "$port" "$code_file")

    xdg-open "$OPENAI_OAUTH_URL" &>/dev/null &

    local waited=0
    while (( waited < OPENAI_OAUTH_TIMEOUT )); do
        sleep 1
        waited=$((waited + 1))
        if ! kill -0 "$server_pid" 2>/dev/null; then
            break
        fi
    done

    kill "$server_pid" 2>/dev/null
    wait "$server_pid" 2>/dev/null || true

    local code
    code=$(cat "$code_file" 2>/dev/null | tr -d '[:space:]')
    rm -f "$code_file"

    if [[ -n "$code" ]]; then
        OPENAI_OAUTH_RC=0
        OPENAI_OAUTH_CODE="$code"
    fi
    return 0
}

openai_oauth_localhost_login() {
    local port="${1:-1455}"
    OPENAI_OAUTH_RC=1

    openai_oauth_generate_pkce
    OPENAI_OAUTH_STATE=$(openai_oauth_generate_state)
    OPENAI_OAUTH_URL=$(openai_oauth_build_auth_url "$port")

    local code_file
    code_file=$(mktemp)

    local server_pid
    server_pid=$(openai_oauth_start_callback_server "$port" "$code_file")

    local waited=0
    while (( waited < OPENAI_OAUTH_TIMEOUT )); do
        sleep 1
        waited=$((waited + 1))
        if ! kill -0 "$server_pid" 2>/dev/null; then
            break
        fi
    done

    kill "$server_pid" 2>/dev/null
    wait "$server_pid" 2>/dev/null || true

    local code
    code=$(cat "$code_file" 2>/dev/null | tr -d '[:space:]')
    rm -f "$code_file"

    if [[ -n "$code" ]]; then
        OPENAI_OAUTH_RC=0
        OPENAI_OAUTH_CODE="$code"
    fi
    return 0
}
