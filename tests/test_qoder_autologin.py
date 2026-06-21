"""
Tests for qoder-autologin.py - pytest-based unit tests.
Follows TDD: write tests first (RED), then implement (GREEN), then refactor.
"""

import importlib
import os
from pathlib import Path
from unittest import mock

import pytest

# Import the module under test (handles hyphenated filename)
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


# ── Step 1: check_dependencies() ────────────────────────────────────────

class TestCheckDependencies:
    """Tests for the check_dependencies() function."""

    def test_returns_dict(self, autologin):
        """check_dependencies returns a dict."""
        with mock.patch("shutil.which", return_value="/usr/bin/qodercli"), \
             mock.patch("subprocess.run") as mock_run:
            mock_run.return_value = mock.Mock(returncode=0, stdout="installed")
            result = autologin.check_dependencies()
        assert isinstance(result, dict)

    def test_checks_qodercli(self, autologin):
        """Result contains 'qodercli' key."""
        with mock.patch("shutil.which", return_value="/usr/bin/qodercli"), \
             mock.patch("subprocess.run") as mock_run:
            mock_run.return_value = mock.Mock(returncode=0, stdout="installed")
            result = autologin.check_dependencies()
        assert "qodercli" in result

    def test_checks_playwright(self, autologin):
        """Result contains 'playwright' key."""
        with mock.patch("shutil.which", return_value="/usr/bin/qodercli"), \
             mock.patch("subprocess.run") as mock_run:
            mock_run.return_value = mock.Mock(returncode=0, stdout="installed")
            result = autologin.check_dependencies()
        assert "playwright" in result

    def test_checks_chromium(self, autologin):
        """Result contains 'chromium' key."""
        with mock.patch("shutil.which", return_value="/usr/bin/qodercli"), \
             mock.patch("subprocess.run") as mock_run:
            mock_run.return_value = mock.Mock(returncode=0, stdout="installed")
            result = autologin.check_dependencies()
        assert "chromium" in result

    def test_each_result_has_required_keys(self, autologin):
        """Each dependency result has installed, version, install_hint."""
        with mock.patch("shutil.which", return_value="/usr/bin/qodercli"), \
             mock.patch("subprocess.run") as mock_run:
            mock_run.return_value = mock.Mock(returncode=0, stdout="installed")
            result = autologin.check_dependencies()
        for key in ("qodercli", "playwright", "chromium"):
            entry = result[key]
            assert "installed" in entry
            assert "version" in entry
            assert "install_hint" in entry

    def test_installed_is_bool(self, autologin):
        """'installed' field is a boolean."""
        with mock.patch("shutil.which", return_value="/usr/bin/qodercli"), \
             mock.patch("subprocess.run") as mock_run:
            mock_run.return_value = mock.Mock(returncode=0, stdout="installed")
            result = autologin.check_dependencies()
        for key in ("qodercli", "playwright", "chromium"):
            assert isinstance(result[key]["installed"], bool)

    def test_qodercli_missing(self, autologin):
        """When qodercli is not found, installed=False and hint is provided."""
        with mock.patch("shutil.which", return_value=None), \
             mock.patch("subprocess.run") as mock_run:
            mock_run.return_value = mock.Mock(returncode=0, stdout="installed")
            result = autologin.check_dependencies()
        assert result["qodercli"]["installed"] is False
        assert result["qodercli"]["install_hint"] is not None

    def test_qodercli_present(self, autologin):
        """When qodercli is found, installed=True."""
        with mock.patch("shutil.which", return_value="/usr/bin/qodercli"), \
             mock.patch("subprocess.run") as mock_run:
            mock_run.return_value = mock.Mock(returncode=0, stdout="installed")
            result = autologin.check_dependencies()
        assert result["qodercli"]["installed"] is True

    def test_playwright_missing(self, autologin):
        """When playwright import fails, installed=False."""
        with mock.patch("shutil.which", return_value="/usr/bin/qodercli"), \
             mock.patch("subprocess.run") as mock_run:
            # First call: playwright check (returns non-zero)
            # Second call: chromium check
            mock_run.side_effect = [
                mock.Mock(returncode=1, stdout=""),
                mock.Mock(returncode=1, stdout=""),
            ]
            result = autologin.check_dependencies()
        assert result["playwright"]["installed"] is False
        assert result["playwright"]["install_hint"] is not None

    def test_chromium_missing(self, autologin):
        """When chromium is not installed, installed=False."""
        with mock.patch("shutil.which", return_value="/usr/bin/qodercli"), \
             mock.patch("subprocess.run") as mock_run:
            # First call: playwright check (OK)
            # Second call: chromium check (fails)
            mock_run.side_effect = [
                mock.Mock(returncode=0, stdout="installed"),
                mock.Mock(returncode=1, stdout=""),
            ]
            result = autologin.check_dependencies()
        assert result["chromium"]["installed"] is False

    def test_all_missing(self, autologin):
        """When everything is missing, all installed=False, no crash."""
        with mock.patch("shutil.which", return_value=None), \
             mock.patch("subprocess.run") as mock_run:
            mock_run.return_value = mock.Mock(returncode=1, stdout="")
            result = autologin.check_dependencies()
        for key in ("qodercli", "playwright", "chromium"):
            assert result[key]["installed"] is False

    def test_all_present(self, autologin):
        """When everything is present, all installed=True."""
        with mock.patch("shutil.which", return_value="/usr/bin/qodercli"), \
             mock.patch("subprocess.run") as mock_run:
            mock_run.return_value = mock.Mock(returncode=0, stdout="installed")
            result = autologin.check_dependencies()
        for key in ("qodercli", "playwright", "chromium"):
            assert result[key]["installed"] is True

    def test_subprocess_exception_handled(self, autologin):
        """If subprocess raises, the function does not crash."""
        with mock.patch("shutil.which", return_value="/usr/bin/qodercli"), \
             mock.patch("subprocess.run", side_effect=FileNotFoundError):
            result = autologin.check_dependencies()
        # Should not crash, playwright/chromium should be not installed
        assert result["playwright"]["installed"] is False
        assert result["chromium"]["installed"] is False


