import json
import os
import sqlite3
import subprocess
import sys

SCRIPT = os.path.join(os.path.dirname(__file__), "..", "lib", "vault_backends.py")
OMP_SCHEMA = """
CREATE TABLE auth_credentials (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    provider TEXT,
    credential_type TEXT,
    data TEXT,
    identity_key TEXT,
    disabled_cause TEXT,
    created_at INTEGER,
    updated_at INTEGER
);
"""


def run_cmd(*args):
    result = subprocess.run(
        [sys.executable, SCRIPT, *args],
        capture_output=True, text=True,
    )
    return result


class TestWriteOmp:
    def test_writes_credential_row_to_empty_db(self, tmp_path):
        db = tmp_path / "creds.db"
        conn = sqlite3.connect(str(db))
        conn.executescript(OMP_SCHEMA)
        conn.close()

        result = run_cmd(
            "write-omp",
            "--db", str(db),
            "--access", "tok_access_123",
            "--refresh", "tok_refresh_456",
            "--expires", "1700000000",
            "--account-id", "acct_789",
            "--email", "user@example.com",
            "--replaced-by", "auth-vault",
        )

        assert result.returncode == 0

        conn = sqlite3.connect(str(db))
        conn.row_factory = sqlite3.Row
        rows = conn.execute(
            "SELECT * FROM auth_credentials WHERE disabled_cause IS NULL"
        ).fetchall()
        conn.close()

        assert len(rows) == 1
        row = rows[0]
        assert row["provider"] == "openai-codex"
        assert row["credential_type"] == "oauth"
        assert row["identity_key"] == "email:user@example.com"

        data = json.loads(row["data"])
        assert data["access"] == "tok_access_123"
        assert data["refresh"] == "tok_refresh_456"
        assert data["expires"] == 1700000000
        assert data["accountId"] == "acct_789"
        assert data["email"] == "user@example.com"

    def test_disables_existing_rows_before_insert(self, tmp_path):
        db = tmp_path / "creds.db"
        conn = sqlite3.connect(str(db))
        conn.executescript(OMP_SCHEMA)
        conn.execute(
            "INSERT INTO auth_credentials "
            "(provider, credential_type, data, identity_key, created_at, updated_at) "
            "VALUES ('openai-codex', 'oauth', '{}', 'email:old@test.com', 1000, 1000)"
        )
        conn.commit()
        conn.close()

        result = run_cmd(
            "write-omp",
            "--db", str(db),
            "--access", "new_access",
            "--refresh", "new_refresh",
            "--expires", "2000000000",
            "--account-id", "new_acct",
            "--email", "new@test.com",
            "--replaced-by", "sync-ai-auth",
        )

        assert result.returncode == 0

        conn = sqlite3.connect(str(db))
        conn.row_factory = sqlite3.Row
        old_rows = conn.execute(
            "SELECT * FROM auth_credentials WHERE disabled_cause IS NOT NULL"
        ).fetchall()
        active_rows = conn.execute(
            "SELECT * FROM auth_credentials WHERE disabled_cause IS NULL"
        ).fetchall()
        conn.close()

        assert len(old_rows) == 1
        assert old_rows[0]["disabled_cause"] == "replaced by sync-ai-auth"
        assert len(active_rows) == 1
        assert json.loads(active_rows[0]["data"])["access"] == "new_access"


class TestWritePi:
    def test_writes_openai_codex_to_new_file(self, tmp_path):
        auth_file = tmp_path / "auth.json"

        result = run_cmd(
            "write-pi",
            "--path", str(auth_file),
            "--access", "pi_access",
            "--refresh", "pi_refresh",
            "--expires", "3000000000",
            "--account-id", "pi_acct",
        )

        assert result.returncode == 0

        with open(auth_file) as f:
            data = json.load(f)

        assert "openai-codex" in data
        entry = data["openai-codex"]
        assert entry["type"] == "oauth"
        assert entry["access"] == "pi_access"
        assert entry["refresh"] == "pi_refresh"
        assert entry["expires"] == 3000000000
        assert entry["accountId"] == "pi_acct"

    def test_preserves_existing_keys(self, tmp_path):
        auth_file = tmp_path / "auth.json"
        existing = {
            "anthropic": {"type": "api-key", "key": "sk-ant-123"},
            "google": {"type": "oauth", "access": "goog_tok"},
        }
        auth_file.write_text(json.dumps(existing, indent=2) + "\n")

        result = run_cmd(
            "write-pi",
            "--path", str(auth_file),
            "--access", "new_pi_access",
            "--refresh", "new_pi_refresh",
            "--expires", "4000000000",
            "--account-id", "new_pi_acct",
        )

        assert result.returncode == 0

        with open(auth_file) as f:
            data = json.load(f)

        assert data["anthropic"] == {"type": "api-key", "key": "sk-ant-123"}
        assert data["google"] == {"type": "oauth", "access": "goog_tok"}
        assert data["openai-codex"]["access"] == "new_pi_access"


