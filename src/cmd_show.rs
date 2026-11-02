use crate::cli::ShowArgs;
use crate::core::*;
use anyhow::{bail, Result};
use serde::Serialize;

#[derive(Serialize)]
struct ShowEntry {
    alias: String,
    user: String,
    host: String,
    proxyjump: String,
}

pub fn run(args: ShowArgs) -> Result<()> {
    if let Some(f) = &args.config {
        if !std::path::Path::new(f).is_file() {
            bail!("{f} not found");
        }
    }
    let cfg_opt = args.config.as_deref();

    if let Some(alias) = args.alias {
        let g = ssh_g(&alias, cfg_opt)
            .map_err(|_| anyhow::anyhow!("error: failed to resolve {alias}"))?;
        if args.format == crate::cli::Format::Json {
            let mut map = serde_json::Map::new();
            for k in [
                "hostname",
                "user",
                "port",
                "proxyjump",
                "identityfile",
                "forwardagent",
                "addkeystoagent",
                "serveraliveinterval",
                "pubkeyauthentication",
                "stricthostkeychecking",
            ] {
                let vals = pick_g_all(&g, k);
                if vals.len() <= 1 {
                    map.insert(k.to_string(), serde_json::Value::String(pick_g(&g, k)));
                } else {
                    map.insert(
                        k.to_string(),
                        serde_json::Value::Array(
                            vals.into_iter().map(serde_json::Value::String).collect(),
                        ),
                    );
                }
            }
            map.insert("alias".to_string(), serde_json::Value::String(alias));
            println!("{}", serde_json::to_string_pretty(&map)?);
            return Ok(());
        }
        for k in [
            "hostname",
            "user",
            "port",
            "proxyjump",
            "identityfile",
            "forwardagent",
            "addkeystoagent",
            "serveraliveinterval",
            "pubkeyauthentication",
            "stricthostkeychecking",
        ] {
            let vals = pick_g_all(&g, k);
            if vals.is_empty() {
                continue;
            }
            let disp = g
                .lines()
                .find_map(|l| {
                    let mut it = l.splitn(2, char::is_whitespace);
                    let kk = it.next().unwrap_or("");
                    if kk.eq_ignore_ascii_case(k) {
                        Some(kk.to_string())
                    } else {
                        None
                    }
                })
                .unwrap_or_else(|| k.to_string());
            for v in vals {
                println!("{disp:<22} {v}");
            }
        }
        return Ok(());
    }

    let aliases: Vec<String> = if let Some(f) = cfg_opt {
        ssh_aliases(&[std::path::PathBuf::from(f)])
    } else {
        let cfg = config_path()?;
        if !cfg.is_file() {
            bail!("{} not found", cfg.display());
        }
        let managed = managed_path()?;
        let mut files = vec![cfg];
        if managed.is_file() {
            files.push(managed);
        }
        ssh_aliases(&files)
    };

    if args.format == crate::cli::Format::Json {
        let mut entries = Vec::new();
        for a in &aliases {
            match ssh_g(a, cfg_opt) {
                Ok(g) => entries.push(ShowEntry {
                    alias: a.clone(),
                    user: pick_g(&g, "user"),
                    host: pick_g(&g, "hostname"),
                    proxyjump: pick_g(&g, "proxyjump"),
                }),
                Err(_) => entries.push(ShowEntry {
                    alias: a.clone(),
                    user: "config error".to_string(),
                    host: String::new(),
                    proxyjump: String::new(),
                }),
            }
        }
        println!("{}", serde_json::to_string_pretty(&entries)?);
        return Ok(());
    }

    println!("{:<14} {:<28} PROXYJUMP", "ALIAS", "USER@HOST");
    for a in &aliases {
        match ssh_g(a, cfg_opt) {
            Ok(g) => {
                let u = pick_g(&g, "user");
                let h = pick_g(&g, "hostname");
                let j = pick_g(&g, "proxyjump");
                println!("{a:<14} {:<28} {j}", format!("{u}@{h}"));
            }
            Err(_) => println!("{a}: config error"),
        }
    }
    Ok(())
}