# ── Step 2: setup subcommand ────────────────────────────────────────────

class TestSetupCommand:
    """Tests for the setup subcommand."""

    def test_setup_subcommand_registered(self, autologin):
        """'setup' is a valid subcommand in argparse."""
        parser = autologin.build_parser()
        args = parser.parse_args(["setup"])
        assert args.command == "setup"

    def test_setup_calls_pip_install(self, autologin):
        """setup installs playwright via pip."""
        with mock.patch("subprocess.run") as mock_run:
            mock_run.return_value = mock.Mock(returncode=0)
            autologin.cmd_setup()
            # Check that pip install playwright was called
            calls = [str(c) for c in mock_run.call_args_list]
            pip_called = any("playwright" in c and "install" in c for c in calls)
            assert pip_called, f"pip install playwright not called. Calls: {calls}"

    def test_setup_installs_chromium(self, autologin):
        """setup runs playwright install chromium."""
        with mock.patch("subprocess.run") as mock_run:
            mock_run.return_value = mock.Mock(returncode=0)
            autologin.cmd_setup()
            calls = [str(c) for c in mock_run.call_args_list]
            chromium_called = any("chromium" in c for c in calls)
            assert chromium_called, f"playwright install chromium not called. Calls: {calls}"

    def test_setup_reports_success(self, autologin, capsys):
        """setup prints success message on success."""
        with mock.patch("subprocess.run") as mock_run:
            mock_run.return_value = mock.Mock(returncode=0)
            autologin.cmd_setup()
        captured = capsys.readouterr()
        # Should not crash, should have some output
        assert len(captured.out) > 0

    def test_setup_reports_failure(self, autologin, capsys):
        """setup reports when pip install fails."""
        with mock.patch("subprocess.run") as mock_run:
            mock_run.return_value = mock.Mock(returncode=1, stderr="install error")
            with pytest.raises(SystemExit):
                autologin.cmd_setup()

    def test_setup_retries_pep668(self, autologin):
        """setup retries with --break-system-packages on PEP 668 error."""
        with mock.patch("subprocess.run") as mock_run:
            pep668_err = "error: externally-managed-environment"
            mock_run.side_effect = [
                mock.Mock(returncode=1, stderr=pep668_err),
                mock.Mock(returncode=0),
                mock.Mock(returncode=0),
            ]
            autologin.cmd_setup()
            calls = [str(c) for c in mock_run.call_args_list]
            retry_called = any("--break-system-packages" in c for c in calls)
            assert retry_called, f"--break-system-packages not used. Calls: {calls}"

    def test_setup_pep668_retry_fails(self, autologin):
        """setup exits when --break-system-packages retry also fails."""
        with mock.patch("subprocess.run") as mock_run:
            pep668_err = "error: externally-managed-environment"
            mock_run.side_effect = [
                mock.Mock(returncode=1, stderr=pep668_err),
                mock.Mock(returncode=1, stderr="still broken"),
            ]
            with pytest.raises(SystemExit):
                autologin.cmd_setup()


