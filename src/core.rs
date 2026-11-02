use anyhow::{bail, Context, Result};
use std::path::{Path, PathBuf};
use std::process::Command;

pub fn home_dir() -> Result<PathBuf> {
    if let Some(p) = dirs::home_dir() {
        return Ok(p);
    }
    if let Ok(h) = std::env::var("USERPROFILE") {
        if !h.is_empty() {
            return Ok(PathBuf::from(h));
        }
    }
    if let Ok(h) = std::env::var("HOME") {
        if !h.is_empty() {
            return Ok(PathBuf::from(h));
        }
    }
    bail!("Cannot determine home directory")
}

pub fn ssh_dir() -> Result<PathBuf> {
    Ok(home_dir()?.join(".ssh"))
}

pub fn config_path() -> Result<PathBuf> {
    Ok(ssh_dir()?.join("config"))
}

pub fn managed_path() -> Result<PathBuf> {
    Ok(ssh_dir()?.join("config.d").join("managed"))
}

pub fn known_hosts_path() -> Result<PathBuf> {
    Ok(ssh_dir()?.join("known_hosts"))
}

pub fn timestamp() -> String {
    chrono::Local::now().format("%Y%m%d-%H%M%S").to_string()
}

pub fn valid_token(s: &str) -> bool {
    !s.is_empty()
        && s.chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '.' || c == '_' || c == '-' || c == '@')
}

pub fn valid_alias(s: &str) -> bool {
    !s.is_empty()
        && s.chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '.' || c == '_' || c == '-')
}

pub fn normalize_jumps(raw: Option<&str>) -> Result<Option<String>> {
    let raw = match raw {
        Some(r) => r,
        None => return Ok(None),
    };
    let parts: Vec<String> = raw
        .split(',')
        .map(|s| s.trim().trim_matches(|c| c == ' ' || c == '\t').to_string())
        .filter(|s| !s.is_empty())
        .collect();
    if parts.is_empty() {
        if raw.trim().is_empty() {
            return Ok(None);
        }
        bail!("Invalid -J format. Example: -J bastion,internal");
    }
    for j in &parts {
        if !valid_alias(j) {
            bail!("Invalid jump host: {j}");
        }
    }
    Ok(Some(parts.join(",")))
}

pub fn expand_tilde(p: &str) -> PathBuf {
    if let Some(rest) = p.strip_prefix("~/") {
        if let Ok(h) = home_dir() {
            return h.join(rest);
        }
    }
    PathBuf::from(p)
}

pub struct Capture {
    pub code: i32,
    pub stdout: String,
    pub stderr: String,
}

pub fn run_capture(exe: &str, args: &[&str]) -> Capture {
    match Command::new(exe).args(args).output() {
        Ok(o) => Capture {
            code: o.status.code().unwrap_or(1),
            stdout: String::from_utf8_lossy(&o.stdout).replace('\r', ""),
            stderr: String::from_utf8_lossy(&o.stderr).replace('\r', ""),
        },
        Err(_) => Capture {
            code: 127,
            stdout: String::new(),
            stderr: format!("{exe} not found"),
        },
    }
}

pub fn require_ssh() -> Result<()> {
    let c = run_capture("ssh", &["-V"]);
    if c.code == 127 {
        bail!("ssh not found. Install OpenSSH and add it to PATH");
    }
    Ok(())
}

pub fn ssh_g(alias: &str, config_file: Option<&str>) -> Result<String> {
    let mut cmd = Command::new("ssh");
    cmd.arg("-G");
    if let Some(f) = config_file {
        cmd.arg("-F").arg(f);
    }
    cmd.arg(alias);
    let out = cmd.output().context("failed to run ssh -G")?;
    let stdout: String = String::from_utf8_lossy(&out.stdout).replace('\r', "");
    if !out.status.success() || stdout.trim().is_empty() {
        bail!("failed to resolve {alias} (config error)");
    }
    Ok(stdout)
}

pub fn pick_g(g: &str, key: &str) -> String {
    for line in g.lines() {
        let mut it = line.splitn(2, char::is_whitespace);
        let k = it.next().unwrap_or("").to_ascii_lowercase();
        if k == key {
            return it.next().unwrap_or("").trim().to_string();
        }
    }
    String::new()
}

