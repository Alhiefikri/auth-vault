#!/bin/bash
# Shared UI helpers for auth-vault scripts
# Requires color variables R, G, Y, N to be set by the caller

usage_bar() {
    local pct="${1:-?}" width="${2:-10}"
    if ! [[ "$pct" =~ ^[0-9]+$ ]]; then echo "  ?"; return; fi
    local filled
    filled=$(( pct * width / 100 ))
    local empty
    empty=$(( width - filled ))
    local color="$G"
    [[ $pct -ge 60 ]] && color="$Y"
    [[ $pct -ge 85 ]] && color="$R"
    local bar=""
    for ((i=0; i<filled; i++)); do bar+="█"; done
    for ((i=0; i<empty; i++)); do bar+="░"; done
    echo -e "${color}${bar}${N} ${pct}%"
}

remaining_bar() {
    local pct="${1:-?}" width="${2:-10}"
    if ! [[ "$pct" =~ ^[0-9]+$ ]]; then echo "  ?"; return; fi
    local filled
    filled=$(( pct * width / 100 ))
    local empty
    empty=$(( width - filled ))
    local color="$R"
    [[ $pct -gt 15 ]] && color="$Y"
    [[ $pct -gt 40 ]] && color="$G"
    local bar=""
    for ((i=0; i<filled; i++)); do bar+="█"; done
    for ((i=0; i<empty; i++)); do bar+="░"; done
    echo -e "${color}${bar}${N} ${pct}%"
}

# Generate a horizontal line of N box-drawing characters (─)
# Handles UTF-8 byte-width correctly (─ is 3 bytes but 1 display column)
hline() {
    local count="${1:-10}"
    local char="${2:-}"
    [[ -z "$char" ]] && char="─"
    local result=""
    for ((i=0; i<count; i++)); do result+="$char"; done
    echo "$result"
}

# Pad a string (which may contain multi-byte UTF-8 characters) to a target display width.
# Usage: padright "text" 20
# Returns the text followed by spaces so display width = target.
padright() {
    local text="$1"
    local width="${2:-10}"
    local dw=${#text}
    if (( dw >= width )); then
        echo -n "$text"
        return
    fi
    local pad=$(( width - dw ))
    printf '%s%*s' "$text" "$pad" ""
}

reset_countdown() {
    local reset_ts="${1:-}"
    [[ -z "$reset_ts" || "$reset_ts" == "0" ]] && { echo "?"; return; }
    [[ "$reset_ts" =~ ^[0-9]+$ ]] || { echo "?"; return; }
    local now; now=$(date +%s)
    local diff=$(( reset_ts - now ))
    if (( diff <= 0 )); then
        echo "reset"
        return
    fi
    local days=$(( diff / 86400 ))
    local hours=$(( (diff % 86400) / 3600 ))
    local mins=$(( (diff % 3600) / 60 ))
    if (( days > 0 )); then
        echo "${days}d ${hours}h"
    elif (( hours > 0 )); then
        echo "${hours}h ${mins}m"
    else
        echo "${mins}m"
    fi
}

copy_to_clipboard() {
    local text="$1"
    if command -v pbcopy &>/dev/null; then
        echo -n "$text" | pbcopy
        return 0
    elif command -v xclip &>/dev/null; then
        echo -n "$text" | xclip -selection clipboard
        return 0
    elif command -v wl-copy &>/dev/null; then
        echo -n "$text" | wl-copy
        return 0
    elif command -v xsel &>/dev/null; then
        echo -n "$text" | xsel --clipboard --input
        return 0
    fi
    return 1
}