# ── Step 3: status subcommand ───────────────────────────────────────────

class TestStatusCommand:
    """Tests for the status subcommand."""

    def test_status_subcommand_registered(self, autologin):
        """'status' is a valid subcommand in argparse."""
        parser = autologin.build_parser()
        args = parser.parse_args(["status"])
        assert args.command == "status"

    def test_status_reports_python(self, autologin, capsys):
        """status output includes Python version info."""
        with mock.patch("shutil.which", return_value="/usr/bin/qodercli"), \
             mock.patch("subprocess.run") as mock_run:
            mock_run.return_value = mock.Mock(returncode=0, stdout="installed")
            autologin.cmd_status()
        captured = capsys.readouterr()
        assert "Python" in captured.out or "python" in captured.out

    def test_status_reports_playwright(self, autologin, capsys):
        """status output includes Playwright status."""
        with mock.patch("shutil.which", return_value="/usr/bin/qodercli"), \
             mock.patch("subprocess.run") as mock_run:
            mock_run.return_value = mock.Mock(returncode=0, stdout="installed")
            autologin.cmd_status()
        captured = capsys.readouterr()
        assert "Playwright" in captured.out or "playwright" in captured.out

    def test_status_reports_qodercli(self, autologin, capsys):
        """status output includes qodercli status."""
        with mock.patch("shutil.which", return_value="/usr/bin/qodercli"), \
             mock.patch("subprocess.run") as mock_run:
            mock_run.return_value = mock.Mock(returncode=0, stdout="installed")
            autologin.cmd_status()
        captured = capsys.readouterr()
        assert "qodercli" in captured.out or "Qodercli" in captured.out

    def test_status_reports_vault_profiles(self, autologin, capsys, tmp_path):
        """status output includes vault profile count."""
        vault_dir = tmp_path / ".auth-vault" / "qoder"
        vault_dir.mkdir(parents=True)
        # Create two fake profiles
        (vault_dir / "profile1").write_text("{}")
        (vault_dir / "profile2").write_text("{}")
        (vault_dir / ".current").write_text("profile1")
        (vault_dir / "profile1.meta.json").write_text("{}")

        with mock.patch("shutil.which", return_value="/usr/bin/qodercli"), \
             mock.patch("subprocess.run") as mock_run, \
             mock.patch.object(autologin, "VAULT_DIR", vault_dir):
            mock_run.return_value = mock.Mock(returncode=0, stdout="installed")
            autologin.cmd_status()
        captured = capsys.readouterr()
        assert "2" in captured.out or "Vault" in captured.out or "vault" in captured.out

    def test_status_reports_chromium(self, autologin, capsys):
        """status output includes Chromium status."""
        with mock.patch("shutil.which", return_value="/usr/bin/qodercli"), \
             mock.patch("subprocess.run") as mock_run:
            mock_run.return_value = mock.Mock(returncode=0, stdout="installed")
            autologin.cmd_status()
        captured = capsys.readouterr()
        assert "Chromium" in captured.out or "chromium" in captured.out


