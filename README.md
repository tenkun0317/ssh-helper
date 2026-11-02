# ssh-helper

One-command CLI to register, verify, and revoke SSH public keys, written in Rust.

`ssh-helper` wraps the OpenSSH client tools (`ssh`, `ssh-keygen`, `ssh-add`, `ssh-keyscan`) and automates the repetitive parts of SSH key management:

- Register your public key on a new host with a single command (the password is used at most once)
- Verify key authentication on all hosts in parallel
- Audit `authorized_keys` on every host against your local keys
- Revoke keys safely, with automatic backups and post-removal verification

Works on Windows and Linux. UI messages are in English.

## Features

- **Managed config block**: writes host entries into `~/.ssh/config.d/managed` and adds an `Include config.d/managed` line to `~/.ssh/config` (creating the config file if it does not exist)
- **Safe writes**: every config/key modification creates a timestamped `.bak-*` backup, is validated with `ssh -G`, and is rolled back automatically on failure
- **Host key pinning**: with `-F SHA256:...`, the host key is fetched with `ssh-keyscan`, verified against your fingerprints, and only then added to `known_hosts`
- **Password used at most once**: if key auth already works, the registration runs non-interactively (BatchMode)
- **Windows ACL handling**: config files are locked down to the current user with `icacls` so Windows OpenSSH accepts them

## Install / Build

```sh
cargo build --release
```

The binary is `target/release/ssh-helper`. Requires OpenSSH tools on `PATH`.

## Usage

```text
ssh-helper [OPTIONS] <COMMAND>
```

Global options: `-y` / `--yes` (auto-approve prompts), `-v` / `--verbose`, `--no-color`.

| Command | Description |
| --- | --- |
| `register [ALIAS]` | Register the public key on a host. Creates `~/.ssh/config` and an ed25519 key automatically if missing. Options: `-J` jump hosts, `-H` hostname, `-u` user, `-i` pubkey files, `-F` trusted fingerprints, `-n` dry-run, `--interactive` |
| `check` | Verify key authentication on all hosts in parallel. Options: `--timeout`, `--jobs`, `--format text|json` |
| `revoke [ALIAS]` | Remove your public key(s) from a host's `authorized_keys` (automatic backup, warns if the file becomes empty) |
| `backup list` / `backup restore [NAME]` / `backup prune --keep N` | Manage `.bak-*` backups |
| `show [ALIAS]` | Show `ssh -G` resolution results |
| `audit [TARGETS]...` | Compare `authorized_keys` fingerprints on each host with your local keys (`PRESENT` / `UNKNOWN` / `MISSING` / `UNREACHABLE`) |
| `keygen` | Generate an ed25519 key if none exists (`-f` to recreate) |
| `agent [status]` | Check ssh-agent and register missing keys |
| `doctor` | Diagnose the environment (ssh, config, keys, agent, Include line) |
| `completion <SHELL>` | Generate shell completions |

## Environment variables

| Variable | Purpose |
| --- | --- |
| `SSH_HELPER_DEFAULT_USER` | Default user for new host entries (falls back to the OS user with a warning) |
| `SSH_HELPER_TRUST_FINGERPRINTS` | Additional trusted host key fingerprints, comma-separated (merged with `-F`) |
| `SSH_HELPER_NO_AGENT=1` | Skip agent registration in `keygen` |
| `NO_COLOR` | Disable colored output |

## Development

```sh
cargo fmt --all
cargo clippy --all-targets -- -D warnings
cargo test
```

CI (`.github/workflows/ci.yml`) runs fmt, clippy, and tests on both Ubuntu and Windows.

## License

MIT
