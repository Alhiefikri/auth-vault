# Auth Vault

TUI-based credential manager for AI coding tools. Manages OpenAI accounts (OMP, Pi, OpenCode, Codex) and Qoder CLI profiles with one-click switching.

## Features

- **Dashboard** - Overview of all AI tool accounts with usage bars
- **Switch OpenAI** - Apply saved profiles to OMP + Pi simultaneously
- **Switch Qoder CLI** - Swap encrypted auth profiles
- **Auto-Login Qoder** - Google SSO automation + save directly to vault (no 9router needed)
- **Save Accounts** - Import from OpenCode/Codex or save current Qoder CLI auth
- **Usage Monitoring** - Hourly/weekly quota bars for OpenAI, credits for Qoder

## Requirements

- `fzf` - Interactive selection
- `jq` - JSON processing
- `sqlite3` - OMP database access
- `python3` - Token handling
- `playwright` + `chromium` - For auto-login (optional, installed via setup)

## Install

```bash
git clone https://github.com/Alhiefikri/auth-vault.git
cd auth-vault
chmod +x auth-vault qoder-autologin qoder-autologin.py
ln -s "$(pwd)/auth-vault" ~/.local/bin/auth-vault
ln -s "$(pwd)/qoder-auth-swap" ~/.local/bin/qoder-auth-swap
ln -s "$(pwd)/qoder-autologin" ~/.local/bin/qoder-autologin

# Optional: install playwright for auto-login
./qoder-autologin setup
```

## Usage

### TUI (Interactive)

```bash
auth-vault
```

Menu:
1. **OpenAI** - View/switch OpenAI accounts
2. **Qoder CLI** - View/switch Qoder profiles from vault
3. **Simpan Qoder CLI** - Save current Qoder auth as profile
4. **Hapus Profile Qoder** - Delete a saved profile
5. **Auto-Login Qoder** - Login via Google SSO + save to vault

### Quick Commands

```bash
# Sync OpenAI accounts to OMP + Pi
sync-ai-auth              # Auto-detect source
sync-ai-auth cockpit      # From Cockpit Tools
sync-ai-auth --status     # Show all accounts

# Qoder CLI profile management
qoder-auth-swap save <name>   # Save current auth
qoder-auth-swap use <name>    # Switch profile
qoder-auth-swap list          # List profiles

# Auto-login (Google SSO + vault)
qoder-auth-swap login user@gmail.com:pass123 akun-utama
qoder-auth-swap batch-login accounts.txt
qoder-autologin login user@gmail.com:pass123 akun-utama
qoder-autologin batch accounts.txt
qoder-autologin interactive   # Interactive mode with prompts
```

### Auto-Login (Google SSO)

Login Qoder accounts automatically via Google SSO, save directly to auth-vault.
No 9router required - accounts are stored in `~/.auth-vault/qoder/`.

```bash
# Single account
qoder-autologin login user@gmail.com:password123 akun-utama

# Batch from file
qoder-autologin batch accounts.txt

# Interactive mode
qoder-autologin interactive accounts.txt

# Options
qoder-autologin login user@gmail.com:pass --headless  # Headless browser
qoder-autologin batch accounts.txt -c 2               # 2 concurrent browsers
```

**Batch file format** (`accounts.txt`):
```
# Comments start with #
email1@gmail.com:password1
email2@gmail.com:password2
```

**How it works:**
1. Runs `qodercli login` (handles PKCE + token + WASM encryption internally)
2. Captures the auth URL from qodercli output
3. Opens Playwright browser, automates Google SSO (email, password, consent screens)
4. After qodercli completes, copies the encrypted auth file to vault
5. Switch between accounts anytime with `qoder-auth-swap use <name>`

## Data Storage

All credentials are stored locally in `~/.auth-vault/`:

```
~/.auth-vault/
├── openai/          # OpenAI OAuth profiles (JSON)
└── qoder/           # Qoder CLI encrypted auth files
    ├── .current     # Active profile name
    ├── akun-a       # Encrypted auth file
    ├── akun-a.meta.json  # Metadata (email, saved_at)
    ├── akun-b
    └── akun-b.meta.json
```

No data is sent to external servers.

## Supported Tools

| Tool | Auth Method | Storage |
|------|------------|---------|
| OMP (Oh My Pi) | SQLite DB | `~/.omp/agent/agent.db` |
| Pi | JSON file | `~/.pi/agent/auth.json` |
| OpenCode | JSON file | `~/.local/share/opencode/auth.json` |
| Codex CLI | JSON file | `~/.codex/auth.json` |
| Qoder CLI | Encrypted file | `~/.qoder/.auth/user` |

## File Structure

```
auth-vault/
├── auth-vault            # Main TUI script
├── qoder-auth-swap       # CLI profile manager
├── qoder-autologin       # Auto-login bash wrapper
├── qoder-autologin.py    # Auto-login Python core
├── sync-ai-auth          # OpenAI sync tool
├── accounts.txt.example  # Batch file template
└── README.md
```

## Companion Tools

This project works alongside:

- [Cockpit Tools](https://github.com/jlcodes99/cockpit-tools) - AI IDE account manager
- [OpenCode](https://github.com/opencode-ai/opencode) - AI coding assistant
- [OMP](https://github.com/oh-my-pi/omp) - Oh My Pi coding agent

## License

MIT
