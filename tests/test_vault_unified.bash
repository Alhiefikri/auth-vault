#!/bin/bash
# Integration tests for unified Qoder CLI vault at ~/.auth-vault/qoder/
# Phase: RED
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$SCRIPT_DIR/test_helpers.sh"

# Override HOME to an isolated temp directory
TEST_HOME="$(mktemp -d)"
export HOME="$TEST_HOME"

SWAP="$REPO_ROOT/qoder-auth-swap"

cleanup() { rm -rf "$TEST_HOME"; }
trap cleanup EXIT

create_test_auth() {
    mkdir -p "$HOME/.qoder/.auth"
    printf '{"test":true,"access_token":"test-token","user":"test@example.com"}\n' \
        > "$HOME/.qoder/.auth/user"
}

echo ""
echo "=== Unified Vault Tests ==="
echo ""

# ── save ──────────────────────────────────────────────────────────────

test_start "qoder-auth-swap save writes to canonical vault path"
create_test_auth
run "$SWAP" save myprofile
assert_success
assert_file_exists "$HOME/.auth-vault/qoder/myprofile"
test_end

test_start "qoder-auth-swap save creates .meta.json"
create_test_auth
run "$SWAP" save meta-profile
assert_success
assert_file_exists "$HOME/.auth-vault/qoder/meta-profile.meta.json"
test_end

# ── use ───────────────────────────────────────────────────────────────

test_start "qoder-auth-swap use reads from canonical vault path"
mkdir -p "$HOME/.auth-vault/qoder"
printf '{"profile":"from-vault"}\n' > "$HOME/.auth-vault/qoder/vaultprofile"
echo "vaultprofile" > "$HOME/.auth-vault/qoder/.current"
run "$SWAP" use vaultprofile
assert_success
assert_file_contains "$HOME/.qoder/.auth/user" "from-vault"
test_end

test_start "qoder-auth-swap use updates .current in canonical vault"
mkdir -p "$HOME/.auth-vault/qoder"
printf '{"profile":"test"}\n' > "$HOME/.auth-vault/qoder/another"
run "$SWAP" use another
assert_success
assert_file_contains "$HOME/.auth-vault/qoder/.current" "another"
test_end

# ── list ──────────────────────────────────────────────────────────────

test_start "qoder-auth-swap list shows profiles from canonical vault"
mkdir -p "$HOME/.auth-vault/qoder"
printf '{"profile":"listtest"}\n' > "$HOME/.auth-vault/qoder/listtest"
run "$SWAP" list
assert_success
assert_output_contains "listtest"
test_end

test_start "qoder-auth-swap list excludes .meta.json entries"
mkdir -p "$HOME/.auth-vault/qoder"
printf '{"profile":"alice"}\n' > "$HOME/.auth-vault/qoder/alice"
printf '{"email":"a@b.com"}\n' > "$HOME/.auth-vault/qoder/alice.meta.json"
run "$SWAP" list
assert_success
assert_output_not_contains "alice.meta.json"
test_end

# ── delete ────────────────────────────────────────────────────────────

test_start "qoder-auth-swap delete removes from canonical vault"
mkdir -p "$HOME/.auth-vault/qoder"
printf '{"profile":"todelete"}\n' > "$HOME/.auth-vault/qoder/todelete"
printf '{"email":"del@test.com"}\n' > "$HOME/.auth-vault/qoder/todelete.meta.json"
echo "todelete" > "$HOME/.auth-vault/qoder/.current"
run "$SWAP" delete todelete
assert_success
assert_file_not_exists "$HOME/.auth-vault/qoder/todelete"
assert_file_not_exists "$HOME/.auth-vault/qoder/todelete.meta.json"
test_end

# ── cross-script consistency ──────────────────────────────────────────

test_start "auth-vault save is visible to qoder-auth-swap list"
mkdir -p "$HOME/.auth-vault/qoder"
printf '{"auth":"from-auth-vault"}\n' > "$HOME/.auth-vault/qoder/tui-profile"
printf '{"name":"tui-profile","email":"tui@test.com"}\n' \
    > "$HOME/.auth-vault/qoder/tui-profile.meta.json"
run "$SWAP" list
assert_success
assert_output_contains "tui-profile"
test_end

test_start "qoder-autologin save is visible to qoder-auth-swap list"
mkdir -p "$HOME/.auth-vault/qoder"
python3 -c "
import sys, os
sys.path.insert(0, '$REPO_ROOT')
import importlib
m = importlib.import_module('qoder-autologin')
os.makedirs('$HOME/.qoder/.auth', exist_ok=True)
with open('$HOME/.qoder/.auth/user', 'w') as f:
    f.write('{\"autologin\":true}\n')
m.save_to_vault('autoprofile', 'auto@test.com')
"
run "$SWAP" list
assert_success
assert_output_contains "autoprofile"
test_end

test_start "qoder-auth-swap save .meta.json has consistent format"
create_test_auth
run "$SWAP" save fmt-profile
assert_success
assert_file_exists "$HOME/.auth-vault/qoder/fmt-profile.meta.json"
run python3 -c "
import json, sys
with open('$HOME/.auth-vault/qoder/fmt-profile.meta.json') as f:
    m = json.load(f)
assert 'name' in m, 'missing name field'
assert 'email' in m, 'missing email field'
assert 'saved_at' in m, 'missing saved_at field'
assert m['name'] == 'fmt-profile', f'wrong name: {m[\"name\"]}'
"
assert_success
test_end

test_start "qoder-auth-swap save updates .current consistently"
create_test_auth
run "$SWAP" save cross-current
assert_success
assert_file_contains "$HOME/.auth-vault/qoder/.current" "cross-current"
test_end

# ── migration ─────────────────────────────────────────────────────────

# Clean vault state for migration tests (previous tests left artifacts)
rm -rf "$HOME/.auth-vault"

test_start "migration: profiles from old path moved to canonical vault"
mkdir -p "$HOME/.qoder/.auth/profiles"
printf '{"profile":"old-one"}\n' > "$HOME/.qoder/.auth/profiles/old-one"
printf '{"profile":"old-two"}\n' > "$HOME/.qoder/.auth/profiles/old-two"
echo "old-one" > "$HOME/.qoder/.auth/profiles/.current"
run "$SWAP" list
assert_success
assert_file_exists "$HOME/.auth-vault/qoder/old-one"
assert_file_exists "$HOME/.auth-vault/qoder/old-two"
test_end

test_start "migration: .current from old path migrated"
rm -rf "$HOME/.auth-vault"
rm -rf "$HOME/.qoder/.auth/profiles"
mkdir -p "$HOME/.qoder/.auth/profiles"
printf '{"profile":"mig-current"}\n' > "$HOME/.qoder/.auth/profiles/mig-current"
echo "mig-current" > "$HOME/.qoder/.auth/profiles/.current"
run "$SWAP" status
assert_success
assert_file_exists "$HOME/.auth-vault/qoder/.current"
assert_file_contains "$HOME/.auth-vault/qoder/.current" "mig-current"
test_end

# ── summary ───────────────────────────────────────────────────────────

test_summary