pub fn pick_g_all(g: &str, key: &str) -> Vec<String> {
    let mut v = Vec::new();
    for line in g.lines() {
        let mut it = line.splitn(2, char::is_whitespace);
        let k = it.next().unwrap_or("").to_ascii_lowercase();
        if k == key {
            v.push(it.next().unwrap_or("").trim().to_string());
        }
    }
    v
}

pub fn host_rest(trimmed_start: &str) -> Option<&str> {
    let head = trimmed_start.get(..4)?;
    if !head.eq_ignore_ascii_case("host") {
        return None;
    }
    let rest = trimmed_start.get(4..)?;
    if rest.starts_with(' ') || rest.starts_with('\t') {
        Some(rest)
    } else {
        None
    }
}

pub fn host_patterns(rest: &str) -> Vec<&str> {
    rest.split(|c: char| c.is_whitespace() || c == ',')
        .map(|s| s.trim())
        .filter(|s| !s.is_empty())
        .collect()
}

pub fn ssh_aliases(files: &[PathBuf]) -> Vec<String> {
    let mut out: Vec<String> = Vec::new();
    for f in files {
        let Ok(text) = std::fs::read_to_string(f) else {
            continue;
        };
        for line in text.lines() {
            let t = line.trim_start();
            let Some(rest) = host_rest(t) else {
                continue;
            };
            for first in host_patterns(rest) {
                if first.contains('*') || first.contains('!') {
                    continue;
                }
                if !valid_alias(first) {
                    continue;
                }
                if !out.iter().any(|x| x == first) {
                    out.push(first.to_string());
                }
            }
        }
    }
    out
}

pub fn find_block(lines: &[String], alias: &str) -> Option<(usize, usize)> {
    let mut start: Option<usize> = None;
    for (i, line) in lines.iter().enumerate() {
        let t = line.trim_start();
        let Some(rest) = host_rest(t) else {
            continue;
        };
        if let Some(s) = start {
            return Some((s, i));
        }
        if host_patterns(rest).contains(&alias) {
            start = Some(i);
        }
    }
    start.map(|s| (s, lines.len()))
}

pub fn find_config_value(block_lines: &[String], key: &str) -> String {
    for line in block_lines {
        let t = line.trim();
        let mut it = t.splitn(2, char::is_whitespace);
        let k = it.next().unwrap_or("");
        if k.eq_ignore_ascii_case(key) {
            return it.next().unwrap_or("").trim().to_string();
        }
    }
    String::new()
}

pub fn read_lines(path: &Path) -> Result<Vec<String>> {
    let text =
        std::fs::read_to_string(path).with_context(|| format!("cannot read {}", path.display()))?;
    Ok(text.lines().map(|s| s.to_string()).collect())
}

pub fn write_lines_nobom(path: &Path, lines: &[String]) -> Result<()> {
    use std::io::Write;
    let mut content = lines.join("\n");
    content.push('\n');
    let f =
        std::fs::File::create(path).with_context(|| format!("cannot write {}", path.display()))?;
    let mut w = std::io::BufWriter::new(f);
    w.write_all(content.as_bytes())?;
    w.flush()?;
    Ok(())
}

pub fn lock_file_to_owner(path: &Path) -> Result<()> {
    if !cfg!(windows) {
        return Ok(());
    }
    let s = path.to_string_lossy().to_string();

    for cand in acl_candidates() {
        let grant = format!("{cand}:(F)");
        let ok = Command::new("icacls")
            .args([&s, "/inheritance:r", "/grant:r", &grant])
            .output()
            .map(|o| o.status.success())
            .unwrap_or(false);
        if !ok {
            continue;
        }
        let _ = Command::new("icacls")
            .args([
                &s,
                "/remove:g",
                "BUILTIN\\Administrators",
                "NT AUTHORITY\\SYSTEM",
            ])
            .output();
        if has_malformed_ace(&s) || std::fs::File::open(path).is_err() {
            let _ = Command::new("icacls").args([&s, "/reset"]).output();
            continue;
        }
        return Ok(());
    }

    if std::fs::File::open(path).is_ok() {
        return Ok(());
    }
    let _ = Command::new("icacls").args([&s, "/reset"]).output();
    Ok(())
}

fn acl_candidates() -> &'static Vec<String> {
    static CANDIDATES: std::sync::OnceLock<Vec<String>> = std::sync::OnceLock::new();
    CANDIDATES.get_or_init(|| {
        let mut candidates: Vec<String> = Vec::new();
        let domain = std::env::var("USERDOMAIN").unwrap_or_default();
        let user = std::env::var("USERNAME")
            .or_else(|_| std::env::var("USER"))
            .unwrap_or_default();
        if !domain.is_empty() && !user.is_empty() {
            candidates.push(format!("{domain}\\{user}"));
        }
        if let Some(sid) = current_user_sid() {
            candidates.push(format!("*{sid}"));
        }
        candidates
    })
}

