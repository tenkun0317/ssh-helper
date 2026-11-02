use crate::cli::RegisterArgs;
use crate::core::*;
use anyhow::{bail, Context, Result};
use std::path::{Path, PathBuf};

pub fn run(args: RegisterArgs, auto_yes: bool, verbose: bool) -> Result<()> {
    require_ssh()?;

    let alias = match args.alias {
        Some(a) => a,
        None => dialoguer::Input::<String>::new()
            .with_prompt("Host alias (e.g. web1)")
            .interact_text()?,
    };
    let alias = alias.trim().to_string();
    if !valid_alias(&alias) {
        bail!("Invalid alias: {alias}");
    }

    let jumps = normalize_jumps(args.jump.as_deref())?;
    if let Some(h) = &args.real_host {
        if !h.trim().is_empty() && !valid_token(h.trim()) {
            bail!("Invalid hostname: {h}");
        }
    }
    if let Some(u) = &args.user {
        if !u.trim().is_empty() && !valid_token(u.trim()) {
            bail!("Invalid user: {u}");
        }
    }
    let real_host_arg = args
        .real_host
        .as_deref()
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .map(str::to_string);
    let user_arg = args
        .user
        .as_deref()
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .map(str::to_string);

    let want_fps = collect_trust_fps(&args.fingerprint)?;
    let need_fp = want_fps.is_some();

    let pubkey_files = match resolve_pubkeys(&args.pubkey) {
        Ok(v) => v,
        Err(e) => {
            if args.pubkey.is_empty() {
                step("No public key found. Generating an ed25519 key...");
                crate::cmd_keygen::create_ed25519()?;
                resolve_pubkeys(&args.pubkey)?
            } else {
                return Err(e);
            }
        }
    };
    let mut pubkey_lines: Vec<String> = Vec::new();
    for f in &pubkey_files {
        pubkey_lines.push(load_pubkey_line(f)?);
    }

    let cfg = config_path()?;
    if !cfg.is_file() {
        std::fs::create_dir_all(cfg.parent().unwrap())?;
        std::fs::write(&cfg, "")?;
        lock_file_to_owner(&cfg)?;
        step(&format!("Created {}", cfg.display()));
    }
    let managed = managed_path()?;
    let cfg_lines = read_lines(&cfg)?;
    let managed_lines: Vec<String> = if managed.is_file() {
        read_lines(&managed)?
    } else {
        Vec::new()
    };

    let main_block = find_block(&cfg_lines, &alias);
    let managed_block = if managed.is_file() {
        find_block(&managed_lines, &alias)
    } else {
        None
    };
    let exists = main_block.is_some() || managed_block.is_some();

    let need_config = !(exists && jumps.is_none() && real_host_arg.is_none() && user_arg.is_none());

    let dest = alias.clone();
    let mut final_host = real_host_arg.clone().unwrap_or_default();
    let mut final_jumps = jumps.clone().unwrap_or_default();
    let mut final_user = user_arg.clone().unwrap_or_default();

    if need_config {
        let (src_lines, range) = if managed_block.is_some() {
            (&managed_lines, managed_block)
        } else if main_block.is_some() {
            (&cfg_lines, main_block)
        } else {
            (&cfg_lines, None)
        };
        let mut orig_hostline = format!("Host {alias}");
        let mut orig_hostname = String::new();
        let mut orig_jump = String::new();
        let mut orig_user = String::new();
        if let Some((s, e)) = range {
            orig_hostline = src_lines[s].clone();
            let slice = &src_lines[s..e.min(src_lines.len())];
            orig_hostname = find_config_value(slice, "hostname");
            orig_jump = find_config_value(slice, "proxyjump");
            orig_user = find_config_value(slice, "user");
        }
        if final_host.is_empty() {
            final_host = if !orig_hostname.is_empty() {
                orig_hostname
            } else {
                alias.clone()
            };
        }
        if final_jumps.is_empty() && !orig_jump.is_empty() {
            final_jumps = orig_jump;
        }
        if final_user.is_empty() {
            if !orig_user.is_empty() {
                final_user = orig_user;
            } else if exists || !final_jumps.is_empty() {
                final_user = default_user();
            } else if args.interactive || auto_yes {
                if args.interactive {
                    let d = default_user();
                    final_user = dialoguer::Input::<String>::new()
                        .with_prompt(format!("Username [{d}]"))
                        .allow_empty(true)
                        .interact_text()?;
                    if final_user.trim().is_empty() {
                        final_user = d;
                    } else {
                        final_user = final_user.trim().to_string();
                    }
                } else {
                    final_user = default_user();
                }
            } else {
                bail!("Specify -u for a new host (e.g. -u deploy)");
            }
        }

        let mut block: Vec<String> = vec![
            orig_hostline,
            format!("  HostName {final_host}"),
            format!("  User {final_user}"),
            "  IdentityFile ~/.ssh/id_ed25519".to_string(),
            "  IdentityFile ~/.ssh/id_rsa".to_string(),
            "  ForwardAgent yes".to_string(),
        ];
        if !final_jumps.is_empty() {
            block.push(format!("  ProxyJump {final_jumps}"));
        }

        if args.dry_run {
            info("--- Content to write to config ---");
            for l in &block {
                println!("{l}");
            }
        } else {
            if verbose || !auto_yes {
                info("--- Content to write to config ---");
                for l in &block {
                    println!("{l}");
                }
                if !confirm("Update config?", auto_yes)? {
                    bail!("Aborted");
                }
            }
            write_config_block(&alias, &block)?;
            if verbose {
                step("[0/3] Config updated (verified with ssh -G)");
            } else {
                step("[0/3] Config updated (backup: *.bak-*)");
            }
        }
    } else if verbose {
        info(&format!("Not modifying config (existing host {alias})"));
    }

    let mut appends = String::new();
    for line in &pubkey_lines {
        let esc = sq_escape(line);
        let part = format!("echo '{esc}' >> ~/.ssh/authorized_keys");
        if appends.is_empty() {
            appends = part;
        } else {
            appends = format!("{appends} && {part}");
        }
    }
    let mut remote = format!("mkdir -p ~/.ssh && cp ~/.ssh/authorized_keys ~/.ssh/authorized_keys.bak-$(date +%Y%m%d-%H%M%S) 2>/dev/null; {appends}");
    remote.push_str(" && tr -d '\\r' < ~/.ssh/authorized_keys > ~/.ssh/authorized_keys.tmp");
    remote.push_str(" && sort -u ~/.ssh/authorized_keys.tmp > ~/.ssh/authorized_keys.tmp2");
    remote.push_str(" && { if [ -L ~/.ssh/authorized_keys ]; then cat ~/.ssh/authorized_keys.tmp2 > ~/.ssh/authorized_keys; else mv -f ~/.ssh/authorized_keys.tmp2 ~/.ssh/authorized_keys; fi; }");
    remote.push_str(" && rm -f ~/.ssh/authorized_keys.tmp ~/.ssh/authorized_keys.tmp2");
    remote.push_str(
        " && { chmod 755 ~ || true; } && chmod 700 ~/.ssh && chmod 600 ~/.ssh/authorized_keys",
    );
    remote
        .push_str(" && { if [ -L ~/.ssh/authorized_keys ]; then echo '(symlink preserved)'; fi; }");
    remote.push_str(
        " && echo '--- fingerprints on server ---' && ssh-keygen -l -f ~/.ssh/authorized_keys",
    );
    remote.push_str(" && echo '--- perms ---' && ls -ld ~ ~/.ssh ~/.ssh/authorized_keys");

    if args.dry_run {
        info("--- Remote command to run ---");
        println!("ssh {dest} \"{remote}\"");
        if need_fp {
            info("(Fingerprint mode: verify with keyscan before adding to known_hosts)");
        }
        return Ok(());
    }

    let mut checking = "accept-new".to_string();
    if need_fp {
        let want = want_fps.unwrap();
        step("Fetching host keys with ssh-keyscan...");
        let g = ssh_g(&alias, None).unwrap_or_default();
        let eff_jump = pick_g(&g, "proxyjump");
        let mut rh = final_host.clone();
        if rh.is_empty() {
            rh = pick_g(&g, "hostname");
        }
        if rh.is_empty() {
            rh = alias.clone();
        }
        let scan = keyscan_via(&eff_jump, &rh)?;
        let tmp = tempfile::NamedTempFile::new()?;
        let filtered: Vec<String> = scan
            .lines()
            .filter(|l| !l.trim().is_empty() && !l.trim_start().starts_with('#'))
            .map(|s| s.to_string())
            .collect();
        std::fs::write(tmp.path(), filtered.join("\n"))?;
        let c = run_capture("ssh-keygen", &["-l", "-f", &tmp.path().to_string_lossy()]);
        let got: Vec<String> = c
            .stdout
            .lines()
            .filter_map(|l| l.split_whitespace().nth(1).map(str::to_string))
            .collect();
        if got.is_empty() {
            bail!("Could not fetch host keys (keyscan failed; network required)");
        }
        let matched = want.iter().find(|w| got.iter().any(|g| g == *w));
        let Some(m) = matched else {
            bail!("Fingerprint mismatch, aborting. Actual: {}", got.join(" "));
        };
        step(&format!("Fingerprint OK ({m}). Adding to known_hosts"));
        append_known_hosts(&scan, &alias)?;
        checking = "strict".to_string();
    }

    if !confirm(&format!("Register the public key on {dest}?"), auto_yes)? {
        bail!("Aborted");
    }

    step(&format!("[1/2] Registering on {dest} ..."));
    let probe_ok = probe_batch(&dest, &checking);
    let auth_pass = !probe_ok;
    exec_remote(&dest, &remote, &checking, auth_pass)?;

    step("[2/2] Verifying with BatchMode...");
    let v = run_capture(
        "ssh",
        &[
            "-o",
            "BatchMode=yes",
            "-o",
            "ConnectTimeout=15",
            &dest,
            "echo REGISTER_OK",
        ],
    );
    if v.stdout.contains("REGISTER_OK") {
        ok_line(&format!("Success: {dest} accepts key authentication"));
        Ok(())
    } else {
        bail!("Key authentication still fails. Check sshd settings\nHint: check ~ permissions (chmod 755 ~) and BOM/CR in authorized_keys");
    }
}

