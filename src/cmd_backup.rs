use crate::cli::{BackupAction, BackupArgs};
use crate::core::*;
use anyhow::{bail, Result};

fn list_backups() -> Vec<std::path::PathBuf> {
    let mut v = Vec::new();
    if let Ok(sd) = ssh_dir() {
        for d in [sd.clone(), sd.join("config.d")] {
            if let Ok(rd) = std::fs::read_dir(&d) {
                for e in rd.flatten() {
                    let p = e.path();
                    if let Some(name) = p.file_name().and_then(|s| s.to_str()) {
                        if name.contains(".bak-") && p.is_file() {
                            v.push(p);
                        }
                    }
                }
            }
        }
    }
    v.sort();
    v
}

pub fn run(args: BackupArgs, auto_yes: bool) -> Result<()> {
    match args.action {
        BackupAction::List => {
            let items = list_backups();
            if items.is_empty() {
                info("No backups");
                return Ok(());
            }
            println!("{:<38} {:<28} SIZE  MODIFIED", "BACKUP", "RESTORES-TO");
            for f in items {
                let base = f.file_name().unwrap().to_string_lossy().to_string();
                let target_name = base.split(".bak-").next().unwrap_or(&base);
                let target = f.parent().unwrap().join(target_name);
                let md = std::fs::metadata(&f);
                let (size, mtime) = match md.and_then(|m| m.modified().map(|t| (m.len(), t))) {
                    Ok((len, t)) => {
                        let dt: chrono::DateTime<chrono::Local> = t.into();
                        (format!("{len}B"), dt.format("%Y-%m-%d %H:%M").to_string())
                    }
                    Err(_) => ("?".to_string(), "?".to_string()),
                };
                println!("{base:<38} {:<28} {size:<6} {mtime}", target.display());
            }
            Ok(())
        }
        BackupAction::Restore { name } => {
            let items = list_backups();
            if items.is_empty() {
                bail!("No backups");
            }
            let src: std::path::PathBuf = match name {
                Some(n) => {
                    let found = items.iter().find(|f| {
                        f.file_name().unwrap().to_string_lossy() == n || f.to_string_lossy() == n
                    });
                    match found {
                        Some(f) => f.clone(),
                        None => bail!("Backup not found: {n} (see `ssh-helper backup list`)"),
                    }
                }
                None => {
                    let labels: Vec<String> = items
                        .iter()
                        .map(|f| f.file_name().unwrap().to_string_lossy().to_string())
                        .collect();
                    let sel = dialoguer::Select::new()
                        .with_prompt("Select a backup to restore")
                        .items(&labels)
                        .default(0)
                        .interact()?;
                    items[sel].clone()
                }
            };
            let base = src.file_name().unwrap().to_string_lossy().to_string();
            let target_name = base.split(".bak-").next().unwrap().to_string();
            let target = src.parent().unwrap().join(&target_name);

            warn(&format!("Restore: {} -> {}", base, target.display()));
            if !confirm("Restore? (current file is backed up first)", auto_yes)? {
                bail!("Aborted");
            }

            let stamp = timestamp();
            let mut pre_backup: Option<std::path::PathBuf> = None;
            if target.is_file() {
                let b = std::path::PathBuf::from(format!("{}.bak-{stamp}", target.display()));
                std::fs::copy(&target, &b)?;
                info(&format!("Backed up current file: {}", b.display()));
                pre_backup = Some(b);
            }
            std::fs::copy(&src, &target)?;
            info(&format!("Restored: {base} -> {}", target.display()));
            lock_file_to_owner(&target)?;

            let text = std::fs::read_to_string(&target).unwrap_or_default();
            let aliases: Vec<String> = {
                let mut out = Vec::new();
                for line in text.lines() {
                    let t = line.trim_start();
                    if let Some(rest) = host_rest(t) {
                        let first = rest.split_whitespace().next().unwrap_or("");
                        if !first.contains('*')
                            && valid_alias(first)
                            && !out.contains(&first.to_string())
                        {
                            out.push(first.to_string());
                        }
                    }
                }
                out
            };
            let mut bad = 0;
            for a in &aliases {
                if ssh_g(a, None).is_err() {
                    eprintln!("Syntax error: {a}");
                    bad += 1;
                }
            }
            if bad > 0 {
                if let Some(b) = pre_backup {
                    std::fs::copy(&b, &target)?;
                    bail!("Validation failed, rolled back automatically");
                }
                bail!("Validation failed: {bad} aliases with errors");
            }
            ok_line(&format!("Validation OK: {} aliases", aliases.len()));
            Ok(())
        }
        BackupAction::Prune { keep } => {
            let items = list_backups();
            if items.is_empty() {
                info("No backups");
                return Ok(());
            }
            let mut groups: std::collections::BTreeMap<String, Vec<std::path::PathBuf>> =
                std::collections::BTreeMap::new();
            for f in items {
                let base = f.file_name().unwrap().to_string_lossy().to_string();
                let target_name = base.split(".bak-").next().unwrap_or(&base).to_string();
                let target = f.parent().unwrap().join(&target_name);
                groups
                    .entry(target.to_string_lossy().to_string())
                    .or_default()
                    .push(f);
            }

            let mut to_delete: Vec<std::path::PathBuf> = Vec::new();
            for (_, mut backups) in groups {
                backups.sort();
                let n = backups.len().saturating_sub(keep);
                if n > 0 {
                    to_delete.extend(backups.into_iter().take(n));
                }
            }
            if to_delete.is_empty() {
                info("Nothing to prune");
                return Ok(());
            }
            for f in &to_delete {
                println!("{}", f.file_name().unwrap().to_string_lossy());
            }
            if !confirm(&format!("Delete {} backup(s)?", to_delete.len()), auto_yes)? {
                bail!("Aborted");
            }
            let mut deleted = 0;
            for f in &to_delete {
                if std::fs::remove_file(f).is_ok() {
                    deleted += 1;
                }
            }
            ok_line(&format!("Deleted {deleted} backup(s)"));
            Ok(())
        }
    }
}
