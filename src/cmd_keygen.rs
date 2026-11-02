use crate::cli::KeygenArgs;
use crate::core::*;
use anyhow::{bail, Result};
use std::path::Path;

pub fn run(args: KeygenArgs, auto_yes: bool) -> Result<()> {
    let sd = ssh_dir()?;
    let key = sd.join("id_ed25519");
    let pubk = sd.join("id_ed25519.pub");

    if key.is_file() && !args.force {
        info(&format!("exists: {} (use -f to recreate)", key.display()));
        let c = run_capture("ssh-keygen", &["-l", "-f", &pubk.to_string_lossy()]);
        print!("{}", c.stdout);
        return Ok(());
    }

    if args.dry_run {
        info(&format!(
            "--- would create: {} (ed25519) ---",
            key.display()
        ));
        return Ok(());
    }

    if key.is_file() {
        warn(&format!(
            "Recreating {} (old key moved to .bak-*)",
            key.display()
        ));
        if !confirm("Continue?", auto_yes)? {
            bail!("Aborted");
        }
        let stamp = timestamp();
        let kb = std::path::PathBuf::from(format!("{}.bak-{stamp}", key.display()));
        std::fs::rename(&key, &kb)?;
        info(&format!("backup: {}", kb.display()));
        if pubk.is_file() {
            let pb = std::path::PathBuf::from(format!("{}.bak-{stamp}", pubk.display()));
            std::fs::rename(&pubk, &pb)?;
            info(&format!("backup: {}", pb.display()));
        }
    }

    generate_ed25519(&key, &pubk)?;

    ok_line(&format!("created: {}", key.display()));
    let c = run_capture("ssh-keygen", &["-l", "-f", &pubk.to_string_lossy()]);
    print!("{}", c.stdout);
    Ok(())
}

pub fn create_ed25519() -> Result<()> {
    let sd = ssh_dir()?;
    let key = sd.join("id_ed25519");
    let pubk = sd.join("id_ed25519.pub");
    if key.is_file() {
        return Ok(());
    }
    generate_ed25519(&key, &pubk)?;
    ok_line(&format!("created: {}", key.display()));
    Ok(())
}

fn generate_ed25519(key: &Path, _pubk: &Path) -> Result<()> {
    let c = run_capture("ssh-keygen", &["-V"]);
    if c.code == 127 {
        bail!("ssh-keygen not found");
    }
    std::fs::create_dir_all(key.parent().unwrap())?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = std::fs::set_permissions(
            key.parent().unwrap(),
            std::fs::Permissions::from_mode(0o700),
        );
    }

    let user = std::env::var("USERNAME")
        .or_else(|_| std::env::var("USER"))
        .unwrap_or_else(|_| "user".to_string());
    let host = hostname_short();
    let comment = format!("{user}@{host}");

    step(&format!("Generating: {} ...", key.display()));
    let status = std::process::Command::new("ssh-keygen")
        .args([
            "-t",
            "ed25519",
            "-N",
            "",
            "-C",
            &comment,
            "-f",
            &key.to_string_lossy(),
        ])
        .status()?;
    if !status.success() {
        bail!("ssh-keygen failed");
    }

    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = std::fs::set_permissions(key, std::fs::Permissions::from_mode(0o600));
        let _ = std::fs::set_permissions(pubk, std::fs::Permissions::from_mode(0o644));
    }
    #[cfg(windows)]
    {
        lock_file_to_owner(key)?;
    }

    if std::env::var("SSH_HELPER_NO_AGENT").unwrap_or_default() != "1" {
        let a = run_capture("ssh-add", &[&key.to_string_lossy()]);
        if a.code == 0 {
            info("Added to agent");
        } else {
            warn("Could not add to ssh-agent. Run `ssh-helper agent` to register");
        }
    } else {
        info("Skipped agent registration (SSH_HELPER_NO_AGENT=1)");
    }
    Ok(())
}

fn hostname_short() -> String {
    let c = run_capture("hostname", &[]);
    let h = c.stdout.trim().to_string();
    if h.is_empty() {
        std::env::var("COMPUTERNAME").unwrap_or_else(|_| "localhost".to_string())
    } else {
        h
    }
}
