#!/bin/bash
# Two strategies: PATH lookup for installed use, relative fallback for running from repo.

find_autologin() {
    local script_dir="${1:-$(dirname "$0")}"

    local path_result
    if path_result=$(command -v qoder-autologin 2>/dev/null) && [[ -n "$path_result" ]]; then
        echo "$path_result"
        return 0
    fi

    local candidate="$script_dir/qoder-autologin.py"
    if [[ -f "$candidate" ]]; then
        echo "python3 $candidate"
        return 0
    fi

    echo "qoder-autologin not found. Install by symlinking to ~/.local/bin/ or run from the repo directory." >&2
    return 1
}

run_autologin() {
    local script="$1"; shift
    if [[ "$script" == python3\ * ]]; then
        $script "$@"
    else
        "$script" "$@"
    fi
}
