#!/bin/bash
# lib/detect-email.sh - Detect the email for the current Qoder CLI auth
#
# Reads the real email from `qodercli status` (the active auth file),
# falling back to Cockpit Tools' current account tracking.
#
# Sourcing script must set:
#   COCKPIT_QODER_ACCOUNTS - path to cockpit qoder accounts dir

_detect_email() {
    local email=""
    if command -v qodercli &>/dev/null; then
        email=$(qodercli status 2>/dev/null | grep -i "^Email:" | head -1 | sed 's/^Email: *//')
    fi
    if [[ -n "$email" && "$email" != "unknown" ]]; then
        echo "$email"
        return
    fi
    email="unknown"
    local cockpit_current="$HOME/.antigravity_cockpit/provider_current_accounts.json"
    local qoder_accounts="${COCKPIT_QODER_ACCOUNTS:-$HOME/.antigravity_cockpit/qoder_accounts}"
    if [[ -f "$cockpit_current" ]]; then
        local qid
        qid=$(jq -r '.current_accounts.qoder // empty' "$cockpit_current" 2>/dev/null || true)
        if [[ -n "$qid" && -f "$qoder_accounts/${qid}.json" ]]; then
            email=$(jq -r '.email // "unknown"' "$qoder_accounts/${qid}.json" 2>/dev/null || echo "unknown")
        fi
    fi
    echo "$email"
}