fn current_user_sid() -> Option<String> {
    let out = Command::new("whoami").args(["/user"]).output().ok()?;
    let text = String::from_utf8_lossy(&out.stdout);
    text.split_whitespace()
        .find(|t| t.starts_with("S-1-5-"))
        .map(|t| t.trim_matches(|c| c == '"' || c == '\'').to_string())
}

fn has_malformed_ace(path_str: &str) -> bool {
    let Ok(out) = Command::new("icacls").arg(path_str).output() else {
        return false;
    };
    let text = String::from_utf8_lossy(&out.stdout);
    text.contains("\\:")
}

pub fn default_user() -> String {
    if let Ok(u) = std::env::var("SSH_HELPER_DEFAULT_USER") {
        if !u.trim().is_empty() {
            return u.trim().to_string();
        }
    }
    let who = std::env::var("USERNAME")
        .or_else(|_| std::env::var("USER"))
        .unwrap_or_default();
    let who = who.trim().to_string();
    let who = if who.is_empty() {
        "user".to_string()
    } else {
        who
    };
    eprintln!("Warning: SSH_HELPER_DEFAULT_USER is not set (using default {who})");
    who
}

pub fn resolve_pubkeys(explicit: &[String]) -> Result<Vec<PathBuf>> {
    if !explicit.is_empty() {
        return Ok(explicit.iter().map(|s| expand_tilde(s)).collect());
    }
    let mut v = Vec::new();
    if let Ok(sd) = ssh_dir() {
        for name in ["id_ed25519.pub", "id_rsa.pub"] {
            let p = sd.join(name);
            if p.is_file() {
                v.push(p);
            }
        }
    }
    if v.is_empty() {
        bail!("No public key found (specify with -i)");
    }
    Ok(v)
}

pub fn load_pubkey_line(path: &Path) -> Result<String> {
    let raw =
        std::fs::read(path).with_context(|| format!("public key not found: {}", path.display()))?;
    let raw = if raw.starts_with(&[0xEF, 0xBB, 0xBF]) {
        &raw[3..]
    } else {
        &raw[..]
    };
    let text = String::from_utf8_lossy(raw).replace('\r', "");
    let text = text.trim().to_string();
    if text.is_empty() {
        bail!("empty public key file: {}", path.display());
    }
    if text.lines().count() > 1 {
        bail!("multi-line public key file: {}", path.display());
    }
    if text.contains('\'') {
        bail!("public key file contains quotes: {}", path.display());
    }
    let mut it = text.split_whitespace();
    let kind = it.next().unwrap_or("");
    let body = it.next().unwrap_or("");
    let ok_kind = kind == "ssh-ed25519"
        || kind == "ssh-rsa"
        || kind == "ssh-dss"
        || kind.starts_with("ecdsa-sha2-")
        || kind.starts_with("sk-ssh-");
    let ok_body = !body.is_empty()
        && body
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '+' || c == '/' || c == '=');
    if !(ok_kind && ok_body) {
        bail!("malformed public key: {}", path.display());
    }
    Ok(text)
}

pub fn collect_trust_fps(cli_fps: &[String]) -> Result<Option<Vec<String>>> {
    let mut all = String::new();
    for f in cli_fps {
        all.push(',');
        all.push_str(f);
    }
    if let Ok(e) = std::env::var("SSH_HELPER_TRUST_FINGERPRINTS") {
        all.push(',');
        all.push_str(&e);
    }
    let mut v: Vec<String> = all
        .split(',')
        .flat_map(|s| s.split(['\n', '\r']))
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
        .collect();
    v.sort();
    v.dedup();
    if v.is_empty() {
        return Ok(None);
    }
    for fp in &v {
        let ok = fp.starts_with("SHA256:")
            && fp.len() > 7
            && fp[7..]
                .chars()
                .all(|c| c.is_ascii_alphanumeric() || c == '+' || c == '/' || c == '=');
        if !ok {
            bail!("-F must be in SHA256:... format: {fp}");
        }
    }
    Ok(Some(v))
}

