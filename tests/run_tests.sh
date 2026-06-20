#!/bin/bash
# Run all auth-vault integration tests
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo ""
echo "=== Auth Vault Integration Tests ==="
echo ""

total_fail=0

for test_file in "$SCRIPT_DIR"/test_*.bash; do
    [[ -f "$test_file" ]] || continue
    name="$(basename "$test_file" .bash)"
    echo "--- $name ---"
    if bash "$test_file"; then
        :
    else
        total_fail=$(( total_fail + 1 ))
    fi
    echo ""
done

if [[ $total_fail -gt 0 ]]; then
    printf '\033[0;31m%d test file(s) had failures\033[0m\n' "$total_fail"
    exit 1
else
    printf '\033[0;32mAll test files passed\033[0m\n'
    exit 0
fi
