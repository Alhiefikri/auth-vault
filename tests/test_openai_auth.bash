#!/bin/bash
# Tests for lib/openai-auth.sh — OpenAI vault CRUD
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/test_helpers.sh"

TEST_HOME="$(mktemp -d)"
export HOME="$TEST_HOME"
OPENAI_VAULT_DIR="$HOME/.auth-vault/openai"
trap 'rm -rf "$TEST_HOME"' EXIT

source "$PROJECT_DIR/lib/openai-auth.sh"

# === openai_vault_save ===

test_start "openai_vault_save: creates account JSON in vault dir"
openai_vault_save "akun-utama" "user@example.com" "access_jwt_123" "refresh_tok_456" "acct_789"
assert_file_exists "$OPENAI_VAULT_DIR/akun-utama.json"
assert_file_contains "$OPENAI_VAULT_DIR/akun-utama.json" '"email": "user@example.com"'
assert_file_contains "$OPENAI_VAULT_DIR/akun-utama.json" '"access_token": "access_jwt_123"'
assert_file_contains "$OPENAI_VAULT_DIR/akun-utama.json" '"refresh_token": "refresh_tok_456"'
assert_file_contains "$OPENAI_VAULT_DIR/akun-utama.json" '"account_id": "acct_789"'
test_end

test_start "openai_vault_save: creates vault dir if missing"
rm -rf "$OPENAI_VAULT_DIR"
openai_vault_save "test-acct" "test@test.com" "tok" "ref" "id1"
assert_file_exists "$OPENAI_VAULT_DIR/test-acct.json"
test_end

test_start "openai_vault_save: overwrites existing account"
openai_vault_save "test-acct" "old@test.com" "old_tok" "old_ref" "old_id"
openai_vault_save "test-acct" "new@test.com" "new_tok" "new_ref" "new_id"
assert_file_contains "$OPENAI_VAULT_DIR/test-acct.json" '"email": "new@test.com"'
assert_file_contains "$OPENAI_VAULT_DIR/test-acct.json" '"access_token": "new_tok"'
test_end

test_start "openai_vault_save: updates .current pointer"
openai_vault_save "my-acct" "me@test.com" "tok" "ref" "id"
local_current=$(cat "$OPENAI_VAULT_DIR/.current" 2>/dev/null)
assert_equal "my-acct" "$local_current"
test_end

# === openai_vault_delete ===

test_start "openai_vault_delete: removes account file"
openai_vault_save "doomed" "del@test.com" "tok" "ref" "id"
openai_vault_delete "doomed"
assert_file_not_exists "$OPENAI_VAULT_DIR/doomed.json"
test_end

test_start "openai_vault_delete: returns 1 when account not found"
rc=0
openai_vault_delete "nonexistent" || rc=$?
assert_equal "1" "$rc"
test_end

test_start "openai_vault_delete: clears .current if deleted was current"
openai_vault_save "cur-acct" "cur@test.com" "tok" "ref" "id"
openai_vault_delete "cur-acct"
if [[ -f "$OPENAI_VAULT_DIR/.current" ]]; then
    current_val=$(cat "$OPENAI_VAULT_DIR/.current")
    if [[ "$current_val" == "cur-acct" ]]; then
        _fail ".current should not point to deleted account"
    fi
fi
test_end

test_start "openai_vault_delete: preserves other accounts"
openai_vault_save "keep-me" "keep@test.com" "tok" "ref" "id"
openai_vault_save "remove-me" "rm@test.com" "tok" "ref" "id"
openai_vault_delete "remove-me"
assert_file_exists "$OPENAI_VAULT_DIR/keep-me.json"
assert_file_not_exists "$OPENAI_VAULT_DIR/remove-me.json"
test_end

# === openai_vault_list ===

test_start "openai_vault_list: lists all account names"
rm -rf "$OPENAI_VAULT_DIR"
openai_vault_save "alpha" "a@test.com" "tok" "ref" "id"
openai_vault_save "beta" "b@test.com" "tok" "ref" "id"
openai_vault_save "gamma" "c@test.com" "tok" "ref" "id"
output=$(openai_vault_list)
echo "$output" | grep -q "alpha" || _fail "missing alpha in list"
echo "$output" | grep -q "beta" || _fail "missing beta in list"
echo "$output" | grep -q "gamma" || _fail "missing gamma in list"
test_end

test_start "openai_vault_list: returns empty for empty vault"
rm -rf "$OPENAI_VAULT_DIR"
output=$(openai_vault_list)
assert_equal "" "$output"
test_end

# === openai_vault_count ===

test_start "openai_vault_count: counts accounts correctly"
rm -rf "$OPENAI_VAULT_DIR"
openai_vault_save "a" "a@test.com" "tok" "ref" "id"
openai_vault_save "b" "b@test.com" "tok" "ref" "id"
openai_vault_save "c" "c@test.com" "tok" "ref" "id"
count=$(openai_vault_count)
assert_equal "3" "$count"
test_end

test_start "openai_vault_count: returns 0 for empty vault"
rm -rf "$OPENAI_VAULT_DIR"
count=$(openai_vault_count)
assert_equal "0" "$count"
test_end

# === openai_vault_get ===

test_start "openai_vault_get: returns account email"
rm -rf "$OPENAI_VAULT_DIR"
openai_vault_save "myacct" "my@test.com" "my_access" "my_refresh" "my_id"
email=$(openai_vault_get "myacct" "email")
assert_equal "my@test.com" "$email"
test_end

test_start "openai_vault_get: returns access_token"
token=$(openai_vault_get "myacct" "access_token")
assert_equal "my_access" "$token"
test_end

test_start "openai_vault_get: returns empty for nonexistent account"
result=$(openai_vault_get "nope" "email")
assert_equal "" "$result"
test_end

