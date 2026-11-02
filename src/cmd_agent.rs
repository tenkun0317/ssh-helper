use crate::cli::AgentArgs;
use crate::core::*;
use anyhow::Result;

#[allow(dead_code)]
fn agent_running() -> bool {
    let (code, _) = ssh_add_list();
    code == 0 || code == 1
}

fn ssh_add_list() -> (i32, String) {
    let c = run_capture("ssh-add", &["-l"]);
    (c.code, format!("{}{}", c.stdout, c.stderr))
}

pub fn run(args: AgentArgs) -> Result<()> {
    let status_only = args.mode.as_deref() == Some("status");

    #[cfg(windows)]
    {
        let (code, _) = ssh_add_list();
        if code == 127 {
            anyhow::bail!("ssh-add not found");
        }
        if status_only {
            if code == 0 || code == 1 {
                info("agent: running");
                print_loaded();
                return Ok(());
            } else {
                info("agent: not running");
                std::process::exit(1);
            }
        }
        if code != 0 && code != 1 {
            err_msg("agent is not responding. Start the 'ssh-agent' service:");
            eprintln!("  Set-Service ssh-agent -StartupType Automatic; Start-Service ssh-agent");
            std::process::exit(1);
        }
    }

    #[cfg(not(windows))]
    {
        if !agent_running() {
            let (code, _) = ssh_add_list();
            let running = code == 0 || code == 1;
            if !running {
                info("agent: not running");
                if status_only {
                    std::process::exit(1);
                }
                info("Starting: eval $(ssh-agent -s)");
                let c = run_capture("ssh-agent", &["-s"]);
                if c.code != 0 {
                    anyhow::bail!("failed to start ssh-agent");
                }
                for line in c.stdout.lines() {
                    for part in line.split(';') {
                        let part = part.trim();
                        if let Some(v) = part.strip_prefix("SSH_AUTH_SOCK=") {
                            std::env::set_var("SSH_AUTH_SOCK", v);
                        } else if let Some(v) = part.strip_prefix("SSH_AGENT_PID=") {
                            std::env::set_var("SSH_AGENT_PID", v);
                        }
                    }
                }
                info("agent: started. To persist in your shell, run:");
                println!("  eval $(ssh-agent -s)");
            } else {
                info("agent: running");
            }
        } else {
            info("agent: running");
        }
        if status_only {
            print_loaded();
            return Ok(());
        }
    }

    let sd = ssh_dir()?;
    let (list_code, list_out) = ssh_add_list();
    let _ = list_code;
    for name in ["id_ed25519", "id_rsa"] {
        let k = sd.join(name);
        if !k.is_file() {
            continue;
        }
        let pubk = sd.join(format!("{name}.pub"));
        let fp = if pubk.is_file() {
            let c = run_capture("ssh-keygen", &["-l", "-f", &pubk.to_string_lossy()]);
            c.stdout.split_whitespace().nth(1).unwrap_or("").to_string()
        } else {
            String::new()
        };
        if !fp.is_empty() && list_out.contains(&fp) {
            info(&format!("loaded: {}", k.display()));
            continue;
        }
        let c = run_capture("ssh-add", &[&k.to_string_lossy()]);
        if c.code == 0 {
            ok_line(&format!("added: {}", k.display()));
        } else {
            warn(&format!(
                "skip (passphrase protected or failed): {}",
                k.display()
            ));
            if !c.stderr.is_empty() {
                eprintln!("{}", c.stderr.trim());
            }
        }
    }
    println!("--- loaded keys ---");
    print_loaded();
    Ok(())
}

fn print_loaded() {
    let c = run_capture("ssh-add", &["-l"]);
    let out = format!("{}{}", c.stdout, c.stderr);
    print!("{out}");
}