# ── Step 4: interactive subcommand ──────────────────────────────────────

class TestInteractiveCommand:
    """Tests for the interactive subcommand."""

    def test_interactive_subcommand_registered(self, autologin):
        """'interactive' is a valid subcommand in argparse."""
        parser = autologin.build_parser()
        args = parser.parse_args(["interactive"])
        assert args.command == "interactive"

    def test_interactive_with_file(self, autologin, tmp_path):
        """interactive can read accounts from a file."""
        accounts_file = tmp_path / "accounts.txt"
        accounts_file.write_text("user1@test.com:pass1\nuser2@test.com:pass2\n")

        parser = autologin.build_parser()
        args = parser.parse_args(["interactive", str(accounts_file)])
        assert args.command == "interactive"
        assert args.file == str(accounts_file)

    def test_interactive_prompts_for_input(self, autologin):
        """interactive prompts for email:password when no file given."""
        inputs = iter([
            "user@test.com:password",  # account line
            "",                         # empty line to finish
            "n",                        # headless? no
            "y",                        # confirm? yes
        ])
        with mock.patch("builtins.input", side_effect=inputs), \
             mock.patch.object(autologin, "run_batch", new_callable=mock.AsyncMock) as mock_batch:
            mock_batch.return_value = []
            autologin.cmd_interactive(file=None)
        # run_batch should have been called with the account
        assert mock_batch.called

    def test_interactive_parses_file(self, autologin, tmp_path):
        """interactive reads and parses accounts from file."""
        accounts_file = tmp_path / "accounts.txt"
        accounts_file.write_text("# comment\nuser1@a.com:pass1\n\nuser2@b.com:pass2\n")

        inputs = iter([
            "n",  # headless?
            "1",  # concurrent (asked because 2 accounts)
            "y",  # confirm?
        ])
        with mock.patch("builtins.input", side_effect=inputs), \
             mock.patch.object(autologin, "run_batch", new_callable=mock.AsyncMock) as mock_batch:
            mock_batch.return_value = []
            autologin.cmd_interactive(file=str(accounts_file))
        # Should have 2 accounts
        call_args = mock_batch.call_args
        accounts = call_args[0][0]
        assert len(accounts) == 2

    def test_interactive_asks_headless(self, autologin):
        """interactive asks about headless mode."""
        inputs = iter([
            "user@test.com:password",
            "",        # finish
            "y",       # headless yes
            "y",       # confirm
        ])
        with mock.patch("builtins.input", side_effect=inputs), \
             mock.patch.object(autologin, "run_batch", new_callable=mock.AsyncMock) as mock_batch:
            mock_batch.return_value = []
            autologin.cmd_interactive(file=None)
        # Check that headless was passed as True
        assert mock_batch.called

    def test_interactive_asks_concurrent(self, autologin):
        """interactive asks about concurrent sessions for multiple accounts."""
        inputs = iter([
            "user1@test.com:pass1",
            "user2@test.com:pass2",
            "",        # finish
            "n",       # headless?
            "3",       # concurrent
            "y",       # confirm
        ])
        with mock.patch("builtins.input", side_effect=inputs), \
             mock.patch.object(autologin, "run_batch", new_callable=mock.AsyncMock) as mock_batch:
            mock_batch.return_value = []
            autologin.cmd_interactive(file=None)
        assert mock_batch.called

    def test_interactive_cancelled(self, autologin):
        """interactive exits gracefully when user cancels."""
        inputs = iter([
            "user@test.com:password",
            "",        # finish
            "n",       # headless
            "n",       # confirm = NO (cancel)
        ])
        with mock.patch("builtins.input", side_effect=inputs), \
             mock.patch.object(autologin, "run_batch", new_callable=mock.AsyncMock) as mock_batch:
            autologin.cmd_interactive(file=None)
        # run_batch should NOT be called
        assert not mock_batch.called

    def test_interactive_no_accounts(self, autologin):
        """interactive handles empty input gracefully."""
        inputs = iter([
            "",  # immediately empty
        ])
        with mock.patch("builtins.input", side_effect=inputs):
            # Should not crash
            autologin.cmd_interactive(file=None)

    def test_interactive_invalid_line_skipped(self, autologin):
        """interactive warns and skips lines without colon."""
        inputs = iter([
            "invalid-no-colon",
            "user@test.com:password",
            "",        # finish
            "n",       # headless
            "y",       # confirm
        ])
        with mock.patch("builtins.input", side_effect=inputs), \
             mock.patch.object(autologin, "run_batch", new_callable=mock.AsyncMock) as mock_batch:
            mock_batch.return_value = []
            autologin.cmd_interactive(file=None)
        # Only the valid account should be passed
        call_args = mock_batch.call_args
        accounts = call_args[0][0]
        assert len(accounts) == 1
        assert accounts[0]["email"] == "user@test.com"