# === openai_vault_get_current ===

test_start "openai_vault_get_current: returns current account name"
rm -rf "$OPENAI_VAULT_DIR"
openai_vault_save "first" "f@test.com" "tok" "ref" "id"
openai_vault_save "second" "s@test.com" "tok" "ref" "id"
current=$(openai_vault_get_current)
assert_equal "second" "$current"
test_end

test_start "openai_vault_get_current: returns empty when no current"
rm -rf "$OPENAI_VAULT_DIR"
mkdir -p "$OPENAI_VAULT_DIR"
current=$(openai_vault_get_current)
assert_equal "" "$current"
test_end

# === Additional edge-case scenarios ===

test_start "openai_vault_get: returns refresh_token field"
rm -rf "$OPENAI_VAULT_DIR"
openai_vault_save "tok-acct" "tok@test.com" "acc_tk" "ref_tk_999" "acct_x"
ref=$(openai_vault_get "tok-acct" "refresh_token")
assert_equal "ref_tk_999" "$ref"
test_end

test_start "openai_vault_get: returns account_id field"
aid=$(openai_vault_get "tok-acct" "account_id")
assert_equal "acct_x" "$aid"
test_end

test_start "openai_vault_get: returns empty for unknown field"
result=$(openai_vault_get "tok-acct" "nonexistent_field")
assert_equal "" "$result"
test_end

test_start "openai_vault_save: .current tracks latest save"
rm -rf "$OPENAI_VAULT_DIR"
openai_vault_save "first" "f@test.com" "t" "r" "i"
openai_vault_save "second" "s@test.com" "t" "r" "i"
openai_vault_save "third" "t@test.com" "t" "r" "i"
current=$(openai_vault_get_current)
assert_equal "third" "$current"
test_end

test_start "openai_vault_delete: does not clear .current when deleting non-current"
rm -rf "$OPENAI_VAULT_DIR"
openai_vault_save "keep-current" "kc@test.com" "t" "r" "i"
openai_vault_save "other" "o@test.com" "t" "r" "i"
# .current points to "other" (last saved)
openai_vault_delete "keep-current"
current=$(openai_vault_get_current)
assert_equal "other" "$current"
test_end

test_start "openai_vault_save: handles special chars in email"
rm -rf "$OPENAI_VAULT_DIR"
openai_vault_save "special" "user+tag@sub.domain.co.id" "tok" "ref" "id"
email=$(openai_vault_get "special" "email")
assert_equal "user+tag@sub.domain.co.id" "$email"
test_end

test_start "openai_vault_save: handles dashes and underscores in name"
rm -rf "$OPENAI_VAULT_DIR"
openai_vault_save "my-cool_account" "x@test.com" "tok" "ref" "id"
assert_file_exists "$OPENAI_VAULT_DIR/my-cool_account.json"
name_list=$(openai_vault_list)
echo "$name_list" | grep -q "my-cool_account" || _fail "missing my-cool_account in list"
test_end

test_start "openai_vault_count: reflects add and delete sequence"
rm -rf "$OPENAI_VAULT_DIR"
openai_vault_save "a" "a@t.com" "t" "r" "i"
openai_vault_save "b" "b@t.com" "t" "r" "i"
openai_vault_save "c" "c@t.com" "t" "r" "i"
openai_vault_delete "b"
count=$(openai_vault_count)
assert_equal "2" "$count"
test_end

test_start "openai_vault_list: single account returns exactly one line"
rm -rf "$OPENAI_VAULT_DIR"
openai_vault_save "only-one" "o@t.com" "t" "r" "i"
output=$(openai_vault_list)
line_count=$(echo "$output" | wc -l)
assert_equal "1" "$line_count"
assert_equal "only-one" "$output"
test_end

test_start "openai_vault_save: JSON has saved_at timestamp"
rm -rf "$OPENAI_VAULT_DIR"
openai_vault_save "ts-acct" "ts@t.com" "t" "r" "i"
saved_at=$(jq -r '.saved_at // empty' "$OPENAI_VAULT_DIR/ts-acct.json" 2>/dev/null)
[[ -n "$saved_at" ]] || _fail "saved_at is missing"
[[ "$saved_at" -gt 0 ]] || _fail "saved_at is not a positive integer"
test_end

test_start "openai_vault_save: overwrite produces new saved_at"
rm -rf "$OPENAI_VAULT_DIR"
openai_vault_save "ow-acct" "old@t.com" "old" "old" "old"
saved1=$(jq -r '.saved_at' "$OPENAI_VAULT_DIR/ow-acct.json")
sleep 1
openai_vault_save "ow-acct" "new@t.com" "new" "new" "new"
saved2=$(jq -r '.saved_at' "$OPENAI_VAULT_DIR/ow-acct.json")
[[ "$saved2" -ge "$saved1" ]] || _fail "saved_at should not decrease after overwrite"
test_end

test_start "openai_vault_get_current: stale .current after external delete"
rm -rf "$OPENAI_VAULT_DIR"
openai_vault_save "stale-acct" "s@t.com" "t" "r" "i"
# Manually remove JSON without going through openai_vault_delete
rm -f "$OPENAI_VAULT_DIR/stale-acct.json"
current=$(openai_vault_get_current)
assert_equal "stale-acct" "$current"
test_end

test_start "openai_vault_delete: all accounts deleted yields empty list and count 0"
rm -rf "$OPENAI_VAULT_DIR"
openai_vault_save "x" "x@t.com" "t" "r" "i"
openai_vault_save "y" "y@t.com" "t" "r" "i"
openai_vault_delete "x"
openai_vault_delete "y"
count=$(openai_vault_count)
assert_equal "0" "$count"
output=$(openai_vault_list)
assert_equal "" "$output"
test_end

test_summary