pub fn classify_error(stderr: &str) -> &'static str {
    if stderr.contains("Could not resolve hostname") {
        "DNS resolution failed"
    } else if stderr.contains("Connection timed out") || stderr.contains("Operation timed out") {
        "Connection timed out"
    } else if stderr.contains("Connection refused") {
        "Connection refused"
    } else if stderr.contains("Permission denied") {
        "Key auth failed (registration required)"
    } else if stderr.contains("Host key verification failed") {
        "Host key unverified"
    } else if stderr.contains("Connection closed") || stderr.contains("closed by remote") {
        "Connection closed"
    } else if stderr.contains("No route to host") {
        "Unreachable"
    } else if stderr.contains("Timeout") || stderr.contains("timed out") {
        "Timed out"
    } else {
        "Other"
    }
}

use colored::Colorize;

pub fn paint_on(no_color: bool) {
    if no_color || std::env::var("NO_COLOR").is_ok() {
        colored::control::set_override(false);
    }
}

pub fn ok_line(s: &str) {
    println!("{} {s}", "OK  ".green().bold());
}
pub fn fail_line(s: &str) {
    println!("{} {s}", "FAIL".red().bold());
}
pub fn info(s: &str) {
    println!("{s}");
}
pub fn step(s: &str) {
    println!("{}", s.cyan());
}
pub fn warn(s: &str) {
    eprintln!("{} {s}", "Warning:".yellow().bold());
}
pub fn err_msg(s: &str) {
    eprintln!("{} {s}", "error:".red().bold());
}

pub fn confirm(prompt: &str, auto_yes: bool) -> Result<bool> {
    if auto_yes {
        return Ok(true);
    }
    Ok(dialoguer::Confirm::new()
        .with_prompt(prompt)
        .default(false)
        .interact()?)
}

pub fn sq_escape(s: &str) -> String {
    s.replace('\'', "'\\''")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn host_rest_ascii_and_japanese() {
        assert_eq!(host_rest("Host foo"), Some(" foo"));
        assert_eq!(host_rest("host  a b"), Some("  a b"));
        assert_eq!(host_rest("Hostname foo"), None);
        assert_eq!(host_rest("Host"), None);
        assert_eq!(host_rest("# 日本語コメント"), None);
        assert_eq!(host_rest("日本語ホスト"), None);
    }

    #[test]
    fn valid_alias_ok() {
        assert!(valid_alias("web1"));
        assert!(valid_alias("a.b-c_d"));
        assert!(!valid_alias("a b"));
        assert!(!valid_alias("あ"));
        assert!(!valid_alias(""));
    }

    #[test]
    fn normalize_jumps_ok() {
        assert_eq!(
            normalize_jumps(Some("bastion, internal")).unwrap(),
            Some("bastion,internal".to_string())
        );
        assert_eq!(normalize_jumps(None).unwrap(), None);
        assert!(normalize_jumps(Some(",,,")).is_err());
    }

    #[test]
    fn find_block_basic() {
        let lines = vec![
            "Host a".to_string(),
            "  User u".to_string(),
            "Host b c".to_string(),
            "  User v".to_string(),
        ];
        assert_eq!(find_block(&lines, "a"), Some((0, 2)));
        assert_eq!(find_block(&lines, "c"), Some((2, 4)));
        assert_eq!(find_block(&lines, "z"), None);
    }

    #[test]
    fn find_block_comma_pattern() {
        let lines = vec![
            "Host a,b".to_string(),
            "  User u".to_string(),
            "Host c".to_string(),
        ];
        assert_eq!(find_block(&lines, "a"), Some((0, 2)));
        assert_eq!(find_block(&lines, "b"), Some((0, 2)));
        assert_eq!(find_block(&lines, "c"), Some((2, 3)));
    }

    #[test]
    fn host_patterns_ok() {
        assert_eq!(host_patterns("a,b c"), vec!["a", "b", "c"]);
        assert_eq!(host_patterns("a, b"), vec!["a", "b"]);
        assert_eq!(host_patterns("a ,b"), vec!["a", "b"]);
        assert_eq!(host_patterns(" a "), vec!["a"]);
        assert!(host_patterns("").is_empty());
    }

    #[test]
    fn classify_known() {
        assert_eq!(
            classify_error("Could not resolve hostname foo"),
            "DNS resolution failed"
        );
        assert_eq!(
            classify_error("Permission denied (publickey)"),
            "Key auth failed (registration required)"
        );
    }
}
