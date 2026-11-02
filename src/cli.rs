use clap::{Parser, Subcommand, ValueEnum};

#[derive(Parser, Debug)]
#[command(
    name = "ssh-helper",
    version,
    about = "One-command CLI to register, verify, and revoke SSH public keys",
    long_about = None
)]
pub struct Cli {
    #[arg(long, global = true, help = "Disable colored output")]
    pub no_color: bool,

    #[arg(short, long, global = true, help = "Verbose output")]
    pub verbose: bool,

    #[arg(
        short = 'y',
        long,
        global = true,
        help = "Skip confirmation prompts (auto-approve dangerous operations)"
    )]
    pub yes: bool,

    #[command(subcommand)]
    pub command: Commands,
}

#[derive(Subcommand, Debug)]
pub enum Commands {
    #[command(about = "Register a public key on a new host (password used at most once)")]
    Register(RegisterArgs),
    #[command(about = "Verify key authentication on all hosts in parallel")]
    Check(CheckArgs),
    #[command(about = "Revoke a public key (remove from authorized_keys)")]
    Revoke(RevokeArgs),
    #[command(about = "Manage config backups")]
    Backup(BackupArgs),
    #[command(about = "Show ssh -G resolution results")]
    Show(ShowArgs),
    #[command(about = "Audit authorized_keys on each host")]
    Audit(AuditArgs),
    #[command(about = "Generate an ed25519 key if no local key exists")]
    Keygen(KeygenArgs),
    #[command(about = "Check the agent and register missing keys")]
    Agent(AgentArgs),
    #[command(about = "Diagnose the environment (permissions, agent, config, keys)")]
    Doctor(DoctorArgs),
    #[command(about = "Generate shell completion scripts")]
    Completion(CompletionArgs),
}

#[derive(clap::Args, Debug)]
pub struct RegisterArgs {
    #[arg(help = "Host alias (prompted interactively if omitted)")]
    pub alias: Option<String>,
    #[arg(
        short = 'J',
        long,
        help = "Comma-separated jump hosts (e.g. bastion,internal). Empty string for direct connection"
    )]
    pub jump: Option<String>,
    #[arg(
        short = 'H',
        long = "host",
        help = "HostName in config (defaults to alias / keeps existing value)"
    )]
    pub real_host: Option<String>,
    #[arg(
        short,
        long,
        help = "User in config (existing value / SSH_HELPER_DEFAULT_USER / OS user if omitted)"
    )]
    pub user: Option<String>,
    #[arg(
        short = 'i',
        long = "pubkey",
        help = "Public key files (repeatable; defaults to existing ed25519/rsa)"
    )]
    pub pubkey: Vec<String>,
    #[arg(
        short = 'F',
        long = "fingerprint",
        help = "Trusted host key fingerprints SHA256:... (repeatable, comma-separated)"
    )]
    pub fingerprint: Vec<String>,
    #[arg(
        short = 'n',
        long = "dry-run",
        help = "Show changes without applying them"
    )]
    pub dry_run: bool,
    #[arg(long, help = "Force the interactive wizard")]
    pub interactive: bool,
}

#[derive(clap::Args, Debug)]
pub struct CheckArgs {
    #[arg(long, default_value_t = 10, help = "Connection timeout in seconds")]
    pub timeout: u64,
    #[arg(
        long,
        value_enum,
        default_value_t = Format::Text,
        help = "Output format"
    )]
    pub format: Format,
    #[arg(long, default_value_t = 0, help = "Parallelism (0 = auto)")]
    pub jobs: usize,
}

#[derive(clap::Args, Debug)]
pub struct RevokeArgs {
    #[arg(help = "Host alias")]
    pub alias: Option<String>,
    #[arg(short, long, help = "User override to form user@alias")]
    pub user: Option<String>,
    #[arg(short = 'i', long = "pubkey", help = "Public key files (repeatable)")]
    pub pubkey: Vec<String>,
    #[arg(
        short = 'n',
        long = "dry-run",
        help = "Show changes without applying them"
    )]
    pub dry_run: bool,
}

#[derive(clap::Args, Debug)]
pub struct BackupArgs {
    #[command(subcommand)]
    pub action: BackupAction,
}

#[derive(Subcommand, Debug)]
pub enum BackupAction {
    #[command(about = "List backups")]
    List,
    #[command(about = "Restore from a backup (interactive selection if omitted)")]
    Restore {
        #[arg(help = "Backup name (basename or full path)")]
        name: Option<String>,
    },
    #[command(about = "Delete old backups, keeping the newest N per target file")]
    Prune {
        #[arg(
            long,
            default_value_t = 10,
            help = "Number of backups to keep per target"
        )]
        keep: usize,
    },
}

#[derive(clap::Args, Debug)]
pub struct ShowArgs {
    #[arg(help = "Host alias (omit for a table of all hosts)")]
    pub alias: Option<String>,
    #[arg(
        short = 'F',
        long = "config",
        help = "Resolve with an alternate config (ssh -G -F)"
    )]
    pub config: Option<String>,
    #[arg(
        long,
        value_enum,
        default_value_t = Format::Text,
        help = "Output format"
    )]
    pub format: Format,
}

#[derive(clap::Args, Debug)]
pub struct AuditArgs {
    #[arg(help = "Target hosts (all if omitted)")]
    pub targets: Vec<String>,
    #[arg(
        long,
        value_enum,
        default_value_t = Format::Text,
        help = "Output format"
    )]
    pub format: Format,
    #[arg(long, default_value_t = 10, help = "Connection timeout in seconds")]
    pub timeout: u64,
}

#[derive(clap::Args, Debug)]
pub struct KeygenArgs {
    #[arg(short = 'f', long, help = "Recreate even if a key already exists")]
    pub force: bool,
    #[arg(
        short = 'n',
        long = "dry-run",
        help = "Show changes without applying them"
    )]
    pub dry_run: bool,
}

#[derive(clap::Args, Debug)]
pub struct AgentArgs {
    #[arg(help = "'status' to show status only (no start or registration)")]
    pub mode: Option<String>,
}

#[derive(clap::Args, Debug)]
pub struct DoctorArgs {}

#[derive(clap::Args, Debug)]
pub struct CompletionArgs {
    #[arg(value_enum)]
    pub shell: clap_complete::Shell,
}

#[derive(Copy, Clone, Debug, PartialEq, Eq, ValueEnum)]
pub enum Format {
    Text,
    Json,
}