# ── Step 5: argparse structure ──────────────────────────────────────────

class TestArgparseStructure:
    """Tests for the full argparse structure with subparsers."""

    def test_login_subcommand(self, autologin):
        """'login' subcommand is registered."""
        parser = autologin.build_parser()
        args = parser.parse_args(["login", "user@test.com:pass"])
        assert args.command == "login"
        assert args.account == "user@test.com:pass"

    def test_login_with_profile(self, autologin):
        """'login' subcommand accepts optional profile."""
        parser = autologin.build_parser()
        args = parser.parse_args(["login", "user@test.com:pass", "my-profile"])
        assert args.profile == "my-profile"

    def test_batch_subcommand(self, autologin):
        """'batch' subcommand is registered."""
        parser = autologin.build_parser()
        args = parser.parse_args(["batch", "accounts.txt"])
        assert args.command == "batch"
        assert args.file == "accounts.txt"

    def test_headless_flag(self, autologin):
        """--headless flag works on login and batch."""
        parser = autologin.build_parser()
        args = parser.parse_args(["login", "user@test.com:pass", "--headless"])
        assert args.headless is True

    def test_concurrent_flag(self, autologin):
        """--concurrent flag works on batch."""
        parser = autologin.build_parser()
        args = parser.parse_args(["batch", "accounts.txt", "--concurrent", "3"])
        assert args.concurrent == 3

    def test_debug_flag(self, autologin):
        """--debug flag works."""
        parser = autologin.build_parser()
        args = parser.parse_args(["login", "user@test.com:pass", "--debug"])
        assert args.debug is True

    def test_no_save_flag(self, autologin):
        """--no-save flag works on login."""
        parser = autologin.build_parser()
        args = parser.parse_args(["login", "user@test.com:pass", "--no-save"])
        assert args.no_save is True

    def test_backward_compat_positional(self, autologin):
        """Backward compatibility: positional email:password still works via main()."""
        parser = autologin.build_parser()
        raw_args = autologin._translate_legacy_args(["user@test.com:pass"])
        args = parser.parse_args(raw_args)
        assert args.command == "login"
        assert args.account == "user@test.com:pass"

    def test_backward_compat_batch_flag(self, autologin):
        """Backward compatibility: --batch FILE still works via main()."""
        parser = autologin.build_parser()
        raw_args = autologin._translate_legacy_args(["--batch", "accounts.txt"])
        args = parser.parse_args(raw_args)
        assert args.command == "batch"
        assert args.file == "accounts.txt"

    def test_all_subcommands_accessible(self, autologin):
        """All 5 subcommands are accessible: login, batch, interactive, setup, status."""
        parser = autologin.build_parser()
        for cmd, extra_args in [
            ("login", ["user@t.com:p"]),
            ("batch", ["file.txt"]),
            ("interactive", []),
            ("setup", []),
            ("status", []),
        ]:
            args = parser.parse_args([cmd] + extra_args)
            assert args.command == cmd, f"subcommand '{cmd}' not registered"


