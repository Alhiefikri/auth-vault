#!/bin/bash
# Tests for lib/find-autologin.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/test_helpers.sh"
source "$PROJECT_DIR/lib/find-autologin.sh"

TEST_HOME=$(mktemp -d)
trap 'rm -rf "$TEST_HOME"' EXIT

# === find_autologin ===

test_start "find_autologin: finds qoder-autologin via PATH (command -v)"
mkdir -p "$TEST_HOME/bin"
printf '#!/bin/bash\necho "from-path"\n' > "$TEST_HOME/bin/qoder-autologin"
chmod +x "$TEST_HOME/bin/qoder-autologin"
result=$(PATH="$TEST_HOME/bin:/usr/bin:/bin" find_autologin "$TEST_HOME/repo")
status=$?
assert_equal "0" "$status"
assert_equal "$TEST_HOME/bin/qoder-autologin" "$result"
test_end

test_start "find_autologin: falls back to relative path when not on PATH"
mkdir -p "$TEST_HOME/repo"
printf '# placeholder\n' > "$TEST_HOME/repo/qoder-autologin.py"
result=$(PATH="/usr/bin:/bin" find_autologin "$TEST_HOME/repo")
status=$?
assert_equal "0" "$status"
assert_equal "python3 $TEST_HOME/repo/qoder-autologin.py" "$result"
test_end

test_start "find_autologin: returns 1 with clear error when not found"
mkdir -p "$TEST_HOME/empty"
_RUN_OUTPUT=$(PATH="/usr/bin:/bin" find_autologin "$TEST_HOME/empty" 2>&1) && _RUN_STATUS=0 || _RUN_STATUS=$?
assert_equal "1" "$_RUN_STATUS"
assert_output_contains "qoder-autologin not found"
test_end

test_summary