fn write_config_block(alias: &str, block: &[String]) -> Result<()> {
    let cfg = config_path()?;
    let managed = managed_path()?;
    let stamp = timestamp();

    std::fs::create_dir_all(managed.parent().unwrap())?;
    if !managed.is_file() {
        std::fs::write(&managed, "")?;
    }
    let cfg_text = std::fs::read_to_string(&cfg).unwrap_or_default();
    let has_include = cfg_text.lines().any(|l| {
        let t = l.trim();
        t.eq_ignore_ascii_case("Include config.d/managed")
    });
    let mut main_block_now = find_block(&read_lines(&cfg)?, alias);
    if !has_include {
        let backup = PathBuf::from(format!("{}.bak-{stamp}", cfg.display()));
        std::fs::copy(&cfg, &backup)?;
        info(&format!(
            "[0/3] Adding 'Include config.d/managed' to the top of config (backup: {})",
            backup.file_name().unwrap().to_string_lossy()
        ));
        let mut new_lines = vec!["Include config.d/managed".to_string()];
        new_lines.extend(read_lines(&cfg)?);
        write_lines_nobom(&cfg, &new_lines)?;
        lock_file_to_owner(&cfg)?;
        main_block_now = find_block(&read_lines(&cfg)?, alias);
    }

    let managed_has = find_block(&read_lines(&managed)?, alias).is_some();
    let target = if !managed_has && main_block_now.is_some() {
        cfg.clone()
    } else {
        managed.clone()
    };
    let backup = PathBuf::from(format!("{}.bak-{stamp}", target.display()));
    std::fs::copy(&target, &backup)?;
    info(&format!(
        "[0/3] Updating {} (backup: {})",
        target.file_name().unwrap().to_string_lossy(),
        backup.file_name().unwrap().to_string_lossy()
    ));

    let lines = read_lines(&target)?;
    if let Some((s, e)) = find_block(&lines, alias) {
        let cur: Vec<String> = lines[s..e.min(lines.len())]
            .iter()
            .map(|l| l.trim().to_string())
            .filter(|l| !l.is_empty())
            .collect();
        let want: Vec<String> = block
            .iter()
            .map(|l| l.trim().to_string())
            .filter(|l| !l.is_empty())
            .collect();
        if cur == want {
            info("[0/3] Config unchanged (identical content, skipping)");
            return Ok(());
        }
    }
    let new_lines = if find_block(&lines, alias).is_some() {
        replace_block(&lines, alias, block)
    } else {
        let mut v = lines;
        if !v.is_empty() && !v.last().unwrap().is_empty() {
            v.push(String::new());
        }
        v.extend(block.iter().cloned());
        v
    };
    write_lines_nobom(&target, &new_lines)?;
    lock_file_to_owner(&target)?;
    match validate_alias(alias) {
        Ok(_) => Ok(()),
        Err(detail) => {
            std::fs::copy(&backup, &target)?;
            bail!(
                "Config validation failed, restored from backup: {}\nDetails: {detail}",
                backup.display()
            );
        }
    }
}

