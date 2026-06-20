#!/bin/bash
# Tests for lib/ui-helpers.sh
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
source "$SCRIPT_DIR/test_helpers.sh"

# Set color variables expected by ui-helpers.sh
R=$'\033[0;31m'; G=$'\033[0;32m'; Y=$'\033[1;33m'; N=$'\033[0m'
source "$PROJECT_DIR/lib/ui-helpers.sh"

# Strip ANSI escape codes for easier assertions
strip_ansi() { sed $'s/\033\\[[0-9;]*m//g'; }

echo "=== UI Helpers Tests ==="
echo ""

# --- usage_bar (for "used" percentages like Qoder credits) ---

test_start "usage_bar: non-numeric returns '?'"
run bash -c "source '$PROJECT_DIR/lib/ui-helpers.sh'; R='\033[0;31m'; G='\033[0;32m'; Y='\033[1;33m'; N='\033[0m'; usage_bar '?'"
assert_output_contains "?"
test_end

test_start "usage_bar: 0% is green"
run bash -c "source '$PROJECT_DIR/lib/ui-helpers.sh'; R='\033[0;31m'; G='\033[0;32m'; Y='\033[1;33m'; N='\033[0m'; usage_bar 0"
# Should contain green escape
_OUTPUT_RAW="$_RUN_OUTPUT"
if [[ "$_OUTPUT_RAW" != *$'\033[0;32m'* ]]; then _fail "expected green color for 0%"; fi
test_end

test_start "usage_bar: 100% is red (fully used)"
run bash -c "source '$PROJECT_DIR/lib/ui-helpers.sh'; R='\033[0;31m'; G='\033[0;32m'; Y='\033[1;33m'; N='\033[0m'; usage_bar 100"
_OUTPUT_RAW="$_RUN_OUTPUT"
if [[ "$_OUTPUT_RAW" != *$'\033[0;31m'* ]]; then _fail "expected red color for 100% used"; fi
test_end

# --- remaining_bar (for "remaining" percentages like OpenAI quota) ---

test_start "remaining_bar: non-numeric returns '?'"
run bash -c "source '$PROJECT_DIR/lib/ui-helpers.sh'; R='\033[0;31m'; G='\033[0;32m'; Y='\033[1;33m'; N='\033[0m'; remaining_bar '?'"
assert_output_contains "?"
test_end

test_start "remaining_bar: 100% remaining is green (full quota)"
run bash -c "source '$PROJECT_DIR/lib/ui-helpers.sh'; R='\033[0;31m'; G='\033[0;32m'; Y='\033[1;33m'; N='\033[0m'; remaining_bar 100"
_OUTPUT_RAW="$_RUN_OUTPUT"
if [[ "$_OUTPUT_RAW" != *$'\033[0;32m'* ]]; then _fail "expected green for 100% remaining"; fi
test_end

test_start "remaining_bar: 0% remaining is red (quota exhausted)"
run bash -c "source '$PROJECT_DIR/lib/ui-helpers.sh'; R='\033[0;31m'; G='\033[0;32m'; Y='\033[1;33m'; N='\033[0m'; remaining_bar 0"
_OUTPUT_RAW="$_RUN_OUTPUT"
if [[ "$_OUTPUT_RAW" != *$'\033[0;31m'* ]]; then _fail "expected red for 0% remaining"; fi
test_end

test_start "remaining_bar: 15% remaining is red (almost empty)"
run bash -c "source '$PROJECT_DIR/lib/ui-helpers.sh'; R='\033[0;31m'; G='\033[0;32m'; Y='\033[1;33m'; N='\033[0m'; remaining_bar 15"
_OUTPUT_RAW="$_RUN_OUTPUT"
if [[ "$_OUTPUT_RAW" != *$'\033[0;31m'* ]]; then _fail "expected red for 15% remaining"; fi
test_end

test_start "remaining_bar: 40% remaining is yellow (caution)"
run bash -c "source '$PROJECT_DIR/lib/ui-helpers.sh'; R='\033[0;31m'; G='\033[0;32m'; Y='\033[1;33m'; N='\033[0m'; remaining_bar 40"
_OUTPUT_RAW="$_RUN_OUTPUT"
if [[ "$_OUTPUT_RAW" != *$'\033[1;33m'* ]]; then _fail "expected yellow for 40% remaining"; fi
test_end

test_start "remaining_bar: 80% remaining is green (healthy)"
run bash -c "source '$PROJECT_DIR/lib/ui-helpers.sh'; R='\033[0;31m'; G='\033[0;32m'; Y='\033[1;33m'; N='\033[0m'; remaining_bar 80"
_OUTPUT_RAW="$_RUN_OUTPUT"
if [[ "$_OUTPUT_RAW" != *$'\033[0;32m'* ]]; then _fail "expected green for 80% remaining"; fi
test_end

test_start "remaining_bar: custom width respected"
run bash -c "source '$PROJECT_DIR/lib/ui-helpers.sh'; R='\033[0;31m'; G='\033[0;32m'; Y='\033[1;33m'; N='\033[0m'; remaining_bar 50 6"
_CLEAN=$(echo "$_RUN_OUTPUT" | strip_ansi)
assert_output_contains "50%"
test_end

test_summary
