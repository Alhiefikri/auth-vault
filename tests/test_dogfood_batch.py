"""
Dogfooding tests for batch (bulk add) account logic.

Exercises the full batch pipeline without real Google accounts:
- File parsing edge cases
- Profile name generation edge cases
- run_batch concurrency, error handling, temp dir cleanup
- CLI batch subcommand end-to-end via main()
- print_summary edge cases
"""

import asyncio
import importlib
import os
import shutil
import tempfile
from pathlib import Path
from unittest import mock

import pytest


def _import_autologin():
    spec = importlib.util.spec_from_file_location(
        "qoder_autologin",
        os.path.join(os.path.dirname(__file__), "..", "qoder-autologin.py"),
    )
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


@pytest.fixture
def autologin():
    return _import_autologin()


# ── parse_accounts_file edge cases ────────────────────────────────────────

class TestDogfoodParseAccountsFile:
    """Thorough parsing tests beyond the basics."""

    def test_password_with_colons(self, autologin, tmp_path):
        """Password containing colons is preserved (split on first colon only)."""
        f = tmp_path / "accounts.txt"
        f.write_text("user@test.com:my:complex:pass:word\n")
        accounts = autologin.parse_accounts_file(str(f))
        assert len(accounts) == 1
        assert accounts[0]["email"] == "user@test.com"
        assert accounts[0]["password"] == "my:complex:pass:word"

    def test_whitespace_around_email_and_password(self, autologin, tmp_path):
        """Leading/trailing whitespace on email and password is stripped."""
        f = tmp_path / "accounts.txt"
        f.write_text("  user@test.com  :  password123  \n")
        accounts = autologin.parse_accounts_file(str(f))
        assert accounts[0]["email"] == "user@test.com"
        assert accounts[0]["password"] == "password123"

    def test_empty_file_returns_empty(self, autologin, tmp_path):
        """A completely empty file returns no accounts."""
        f = tmp_path / "accounts.txt"
        f.write_text("")
        accounts = autologin.parse_accounts_file(str(f))
        assert accounts == []

    def test_only_comments_and_blanks(self, autologin, tmp_path):
        """File with only comments and blank lines returns no accounts."""
        f = tmp_path / "accounts.txt"
        f.write_text("# comment1\n\n# comment2\n\n\n")
        accounts = autologin.parse_accounts_file(str(f))
        assert accounts == []

    def test_all_malformed_lines(self, autologin, tmp_path):
        """File with only malformed lines returns no accounts."""
        f = tmp_path / "accounts.txt"
        f.write_text("no-colon\nalso-no-colon\nstillbad\n")
        accounts = autologin.parse_accounts_file(str(f))
        assert accounts == []

    def test_mixed_valid_invalid_comments_blanks(self, autologin, tmp_path):
        """Mixed content: valid, invalid, comments, blanks all handled."""
        f = tmp_path / "accounts.txt"
        f.write_text(
            "# Header comment\n"
            "\n"
            "user1@a.com:pass1\n"
            "invalid-line\n"
            "# Another comment\n"
            "user2@b.com:pass2\n"
            "\n"
            "also-bad\n"
            "user3@c.com:pass3\n"
        )
        accounts = autologin.parse_accounts_file(str(f))
        assert len(accounts) == 3
        assert accounts[0]["email"] == "user1@a.com"
        assert accounts[1]["email"] == "user2@b.com"
        assert accounts[2]["email"] == "user3@c.com"

    def test_email_without_domain(self, autologin, tmp_path):
        """Email without @ is still accepted (parsing doesn't validate email format)."""
        f = tmp_path / "accounts.txt"
        f.write_text("justname:password\n")
        accounts = autologin.parse_accounts_file(str(f))
        assert len(accounts) == 1
        assert accounts[0]["email"] == "justname"
        assert accounts[0]["password"] == "password"

    def test_empty_password(self, autologin, tmp_path):
        """Empty password (line ending with colon) is accepted."""
        f = tmp_path / "accounts.txt"
        f.write_text("user@test.com:\n")
        accounts = autologin.parse_accounts_file(str(f))
        assert len(accounts) == 1
        assert accounts[0]["email"] == "user@test.com"
        assert accounts[0]["password"] == ""

    def test_empty_email_with_password(self, autologin, tmp_path):
        """Empty email with password is accepted (just a colon + password)."""
        f = tmp_path / "accounts.txt"
        f.write_text(":password123\n")
        accounts = autologin.parse_accounts_file(str(f))
        assert len(accounts) == 1
        assert accounts[0]["email"] == ""
        assert accounts[0]["password"] == "password123"

    def test_unicode_content(self, autologin, tmp_path):
        """Unicode characters in email/password are handled."""
        f = tmp_path / "accounts.txt"
        f.write_text("user@t\u00e9st.com:p\u00e4ssw\u00f6rd\n")
        accounts = autologin.parse_accounts_file(str(f))
        assert len(accounts) == 1
        assert accounts[0]["email"] == "user@t\u00e9st.com"
        assert accounts[0]["password"] == "p\u00e4ssw\u00f6rd"

    def test_large_file(self, autologin, tmp_path):
        """Parsing 500 accounts works correctly."""
        f = tmp_path / "accounts.txt"
        lines = [f"user{i}@test.com:pass{i}\n" for i in range(500)]
        f.write_text("".join(lines))
        accounts = autologin.parse_accounts_file(str(f))
        assert len(accounts) == 500
        assert accounts[0]["email"] == "user0@test.com"
        assert accounts[499]["email"] == "user499@test.com"

    def test_tab_separated_whitespace(self, autologin, tmp_path):
        """Tabs around fields are stripped (strip() handles all whitespace)."""
        f = tmp_path / "accounts.txt"
        f.write_text("\tuser@test.com\t:\tpassword\t\n")
        accounts = autologin.parse_accounts_file(str(f))
        assert accounts[0]["email"] == "user@test.com"
        assert accounts[0]["password"] == "password"

    def test_windows_line_endings(self, autologin, tmp_path):
        """Windows-style \\r\\n line endings are handled."""
        f = tmp_path / "accounts.txt"
        f.write_text("user1@a.com:pass1\r\nuser2@b.com:pass2\r\n")
        accounts = autologin.parse_accounts_file(str(f))
        assert len(accounts) == 2
        assert accounts[0]["password"] == "pass1"
        assert accounts[1]["password"] == "pass2"


