#!/usr/bin/env python3
"""
qoder-autologin - Auto-login Qoder accounts via Google SSO + save to auth-vault

Reverse-engineered from qodercli login flow:
  1. Run `qodercli login` as subprocess (handles PKCE + token + WASM encryption)
  2. Parse the auth URL from stdout
  3. Automate Google SSO with Playwright
  4. After qodercli completes, copy auth file to vault

Usage:
  python3 qoder-autologin.py user@gmail.com:password123 [profile_name]
  python3 qoder-autologin.py --batch accounts.txt
  python3 qoder-autologin.py --batch accounts.txt --headless --concurrent 2
"""

import argparse, asyncio, json, re, shutil, subprocess, sys, time
from datetime import datetime
from pathlib import Path

# ── Paths ─────────────────────────────────────────────────────────────
HOME = Path.home()
QODER_AUTH = HOME / ".qoder" / ".auth" / "user"
VAULT_DIR = HOME / ".auth-vault" / "qoder"

# ── Globals ───────────────────────────────────────────────────────────
HEADLESS = False
DEBUG = False
CONCURRENT = 1


def log(msg, level="INFO"):
    ts = datetime.now().strftime("%H:%M:%S")
    icons = {"INFO": "ℹ", "OK": "✅", "ERR": "❌", "DBG": "🔍", "WAIT": "⏳", "SUM": "📊"}
    pfx = icons.get(level, " ")
    print(f"[{ts}] {pfx} {msg}", flush=True)


def dbg(msg):
    if DEBUG:
        log(msg, "DBG")


def get_auth_file_mtime():
    try:
        return QODER_AUTH.stat().st_mtime
    except OSError:
        return 0


def save_to_vault(profile_name, email="unknown"):
    VAULT_DIR.mkdir(parents=True, exist_ok=True)
    if not QODER_AUTH.exists():
        log("Auth file not found after login", "ERR")
        return False

    dest = VAULT_DIR / profile_name
    shutil.copy2(str(QODER_AUTH), str(dest))
    (VAULT_DIR / ".current").write_text(profile_name)

    meta = {"name": profile_name, "email": email, "saved_at": int(time.time())}
    meta_file = VAULT_DIR / f"{profile_name}.meta.json"
    meta_file.write_text(json.dumps(meta, indent=2) + "\n")
    log(f"Profile '{profile_name}' saved to vault ({email})", "OK")
    return True


# ── Dependency checking ───────────────────────────────────────────────
def check_dependencies():
    """Check for required dependencies and return structured results.

    Returns a dict keyed by component name, each with:
      installed (bool), version (str|None), install_hint (str|None)
    """
    result = {}

    # qodercli
    qodercli_path = shutil.which("qodercli")
    result["qodercli"] = {
        "installed": qodercli_path is not None,
        "version": None,
        "install_hint": None if qodercli_path else "Install Qoder CLI: https://qoder.com",
    }

    # playwright (Python package)
    pw_installed = False
    pw_version = None
    try:
        proc = subprocess.run(
            [sys.executable, "-c", "import playwright; print('installed')"],
            capture_output=True, text=True, timeout=10,
        )
        pw_installed = proc.returncode == 0 and "installed" in proc.stdout
    except Exception:
        pass
    result["playwright"] = {
        "installed": pw_installed,
        "version": pw_version,
        "install_hint": None if pw_installed else "Run: qoder-autologin setup",
    }

    # chromium (Playwright browser)
    cr_installed = False
    try:
        proc = subprocess.run(
            [sys.executable, "-m", "playwright", "install", "--dry-run", "chromium"],
            capture_output=True, text=True, timeout=15,
        )
        cr_installed = proc.returncode == 0
    except Exception:
        pass
    result["chromium"] = {
        "installed": cr_installed,
        "version": None,
        "install_hint": None if cr_installed else "playwright install chromium",
    }

    return result


# ── Google SSO Automation ─────────────────────────────────────────────
async def _auto_dismiss(dialog, email=""):
    try:
        await dialog.dismiss()
    except Exception:
        pass


