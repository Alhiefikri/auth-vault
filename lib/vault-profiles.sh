#!/bin/bash
# lib/vault-profiles.sh - Shared vault CRUD for Qoder CLI profiles
#
# Sourcing script must set:
#   VAULT_DIR          - canonical vault path (e.g. ~/.auth-vault/qoder)
#   QODER_AUTH         - active auth file (e.g. ~/.qoder/.auth/user)
# Optional:
#   OLD_PROFILES_DIR   - legacy path for migration (default: ~/.qoder/.auth/profiles)

VAULT_DIR="${VAULT_DIR:-$HOME/.auth-vault/qoder}"
QODER_AUTH="${QODER_AUTH:-$HOME/.qoder/.auth/user}"
OLD_PROFILES_DIR="${OLD_PROFILES_DIR:-$HOME/.qoder/.auth/profiles}"

vault_ensure_dir() {
    mkdir -p "$VAULT_DIR"
}

vault_migrate() {
    if [[ -d "$OLD_PROFILES_DIR" ]]; then
        vault_ensure_dir
        if [[ -f "$OLD_PROFILES_DIR/.current" && ! -f "$VAULT_DIR/.current" ]]; then
            cp "$OLD_PROFILES_DIR/.current" "$VAULT_DIR/.current"
        fi
        for f in "$OLD_PROFILES_DIR"/*; do
            [[ -f "$f" ]] || continue
            local bn; bn=$(basename "$f")
            if [[ "$bn" == *.meta.json ]]; then continue; fi
            if [[ ! -f "$VAULT_DIR/$bn" ]]; then
                cp "$f" "$VAULT_DIR/$bn"
            fi
        done
    fi
}

vault_save() {
    local name="$1"
    local email="${2:-unknown}"

    if [[ ! -f "$QODER_AUTH" ]]; then
        return 1
    fi

    vault_ensure_dir
    cp "$QODER_AUTH" "$VAULT_DIR/$name"
    echo "$name" > "$VAULT_DIR/.current"

    local _lib_dir
    _lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    python3 "$_lib_dir/vault_backends.py" write-meta \
        --dir "$VAULT_DIR" \
        --name "$name" \
        --email "$email"
}

vault_use() {
    local name="$1"
    local profile="$VAULT_DIR/$name"

    if [[ ! -f "$profile" ]]; then
        return 1
    fi

    if [[ -f "$QODER_AUTH" ]]; then
        cp "$QODER_AUTH" "$QODER_AUTH.bak"
    fi

    cp "$profile" "$QODER_AUTH"
    echo "$name" > "$VAULT_DIR/.current"
}

vault_list_names() {
    vault_ensure_dir
    for f in "$VAULT_DIR"/*; do
        [[ -f "$f" ]] || continue
        local bn; bn=$(basename "$f")
        if [[ "$bn" == ".current" || "$bn" == *.meta.json ]]; then continue; fi
        echo "$bn"
    done
}

vault_get_current() {
    cat "$VAULT_DIR/.current" 2>/dev/null || echo ""
}

vault_get_email() {
    local name="$1"
    if [[ -f "$VAULT_DIR/${name}.meta.json" ]]; then
        jq -r '.email // "?"' "$VAULT_DIR/${name}.meta.json" 2>/dev/null
    else
        echo "?"
    fi
}

vault_delete() {
    local name="$1"

    if [[ ! -f "$VAULT_DIR/$name" ]]; then
        return 1
    fi

    rm -f "$VAULT_DIR/$name" "$VAULT_DIR/${name}.meta.json"
    if [[ "$(vault_get_current)" == "$name" ]]; then
        rm -f "$VAULT_DIR/.current"
    fi
}

vault_count() {
    vault_ensure_dir
    find "$VAULT_DIR" -maxdepth 1 -type f ! -name '.current' ! -name '*.meta.json' | wc -l
}