class TestWriteMeta:
    def test_writes_meta_json_with_correct_fields(self, tmp_path):
        result = run_cmd(
            "write-meta",
            "--dir", str(tmp_path),
            "--name", "my-profile",
            "--email", "me@example.com",
        )

        assert result.returncode == 0

        meta_file = tmp_path / "my-profile.meta.json"
        assert meta_file.exists()

        with open(meta_file) as f:
            data = json.load(f)

        assert data["name"] == "my-profile"
        assert data["email"] == "me@example.com"
        assert isinstance(data["saved_at"], int)
        assert data["saved_at"] > 0


class TestUpdateCockpitCurrent:
    def test_creates_nested_structure_in_new_file(self, tmp_path):
        cockpit_file = tmp_path / "current.json"

        result = run_cmd(
            "update-cockpit-current",
            "--path", str(cockpit_file),
            "--provider", "codex",
            "--account-id", "acct_abc",
        )

        assert result.returncode == 0

        with open(cockpit_file) as f:
            data = json.load(f)

        assert data["current_accounts"]["codex"] == "acct_abc"

    def test_preserves_other_providers(self, tmp_path):
        cockpit_file = tmp_path / "current.json"
        existing = {
            "current_accounts": {"qoder": "uid_xyz"},
            "other_key": "keep_me",
        }
        cockpit_file.write_text(json.dumps(existing, indent=2) + "\n")

        result = run_cmd(
            "update-cockpit-current",
            "--path", str(cockpit_file),
            "--provider", "codex",
            "--account-id", "acct_new",
        )

        assert result.returncode == 0

        with open(cockpit_file) as f:
            data = json.load(f)

        assert data["current_accounts"]["codex"] == "acct_new"
        assert data["current_accounts"]["qoder"] == "uid_xyz"
        assert data["other_key"] == "keep_me"


class TestWriteOpenaiVault:
    def test_writes_account_json_to_vault_dir(self, tmp_path):
        vault_dir = tmp_path / "openai"
        vault_dir.mkdir()

        result = run_cmd(
            "write-openai-vault",
            "--dir", str(vault_dir),
            "--name", "akun-utama",
            "--email", "user@example.com",
            "--access", "access_jwt_123",
            "--refresh", "refresh_tok_456",
            "--account-id", "acct_789",
        )

        assert result.returncode == 0

        account_file = vault_dir / "akun-utama.json"
        assert account_file.exists()

        with open(account_file) as f:
            data = json.load(f)

        assert data["email"] == "user@example.com"
        assert data["account_id"] == "acct_789"
        assert data["tokens"]["access_token"] == "access_jwt_123"
        assert data["tokens"]["refresh_token"] == "refresh_tok_456"
        assert isinstance(data["saved_at"], int)
        assert data["saved_at"] > 0

    def test_creates_vault_dir_if_missing(self, tmp_path):
        vault_dir = tmp_path / "new_vault"

        result = run_cmd(
            "write-openai-vault",
            "--dir", str(vault_dir),
            "--name", "test-acct",
            "--email", "test@test.com",
            "--access", "tok",
            "--refresh", "ref",
            "--account-id", "id1",
        )

        assert result.returncode == 0
        assert (vault_dir / "test-acct.json").exists()

    def test_overwrites_existing_account(self, tmp_path):
        vault_dir = tmp_path / "openai"
        vault_dir.mkdir()
        old = {"email": "old@test.com", "tokens": {"access_token": "old"}, "account_id": "old", "saved_at": 1}
        (vault_dir / "myacct.json").write_text(json.dumps(old))

        result = run_cmd(
            "write-openai-vault",
            "--dir", str(vault_dir),
            "--name", "myacct",
            "--email", "new@test.com",
            "--access", "new_tok",
            "--refresh", "new_ref",
            "--account-id", "new_id",
        )

        assert result.returncode == 0
        with open(vault_dir / "myacct.json") as f:
            data = json.load(f)
        assert data["email"] == "new@test.com"
        assert data["tokens"]["access_token"] == "new_tok"


