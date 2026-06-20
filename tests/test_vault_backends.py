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
