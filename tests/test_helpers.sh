#!/bin/bash
# Minimal test framework for auth-vault integration tests

_TEST_PASS=0
_TEST_FAIL=0
_TEST_NAME=""
_TEST_FAILED=false
_RUN_OUTPUT=""
_RUN_STATUS=0

test_start() {
    _TEST_NAME="$1"
    _TEST_FAILED=false
}

test_end() {
    if [[ "$_TEST_FAILED" == "false" ]]; then
        _TEST_PASS=$(( _TEST_PASS + 1 ))
        printf '  \033[0;32m✓\033[0m %s\n' "$_TEST_NAME"
    else
        _TEST_FAIL=$(( _TEST_FAIL + 1 ))
    fi
}

run() {
    _RUN_OUTPUT=$( "$@" 2>&1 ) || true
    _RUN_STATUS=$?
}

_fail() {
    printf '  \033[0;31m✗\033[0m %s\n' "$_TEST_NAME"
    printf '    %s\n' "$1"
    _TEST_FAILED=true
}

assert_success() {
    if [[ $_RUN_STATUS -ne 0 ]]; then
        _fail "expected exit 0, got $_RUN_STATUS"
        if [[ -n "$_RUN_OUTPUT" ]]; then
            printf '    output: %s\n' "${_RUN_OUTPUT:0:200}"
        fi
    fi
}

assert_fail() {
    if [[ $_RUN_STATUS -eq 0 ]]; then
        _fail "expected non-zero exit, got 0"
    fi
}

assert_file_exists() {
    if [[ ! -f "$1" ]]; then
        _fail "file not found: $1"
    fi
}

assert_file_not_exists() {
    if [[ -f "$1" ]]; then
        _fail "file should not exist: $1"
    fi
}

assert_file_contains() {
    local file="$1" pattern="$2"
    if ! grep -q "$pattern" "$file" 2>/dev/null; then
        if [[ -f "$file" ]]; then
            _fail "file $file does not contain \"$pattern\" (content: $(cat "$file"))"
        else
            _fail "file does not exist: $file"
        fi
    fi
}

assert_output_contains() {
    local pattern="$1"
    if ! printf '%s' "$_RUN_OUTPUT" | grep -q "$pattern"; then
        _fail "output does not contain \"$pattern\""
        printf '    output: %s\n' "${_RUN_OUTPUT:0:300}"
    fi
}

assert_output_not_contains() {
    local pattern="$1"
    if printf '%s' "$_RUN_OUTPUT" | grep -q "$pattern"; then
        _fail "output should not contain \"$pattern\""
        printf '    output: %s\n' "${_RUN_OUTPUT:0:300}"
    fi
}

assert_equal() {
    local expected="$1" actual="$2"
    if [[ "$expected" != "$actual" ]]; then
        _fail "expected \"$expected\", got \"$actual\""
    fi
}

test_summary() {
    echo ""
    local total=$(( _TEST_PASS + _TEST_FAIL ))
    if [[ $_TEST_FAIL -eq 0 ]]; then
        printf '  \033[0;32m%d/%d tests passed\033[0m\n' "$_TEST_PASS" "$total"
        return 0
    else
        printf '  \033[0;31m%d/%d tests passed\033[0m, \033[0;31m%d failed\033[0m\n' \
            "$_TEST_PASS" "$total" "$_TEST_FAIL"
        return 1
    fi
}