class TestDeleteOpenai:
    def test_deletes_account_file(self, tmp_path):
        vault_dir = tmp_path / "openai"
        vault_dir.mkdir()
        acct = {"email": "del@test.com", "tokens": {"access_token": "x"}, "account_id": "x", "saved_at": 1}
        (vault_dir / "doomed.json").write_text(json.dumps(acct))

        result = run_cmd(
            "delete-openai",
            "--dir", str(vault_dir),
            "--name", "doomed",
        )

        assert result.returncode == 0
        assert not (vault_dir / "doomed.json").exists()

    def test_fails_when_account_not_found(self, tmp_path):
        vault_dir = tmp_path / "openai"
        vault_dir.mkdir()

        result = run_cmd(
            "delete-openai",
            "--dir", str(vault_dir),
            "--name", "nonexistent",
        )

        assert result.returncode != 0

    def test_clears_current_pointer_if_deleted_was_current(self, tmp_path):
        vault_dir = tmp_path / "openai"
        vault_dir.mkdir()
        acct = {"email": "cur@test.com", "tokens": {"access_token": "x"}, "account_id": "x", "saved_at": 1}
        (vault_dir / "current-acct.json").write_text(json.dumps(acct))
        (vault_dir / ".current").write_text("current-acct")

        result = run_cmd(
            "delete-openai",
            "--dir", str(vault_dir),
            "--name", "current-acct",
        )

        assert result.returncode == 0
        current_file = vault_dir / ".current"
        if current_file.exists():
            assert current_file.read_text().strip() != "current-acct"

    def test_preserves_other_accounts(self, tmp_path):
        vault_dir = tmp_path / "openai"
        vault_dir.mkdir()
        (vault_dir / "keep.json").write_text(json.dumps({"email": "keep@test.com"}))
        (vault_dir / "remove.json").write_text(json.dumps({"email": "rm@test.com"}))

        result = run_cmd(
            "delete-openai",
            "--dir", str(vault_dir),
            "--name", "remove",
        )

        assert result.returncode == 0
        assert (vault_dir / "keep.json").exists()
        assert not (vault_dir / "remove.json").exists()


