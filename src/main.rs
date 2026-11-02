mod cli;
mod cmd_agent;
mod cmd_audit;
mod cmd_backup;
mod cmd_check;
mod cmd_doctor;
mod cmd_keygen;
mod cmd_register;
mod cmd_revoke;
mod cmd_show;
mod core;

use clap::{CommandFactory, Parser};
use cli::{Cli, Commands};

fn main() -> anyhow::Result<()> {
    let cli = Cli::parse();
    core::paint_on(cli.no_color);

    match cli.command {
        Commands::Register(a) => cmd_register::run(a, cli.yes, cli.verbose),
        Commands::Check(a) => cmd_check::run(a),
        Commands::Revoke(a) => cmd_revoke::run(a, cli.yes),
        Commands::Backup(a) => cmd_backup::run(a, cli.yes),
        Commands::Show(a) => cmd_show::run(a),
        Commands::Audit(a) => cmd_audit::run(a),
        Commands::Keygen(a) => cmd_keygen::run(a, cli.yes),
        Commands::Agent(a) => cmd_agent::run(a),
        Commands::Doctor(_) => cmd_doctor::run(),
        Commands::Completion(a) => {
            let mut cmd = Cli::command();
            clap_complete::generate(a.shell, &mut cmd, "ssh-helper", &mut std::io::stdout());
            Ok(())
        }
    }
    .map_err(|e| {
        core::err_msg(&format!("{e:#}"));
        e
    })
}