# ── _generate_unique_profiles edge cases ──────────────────────────────────

class TestDogfoodGenerateUniqueProfiles:
    """Profile name generation edge cases."""

    def test_dots_replaced_with_hyphens(self, autologin):
        """Dots in email local part become hyphens in profile name."""
        accounts = [{"email": "john.doe@test.com", "password": "p"}]
        profiles = autologin._generate_unique_profiles(accounts)
        assert profiles == ["john-doe"]

    def test_multiple_dots(self, autologin):
        """Multiple dots are all replaced."""
        accounts = [{"email": "a.b.c.d@test.com", "password": "p"}]
        profiles = autologin._generate_unique_profiles(accounts)
        assert profiles == ["a-b-c-d"]

    def test_dot_collision_with_hyphen(self, autologin):
        """john.doe and john-doe produce a collision -> suffix applied."""
        accounts = [
            {"email": "john.doe@a.com", "password": "p"},
            {"email": "john-doe@b.com", "password": "p"},
        ]
        profiles = autologin._generate_unique_profiles(accounts)
        assert profiles[0] == "john-doe"
        assert profiles[1] == "john-doe-2"

    def test_five_collisions(self, autologin):
        """Five accounts with same local part get correct suffixes."""
        accounts = [{"email": f"x@domain{i}.com", "password": "p"} for i in range(5)]
        profiles = autologin._generate_unique_profiles(accounts)
        assert profiles == ["x", "x-2", "x-3", "x-4", "x-5"]

    def test_empty_local_part_produces_unknown(self, autologin):
        """Email starting with @ produces 'unknown' profile."""
        accounts = [{"email": "@gmail.com", "password": "p"}]
        profiles = autologin._generate_unique_profiles(accounts)
        assert profiles == ["unknown"]

    def test_multiple_empty_local_parts(self, autologin):
        """Multiple @-only emails get unique 'unknown' variants."""
        accounts = [
            {"email": "@a.com", "password": "p"},
            {"email": "@b.com", "password": "p"},
        ]
        profiles = autologin._generate_unique_profiles(accounts)
        assert profiles == ["unknown", "unknown-2"]

    def test_no_accounts_returns_empty(self, autologin):
        """Empty accounts list returns empty profiles list."""
        profiles = autologin._generate_unique_profiles([])
        assert profiles == []

    def test_single_account_no_collision(self, autologin):
        """Single account has no suffix."""
        accounts = [{"email": "solo@test.com", "password": "p"}]
        profiles = autologin._generate_unique_profiles(accounts)
        assert profiles == ["solo"]

    def test_mixed_collisions_and_uniques(self, autologin):
        """Mix of colliding and unique names."""
        accounts = [
            {"email": "alice@a.com", "password": "p"},
            {"email": "bob@b.com", "password": "p"},
            {"email": "alice@c.com", "password": "p"},
            {"email": "charlie@d.com", "password": "p"},
            {"email": "alice@e.com", "password": "p"},
        ]
        profiles = autologin._generate_unique_profiles(accounts)
        assert profiles == ["alice", "bob", "alice-2", "charlie", "alice-3"]

    def test_all_unique_preserves_order(self, autologin):
        """All unique names preserve input order."""
        accounts = [
            {"email": "z@t.com", "password": "p"},
            {"email": "a@t.com", "password": "p"},
            {"email": "m@t.com", "password": "p"},
        ]
        profiles = autologin._generate_unique_profiles(accounts)
        assert profiles == ["z", "a", "m"]