class TestWriteOpenaiVaultExtra:
    def test_saved_at_is_recent_unix_timestamp(self, tmp_path):
        import time
        vault_dir = tmp_path / "openai"
        vault_dir.mkdir()

        before = int(time.time())
        result = run_cmd(
            "write-openai-vault",
            "--dir", str(vault_dir),
            "--name", "ts-acct",
            "--email", "ts@test.com",
            "--access", "tok",
            "--refresh", "ref",
            "--account-id", "id",
        )
        after = int(time.time())

        assert result.returncode == 0
        with open(vault_dir / "ts-acct.json") as f:
            data = json.load(f)
        assert before <= data["saved_at"] <= after

    def test_write_does_not_create_current_file(self, tmp_path):
        vault_dir = tmp_path / "openai"
        vault_dir.mkdir()

        run_cmd(
            "write-openai-vault",
            "--dir", str(vault_dir),
            "--name", "no-current",
            "--email", "nc@test.com",
            "--access", "tok",
            "--refresh", "ref",
            "--account-id", "id",
        )

        assert not (vault_dir / ".current").exists()

    def test_preserves_existing_files_in_dir(self, tmp_path):
        vault_dir = tmp_path / "openai"
        vault_dir.mkdir()
        readme = vault_dir / "README.txt"
        readme.write_text("keep me")

        run_cmd(
            "write-openai-vault",
            "--dir", str(vault_dir),
            "--name", "new-acct",
            "--email", "new@test.com",
            "--access", "tok",
            "--refresh", "ref",
            "--account-id", "id",
        )

        assert readme.exists()
        assert readme.read_text() == "keep me"

    def test_handles_special_chars_in_email(self, tmp_path):
        vault_dir = tmp_path / "openai"
        vault_dir.mkdir()

        result = run_cmd(
            "write-openai-vault",
            "--dir", str(vault_dir),
            "--name", "special",
            "--email", "user+tag@sub.domain.co.id",
            "--access", "tok",
            "--refresh", "ref",
            "--account-id", "id",
        )

        assert result.returncode == 0
        with open(vault_dir / "special.json") as f:
            data = json.load(f)
        assert data["email"] == "user+tag@sub.domain.co.id"

    def test_multiple_accounts_in_same_vault(self, tmp_path):
        vault_dir = tmp_path / "openai"
        vault_dir.mkdir()

        for name in ["alpha", "beta", "gamma"]:
            run_cmd(
                "write-openai-vault",
                "--dir", str(vault_dir),
                "--name", name,
                "--email", f"{name}@test.com",
                "--access", f"tok_{name}",
                "--refresh", f"ref_{name}",
                "--account-id", f"id_{name}",
            )

        files = sorted(f.name for f in vault_dir.iterdir() if f.suffix == ".json")
        assert files == ["alpha.json", "beta.json", "gamma.json"]

    def test_write_with_empty_token_strings(self, tmp_path):
        vault_dir = tmp_path / "openai"
        vault_dir.mkdir()

        result = run_cmd(
            "write-openai-vault",
            "--dir", str(vault_dir),
            "--name", "empty-tok",
            "--email", "e@test.com",
            "--access", "",
            "--refresh", "",
            "--account-id", "",
        )

        assert result.returncode == 0
        with open(vault_dir / "empty-tok.json") as f:
            data = json.load(f)
        assert data["tokens"]["access_token"] == ""
        assert data["tokens"]["refresh_token"] == ""


class TestDeleteOpenaiExtra:
    def test_delete_when_no_current_file_exists(self, tmp_path):
        vault_dir = tmp_path / "openai"
        vault_dir.mkdir()
        (vault_dir / "acct.json").write_text(json.dumps({"email": "a@test.com"}))

        result = run_cmd(
            "delete-openai",
            "--dir", str(vault_dir),
            "--name", "acct",
        )

        assert result.returncode == 0
        assert not (vault_dir / "acct.json").exists()
        assert not (vault_dir / ".current").exists()

    def test_delete_when_current_points_to_different_account(self, tmp_path):
        vault_dir = tmp_path / "openai"
        vault_dir.mkdir()
        (vault_dir / "other.json").write_text(json.dumps({"email": "o@test.com"}))
        (vault_dir / "target.json").write_text(json.dumps({"email": "t@test.com"}))
        (vault_dir / ".current").write_text("other")

        result = run_cmd(
            "delete-openai",
            "--dir", str(vault_dir),
            "--name", "target",
        )

        assert result.returncode == 0
        assert not (vault_dir / "target.json").exists()
        assert (vault_dir / ".current").exists()
        assert (vault_dir / ".current").read_text().strip() == "other"

    def test_delete_nonexistent_from_populated_vault(self, tmp_path):
        vault_dir = tmp_path / "openai"
        vault_dir.mkdir()
        (vault_dir / "existing.json").write_text(json.dumps({"email": "e@test.com"}))

        result = run_cmd(
            "delete-openai",
            "--dir", str(vault_dir),
            "--name", "nonexistent",
        )

        assert result.returncode != 0
        assert (vault_dir / "existing.json").exists()

    def test_delete_all_accounts_leaves_empty_dir(self, tmp_path):
        vault_dir = tmp_path / "openai"
        vault_dir.mkdir()
        (vault_dir / "a.json").write_text(json.dumps({"email": "a@t.com"}))
        (vault_dir / "b.json").write_text(json.dumps({"email": "b@t.com"}))

        run_cmd("delete-openai", "--dir", str(vault_dir), "--name", "a")
        result = run_cmd("delete-openai", "--dir", str(vault_dir), "--name", "b")

        assert result.returncode == 0
        json_files = list(vault_dir.glob("*.json"))
        assert len(json_files) == 0
