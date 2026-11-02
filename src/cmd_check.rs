use crate::cli::CheckArgs;
use crate::core::*;
use anyhow::Result;
use rayon::prelude::*;
use serde::Serialize;

#[derive(Serialize)]
struct CheckResult {
    alias: String,
    ok: bool,
    reason: String,
}

pub fn run(args: CheckArgs) -> Result<()> {
    require_ssh()?;
    let cfg = config_path()?;
    if !cfg.is_file() {
        anyhow::bail!("{} not found", cfg.display());
    }
    let managed = managed_path()?;
    let mut files = vec![cfg];
    if managed.is_file() {
        files.push(managed);
    }
    let hosts = ssh_aliases(&files);
    if hosts.is_empty() {
        eprintln!("No hosts found");
        std::process::exit(2);
    }

    if args.jobs > 0 {
        rayon::ThreadPoolBuilder::new()
            .num_threads(args.jobs)
            .build_global()
            .ok();
    }

    let pb = indicatif::ProgressBar::new(hosts.len() as u64);
    pb.set_style(
        indicatif::ProgressStyle::with_template("Checking {bar:30} {pos}/{len}")
            .unwrap()
            .progress_chars("=> "),
    );
    let results: Vec<CheckResult> = hosts
        .par_iter()
        .map(|h| {
            let c = run_capture(
                "ssh",
                &[
                    "-o",
                    "BatchMode=yes",
                    "-o",
                    &format!("ConnectTimeout={}", args.timeout),
                    h,
                    "echo OK",
                ],
            );
            let ok = c.code == 0 && c.stdout.contains("OK");
            let reason = if ok {
                String::new()
            } else {
                classify_error(&format!("{} {}", c.stderr, c.stdout)).to_string()
            };
            pb.inc(1);
            CheckResult {
                alias: h.clone(),
                ok,
                reason,
            }
        })
        .collect();
    pb.finish_and_clear();

    let mut ordered: Vec<&CheckResult> = Vec::new();
    for h in &hosts {
        if let Some(r) = results.iter().find(|r| &r.alias == h) {
            ordered.push(r);
        }
    }

    if args.format == crate::cli::Format::Json {
        println!("{}", serde_json::to_string_pretty(&ordered)?);
    } else {
        for r in &ordered {
            if r.ok {
                ok_line(&r.alias);
            } else {
                fail_line(&format!("{} (reason: {})", r.alias, r.reason));
            }
        }
        let ok = ordered.iter().filter(|r| r.ok).count();
        let ng = ordered.len() - ok;
        println!("--- {ok} OK / {ng} FAIL ---");
        if ng > 0 {
            println!("Hint: run `ssh-helper register <host>` to fix key auth failures");
            std::process::exit(1);
        }
    }
    Ok(())
}