# ── run_batch end-to-end ─────────────────────────────────────────────────

class TestDogfoodRunBatch:
    """End-to-end tests for run_batch with mocked login_account."""

    def _mock_login_success(self, autologin):
        """Return a mock that simulates successful login."""
        async def mock_login(email, password, profile_name=None, save=True,
                             auth_file_override=None):
            return {
                "email": email, "success": True, "profile": profile_name,
                "error": None, "duration": 0.1,
            }
        return mock_login

    def _mock_login_failure(self, autologin):
        """Return a mock that simulates failed login."""
        async def mock_login(email, password, profile_name=None, save=True,
                             auth_file_override=None):
            return {
                "email": email, "success": False, "profile": profile_name,
                "error": "auth_file_not_updated", "duration": 0.1,
            }
        return mock_login

    def test_batch_all_success(self, autologin):
        """All accounts succeed -> all results have success=True."""
        accounts = [
            {"email": f"user{i}@test.com", "password": f"pass{i}"}
            for i in range(5)
        ]
        with mock.patch.object(autologin, "login_account",
                               side_effect=self._mock_login_success(autologin)):
            results = asyncio.run(autologin.run_batch(accounts))

        assert len(results) == 5
        assert all(r["success"] for r in results)

    def test_batch_all_failure(self, autologin):
        """All accounts fail -> all results have success=False."""
        accounts = [
            {"email": f"user{i}@test.com", "password": f"pass{i}"}
            for i in range(3)
        ]
        with mock.patch.object(autologin, "login_account",
                               side_effect=self._mock_login_failure(autologin)):
            results = asyncio.run(autologin.run_batch(accounts))

        assert len(results) == 3
        assert all(not r["success"] for r in results)

    def test_batch_mixed_results(self, autologin):
        """Some succeed, some fail."""
        call_count = {"n": 0}

        async def mixed_login(email, password, profile_name=None, save=True,
                              auth_file_override=None):
            call_count["n"] += 1
            success = call_count["n"] % 2 == 1
            return {
                "email": email, "success": success, "profile": profile_name,
                "error": None if success else "fail",
                "duration": 0.1,
            }

        accounts = [
            {"email": f"user{i}@test.com", "password": "p"}
            for i in range(4)
        ]
        with mock.patch.object(autologin, "login_account", side_effect=mixed_login):
            results = asyncio.run(autologin.run_batch(accounts))

        successes = [r for r in results if r["success"]]
        failures = [r for r in results if not r["success"]]
        assert len(successes) == 2
        assert len(failures) == 2

    def test_batch_profiles_match_accounts(self, autologin):
        """Each result gets the correct profile name."""
        captured = []

        async def capture_login(email, password, profile_name=None, save=True,
                                auth_file_override=None):
            captured.append((email, profile_name))
            return {
                "email": email, "success": True, "profile": profile_name,
                "error": None, "duration": 0.1,
            }

        accounts = [
            {"email": "alice@a.com", "password": "p"},
            {"email": "bob@b.com", "password": "p"},
            {"email": "alice@c.com", "password": "p"},
        ]
        with mock.patch.object(autologin, "login_account", side_effect=capture_login):
            results = asyncio.run(autologin.run_batch(accounts))

        assert captured[0] == ("alice@a.com", "alice")
        assert captured[1] == ("bob@b.com", "bob")
        assert captured[2] == ("alice@c.com", "alice-2")

    def test_batch_concurrent_creates_isolated_dirs(self, autologin):
        """With concurrent>1, each login gets a unique temp auth file."""
        auth_files = []

        async def capture_login(email, password, profile_name=None, save=True,
                                auth_file_override=None):
            auth_files.append(auth_file_override)
            return {
                "email": email, "success": True, "profile": profile_name,
                "error": None, "duration": 0.1,
            }

        accounts = [
            {"email": f"user{i}@test.com", "password": "p"}
            for i in range(3)
        ]
        with mock.patch.object(autologin, "login_account", side_effect=capture_login):
            asyncio.run(autologin.run_batch(accounts, concurrent=3))

        assert len(auth_files) == 3
        assert all(f is not None for f in auth_files)
        assert len(set(auth_files)) == 3

    def test_batch_concurrent_temp_dirs_cleaned_up(self, autologin):
        """Temp directories created during concurrent batch are cleaned up."""
        created_dirs = []

        original_mkdtemp = tempfile.mkdtemp

        def tracking_mkdtemp(*args, **kwargs):
            d = original_mkdtemp(*args, **kwargs)
            created_dirs.append(d)
            return d

        async def mock_login(email, password, profile_name=None, save=True,
                             auth_file_override=None):
            return {
                "email": email, "success": True, "profile": profile_name,
                "error": None, "duration": 0.1,
            }

        accounts = [
            {"email": f"user{i}@test.com", "password": "p"}
            for i in range(2)
        ]
        with mock.patch.object(autologin, "login_account", side_effect=mock_login), \
             mock.patch("tempfile.mkdtemp", side_effect=tracking_mkdtemp):
            asyncio.run(autologin.run_batch(accounts, concurrent=2))

        for d in created_dirs:
            assert not os.path.exists(d), f"Temp dir {d} was not cleaned up"

    def test_batch_sequential_no_temp_dirs(self, autologin):
        """With concurrent=1, no temp directories are created."""
        auth_files = []

        async def capture_login(email, password, profile_name=None, save=True,
                                auth_file_override=None):
            auth_files.append(auth_file_override)
            return {
                "email": email, "success": True, "profile": profile_name,
                "error": None, "duration": 0.1,
            }

        accounts = [{"email": "user@test.com", "password": "p"}]
        with mock.patch.object(autologin, "login_account", side_effect=capture_login):
            asyncio.run(autologin.run_batch(accounts, concurrent=1))

        assert auth_files == [None]

    def test_batch_no_save_propagates(self, autologin):
        """no_save=True makes save=False reach login_account."""
        save_values = []

        async def capture_login(email, password, profile_name=None, save=True,
                                auth_file_override=None):
            save_values.append(save)
            return {
                "email": email, "success": True, "profile": profile_name,
                "error": None, "duration": 0.1,
            }

        accounts = [
            {"email": f"user{i}@test.com", "password": "p"}
            for i in range(3)
        ]
        with mock.patch.object(autologin, "login_account", side_effect=capture_login):
            asyncio.run(autologin.run_batch(accounts, no_save=True))

        assert save_values == [False, False, False]

    def test_batch_save_default_is_true(self, autologin):
        """Default no_save=False means save=True reaches login_account."""
        save_values = []

        async def capture_login(email, password, profile_name=None, save=True,
                                auth_file_override=None):
            save_values.append(save)
            return {
                "email": email, "success": True, "profile": profile_name,
                "error": None, "duration": 0.1,
            }

        accounts = [{"email": "user@test.com", "password": "p"}]
        with mock.patch.object(autologin, "login_account", side_effect=capture_login):
            asyncio.run(autologin.run_batch(accounts))

        assert save_values == [True]

    def test_batch_empty_accounts(self, autologin):
        """Empty accounts list returns empty results without error."""
        with mock.patch.object(autologin, "login_account",
                               side_effect=self._mock_login_success(autologin)):
            results = asyncio.run(autologin.run_batch([]))
        assert results == []

    def test_batch_exception_in_login_propagates(self, autologin):
        """If login_account raises, the exception propagates through gather."""
        async def failing_login(email, password, profile_name=None, save=True,
                                auth_file_override=None):
            raise RuntimeError("simulated crash")

        accounts = [{"email": "user@test.com", "password": "p"}]
        with mock.patch.object(autologin, "login_account", side_effect=failing_login):
            with pytest.raises(RuntimeError, match="simulated crash"):
                asyncio.run(autologin.run_batch(accounts))

    def test_batch_concurrent_semaphore_respected(self, autologin):
        """Verify that concurrency is limited by the semaphore.

        We track peak concurrency: the max number of simultaneous logins.
        With concurrent=2 and 4 accounts, peak should be <= 2.
        """
        active = {"count": 0}
        peak = {"max": 0}

        async def tracked_login(email, password, profile_name=None, save=True,
                                auth_file_override=None):
            active["count"] += 1
            peak["max"] = max(peak["max"], active["count"])
            await asyncio.sleep(0.05)
            active["count"] -= 1
            return {
                "email": email, "success": True, "profile": profile_name,
                "error": None, "duration": 0.05,
            }

        accounts = [
            {"email": f"user{i}@test.com", "password": "p"}
            for i in range(4)
        ]
        with mock.patch.object(autologin, "login_account", side_effect=tracked_login):
            asyncio.run(autologin.run_batch(accounts, concurrent=2))

        assert peak["max"] <= 2, f"Peak concurrency was {peak['max']}, expected <= 2"

    def test_batch_results_order_matches_input(self, autologin):
        """Results are returned in the same order as input accounts."""
        async def delayed_login(email, password, profile_name=None, save=True,
                                auth_file_override=None):
            await asyncio.sleep(0.01)
            return {
                "email": email, "success": True, "profile": profile_name,
                "error": None, "duration": 0.01,
            }

        accounts = [
            {"email": "first@test.com", "password": "p"},
            {"email": "second@test.com", "password": "p"},
            {"email": "third@test.com", "password": "p"},
        ]
        with mock.patch.object(autologin, "login_account", side_effect=delayed_login):
            results = asyncio.run(autologin.run_batch(accounts, concurrent=3))

        assert results[0]["email"] == "first@test.com"
        assert results[1]["email"] == "second@test.com"
        assert results[2]["email"] == "third@test.com"