fn validate_alias(alias: &str) -> Result<(), String> {
    let out = std::process::Command::new("ssh")
        .arg("-G")
        .arg(alias)
        .output()
        .map_err(|e| format!("ssh failed: {e}"))?;
    let stdout: String = String::from_utf8_lossy(&out.stdout).replace('\r', "");
    if out.status.success() && !stdout.trim().is_empty() {
        return Ok(());
    }
    let stderr: String = String::from_utf8_lossy(&out.stderr).replace('\r', "");
    let first = stderr
        .lines()
        .next()
        .unwrap_or("ssh -G failed")
        .trim()
        .to_string();
    Err(first)
}

fn replace_block(lines: &[String], alias: &str, block: &[String]) -> Vec<String> {
    let mut out: Vec<String> = Vec::new();
    let mut i = 0;
    let mut done = false;
    while i < lines.len() {
        let t = lines[i].trim_start();
        if let Some(rest) = host_rest(t) {
            if !done && host_patterns(rest).contains(&alias) {
                out.extend(block.iter().cloned());
                done = true;
                i += 1;
                while i < lines.len() {
                    let t2 = lines[i].trim_start();
                    if host_rest(t2).is_some() {
                        break;
                    }
                    i += 1;
                }
                continue;
            }
        }
        out.push(lines[i].clone());
        i += 1;
    }
    if !done {
        if !out.is_empty() && !out.last().unwrap().is_empty() {
            out.push(String::new());
        }
        out.extend(block.iter().cloned());
    }
    out
}