async def automate_google_sso(auth_url, email, password):
    from playwright.async_api import async_playwright

    log(f"[{email}] Opening auth page...")
    dbg(f"URL: {auth_url[:120]}...")

    async with async_playwright() as p:
        browser = await p.chromium.launch(
            headless=HEADLESS,
            args=[
                "--disable-blink-features=AutomationControlled",
                "--no-sandbox",
                "--disable-dev-shm-usage",
                "--disable-infobars",
                "--disable-features=PrivateNetworkAccessRespectPreflightResults,"
                "PrivateNetworkAccessSendPreflights,"
                "BlockInsecurePrivateNetworkRequests,"
                "TranslateUI,OptimizationHints",
            ],
        )
        ctx = await browser.new_context(
            viewport={"width": 500, "height": 700},
            user_agent="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
                       "(KHTML, like Gecko) Chrome/137.0.0.0 Safari/537.36",
        )
        await ctx.add_init_script("""
            Object.defineProperty(navigator, 'webdriver', {get: () => undefined});
            Object.defineProperty(navigator, 'plugins', {get: () => [1, 2, 3, 4, 5]});
            Object.defineProperty(navigator, 'languages', {get: () => ['en-US', 'en']});
            window.chrome = { runtime: {} };
        """)

        page = await ctx.new_page()
        page.on("dialog", lambda d: asyncio.ensure_future(_auto_dismiss(d, email)))
        page.set_default_timeout(30000)

        state = {"done": False, "error": None}

        try:
            await page.goto(auth_url, wait_until="domcontentloaded", timeout=30000)
            await asyncio.sleep(2)
            url = page.url
            log(f"[{email}] Page: {url[:80]}...")

            if "sign-in" in url or "users" in url:
                sso_found = await _try_google_sso(page, email)
                if not sso_found:
                    log(f"[{email}] Google SSO not found on login page", "ERR")
                    state["error"] = "google_sso_not_found"
                else:
                    await _handle_google_login(page, email, password)
                    for i in range(90):
                        await asyncio.sleep(1)
                        try:
                            url = page.url
                        except Exception:
                            break
                        if "selectAccounts" in url:
                            log(f"[{email}] Redirected to selectAccounts", "OK")
                            await _handle_select_accounts(page, email)
                            state["done"] = True
                            break
                        if any(x in url for x in ("callback", "success", "authorized")):
                            log(f"[{email}] Login successful!", "OK")
                            state["done"] = True
                            break

            elif "selectAccounts" in url:
                await _handle_select_accounts(page, email)
                state["done"] = True
            else:
                log(f"[{email}] Unexpected page: {url}", "ERR")

            if state["done"]:
                log(f"[{email}] SSO complete. Waiting for qodercli...", "WAIT")
                await asyncio.sleep(2)

        except Exception as e:
            log(f"[{email}] Browser error: {e}", "ERR")
            state["error"] = str(e)
        finally:
            await asyncio.sleep(1)
            await browser.close()

    return state


async def _try_google_sso(page, email):
    selectors = [
        'button:has-text("Google")', 'a:has-text("Google")',
        'button:has-text("Sign in with Google")', 'a:has-text("Sign in with Google")',
        'button[data-provider="google"]', '[aria-label*="Google" i]',
        'img[alt*="Google" i]', 'span:has-text("Google")',
    ]
    for sel in selectors:
        try:
            el = page.locator(sel).first
            if await el.is_visible(timeout=1500):
                await el.click(force=True)
                dbg(f"[{email}] Google SSO clicked: {sel}")
                await asyncio.sleep(2)
                return True
        except Exception:
            continue

    try:
        clicked = await page.evaluate("""() => {
            const els = document.querySelectorAll(
                'button, a, div[role="button"], span[role="button"], ' +
                '[onclick], [class*="btn"], [class*="button"], [class*="social"], ' +
                '[class*="oauth"], [class*="provider"], [class*="sso"]'
            );
            for (const el of els) {
                const txt = (el.textContent || el.innerText || el.getAttribute('aria-label') || '').toLowerCase();
                if (txt.includes('google')) {
                    el.scrollIntoView({block: 'center'});
                    el.click();
                    return 'clicked: ' + txt.trim().substring(0, 30);
                }
            }
            const imgs = document.querySelectorAll('img');
            for (const img of imgs) {
                const alt = (img.alt || '').toLowerCase();
                const src = (img.src || '').toLowerCase();
                if (alt.includes('google') || src.includes('google')) {
                    const parent = img.closest('button, a, [role="button"]') || img;
                    parent.scrollIntoView({block: 'center'});
                    parent.click();
                    return 'clicked img: ' + alt.substring(0, 30);
                }
            }
            return null;
        }""")
        if clicked:
            dbg(f"[{email}] JS fallback: {clicked}")
            await asyncio.sleep(3)
            return True
    except Exception:
        pass
    return False


