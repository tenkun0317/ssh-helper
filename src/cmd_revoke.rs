use crate::cli::RevokeArgs;
use crate::core::*;
use anyhow::{bail, Result};

pub fn run(args: RevokeArgs, auto_yes: bool) -> Result<()> {
    require_ssh()?;
    let alias = match args.alias {
        Some(a) => a,
        None => dialoguer::Input::<String>::new()
            .with_prompt("Host to revoke")
            .interact_text()?,
    };
    let alias = alias.trim().to_string();
    if !valid_alias(&alias) {
        bail!("Invalid alias: {alias}");
    }

    let pubkey_files = resolve_pubkeys(&args.pubkey)?;
    let mut bodies: Vec<String> = Vec::new();
    for f in &pubkey_files {
        let line = load_pubkey_line(f)?;
        let body = line.split_whitespace().nth(1).unwrap_or("").to_string();
        if body.is_empty() || body.contains('\'') {
            bail!("Malformed public key: {}", f.display());
        }
        bodies.push(body);
    }

    let dest = if let Some(u) = args.user {
        if u.trim().is_empty() {
            alias.clone()
        } else {
            if !valid_token(u.trim()) {
                bail!("Invalid user: {u}");
            }
            format!("{}@{}", u.trim(), alias)
        }
    } else {
        alias.clone()
    };

    let mut filters = String::new();
    for b in &bodies {
        filters.push_str(&format!(" -e '{b}'"));
    }
    let remote = format!(
        "cp ~/.ssh/authorized_keys ~/.ssh/authorized_keys.bak-$(date +%Y%m%d-%H%M%S) && grep -v -F{filters} ~/.ssh/authorized_keys > ~/.ssh/authorized_keys.tmp && {{ if [ -L ~/.ssh/authorized_keys ]; then cat ~/.ssh/authorized_keys.tmp > ~/.ssh/authorized_keys; else mv -f ~/.ssh/authorized_keys.tmp ~/.ssh/authorized_keys; fi; }} && rm -f ~/.ssh/authorized_keys.tmp && chmod 600 ~/.ssh/authorized_keys && echo '--- remaining keys ---' && {{ ssh-keygen -l -f ~/.ssh/authorized_keys || true; }} && echo \"REMAIN:$(grep -c . ~/.ssh/authorized_keys)\""
    );

    if args.dry_run {
        info("--- Remote command to run ---");
        println!("ssh {dest} \"{remote}\"");
        return Ok(());
    }

    warn(&format!(
        "Revoking {n} key(s) from {dest}",
        n = bodies.len()
    ));
    if !confirm("Revoke? (automatic backup included)", auto_yes)? {
        bail!("Aborted");
    }

    step(&format!("[1/2] Revoking from {dest}..."));
    let c = run_capture("ssh", &[&dest, &remote]);
    print!("{}", c.stdout);
    eprint!("{}", c.stderr);
    if c.code != 0 {
        bail!("Revoke command failed");
    }

    let remain = c
        .stdout
        .lines()
        .find_map(|l| l.strip_prefix("REMAIN:"))
        .and_then(|n| n.trim().parse::<usize>().ok());
    if remain == Some(0) {
        warn(
            "authorized_keys is now empty. You may be locked out if password authentication is disabled",
        );
    }

    step("[2/2] Verifying with BatchMode...");
    let v = run_capture(
        "ssh",
        &[
            "-o",
            "BatchMode=yes",
            "-o",
            "ConnectTimeout=15",
            &dest,
            "echo STILL_OK",
        ],
    );
    if v.stdout.contains("STILL_OK") {
        warn("Note: key auth still works (another key remains)");
    } else {
        ok_line(&format!("Revoked: {dest} no longer accepts key auth"));
    }
    Ok(())
}