fn keyscan_via(eff_jump: &str, realhost: &str) -> Result<String> {
    if eff_jump.is_empty() || eff_jump == "none" {
        let c = run_capture("ssh-keyscan", &["-T", "10", realhost]);
        if c.stdout.trim().is_empty() {
            bail!("Could not fetch host keys (keyscan failed; network required)");
        }
        return Ok(c.stdout);
    }
    let parts: Vec<&str> = eff_jump.split(',').collect();
    let last = parts.last().unwrap().to_string();
    let remote_cmd = format!("ssh-keyscan -T 10 {realhost}");
    let c = if parts.len() == 1 {
        run_capture("ssh", &[&last, &remote_cmd])
    } else {
        let rest = parts[..parts.len() - 1].join(",");
        run_capture("ssh", &["-J", &rest, &last, &remote_cmd])
    };
    if c.stdout.trim().is_empty() {
        bail!("Could not fetch host keys (keyscan failed; network required)");
    }
    Ok(c.stdout)
}

fn append_known_hosts(scan: &str, alias: &str) -> Result<()> {
    let kh = known_hosts_path()?;
    append_known_hosts_file(&kh, scan, alias)
}

fn append_known_hosts_file(kh: &Path, scan: &str, alias: &str) -> Result<()> {
    if !kh.is_file() {
        std::fs::write(kh, "")?;
    }
    let existing = std::fs::read_to_string(kh).unwrap_or_default();
    let mut to_add: Vec<String> = Vec::new();
    for line in scan.lines() {
        let l = line.trim();
        if l.is_empty() || l.starts_with('#') {
            continue;
        }
        if !existing.lines().any(|e| e == l) && !to_add.iter().any(|e| e == l) {
            to_add.push(l.to_string());
        }
        let mut it = l.split_whitespace();
        let name = it.next().unwrap_or("");
        let rest: Vec<&str> = it.collect();
        if name != alias && !rest.is_empty() {
            let cand = format!("{alias} {}", rest.join(" "));
            if !existing.lines().any(|e| e == cand) && !to_add.iter().any(|e| e == &cand) {
                to_add.push(cand);
            }
        }
    }
    if !to_add.is_empty() {
        use std::io::Write;
        let mut f = std::fs::OpenOptions::new().append(true).open(kh)?;
        for l in to_add {
            writeln!(f, "{l}")?;
        }
    }
    Ok(())
}

