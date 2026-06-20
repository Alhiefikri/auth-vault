# Auth Vault

TUI-based credential manager for AI coding tools. Manages OpenAI accounts (OMP, Pi, OpenCode, Codex) and Qoder CLI profiles with one-click switching.

## Features

- **Dashboard** - Overview of all AI tool accounts with usage bars
- **Switch OpenAI** - Apply saved profiles to OMP + Pi simultaneously
- **Switch Qoder CLI** - Swap encrypted auth profiles
- **Save Accounts** - Import from OpenCode/Codex or save current Qoder CLI auth
- **Usage Monitoring** - Hourly/weekly quota bars for OpenAI, credits for Qoder

## Requirements

- `fzf` - Interactive selection
- `jq` - JSON processing
- `sqlite3` - OMP database access
- `python3` - Token handling

## Install

```bash
git clone https://github.com/Alhiefikri/auth-vault.git
cd auth-vault
chmod +x auth-vault
ln -s "$(pwd)/auth-vault" ~/.local/bin/auth-vault
```

## Usage

```bash
auth-vault
```

### Quick Commands (included tools)

```bash
# Sync OpenAI accounts to OMP + Pi
sync-ai-auth              # Auto-detect source
sync-ai-auth cockpit      # From Cockpit Tools
sync-ai-auth --status     # Show all accounts

# Qoder CLI profile management
qoder-auth-swap save <name>   # Save current auth
qoder-auth-swap use <name>    # Switch profile
qoder-auth-swap list          # List profiles
```

## Data Storage

All credentials are stored locally in `~/.auth-vault/`:

```
~/.auth-vault/
├── openai/          # OpenAI OAuth profiles (JSON)
└── qoder/           # Qoder CLI encrypted auth files
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

## Companion Tools

This project works alongside:

- [Cockpit Tools](https://github.com/jlcodes99/cockpit-tools) - AI IDE account manager
- [OpenCode](https://github.com/opencode-ai/opencode) - AI coding assistant
- [OMP](https://github.com/oh-my-pi/omp) - Oh My Pi coding agent

## License

MIT