# ── Existing functionality preservation ─────────────────────────────────

class TestExistingFunctionality:
    """Tests ensuring existing functionality is preserved."""

    def test_parse_accounts_file(self, autologin, tmp_path):
        """parse_accounts_file reads email:password lines."""
        f = tmp_path / "accounts.txt"
        f.write_text("# comment\nuser@a.com:pass1\n\nuser@b.com:pass2\n")
        accounts = autologin.parse_accounts_file(str(f))
        assert len(accounts) == 2
        assert accounts[0]["email"] == "user@a.com"
        assert accounts[0]["password"] == "pass1"
        assert accounts[1]["email"] == "user@b.com"

    def test_parse_accounts_file_skips_comments(self, autologin, tmp_path):
        """parse_accounts_file skips comment lines."""
        f = tmp_path / "accounts.txt"
        f.write_text("# this is a comment\n# another\nuser@a.com:pass1\n")
        accounts = autologin.parse_accounts_file(str(f))
        assert len(accounts) == 1

    def test_parse_accounts_file_skips_empty(self, autologin, tmp_path):
        """parse_accounts_file skips empty lines."""
        f = tmp_path / "accounts.txt"
        f.write_text("\n\nuser@a.com:pass1\n\n\n")
        accounts = autologin.parse_accounts_file(str(f))
        assert len(accounts) == 1

    def test_parse_accounts_file_skips_malformed(self, autologin, tmp_path):
        """parse_accounts_file skips lines without colon."""
        f = tmp_path / "accounts.txt"
        f.write_text("invalid\nuser@a.com:pass1\nno-colon-here\n")
        accounts = autologin.parse_accounts_file(str(f))
        assert len(accounts) == 1

    def test_save_to_vault(self, autologin, tmp_path):
        """save_to_vault copies auth file and creates meta."""
        vault_dir = tmp_path / "vault"
        vault_dir.mkdir()
        auth_dir = tmp_path / "qoder" / ".auth"
        auth_dir.mkdir(parents=True)
        auth_file = auth_dir / "user"
        auth_file.write_text('{"token":"test"}')

        with mock.patch.object(autologin, "VAULT_DIR", vault_dir), \
             mock.patch.object(autologin, "QODER_AUTH", auth_file):
            result = autologin.save_to_vault("test-profile", "test@example.com")

        assert result is True
        assert (vault_dir / "test-profile").exists()
        assert (vault_dir / "test-profile.meta.json").exists()
        assert (vault_dir / ".current").read_text() == "test-profile"

    def test_print_summary(self, autologin, capsys):
        """print_summary outputs results."""
        results = [
            {"email": "a@b.com", "success": True, "profile": "p1", "duration": 5.0},
            {"email": "c@d.com", "success": False, "error": "fail", "duration": 3.0},
        ]
        ok = autologin.print_summary(results)
        assert ok is False
        captured = capsys.readouterr()
        assert "a@b.com" in captured.out
        assert "c@d.com" in captured.out


# ── Bug fix verification tests ──────────────────────────────────────────

