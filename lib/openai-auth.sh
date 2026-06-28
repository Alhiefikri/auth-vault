#!/bin/bash
# lib/openai-auth.sh - OpenAI account vault CRUD
#
# Sourcing script must set:
#   OPENAI_VAULT_DIR - vault path (e.g. ~/.auth-vault/openai)

OPENAI_VAULT_DIR="${OPENAI_VAULT_DIR:-$HOME/.auth-vault/openai}"

openai_vault_ensure_dir() {
    mkdir -p "$OPENAI_VAULT_DIR"
}

openai_vault_save() {
    local name="$1"
    local email="$2"
    local access="$3"
    local refresh="$4"
    local account_id="$5"

    openai_vault_ensure_dir

    local _lib_dir
    _lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    python3 "$_lib_dir/vault_backends.py" write-openai-vault \
        --dir "$OPENAI_VAULT_DIR" \
        --name "$name" \
        --email "$email" \
        --access "$access" \
        --refresh "$refresh" \
        --account-id "$account_id"

    echo "$name" > "$OPENAI_VAULT_DIR/.current"
}

openai_vault_delete() {
    local name="$1"

    if [[ ! -f "$OPENAI_VAULT_DIR/$name.json" ]]; then
        return 1
    fi

    local _lib_dir
    _lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    python3 "$_lib_dir/vault_backends.py" delete-openai \
        --dir "$OPENAI_VAULT_DIR" \
        --name "$name"
}

openai_vault_list() {
    openai_vault_ensure_dir
    local found=false
    for f in "$OPENAI_VAULT_DIR"/*.json; do
        [[ -f "$f" ]] || continue
        local bn; bn=$(basename "$f" .json)
        echo "$bn"
        found=true
    done
    if [[ "$found" == "false" ]]; then
        echo ""
    fi
}

openai_vault_count() {
    openai_vault_ensure_dir
    local count=0
    for f in "$OPENAI_VAULT_DIR"/*.json; do
        [[ -f "$f" ]] || continue
        count=$((count + 1))
    done
    echo "$count"
}

openai_vault_get() {
    local name="$1"
    local field="$2"
    local file="$OPENAI_VAULT_DIR/$name.json"

    if [[ ! -f "$file" ]]; then
        echo ""
        return 0
    fi

    case "$field" in
        email)
            jq -r '.email // empty' "$file" 2>/dev/null
            ;;
        account_id)
            jq -r '.account_id // empty' "$file" 2>/dev/null
            ;;
        access_token)
            jq -r '.tokens.access_token // empty' "$file" 2>/dev/null
            ;;
        refresh_token)
            jq -r '.tokens.refresh_token // empty' "$file" 2>/dev/null
            ;;
        *)
            jq -r ".$field // empty" "$file" 2>/dev/null
            ;;
    esac
}

openai_vault_get_current() {
    if [[ -f "$OPENAI_VAULT_DIR/.current" ]]; then
        cat "$OPENAI_VAULT_DIR/.current" 2>/dev/null
    else
        echo ""
    fi
}

# Requires: COCKPIT_CURRENT, COCKPIT_CODEX_ACCOUNTS, OPENAI_VAULT_DIR set by caller
# Returns: vault profile name via stdout (empty + return 1 if not found)
openai_vault_get_cockpit_active() {
    if [[ ! -f "${COCKPIT_CURRENT:-}" ]]; then
        echo ""; return 1
    fi

    local current_codex_id
    current_codex_id=$(jq -r '.current_accounts.codex // empty' "$COCKPIT_CURRENT" 2>/dev/null)
    if [[ -z "$current_codex_id" ]]; then
        echo ""; return 1
    fi

    local account_file="${COCKPIT_CODEX_ACCOUNTS:-}/${current_codex_id}.json"
    if [[ ! -f "$account_file" ]]; then
        echo ""; return 1
    fi

    local cockpit_email
    cockpit_email=$(jq -r '.email // empty' "$account_file" 2>/dev/null)
    if [[ -z "$cockpit_email" ]]; then
        echo ""; return 1
    fi

    # Search the OpenAI vault for a matching email
    openai_vault_ensure_dir
    for f in "$OPENAI_VAULT_DIR"/*.json; do
        [[ -f "$f" ]] || continue
        local vault_email
        vault_email=$(jq -r '.email // empty' "$f" 2>/dev/null)
        if [[ "$vault_email" == "$cockpit_email" ]]; then
            local bn
            bn=$(basename "$f" .json)
            echo "$bn"
            return 0
        fi
    done

    echo ""; return 1
}