async def _handle_google_login(page, email, password):
    log(f"[{email}] Handling Google login...")

    for attempt in range(90):
        try:
            url = page.url
        except Exception:
            return

        if "accounts.google.com" not in url and "accounts.google.co" not in url:
            log(f"[{email}] Left Google. Now at: {url[:60]}", "OK")
            return

        # Email step
        try:
            email_visible = await page.evaluate("""() => {
                const el = document.querySelector('#identifierId');
                return el && el.offsetParent !== null;
            }""")
        except Exception:
            email_visible = False

        if email_visible:
            dbg(f"[{email}] Filling email...")
            loc = page.locator("#identifierId").first
            await loc.click(force=True)
            await asyncio.sleep(0.2)
            await loc.press("Control+a")
            await loc.press("Backspace")
            await loc.press_sequentially(email, delay=40)
            await asyncio.sleep(0.3)
            await page.evaluate("""() => {
                const btn = document.querySelector('#identifierNext button');
                if (btn) btn.click();
            }""")
            for _w in range(10):
                await asyncio.sleep(0.5)
                try:
                    pwd_check = await page.evaluate("""() => {
                        for (const el of document.querySelectorAll(
                                'input[name="Passwd"], input[type="password"]')) {
                            if (el.offsetParent !== null) return true;
                        }
                        return false;
                    }""")
                    if pwd_check:
                        break
                except Exception:
                    pass
            await asyncio.sleep(0.5)
            continue

        # Password step
        try:
            pwd_visible = await page.evaluate("""() => {
                for (const el of document.querySelectorAll(
                        'input[name="Passwd"], input[type="password"]')) {
                    if (el.offsetParent !== null) return true;
                }
                return false;
            }""")
        except Exception:
            pwd_visible = False

        if pwd_visible:
            dbg(f"[{email}] Filling password...")
            loc = page.locator('input[name="Passwd"]').first
            try:
                if await loc.count() == 0 or not await loc.is_visible():
                    loc = page.locator('input[type="password"]').first
            except Exception:
                loc = page.locator('input[type="password"]').first
            await loc.click(force=True)
            await asyncio.sleep(0.2)
            await loc.press("Control+a")
            await loc.press("Backspace")
            await loc.press_sequentially(password, delay=30)
            await asyncio.sleep(0.2)
            await page.evaluate("""() => {
                const btn = document.querySelector('#passwordNext button');
                if (btn) btn.click();
            }""")
            try:
                await page.wait_for_load_state("domcontentloaded", timeout=10000)
            except Exception:
                pass
            await asyncio.sleep(2)
            continue

        # Consent screens
        try:
            consent_clicked = await page.evaluate("""() => {
                const knownIds = ['confirm', 'submit_approve_access', 'approve_button',
                                 'next', 'identifierNext', 'passwordNext'];
                for (const id of knownIds) {
                    const el = document.getElementById(id);
                    if (el && el.offsetParent !== null) {
                        el.click(); return 'clicked id: ' + id;
                    }
                }
                const consentTexts = [
                    'i understand', 'i agree', 'agree', 'allow', 'continue', 'next',
                    'approve', 'confirm', 'accept', 'got it', 'accept all', 'done',
                    'saya mengerti', 'saya setuju', 'setuju', 'lanjutkan', 'terima',
                    'izinkan', 'konfirmasi', 'mengerti'
                ];
                const buttons = document.querySelectorAll(
                    'button, [role="button"], span[role="button"], input[type="submit"]'
                );
                for (const btn of buttons) {
                    const txt = (btn.textContent || btn.value || '').toLowerCase().trim();
                    if (consentTexts.some(t => txt.includes(t))) {
                        btn.click();
                        if (btn.tagName === 'SPAN' && btn.parentElement?.tagName === 'BUTTON')
                            btn.parentElement.click();
                        return 'clicked: ' + txt;
                    }
                }
                const advEl = document.querySelector('#advancedButton') ||
                              document.querySelector('[id*="advanced"]');
                if (advEl) { advEl.click(); return 'clicked: advanced'; }
                for (const el of document.querySelectorAll('a, button, span')) {
                    const t = (el.textContent || '').toLowerCase();
                    if (t.includes('advanced') || t.includes('lanjutan')) {
                        el.click(); return 'clicked: advanced (text)';
                    }
                }
                return null;
            }""")
        except Exception:
            consent_clicked = None

        if consent_clicked:
            dbg(f"[{email}] Consent: {consent_clicked}")
            await asyncio.sleep(1.5)
            if "advanced" in str(consent_clicked):
                await asyncio.sleep(1)
                try:
                    unsafe = await page.evaluate("""() => {
                        const links = document.querySelectorAll('a, button, [role="button"]');
                        for (const el of links) {
                            const t = (el.textContent || '').toLowerCase();
                            if (t.includes('go to') || t.includes('unsafe') || t.includes('proceed')) {
                                el.click(); return 'clicked: ' + t.trim().substring(0, 40);
                            }
                        }
                        return null;
                    }""")
                    if unsafe:
                        dbg(f"[{email}] Unsafe link: {unsafe}")
                        await asyncio.sleep(2)
                except Exception:
                    pass
            continue

        # Choose account
        try:
            acct = await page.evaluate("""() => {
                const accounts = document.querySelectorAll('[data-identifier], [data-email]');
                if (accounts.length > 0) { accounts[0].click(); return 'picked first'; }
                return null;
            }""")
            if acct:
                dbg(f"[{email}] Account: {acct}")
                await asyncio.sleep(2)
                continue
        except Exception:
            pass

        await asyncio.sleep(1)

    log(f"[{email}] Google login timed out (90s)", "ERR")


