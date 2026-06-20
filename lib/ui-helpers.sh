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
