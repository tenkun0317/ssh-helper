use crate::core::*;
use anyhow::Result;

pub fn run() -> Result<()> {
    let mut ok = 0;
    let mut ng = 0;
    let mut check = |name: &str, pass: bool, hint: &str| {
        if pass {
            ok_line(name);
            ok += 1;
        } else {
            fail_line(&format!("{name} -- {hint}"));
            ng += 1;
        }
    };

    let ssh_ok = run_capture("ssh", &["-V"]).code != 127;
    check("ssh", ssh_ok, "Install OpenSSH");

    let cfg = config_path().unwrap_or_default();
    check(
        &format!("config {}", cfg.display()),
        cfg.is_file(),
        "config not found",
    );

    let mut syntax_ok = true;
    let mut n_alias = 0;
    if cfg.is_file() {
        let managed = managed_path().unwrap_or_default();
        let mut files = vec![cfg.clone()];
        if managed.is_file() {
            files.push(managed);
        }
        let aliases = ssh_aliases(&files);
        n_alias = aliases.len();
        for a in &aliases {
            if ssh_g(a, None).is_err() {
                syntax_ok = false;
                break;
            }
        }
    }
    check(
        &format!("config syntax ({n_alias} hosts)"),
        syntax_ok,
        "restore with `ssh-helper backup list`",
    );

    let sd = ssh_dir().unwrap_or_default();
    let has_key = sd.join("id_ed25519").is_file() || sd.join("id_rsa").is_file();
    check("local keys", has_key, "generate with `ssh-helper keygen`");

    let c = run_capture("ssh-add", &["-l"]);
    check(
        "ssh-agent",
        c.code == 0 || c.code == 1,
        "start/register with `ssh-helper agent`",
    );

    let include_ok = std::fs::read_to_string(&cfg)
        .map(|t| {
            t.lines()
                .any(|l| l.trim().eq_ignore_ascii_case("Include config.d/managed"))
        })
        .unwrap_or(false);
    if cfg.is_file() {
        check(
            "Include config.d/managed",
            include_ok,
            "added automatically by `ssh-helper register`",
        );
    }

    println!("--- {ok} OK / {ng} NG ---");
    if ng > 0 {
        std::process::exit(1);
    }
    Ok(())
}