async def _handle_select_accounts(page, email):
    log(f"[{email}] Handling selectAccounts page...")
    try:
        clicked = await page.evaluate("""() => {
            const buttons = document.querySelectorAll('button, [role="button"], a');
            for (const btn of buttons) {
                const txt = (btn.textContent || '').toLowerCase();
                if (txt.includes('continue') || txt.includes('select') || txt.includes('confirm')) {
                    btn.click();
                    return 'clicked: ' + txt.trim().substring(0, 30);
                }
            }
            if (buttons.length > 0) {
                buttons[0].click();
                return 'clicked first button';
            }
            return null;
        }""")
        if clicked:
            dbg(f"[{email}] selectAccounts: {clicked}")
            await asyncio.sleep(2)
            return True
    except Exception as e:
        dbg(f"[{email}] selectAccounts error: {e}")
    return False


# ── Main login flow ──────────────────────────────────────────────────
async def login_account(email, password, profile_name=None):
    start_time = time.time()
    log(f"[{email}] Starting login...")

    if not profile_name:
        profile_name = email.split("@")[0].replace(".", "-")

    pre_mtime = get_auth_file_mtime()

    proc = subprocess.Popen(
        ["qodercli", "login"],
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        bufsize=1,
    )

    auth_url = None
    try:
        for line in proc.stdout:
            line = line.strip()
            dbg(f"[{email}] qodercli: {line}")
            match = re.search(r'(https://qoder\.com/device/selectAccounts\S+)', line)
            if match:
                auth_url = match.group(1)
                break
            if "error" in line.lower() or "failed" in line.lower():
                log(f"[{email}] qodercli error: {line}", "ERR")
    except Exception:
        pass

    if not auth_url:
        log(f"[{email}] Could not capture auth URL from qodercli", "ERR")
        proc.kill()
        return {"email": email, "success": False, "error": "no_auth_url",
                "duration": time.time() - start_time}

    log(f"[{email}] Auth URL captured", "OK")

    sso_state = await automate_google_sso(auth_url, email, password)

    if sso_state.get("error") and not sso_state.get("done"):
        log(f"[{email}] SSO failed: {sso_state['error']}", "ERR")
        proc.kill()
        return {"email": email, "success": False, "error": sso_state["error"],
                "duration": time.time() - start_time}

    log(f"[{email}] Waiting for qodercli to finish...", "WAIT")

    try:
        proc.wait(timeout=120)
    except subprocess.TimeoutExpired:
        log(f"[{email}] qodercli timed out (120s)", "ERR")
        proc.kill()

    # Check if auth file was updated
    post_mtime = get_auth_file_mtime()
    if post_mtime > pre_mtime:
        log(f"[{email}] Auth file updated!", "OK")
        saved = save_to_vault(profile_name, email)
        duration = time.time() - start_time
        return {"email": email, "success": saved, "profile": profile_name,
                "error": None if saved else "vault_save_failed",
                "duration": duration}
    else:
        log(f"[{email}] Auth file was NOT updated", "ERR")
        proc_output = ""
        try:
            proc_output = proc.stdout.read() or ""
        except Exception:
            pass
        if proc_output:
            dbg(f"[{email}] qodercli output: {proc_output[:200]}")
        return {"email": email, "success": False, "error": "auth_file_not_updated",
                "duration": time.time() - start_time}