# ── CLI batch subcommand via main() ───────────────────────────────────────

class TestDogfoodCLIBatch:
    """Test the batch subcommand through main() with --no-save."""

    def test_batch_main_with_no_save(self, autologin, tmp_path):
        """main() with batch + --no-save doesn't save to vault."""
        accounts_file = tmp_path / "accounts.txt"
        accounts_file.write_text("user1@test.com:pass1\nuser2@test.com:pass2\n")

        async def mock_batch(accounts, concurrent=1, no_save=False):
            assert no_save is True
            return [
                {"email": a["email"], "success": True, "profile": "p",
                 "error": None, "duration": 0.1}
                for a in accounts
            ]

        with mock.patch.object(autologin, "run_batch",
                               new_callable=mock.AsyncMock,
                               side_effect=mock_batch), \
             mock.patch("sys.argv",
                        ["qoder-autologin.py", "batch", str(accounts_file),
                         "--no-save"]):
            with pytest.raises(SystemExit) as exc_info:
                autologin.main()
            assert exc_info.value.code == 0

    def test_batch_main_file_not_found(self, autologin):
        """main() with non-existent file exits with code 1."""
        with mock.patch("sys.argv",
                        ["qoder-autologin.py", "batch", "/nonexistent/file.txt"]):
            with pytest.raises(SystemExit) as exc_info:
                autologin.main()
            assert exc_info.value.code == 1

    def test_batch_main_empty_file(self, autologin, tmp_path):
        """main() with file containing only comments exits with code 1."""
        accounts_file = tmp_path / "accounts.txt"
        accounts_file.write_text("# only comments\n\n")

        with mock.patch("sys.argv",
                        ["qoder-autologin.py", "batch", str(accounts_file)]):
            with pytest.raises(SystemExit) as exc_info:
                autologin.main()
            assert exc_info.value.code == 1

    def test_batch_main_all_success_exits_zero(self, autologin, tmp_path):
        """All logins succeed -> exit code 0."""
        accounts_file = tmp_path / "accounts.txt"
        accounts_file.write_text("user@test.com:pass\n")

        with mock.patch.object(autologin, "run_batch",
                               new_callable=mock.AsyncMock,
                               return_value=[{
                                   "email": "user@test.com", "success": True,
                                   "profile": "user", "error": None, "duration": 1.0,
                               }]), \
             mock.patch("sys.argv",
                        ["qoder-autologin.py", "batch", str(accounts_file)]):
            with pytest.raises(SystemExit) as exc_info:
                autologin.main()
            assert exc_info.value.code == 0

    def test_batch_main_any_failure_exits_one(self, autologin, tmp_path):
        """Any login failure -> exit code 1."""
        accounts_file = tmp_path / "accounts.txt"
        accounts_file.write_text("user@test.com:pass\n")

        with mock.patch.object(autologin, "run_batch",
                               new_callable=mock.AsyncMock,
                               return_value=[{
                                   "email": "user@test.com", "success": False,
                                   "profile": "user", "error": "fail", "duration": 1.0,
                               }]), \
             mock.patch("sys.argv",
                        ["qoder-autologin.py", "batch", str(accounts_file)]):
            with pytest.raises(SystemExit) as exc_info:
                autologin.main()
            assert exc_info.value.code == 1

    def test_batch_main_concurrent_flag(self, autologin, tmp_path):
        """--concurrent flag is passed to run_batch."""
        accounts_file = tmp_path / "accounts.txt"
        accounts_file.write_text("user@test.com:pass\n")

        captured_concurrent = {}

        async def mock_batch(accounts, concurrent=1, no_save=False):
            captured_concurrent["value"] = concurrent
            return [{"email": "user@test.com", "success": True, "profile": "user",
                     "error": None, "duration": 0.1}]

        with mock.patch.object(autologin, "run_batch",
                               new_callable=mock.AsyncMock,
                               side_effect=mock_batch), \
             mock.patch("sys.argv",
                        ["qoder-autologin.py", "batch", str(accounts_file),
                         "--concurrent", "3"]):
            with pytest.raises(SystemExit):
                autologin.main()
            assert captured_concurrent["value"] == 3

    def test_batch_legacy_batch_flag(self, autologin, tmp_path):
        """Legacy --batch FILE syntax still works via _translate_legacy_args."""
        accounts_file = tmp_path / "accounts.txt"
        accounts_file.write_text("user@test.com:pass\n")

        with mock.patch.object(autologin, "run_batch",
                               new_callable=mock.AsyncMock,
                               return_value=[{
                                   "email": "user@test.com", "success": True,
                                   "profile": "user", "error": None, "duration": 0.1,
                               }]), \
             mock.patch("sys.argv",
                        ["qoder-autologin.py", "--batch", str(accounts_file)]):
            with pytest.raises(SystemExit) as exc_info:
                autologin.main()
            assert exc_info.value.code == 0

    def test_batch_alias_b(self, autologin, tmp_path):
        """Alias 'b' works as shorthand for 'batch'."""
        accounts_file = tmp_path / "accounts.txt"
        accounts_file.write_text("user@test.com:pass\n")

        parser = autologin.build_parser()
        args = parser.parse_args(["b", str(accounts_file)])
        assert args.command == "b"
        assert args.file == str(accounts_file)