fn probe_batch(dest: &str, checking: &str) -> bool {
    let c = if checking == "strict" {
        run_capture(
            "ssh",
            &[
                "-o",
                "BatchMode=yes",
                "-o",
                "ConnectTimeout=15",
                dest,
                "echo PROBE_OK",
            ],
        )
    } else {
        run_capture(
            "ssh",
            &[
                "-o",
                "BatchMode=yes",
                "-o",
                "ConnectTimeout=15",
                "-o",
                "StrictHostKeyChecking=accept-new",
                dest,
                "echo PROBE_OK",
            ],
        )
    };
    c.stdout.contains("PROBE_OK")
}

fn exec_remote(dest: &str, remote: &str, checking: &str, auth_pass: bool) -> Result<()> {
    use std::process::Command;
    let mut cmd = Command::new("ssh");
    if checking != "strict" {
        cmd.arg("-o").arg("StrictHostKeyChecking=accept-new");
    }
    if auth_pass {
        cmd.arg("-o")
            .arg("PreferredAuthentications=password,keyboard-interactive");
    }
    let status = cmd
        .arg(dest)
        .arg(remote)
        .status()
        .with_context(|| format!("failed to connect to {dest}"))?;
    if !status.success() {
        bail!(
            "Remote registration failed (exit code: {})",
            status.code().unwrap_or(1)
        );
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn replace_block_existing() {
        let lines: Vec<String> = vec![
            "Host a".into(),
            "  User old".into(),
            "Host b".into(),
            "  User keep".into(),
        ];
        let block = vec!["Host a".to_string(), "  User new".to_string()];
        let out = replace_block(&lines, "a", &block);
        assert_eq!(out, vec!["Host a", "  User new", "Host b", "  User keep"]);
    }

    #[test]
    fn replace_block_appends_when_missing() {
        let lines: Vec<String> = vec!["Host a".into(), "  User u".into()];
        let block = vec!["Host b".to_string(), "  User v".to_string()];
        let out = replace_block(&lines, "b", &block);
        assert_eq!(out, vec!["Host a", "  User u", "", "Host b", "  User v"]);
    }

    #[test]
    fn replace_block_comma_pattern() {
        let lines: Vec<String> = vec!["Host a,b".into(), "  User u".into()];
        let block = vec!["Host a,b".to_string(), "  User new".to_string()];
        let out = replace_block(&lines, "a", &block);
        assert_eq!(out, vec!["Host a,b", "  User new"]);
        let out = replace_block(&lines, "b", &block);
        assert_eq!(out, vec!["Host a,b", "  User new"]);
    }

    #[test]
    fn append_known_hosts_dedup() {
        let dir = tempfile::tempdir().unwrap();
        let kh = dir.path().join("known_hosts");
        let scan = "web1 ssh-ed25519 AAAA1\nweb1,10.0.0.1 ssh-ed25519 AAAA1\n# comment\n";
        append_known_hosts_file(&kh, scan, "web1").unwrap();
        let first = std::fs::read_to_string(&kh).unwrap();
        assert_eq!(first.lines().count(), 2);
        append_known_hosts_file(&kh, scan, "web1").unwrap();
        let second = std::fs::read_to_string(&kh).unwrap();
        assert_eq!(first, second);
    }
}
