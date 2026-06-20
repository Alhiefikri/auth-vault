#!/bin/bash
# Shared account source readers for auth-vault scripts
# Requires: jwt-helpers.sh sourced, and path variables set by caller:
#   OPENCODE_AUTH, CODEX_AUTH, COCKPIT_CURRENT, COCKPIT_CODEX_ACCOUNTS
#
# Each function sets these globals on success and returns 0, or returns 1 on failure:
#   ACCESS_TOKEN, REFRESH_TOKEN, EXPIRES, ACCOUNT_ID, EMAIL, SOURCE

read_source_opencode() {
    if [[ ! -f "$OPENCODE_AUTH" ]]; then return 1; fi
    local openai_entry
    openai_entry=$(jq -r '.openai // empty' "$OPENCODE_AUTH" 2>/dev/null)
    if [[ -z "$openai_entry" || "$openai_entry" == "null" ]]; then return 1; fi

    ACCESS_TOKEN=$(jq -r '.openai.access' "$OPENCODE_AUTH")
    REFRESH_TOKEN=$(jq -r '.openai.refresh' "$OPENCODE_AUTH")
    EXPIRES=$(jq -r '.openai.expires' "$OPENCODE_AUTH")
    ACCOUNT_ID=$(jq -r '.openai.accountId // empty' "$OPENCODE_AUTH")
    EMAIL=$(jwt_email "$ACCESS_TOKEN")
    SOURCE="OpenCode"
    return 0
}

read_source_codex() {
    if [[ ! -f "$CODEX_AUTH" ]]; then return 1; fi
    local has_tokens
    has_tokens=$(jq -r '.tokens.access_token // empty' "$CODEX_AUTH" 2>/dev/null)
    if [[ -z "$has_tokens" ]]; then return 1; fi

    ACCESS_TOKEN=$(jq -r '.tokens.access_token' "$CODEX_AUTH")
    REFRESH_TOKEN=$(jq -r '.tokens.refresh_token' "$CODEX_AUTH")
    EXPIRES=$(jwt_exp_ms "$ACCESS_TOKEN")
    ACCOUNT_ID=$(jq -r '.tokens.account_id // empty' "$CODEX_AUTH")
    EMAIL=$(jwt_email "$ACCESS_TOKEN")
    SOURCE="Codex CLI"
    return 0
}

read_source_cockpit() {
    if [[ ! -f "$COCKPIT_CURRENT" ]]; then return 1; fi
    local current_codex_id
    current_codex_id=$(jq -r '.current_accounts.codex // empty' "$COCKPIT_CURRENT" 2>/dev/null)
    if [[ -z "$current_codex_id" ]]; then return 1; fi

    local account_file="$COCKPIT_CODEX_ACCOUNTS/${current_codex_id}.json"
    if [[ ! -f "$account_file" ]]; then
        return 1
    fi

    ACCESS_TOKEN=$(jq -r '.tokens.access_token' "$account_file")
    REFRESH_TOKEN=$(jq -r '.tokens.refresh_token' "$account_file")
    EXPIRES=$(jwt_exp_ms "$ACCESS_TOKEN")
    ACCOUNT_ID=$(jq -r '.account_id // empty' "$account_file")
    EMAIL=$(jq -r '.email // empty' "$account_file")
    if [[ -z "$EMAIL" ]]; then
        EMAIL=$(jwt_email "$ACCESS_TOKEN")
    fi
    SOURCE="Cockpit Tools"
    return 0
}