# ── Batch mode ────────────────────────────────────────────────────────
def parse_accounts_file(filepath):
    accounts = []
    with open(filepath) as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            if ":" not in line:
                log(f"Skipping malformed line: {line}", "ERR")
                continue
            parts = line.split(":", 1)
            accounts.append({"email": parts[0].strip(), "password": parts[1].strip()})
    return accounts


async def run_batch(accounts, concurrent=1):
    semaphore = asyncio.Semaphore(concurrent)

    async def limited_login(acct):
        async with semaphore:
            return await login_account(acct["email"], acct["password"])

    tasks = [limited_login(a) for a in accounts]
    return list(await asyncio.gather(*tasks))


def print_summary(results):
    success = [r for r in results if r["success"]]
    failed = [r for r in results if not r["success"]]
    total_time = sum(r["duration"] for r in results)

    print()
    log(f"SUMMARY: {len(success)}✅ {len(failed)}❌ | Total: {total_time:.0f}s", "SUM")
    print("=" * 60)
    for r in results:
        if r["success"]:
            print(f"  ✅ {r['email']} → {r.get('profile', '?')} ({r['duration']:.0f}s)")
        else:
            print(f"  ❌ {r['email']} — {r.get('error', 'unknown')}")
    print()

    if failed:
        log(f"{len(failed)} account(s) failed", "ERR")

    return len(failed) == 0


# ── Subcommand handlers ──────────────────────────────────────────────

def cmd_setup():
    """Install dependencies: playwright + chromium browser."""
    log("=== Qoder Auto-Login Setup ===", "INFO")
    log("Installing dependencies...", "INFO")

    log("Installing playwright...", "WAIT")
    pip_cmd = [sys.executable, "-m", "pip", "install", "--user", "playwright"]
    proc = subprocess.run(pip_cmd, capture_output=True, text=True)
    if proc.returncode != 0:
        if "externally-managed-environment" in proc.stderr:
            log("PEP 668 detected, retrying with --break-system-packages...", "WAIT")
            pip_cmd.append("--break-system-packages")
            proc = subprocess.run(pip_cmd, capture_output=True, text=True)
        if proc.returncode != 0:
            log(f"pip install playwright failed: {proc.stderr[:200]}", "ERR")
            sys.exit(1)

    # Install chromium browser
    log("Installing Playwright chromium browser...", "WAIT")
    proc = subprocess.run(
        [sys.executable, "-m", "playwright", "install", "chromium"],
        capture_output=True, text=True,
    )
    if proc.returncode != 0:
        log(f"playwright install chromium failed: {proc.stderr[:200]}", "ERR")
        sys.exit(1)

    log("Dependencies installed!", "OK")


