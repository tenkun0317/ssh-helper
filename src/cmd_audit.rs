use crate::cli::AuditArgs;
use crate::core::*;
use anyhow::{bail, Result};
use rayon::prelude::*;
use serde::Serialize;

#[derive(Serialize, Clone)]
struct AuditLine {
    host: String,
    status: String,
    label: String,
    fingerprint: String,
    rest: String,
}

pub fn run(args: AuditArgs) -> Result<()> {
    require_ssh()?;
    let cfg = config_path()?;
    if !cfg.is_file() {
        bail!("{} not found", cfg.display());
    }
    let sd = ssh_dir()?;
    let mut local: Vec<(String, String)> = Vec::new();
    for (file, label) in [("id_ed25519.pub", "ed25519"), ("id_rsa.pub", "rsa")] {
        let p = sd.join(file);
        if p.is_file() {
            let c = run_capture("ssh-keygen", &["-l", "-f", &p.to_string_lossy()]);
            if let Some(fp) = c.stdout.split_whitespace().nth(1) {
                if !fp.is_empty() {
                    local.push((fp.to_string(), label.to_string()));
                }
            }
        }
    }
    if local.is_empty() {
        bail!("No local public keys");
    }

    let hosts: Vec<String> = if args.targets.is_empty() {
        let managed = managed_path()?;
        let mut files = vec![cfg];
        if managed.is_file() {
            files.push(managed);
        }
        ssh_aliases(&files)
    } else {
        args.targets.clone()
    };
    if hosts.is_empty() {
        eprintln!("No hosts found");
        std::process::exit(2);
    }

    let pb = indicatif::ProgressBar::new(hosts.len() as u64);
    pb.set_style(
        indicatif::ProgressStyle::with_template("Auditing {bar:30} {pos}/{len}")
            .unwrap()
            .progress_chars("=> "),
    );
    let results: Vec<Vec<AuditLine>> = hosts
        .par_iter()
        .map(|h| {
            let lines = audit_host(h, args.timeout, &local);
            pb.inc(1);
            lines
        })
        .collect();
    pb.finish_and_clear();

    if args.format == crate::cli::Format::Json {
        let all: Vec<AuditLine> = results.into_iter().flatten().collect();
        println!("{}", serde_json::to_string_pretty(&all)?);
    } else {
        for (h, lines) in hosts.iter().zip(&results) {
            println!("== {h}");
            for l in lines {
                match l.status.as_str() {
                    "PRESENT" => println!("  PRESENT {} {} {}", l.label, l.fingerprint, l.rest),
                    "UNKNOWN" => println!("  UNKNOWN {} {}", l.fingerprint, l.rest),
                    "MISSING" => println!("  MISSING {} {}", l.label, l.fingerprint),
                    _ => println!("  UNREACHABLE"),
                }
            }
        }
    }
    Ok(())
}

fn audit_host(h: &str, timeout: u64, local: &[(String, String)]) -> Vec<AuditLine> {
    let c = run_capture(
        "ssh",
        &[
            "-o",
            "BatchMode=yes",
            "-o",
            &format!("ConnectTimeout={timeout}"),
            h,
            "ssh-keygen -l -f ~/.ssh/authorized_keys",
        ],
    );
    if c.code != 0 {
        return vec![AuditLine {
            host: h.to_string(),
            status: "UNREACHABLE".into(),
            label: String::new(),
            fingerprint: String::new(),
            rest: String::new(),
        }];
    }
    let mut out: Vec<AuditLine> = Vec::new();
    let mut seen: Vec<String> = Vec::new();
    for out_line in c.stdout.lines() {
        let parts: Vec<&str> = out_line.split_whitespace().collect();
        if parts.len() < 2 {
            continue;
        }
        let fp = parts[1].to_string();
        let rest = parts[2..].join(" ");
        seen.push(fp.clone());
        if let Some((_, label)) = local.iter().find(|(f, _)| f == &fp) {
            out.push(AuditLine {
                host: h.to_string(),
                status: "PRESENT".into(),
                label: label.clone(),
                fingerprint: fp,
                rest,
            });
        } else {
            out.push(AuditLine {
                host: h.to_string(),
                status: "UNKNOWN".into(),
                label: String::new(),
                fingerprint: fp,
                rest,
            });
        }
    }
    for (fp, label) in local {
        if !seen.iter().any(|s| s == fp) {
            out.push(AuditLine {
                host: h.to_string(),
                status: "MISSING".into(),
                label: label.clone(),
                fingerprint: fp.clone(),
                rest: String::new(),
            });
        }
    }
    out
}
