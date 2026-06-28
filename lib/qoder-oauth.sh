#!/bin/bash
# lib/qoder-oauth.sh - Qoder OAuth login flow
#
# Runs `qodercli login` (PKCE OAuth), captures the auth URL,
# waits for completion, and saves to vault.
#
# Sourcing script must set:
#   VAULT_DIR   - canonical vault path (e.g. ~/.auth-vault/qoder)
#   QODER_AUTH  - active auth file (e.g. ~/.qoder/.auth/user)

_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$_lib_dir/detect-email.sh"

QODER_OAUTH_TIMEOUT="${QODER_OAUTH_TIMEOUT:-120}"
QODER_OAUTH_URL=""
QODER_OAUTH_RC=1

qoder_oauth_extract_url() {
    local output="$1"
    local url
    url=$(echo "$output" | grep -oE 'https://[^ "'"'"'[:cntrl:]]+' | head -1) || true
    echo "$url"
}

# Runs qodercli login in background, captures URL, waits for auth.
# Sets QODER_OAUTH_URL and QODER_OAUTH_RC (0=success, 1=failure).
# Always returns 0 to avoid set -e issues; check QODER_OAUTH_RC.
qoder_oauth_login() {
    QODER_OAUTH_URL=""
    QODER_OAUTH_RC=1

    local auth_file="${QODER_AUTH:-$HOME/.qoder/.auth/user}"
    local timeout="${QODER_OAUTH_TIMEOUT:-120}"

    local old_mtime=""
    [[ -f "$auth_file" ]] && old_mtime=$(stat -c '%Y' "$auth_file" 2>/dev/null || echo "")

    local tmpfile
    tmpfile=$(mktemp)

    qodercli login > "$tmpfile" 2>&1 &
    local pid=$!

    local url="" elapsed=0
    local opened_browser=false
    while (( elapsed < 10 )) && kill -0 "$pid" 2>/dev/null; do
        sleep 1
        elapsed=$((elapsed + 1))
        if [[ -z "$url" ]]; then
            url=$(qoder_oauth_extract_url "$(cat "$tmpfile" 2>/dev/null)")
            if [[ -n "$url" && "$opened_browser" == false ]]; then
                echo -e "  [i] Silakan klik link berikut jika browser tidak terbuka otomatis:\n  \033[0;36m$url\033[0m" >&2
                if command -v xdg-open &>/dev/null; then
                    xdg-open "$url" &>/dev/null &
                elif command -v open &>/dev/null; then
                    open "$url" &>/dev/null &
                fi
                opened_browser=true
            fi
        fi
    done

    QODER_OAUTH_URL="${url:-}"

    # Wait for auth file update or process completion
    local waited=0
    while kill -0 "$pid" 2>/dev/null && (( waited < timeout )); do
        sleep 1
        waited=$((waited + 1))
        if [[ -f "$auth_file" ]]; then
            local new_mtime
            new_mtime=$(stat -c '%Y' "$auth_file" 2>/dev/null || echo "")
            if [[ "$new_mtime" != "$old_mtime" ]]; then
                wait "$pid" 2>/dev/null || true
                rm -f "$tmpfile"
                QODER_OAUTH_RC=0
                return 0
            fi
        fi
    done

    # Timeout - kill lingering process
    if kill -0 "$pid" 2>/dev/null; then
        kill "$pid" 2>/dev/null
        wait "$pid" 2>/dev/null || true
        rm -f "$tmpfile"
        return 0
    fi

    # Process finished - check exit code
    local rc=0
    wait "$pid" || rc=$?
    rm -f "$tmpfile"
    if [[ "$rc" -eq 0 && -f "$auth_file" ]]; then
        QODER_OAUTH_RC=0
    fi
    return 0
}

qoder_oauth_interactive() {
    local R='\033[0;31m' G='\033[0;32m' Y='\033[1;33m' C='\033[0;36m' D='\033[2m' N='\033[0m'

    echo -e "  ${Y}Menjalankan qodercli login...${N}"
    echo -e "  ${D}Browser akan terbuka. Selesaikan login di browser.${N}"
    echo ""

    qoder_oauth_login
    if [[ "$QODER_OAUTH_RC" -ne 0 ]]; then
        echo -e "  ${R}Login gagal atau timeout.${N}"
        return 1
    fi

    local auth_file="${QODER_AUTH:-$HOME/.qoder/.auth/user}"
    if [[ ! -f "$auth_file" ]]; then
        echo -e "  ${R}Auth file tidak terupdate.${N}"
        return 1
    fi

    echo -e "  ${G}✓ Login berhasil!${N}"
    echo ""

    echo -e "  ${Y}Nama profile (contoh: akun-utama):${N}"
    echo -n "  > "
    local name
    read -r name
    [[ -z "$name" ]] && { echo -e "  ${R}Dibatalkan.${N}"; return 1; }

    local email
    email=$(_detect_email)

    vault_save "$name" "$email"
    echo -e "  ${G}✓ Profile '$name' disimpan ke vault!${N}"
    return 0
}