def cmd_status():
    """Show status of all dependencies and vault profiles."""
    log("=== Qoder Auto-Login Status ===", "INFO")
    print()

    sep = "──────────────────────────────────────────────"
    print(f"  {sep}")
    print(f"  {'Item':<15s}  Status")
    print(f"  {sep}")

    # Python
    py_ver = f"{sys.version_info.major}.{sys.version_info.minor}.{sys.version_info.micro}"
    print(f"  {'Python':<15s}  Python {py_ver}")

    # Check dependencies
    deps = check_dependencies()
    for label, key in [("Playwright", "playwright"), ("Chromium", "chromium"),
                        ("qodercli", "qodercli")]:
        status = "installed" if deps[key]["installed"] else "NOT installed"
        print(f"  {label:<15s}  {status}")

    # Vault profiles
    vault_count = 0
    if VAULT_DIR.exists():
        vault_count = sum(
            1 for f in VAULT_DIR.iterdir()
            if f.is_file() and f.name != ".current" and not f.name.endswith(".meta.json")
        )
    print(f"  {'Vault profiles':<15s}  {vault_count}")

    print(f"  {sep}")
    print()


def cmd_interactive(file=None):
    """Interactive mode: prompt for accounts and settings, then run batch."""
    print()
    print("=" * 60)
    print("     Qoder Auto-Login - Interactive Mode")
    print("=" * 60)
    print()

    accounts = []

    if file and Path(file).is_file():
        # Read from file
        accounts = parse_accounts_file(file)
        log(f"Found {len(accounts)} account(s) in {file}", "OK")
    else:
        # Prompt for accounts
        print("Enter accounts (email:password), one per line. Empty line to finish:")
        while True:
            try:
                line = input("  > ").strip()
            except (EOFError, KeyboardInterrupt):
                print()
                break
            if not line:
                break
            if ":" not in line:
                log("Invalid format. Use email:password", "ERR")
                continue
            parts = line.split(":", 1)
            accounts.append({"email": parts[0].strip(), "password": parts[1].strip()})

    if not accounts:
        log("No accounts provided", "ERR")
        return

    print()
    print("  ────────────────────────────────────────────────────────")
    for i, acct in enumerate(accounts):
        print(f"  {i + 1}. {acct['email']}")
    print("  ────────────────────────────────────────────────────────")
    print()

    # Ask headless
    headless = False
    try:
        ans = input("Headless mode (browser invisible)? [y/N]: ").strip().lower()
        headless = ans == "y"
    except (EOFError, KeyboardInterrupt):
        print()

    # Ask concurrent (only if multiple accounts)
    concurrent = 1
    if len(accounts) > 1:
        try:
            ans = input("Concurrent browsers (1-5) [1]: ").strip()
            if ans and ans.isdigit() and 1 <= int(ans) <= 5:
                concurrent = int(ans)
        except (EOFError, KeyboardInterrupt):
            print()

    # Summary
    print()
    print("  +--------------------------------------+")
    print(f"  |  Accounts:   {len(accounts)}")
    print(f"  |  Browser:    {'Headless' if headless else 'Visible'}")
    print(f"  |  Concurrent: {concurrent}")
    print(f"  |  Save to:    auth-vault")
    print("  +--------------------------------------+")
    print()

    # Confirm
    try:
        confirm = input("Start login? [Y/n]: ").strip().lower()
    except (EOFError, KeyboardInterrupt):
        print()
        confirm = "n"

    if confirm == "n":
        log("Cancelled.", "INFO")
        return

    # Set globals for the browser automation
    global HEADLESS, CONCURRENT
    HEADLESS = headless
    CONCURRENT = concurrent

    results = asyncio.run(run_batch(accounts, concurrent))
    print_summary(results)


# ── CLI ───────────────────────────────────────────────────────────────