# ── print_summary edge cases ──────────────────────────────────────────────

class TestDogfoodPrintSummary:
    """Summary output edge cases."""

    def test_all_success(self, autologin, capsys):
        """All successes -> returns True."""
        results = [
            {"email": f"user{i}@t.com", "success": True, "profile": f"p{i}",
             "error": None, "duration": 1.0}
            for i in range(3)
        ]
        ok = autologin.print_summary(results)
        assert ok is True
        captured = capsys.readouterr()
        assert "3" in captured.out

    def test_all_failure(self, autologin, capsys):
        """All failures -> returns False."""
        results = [
            {"email": f"user{i}@t.com", "success": False, "profile": None,
             "error": "timeout", "duration": 1.0}
            for i in range(2)
        ]
        ok = autologin.print_summary(results)
        assert ok is False

    def test_single_success(self, autologin, capsys):
        """Single successful account."""
        results = [
            {"email": "solo@t.com", "success": True, "profile": "solo",
             "error": None, "duration": 5.5}
        ]
        ok = autologin.print_summary(results)
        assert ok is True
        captured = capsys.readouterr()
        assert "solo@t.com" in captured.out

    def test_single_failure(self, autologin, capsys):
        """Single failed account."""
        results = [
            {"email": "fail@t.com", "success": False, "profile": None,
             "error": "no_auth_url", "duration": 0.5}
        ]
        ok = autologin.print_summary(results)
        assert ok is False
        captured = capsys.readouterr()
        assert "no_auth_url" in captured.out

    def test_total_time_is_sum(self, autologin, capsys):
        """Total time in summary is the sum of all durations."""
        results = [
            {"email": "a@t.com", "success": True, "profile": "a",
             "error": None, "duration": 10.0},
            {"email": "b@t.com", "success": True, "profile": "b",
             "error": None, "duration": 20.0},
        ]
        autologin.print_summary(results)
        captured = capsys.readouterr()
        assert "30" in captured.out

    def test_missing_profile_key(self, autologin, capsys):
        """Result without 'profile' key shows '?' for profile."""
        results = [
            {"email": "a@t.com", "success": True, "duration": 1.0}
        ]
        ok = autologin.print_summary(results)
        assert ok is True
        captured = capsys.readouterr()
        assert "?" in captured.out

    def test_missing_error_key(self, autologin, capsys):
        """Failed result without 'error' key shows 'unknown'."""
        results = [
            {"email": "a@t.com", "success": False, "duration": 1.0}
        ]
        ok = autologin.print_summary(results)
        assert ok is False
        captured = capsys.readouterr()
        assert "unknown" in captured.out