class TestBugNoSaveFlag:
    """Fix: --no-save flag now prevents save_to_vault() via save parameter."""

    def test_no_save_flag_prevents_vault_save(self, autologin, tmp_path):
        """When save=False, save_to_vault should NOT be called."""
        vault_dir = tmp_path / "vault"
        vault_dir.mkdir()
        auth_dir = tmp_path / "qoder" / ".auth"
        auth_dir.mkdir(parents=True)
        auth_file = auth_dir / "user"
        auth_file.write_text('{"token":"test"}')

        mock_proc = mock.MagicMock()
        mock_proc.stdout = iter([
            "Visit https://qoder.com/device/selectAccounts?code=abc\n",
        ])
        mock_proc.wait.return_value = 0

        async def touch_auth_then_sso(*args, **kwargs):
            import time as _time
            _time.sleep(0.05)
            auth_file.write_text('{"token":"updated"}')
            return {"done": True, "error": None}

        with mock.patch.object(autologin, "VAULT_DIR", vault_dir), \
             mock.patch.object(autologin, "QODER_AUTH", auth_file), \
             mock.patch("subprocess.Popen", return_value=mock_proc), \
             mock.patch.object(autologin, "automate_google_sso",
                               new_callable=mock.AsyncMock,
                               side_effect=touch_auth_then_sso), \
             mock.patch.object(autologin, "save_to_vault") as mock_save:
            import asyncio
            result = asyncio.run(autologin.login_account(
                "test@a.com", "pass", "test-profile", save=False
            ))

        assert result["success"] is True
        mock_save.assert_not_called()


class TestBugProfileNameCollision:
    """Fix: _generate_unique_profiles appends suffix for duplicate local parts."""

    def test_different_emails_same_local_part_get_unique_profiles(self, autologin):
        """Two emails with same local part get different profile names."""
        accounts = [
            {"email": "john@gmail.com", "password": "p1"},
            {"email": "john@yahoo.com", "password": "p2"},
        ]
        profiles = autologin._generate_unique_profiles(accounts)
        assert len(set(profiles)) == 2
        assert profiles[0] == "john"
        assert profiles[1] == "john-2"

    def test_three_collisions_get_incrementing_suffix(self, autologin):
        """Three accounts with same local part get -2, -3 suffixes."""
        accounts = [
            {"email": "alice@a.com", "password": "p"},
            {"email": "alice@b.com", "password": "p"},
            {"email": "alice@c.com", "password": "p"},
        ]
        profiles = autologin._generate_unique_profiles(accounts)
        assert profiles == ["alice", "alice-2", "alice-3"]

    def test_no_collision_unchanged(self, autologin):
        """Accounts with different local parts keep original names."""
        accounts = [
            {"email": "alice@a.com", "password": "p"},
            {"email": "bob@b.com", "password": "p"},
        ]
        profiles = autologin._generate_unique_profiles(accounts)
        assert profiles == ["alice", "bob"]

    def test_batch_accounts_get_unique_profiles(self, autologin, tmp_path):
        """run_batch passes unique profile names to login_account."""
        accounts = [
            {"email": "john@gmail.com", "password": "pass1"},
            {"email": "john@yahoo.com", "password": "pass2"},
        ]

        saved_profiles = []

        async def mock_login(email, password, profile_name=None, save=True,
                             auth_file_override=None):
            saved_profiles.append(profile_name)
            return {"email": email, "success": True, "profile": profile_name,
                    "error": None, "duration": 1.0}

        with mock.patch.object(autologin, "login_account", side_effect=mock_login):
            import asyncio
            asyncio.run(autologin.run_batch(accounts))

        assert len(set(saved_profiles)) == len(accounts)


class TestBugEmptyProfileName:
    """Fix: emails like '@gmail.com' now produce 'unknown' instead of empty."""

    def test_empty_local_part_produces_unknown(self, autologin):
        """An email starting with '@' produces 'unknown' profile name."""
        email = "@gmail.com"
        profile = email.split("@")[0].replace(".", "-") or "unknown"
        assert profile == "unknown"

    def test_generate_unique_profiles_handles_empty_local(self, autologin):
        """_generate_unique_profiles falls back to 'unknown' for empty local parts."""
        accounts = [{"email": "@gmail.com", "password": "p"}]
        profiles = autologin._generate_unique_profiles(accounts)
        assert profiles == ["unknown"]