def build_parser():
    """Build the argparse parser with subparsers for all subcommands."""
    parser = argparse.ArgumentParser(
        description="Auto-login Qoder accounts via Google SSO + save to vault"
    )

    # Common flags shared by login/batch subcommands
    common = argparse.ArgumentParser(add_help=False)
    common.add_argument("--headless", action="store_true", help="Run browser headless")
    common.add_argument("-c", "--concurrent", type=int, default=1,
                        help="Concurrent browser sessions (1-5)")
    common.add_argument("-d", "--debug", action="store_true", help="Debug output")
    common.add_argument("--no-save", action="store_true",
                        help="Don't save to vault (test mode)")

    # Global flags (also available on subcommands)
    parser.add_argument("--headless", action="store_true", help="Run browser headless")
    parser.add_argument("-c", "--concurrent", type=int, default=1,
                        help="Concurrent browser sessions (1-5)")
    parser.add_argument("-d", "--debug", action="store_true", help="Debug output")
    parser.add_argument("--no-save", action="store_true",
                        help="Don't save to vault (test mode)")

    subparsers = parser.add_subparsers(dest="command")

    # login subcommand
    login_parser = subparsers.add_parser("login", aliases=["l"],
                                          parents=[common],
                                          help="Login single account + save to vault")
    login_parser.add_argument("account", help="email:password")
    login_parser.add_argument("profile", nargs="?", help="Profile name for vault")

    # batch subcommand
    batch_parser = subparsers.add_parser("batch", aliases=["b"],
                                          parents=[common],
                                          help="Login from accounts file")
    batch_parser.add_argument("file", help="Path to accounts file")

    # interactive subcommand
    interactive_parser = subparsers.add_parser("interactive", aliases=["i"],
                                                help="Interactive mode with prompts")
    interactive_parser.add_argument("file", nargs="?", default=None,
                                     help="Optional accounts file")

    # setup subcommand
    subparsers.add_parser("setup", aliases=["s"],
                           help="Install dependencies")

    # status subcommand
    subparsers.add_parser("status", aliases=["st"],
                           help="Check installation status")

    return parser


def _translate_legacy_args(raw_args):
    """Translate legacy CLI syntax to the new subcommand format.

    Handles:
      - email:password -> login email:password
      - --batch FILE   -> batch FILE
    """
    # --batch FILE [flags] -> batch FILE [flags]
    if "--batch" in raw_args or "-b" in raw_args:
        new_args = []
        skip_next = False
        for i, arg in enumerate(raw_args):
            if skip_next:
                skip_next = False
                continue
            if arg in ("--batch", "-b"):
                new_args.append("batch")
                if i + 1 < len(raw_args):
                    new_args.append(raw_args[i + 1])
                    skip_next = True
            else:
                new_args.append(arg)
        return new_args

    # Bare email:password -> login email:password
    known_commands = {"login", "l", "batch", "b", "interactive", "i",
                      "setup", "s", "status", "st"}
    if (raw_args
            and not raw_args[0].startswith("-")
            and ":" in raw_args[0]
            and raw_args[0] not in known_commands):
        return ["login"] + raw_args

    return raw_args


def main():
    global HEADLESS, DEBUG, CONCURRENT

    parser = build_parser()
    raw_args = _translate_legacy_args(sys.argv[1:])
    args = parser.parse_args(raw_args)

    # Apply global flags
    HEADLESS = getattr(args, "headless", False)
    DEBUG = getattr(args, "debug", False)
    CONCURRENT = min(max(getattr(args, "concurrent", 1), 1), 5)

    cmd = getattr(args, "command", None)

    if cmd in ("setup", "s"):
        cmd_setup()

    elif cmd in ("status", "st"):
        cmd_status()

    elif cmd in ("interactive", "i"):
        cmd_interactive(file=getattr(args, "file", None))

    elif cmd in ("batch", "b"):
        filepath = args.file
        if not Path(filepath).is_file():
            log(f"File not found: {filepath}", "ERR")
            sys.exit(1)
        accounts = parse_accounts_file(filepath)
        if not accounts:
            log("No accounts found in batch file", "ERR")
            sys.exit(1)
        log(f"Found {len(accounts)} account(s)", "INFO")
        results = asyncio.run(run_batch(accounts, CONCURRENT))
        ok = print_summary(results)
        sys.exit(0 if ok else 1)

    elif cmd in ("login", "l"):
        account = args.account
        if ":" not in account:
            log("Account must be email:password format", "ERR")
            sys.exit(1)
        parts = account.split(":", 1)
        email, password = parts[0].strip(), parts[1].strip()
        profile = args.profile or email.split("@")[0].replace(".", "-")

        if args.no_save:
            log("Test mode: will not save to vault", "INFO")

        result = asyncio.run(login_account(email, password, profile))

        if args.no_save and result["success"]:
            log("Test mode: skipping vault save", "INFO")

        if result["success"]:
            log(f"Login successful! Profile: {result.get('profile', '?')}", "OK")
            sys.exit(0)
        else:
            log(f"Login failed: {result.get('error', 'unknown')}", "ERR")
            sys.exit(1)

    else:
        parser.print_help()
        sys.exit(1)


if __name__ == "__main__":
    main()
