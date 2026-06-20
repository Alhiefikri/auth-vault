#!/bin/bash
# Shared JWT decoding helpers for auth-vault scripts
# Source this file: source "$SCRIPT_DIR/lib/jwt-helpers.sh"

jwt_decode() {
    local token="$1"
    local parts
    IFS='.' read -ra parts <<< "$token"
    [[ ${#parts[@]} -eq 3 ]] || return 0
    echo "${parts[1]}" | tr '_-' '/+' | base64 -d 2>/dev/null || true
}

jwt_claim() {
    local token="$1" claim="$2"
    local payload
    payload=$(jwt_decode "$token")
    [[ -z "$payload" ]] && { echo "?"; return; }
    [[ "$claim" == .* ]] || claim=".${claim}"
    echo "$payload" | jq -r "${claim} // \"?\"" 2>/dev/null || echo "?"
}

jwt_email() {
    local p
    p=$(jwt_decode "$1")
    [[ -z "$p" ]] && { echo "?"; return; }
    local result
    result=$(echo "$p" | jq -r '."https://api.openai.com/profile".email // "?"' 2>/dev/null) || result="?"
    echo "${result:-?}"
}

jwt_plan() {
    local p
    p=$(jwt_decode "$1")
    [[ -z "$p" ]] && { echo "?"; return; }
    local result
    result=$(echo "$p" | jq -r '."https://api.openai.com/auth".chatgpt_plan_type // "?"' 2>/dev/null) || result="?"
    echo "${result:-?}"
}

jwt_exp_days() {
    local p
    p=$(jwt_decode "$1")
    local exp
    exp=$(echo "$p" | jq -r '.exp // 0' 2>/dev/null)
    local now
    now=$(date +%s)
    if [[ "$exp" -gt "$now" ]]; then
        echo "$(( (exp - now) / 86400 ))d"
    else
        echo "expired"
    fi
}

jwt_exp_ms() {
    local p
    p=$(jwt_decode "$1")
    local exp
    exp=$(echo "$p" | jq -r '.exp // empty' 2>/dev/null)
    if [[ -n "$exp" ]]; then
        echo $(( exp * 1000 ))
    else
        echo "0"
    fi
}

jwt_info() {
    local token="$1"
    if [[ -z "$token" ]]; then
        echo "???|???|???"
        return
    fi
    local payload
    payload=$(jwt_decode "$token")
    if [[ -z "$payload" ]] || ! echo "$payload" | jq -e 'type == "object"' &>/dev/null; then
        echo "???|???|???"
        return
    fi
    local email plan exp now status
    email=$(echo "$payload" | jq -r '."https://api.openai.com/profile".email // "?"' 2>/dev/null)
    plan=$(echo "$payload" | jq -r '."https://api.openai.com/auth".chatgpt_plan_type // "?"' 2>/dev/null)
    exp=$(echo "$payload" | jq -r '.exp // 0' 2>/dev/null)
    now=$(date +%s)
    if [[ "$exp" -gt "$now" ]]; then
        local days_left=$(( (exp - now) / 86400 ))
        status="${days_left}d"
    else
        status="expired"
    fi
    echo "${email:-?}|${plan:-?}|${status}"
}