class TestBugZombieProcess:
    """Fix: proc.kill() is now always followed by proc.wait()."""

    def test_kill_followed_by_wait(self, autologin, tmp_path):
        """After proc.kill(), proc.wait() must be called to reap the zombie."""
        auth_dir = tmp_path / "qoder" / ".auth"
        auth_dir.mkdir(parents=True)
        auth_file = auth_dir / "user"
        auth_file.write_text("")

        mock_proc = mock.MagicMock()
        mock_proc.stdout = iter([
            "Starting login...\n",
            "Some error output\n",
        ])

        with mock.patch.object(autologin, "QODER_AUTH", auth_file), \
             mock.patch("subprocess.Popen", return_value=mock_proc):
            import asyncio
            result = asyncio.run(autologin.login_account("a@b.com", "pass"))

        assert result["success"] is False
        mock_proc.kill.assert_called()
        # Verify wait() was called after kill()
        method_calls = mock_proc.method_calls
        kill_idx = None
        wait_after_kill = False
        for i, call in enumerate(method_calls):
            if call == mock.call.kill():
                kill_idx = i
            elif kill_idx is not None and i > kill_idx:
                if call == mock.call.wait() or str(call).startswith("call.wait("):
                    wait_after_kill = True
                    break
        assert wait_after_kill, (
            "proc.kill() called without subsequent proc.wait()"
        )


class TestBugPrintSummaryEmptyResults:
    """Fix: print_summary returns False for empty results."""

    def test_empty_results_returns_false(self, autologin, capsys):
        """Empty results list returns False (not success)."""
        ok = autologin.print_summary([])
        assert ok is False


class TestBugConcurrentSharedAuthFile:
    """Fix: concurrent > 1 uses isolated temp auth files per login."""

    def test_concurrent_logins_use_isolated_auth_files(self, autologin):
        """With concurrent>1, each login gets its own auth file path."""
        accounts = [
            {"email": "a@test.com", "password": "pass1"},
            {"email": "b@test.com", "password": "pass2"},
        ]

        auth_files_used = []

        async def mock_login(email, password, profile_name=None, save=True,
                             auth_file_override=None):
            auth_files_used.append(auth_file_override)
            return {"email": email, "success": True, "profile": profile_name,
                    "error": None, "duration": 1.0}

        with mock.patch.object(autologin, "login_account", side_effect=mock_login):
            import asyncio
            asyncio.run(autologin.run_batch(accounts, concurrent=2))

        # Each concurrent login should get a different auth file path
        assert all(f is not None for f in auth_files_used), (
            "auth_file_override should be set for concurrent logins"
        )
        assert len(set(auth_files_used)) == len(accounts), (
            f"Expected unique auth files, got: {auth_files_used}"
        )

    def test_sequential_logins_share_auth_file(self, autologin):
        """With concurrent=1, auth_file_override is None (uses default)."""
        accounts = [{"email": "a@test.com", "password": "pass1"}]

        auth_files_used = []

        async def mock_login(email, password, profile_name=None, save=True,
                             auth_file_override=None):
            auth_files_used.append(auth_file_override)
            return {"email": email, "success": True, "profile": profile_name,
                    "error": None, "duration": 1.0}

        with mock.patch.object(autologin, "login_account", side_effect=mock_login):
            import asyncio
            asyncio.run(autologin.run_batch(accounts, concurrent=1))

        assert auth_files_used == [None]


class TestBugBatchNoSaveFlag:
    """Fix: batch mode now passes no_save to run_batch."""

    def test_batch_passes_no_save_to_run_batch(self, autologin, tmp_path):
        """run_batch receives no_save and passes save=False to login_account."""
        accounts = [{"email": "user@test.com", "password": "pass"}]

        save_values = []

        async def mock_login(email, password, profile_name=None, save=True,
                             auth_file_override=None):
            save_values.append(save)
            return {"email": email, "success": True, "profile": profile_name,
                    "error": None, "duration": 1.0}

        with mock.patch.object(autologin, "login_account", side_effect=mock_login):
            import asyncio
            asyncio.run(autologin.run_batch(accounts, no_save=True))

        assert save_values == [False], (
            f"Expected save=False when no_save=True, got: {save_values}"
        )