# ── Integration: full pipeline (file -> parse -> batch -> summary) ────────

class TestDogfoodFullPipeline:
    """Integration tests exercising the full batch pipeline."""

    def test_file_to_batch_pipeline(self, autologin, tmp_path):
        """Parse file -> run batch -> print summary, all mocked login."""
        accounts_file = tmp_path / "accounts.txt"
        accounts_file.write_text(
            "# Test accounts\n"
            "alice@gmail.com:pass1\n"
            "bob.smith@yahoo.com:pass2\n"
            "alice@hotmail.com:pass3\n"
            "\n"
            "# Comment in middle\n"
            "charlie@test.com:my:complex:password\n"
        )

        accounts = autologin.parse_accounts_file(str(accounts_file))
        assert len(accounts) == 4

        profiles = autologin._generate_unique_profiles(accounts)
        assert profiles == ["alice", "bob-smith", "alice-2", "charlie"]

        captured_profiles = []

        async def mock_login(email, password, profile_name=None, save=True,
                             auth_file_override=None):
            captured_profiles.append(profile_name)
            return {
                "email": email, "success": True, "profile": profile_name,
                "error": None, "duration": 0.1,
            }

        with mock.patch.object(autologin, "login_account", side_effect=mock_login):
            results = asyncio.run(autologin.run_batch(accounts))

        assert len(results) == 4
        assert all(r["success"] for r in results)
        assert captured_profiles == ["alice", "bob-smith", "alice-2", "charlie"]

        ok = autologin.print_summary(results)
        assert ok is True

    def test_pipeline_with_some_failures(self, autologin, tmp_path, capsys):
        """Pipeline where some accounts fail."""
        accounts_file = tmp_path / "accounts.txt"
        accounts_file.write_text(
            "good1@test.com:pass1\n"
            "bad@test.com:pass2\n"
            "good2@test.com:pass3\n"
        )

        accounts = autologin.parse_accounts_file(str(accounts_file))

        call_idx = {"n": 0}

        async def mock_login(email, password, profile_name=None, save=True,
                             auth_file_override=None):
            call_idx["n"] += 1
            success = email != "bad@test.com"
            return {
                "email": email, "success": success, "profile": profile_name,
                "error": None if success else "auth_file_not_updated",
                "duration": 0.1,
            }

        with mock.patch.object(autologin, "login_account", side_effect=mock_login):
            results = asyncio.run(autologin.run_batch(accounts))

        assert len(results) == 3
        assert sum(1 for r in results if r["success"]) == 2
        assert sum(1 for r in results if not r["success"]) == 1

        ok = autologin.print_summary(results)
        assert ok is False
        captured = capsys.readouterr()
        assert "bad@test.com" in captured.out
        assert "auth_file_not_updated" in captured.out

    def test_pipeline_concurrent_with_collision(self, autologin, tmp_path):
        """Concurrent batch with profile name collisions works correctly."""
        accounts_file = tmp_path / "accounts.txt"
        accounts_file.write_text(
            "john@a.com:p1\n"
            "john@b.com:p2\n"
            "jane@c.com:p3\n"
            "john@d.com:p4\n"
        )

        accounts = autologin.parse_accounts_file(str(accounts_file))
        profiles = autologin._generate_unique_profiles(accounts)
        assert profiles == ["john", "john-2", "jane", "john-3"]

        captured = []

        async def mock_login(email, password, profile_name=None, save=True,
                             auth_file_override=None):
            captured.append({
                "email": email,
                "profile": profile_name,
                "auth_file": auth_file_override,
            })
            return {
                "email": email, "success": True, "profile": profile_name,
                "error": None, "duration": 0.1,
            }

        with mock.patch.object(autologin, "login_account", side_effect=mock_login):
            results = asyncio.run(autologin.run_batch(accounts, concurrent=4))

        assert len(results) == 4
        profile_names = [c["profile"] for c in captured]
        assert len(set(profile_names)) == 4
        auth_files = [c["auth_file"] for c in captured]
        assert all(f is not None for f in auth_files)
        assert len(set(auth_files)) == 4
