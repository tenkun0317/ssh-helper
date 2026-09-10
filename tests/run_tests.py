#!/usr/bin/env python3
import glob
import os
import shutil
import subprocess
import sys
import tempfile

HELPER = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SH = "sh"
POWERSHELL = shutil.which("powershell") or shutil.which("pwsh")
HAVE_PS = POWERSHELL is not None
HAVE_SH = shutil.which(SH) is not None

FIX_CONFIG = """Host t1
  HostName h1.invalid
  User u1

Host t2
  HostName h2.invalid
  User u2
  ProxyJump t1
"""

_FIX_KEYS = None


def fixture_keys():
    global _FIX_KEYS
    if _FIX_KEYS is None:
        d = tempfile.mkdtemp(prefix="sshhelper-keys-")
        subprocess.run(
            [
                "ssh-keygen",
                "-q",
                "-t",
                "ed25519",
                "-N",
                "",
                "-C",
                "fixture@test",
                "-f",
                os.path.join(d, "id_ed25519"),
            ],
            check=True,
            capture_output=True,
            timeout=60,
        )
        subprocess.run(
            [
                "ssh-keygen",
                "-q",
                "-t",
                "rsa",
                "-b",
                "2048",
                "-N",
                "",
                "-C",
                "fixture@test",
                "-f",
                os.path.join(d, "id_rsa"),
            ],
            check=True,
            capture_output=True,
            timeout=120,
        )
        _FIX_KEYS = d
    return _FIX_KEYS


PASS = 0
FAIL = 0


def check(name, cond, detail=""):
    global PASS, FAIL
    if cond:
        PASS += 1
        print(f"PASS {name}")
    else:
        FAIL += 1
        print(f"FAIL {name} {detail}")


def lock_win(path):
    if os.name != "nt":
        return
    try:
        me = subprocess.run(
            ["whoami"], capture_output=True, text=True, timeout=30
        ).stdout.strip()
    except Exception:
        me = ""
    if not me:
        return
    subprocess.run(
        ["icacls", path, "/inheritance:r", "/grant:r", f"{me}:(F)"], capture_output=True
    )
    subprocess.run(
        [
            "icacls",
            path,
            "/remove:g",
            "BUILTIN\\Administrators",
            "NT AUTHORITY\\SYSTEM",
        ],
        capture_output=True,
    )
    try:
        with open(path, encoding="utf-8") as f:
            f.read(1)
    except OSError:
        subprocess.run(["icacls", path, "/reset"], capture_output=True)


def make_home():
    tmp = tempfile.mkdtemp(prefix="sshhelper-test-")
    sshdir = os.path.join(tmp, ".ssh")
    os.makedirs(sshdir)
    with open(os.path.join(sshdir, "config"), "w", encoding="utf-8") as f:
        f.write(FIX_CONFIG)
    kd = fixture_keys()
    for name in ("id_ed25519.pub", "id_rsa.pub"):
        shutil.copy(os.path.join(kd, name), os.path.join(sshdir, name))
    for name in ("config", "id_ed25519.pub", "id_rsa.pub"):
        lock_win(os.path.join(sshdir, name))
    env = dict(os.environ)
    env["HOME"] = tmp.replace(os.sep, "/")
    env["USERPROFILE"] = tmp
    return tmp, env


def run(cmd, env, timeout=90):
    p = subprocess.run(
        cmd,
        capture_output=True,
        text=True,
        errors="replace",
        timeout=timeout,
        env=env,
        cwd=HELPER,
    )
    return p.returncode, p.stdout + p.stderr


def read(p):
    with open(p, encoding="utf-8") as f:
        return f.read()


def test_sh_syntax():
    for f in sorted(glob.glob(os.path.join(HELPER, "*.sh"))):
        rc, out = run([SH, "-n", f], dict(os.environ))
        check(f"sh-syntax:{os.path.basename(f)}", rc == 0, out[-300:])


def test_ps_syntax():
    if not HAVE_PS:
        print("SKIP ps-syntax (powershellなし)")
        return
    for f in sorted(
        glob.glob(os.path.join(HELPER, "*.ps1"))
        + glob.glob(os.path.join(HELPER, "*.psm1"))
    ):
        with open(f, "rb") as fh:
            check(f"ps-bom:{os.path.basename(f)}", fh.read(3) == b"\xef\xbb\xbf")
    checker = tempfile.mktemp(suffix=".ps1", prefix="parsecheck-")
    try:
        lines = ["$errs = $null", "$toks = $null"]
        files = sorted(
            glob.glob(os.path.join(HELPER, "*.ps1"))
            + glob.glob(os.path.join(HELPER, "*.psm1"))
        )
        for f in files:
            lines.append(f"$errs = $null")
            lines.append(
                f"[void][System.Management.Automation.Language.Parser]::ParseFile('{f}', [ref]$toks, [ref]$errs)"
            )
            lines.append(f"Write-Output ('{os.path.basename(f)}:' + $errs.Count)")
        with open(checker, "w", encoding="utf-8") as fh:
            fh.write("\n".join(lines) + "\n")
        rc, out = run([POWERSHELL, "-NoProfile", "-File", checker], dict(os.environ))
        for f in files:
            check(
                f"ps-syntax:{os.path.basename(f)}",
                f"{os.path.basename(f)}:0" in out,
                out[-300:],
            )
    finally:
        if os.path.exists(checker):
            os.remove(checker)


def test_register_dryrun(runner, label):
    tmp, env = make_home()
    try:
        before = read(os.path.join(tmp, ".ssh", "config"))
        if runner == "sh":
            cmd = [
                SH,
                os.path.join(HELPER, "register-ssh-key.sh"),
                "-n",
                "-i",
                os.path.join(tmp, ".ssh", "id_ed25519.pub"),
                "t1",
            ]
        else:
            cmd = [
                POWERSHELL,
                "-NoProfile",
                "-ExecutionPolicy",
                "Bypass",
                "-File",
                os.path.join(HELPER, "Register-SshKey.ps1"),
                "-n",
                "-i",
                os.path.join(tmp, ".ssh", "id_ed25519.pub"),
                "t1",
            ]
        rc, out = run(cmd, env)
        after = read(os.path.join(tmp, ".ssh", "config"))
        check(f"{label}-dryrun-existing-rc", rc == 0, out[-300:])
        check(
            f"{label}-dryrun-existing-untouched",
            before == after
            and not os.path.exists(os.path.join(tmp, ".ssh", "config.d")),
            out[-300:],
        )

        env2 = dict(env)
        env2["SSH_HELPER_DEFAULT_USER"] = "custom9"
        if runner == "sh":
            cmd = [
                SH,
                os.path.join(HELPER, "register-ssh-key.sh"),
                "-n",
                "-J",
                "a, b",
                "-H",
                "h.invalid",
                "new1",
            ]
        else:
            cmd = [
                POWERSHELL,
                "-NoProfile",
                "-ExecutionPolicy",
                "Bypass",
                "-File",
                os.path.join(HELPER, "Register-SshKey.ps1"),
                "-n",
                "-J",
                "a, b",
                "-RealHost",
                "h.invalid",
                "new1",
            ]
        rc, out = run(cmd, env2)
        check(f"{label}-dryrun-new-rc", rc == 0, out[-300:])
        check(f"{label}-dryrun-new-jump", "ProxyJump a,b" in out, out[-500:])
        check(f"{label}-dryrun-new-hostname", "HostName h.invalid" in out, out[-500:])
        check(f"{label}-dryrun-new-envuser", "User custom9" in out, out[-500:])
        check(f"{label}-dryrun-new-no-warning", "DEFAULT_USER" not in out, out[-500:])

        env3 = dict(env)
        env3.pop("SSH_HELPER_DEFAULT_USER", None)
        env3["USER"] = "testuser9"
        env3["USERNAME"] = "testuser9"
        if runner == "sh":
            cmd = [
                SH,
                os.path.join(HELPER, "register-ssh-key.sh"),
                "-n",
                "-J",
                "j1",
                "-H",
                "h.invalid",
                "newW",
            ]
        else:
            cmd = [
                POWERSHELL,
                "-NoProfile",
                "-ExecutionPolicy",
                "Bypass",
                "-File",
                os.path.join(HELPER, "Register-SshKey.ps1"),
                "-n",
                "-J",
                "j1",
                "-RealHost",
                "h.invalid",
                "newW",
            ]
        rc, out = run(cmd, env3)
        check(f"{label}-dryrun-unset-warn-rc", rc == 0, out[-300:])
        check(f"{label}-dryrun-unset-warn-msg", "DEFAULT_USER" in out, out[-500:])
        check(
            f"{label}-dryrun-unset-warn-fallback", "User testuser9" in out, out[-500:]
        )

        if runner == "sh":
            cmd = [SH, os.path.join(HELPER, "register-ssh-key.sh"), "-n", "bad;alias"]
        else:
            cmd = [
                POWERSHELL,
                "-NoProfile",
                "-ExecutionPolicy",
                "Bypass",
                "-File",
                os.path.join(HELPER, "Register-SshKey.ps1"),
                "-n",
                "bad;alias",
            ]
        rc, out = run(cmd, env)
        check(f"{label}-dryrun-badalias", rc != 0, out[-300:])
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def test_register_write(runner, label):
    tmp, env = make_home()
    try:
        if runner == "sh":
            cmd = [
                SH,
                os.path.join(HELPER, "register-ssh-key.sh"),
                "-i",
                os.path.join(tmp, ".ssh", "id_ed25519.pub"),
                "-H",
                "host.invalid",
                "-u",
                "u3",
                "new3",
            ]
        else:
            cmd = [
                POWERSHELL,
                "-NoProfile",
                "-ExecutionPolicy",
                "Bypass",
                "-File",
                os.path.join(HELPER, "Register-SshKey.ps1"),
                "-i",
                os.path.join(tmp, ".ssh", "id_ed25519.pub"),
                "-RealHost",
                "host.invalid",
                "-u",
                "u3",
                "new3",
            ]
        rc, out = run(cmd, env)
        cfg = read(os.path.join(tmp, ".ssh", "config"))
        man = os.path.join(tmp, ".ssh", "config.d", "managed")
        check(f"{label}-write-ssh-fails-fast", rc != 0, out[-300:])
        check(f"{label}-write-include", "Include config.d/managed" in cfg, cfg[:200])
        check(
            f"{label}-write-managed",
            os.path.exists(man)
            and "Host new3" in read(man)
            and "HostName host.invalid" in read(man),
            out[-500:],
        )
        check(
            f"{label}-write-backup",
            len(glob.glob(os.path.join(tmp, ".ssh", "*.bak-*"))) >= 1,
            out[-300:],
        )
        check(
            f"{label}-write-existing-intact",
            "Host t1" in cfg and "HostName h1.invalid" in cfg,
            cfg[:300],
        )
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def test_backup(runner, label):
    tmp, env = make_home()
    try:
        marker = "Host zz9\n  HostName z9.invalid\n  User u9\n"
        with open(
            os.path.join(tmp, ".ssh", "config.bak-TEST9"), "w", encoding="utf-8"
        ) as f:
            f.write(marker)
        if runner == "sh":
            lst = [SH, os.path.join(HELPER, "ssh-backup.sh"), "list"]
            rst = [
                SH,
                os.path.join(HELPER, "ssh-backup.sh"),
                "restore",
                "config.bak-TEST9",
            ]
        else:
            lst = [
                POWERSHELL,
                "-NoProfile",
                "-ExecutionPolicy",
                "Bypass",
                "-File",
                os.path.join(HELPER, "Backup-SshConfig.ps1"),
                "list",
            ]
            rst = [
                POWERSHELL,
                "-NoProfile",
                "-ExecutionPolicy",
                "Bypass",
                "-File",
                os.path.join(HELPER, "Backup-SshConfig.ps1"),
                "restore",
                "config.bak-TEST9",
            ]
        rc, out = run(lst, env)
        check(f"{label}-backup-list", rc == 0 and "config.bak-TEST9" in out, out[-300:])
        check(f"{label}-backup-list-info", "B " in out, out[-300:])
        rc, out = run(rst, env)
        check(f"{label}-backup-restore-rc", rc == 0, out[-400:])
        if rc != 0:
            print(f"---- {label} restore full output ----")
            print(out[-3000:])
        check(
            f"{label}-backup-restore-content",
            read(os.path.join(tmp, ".ssh", "config")) == marker,
            out[-400:],
        )
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def test_check_invalid(runner, label):
    tmp, env = make_home()
    try:
        if runner == "sh":
            cmd = [SH, os.path.join(HELPER, "ssh-check.sh")]
        else:
            cmd = [
                POWERSHELL,
                "-NoProfile",
                "-ExecutionPolicy",
                "Bypass",
                "-File",
                os.path.join(HELPER, "Test-Ssh.ps1"),
            ]
        rc, out = run(cmd, env)
        check(f"{label}-check-fail-rc", rc != 0, out[-300:])
        check(
            f"{label}-check-fail-lines",
            "FAIL t1" in out and "FAIL t2" in out,
            out[-300:],
        )
        check(f"{label}-check-fail-reason", "(reason: " in out, out[-300:])
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def test_revoke_dryrun(runner, label):
    tmp, env = make_home()
    try:
        if runner == "sh":
            cmd = [
                SH,
                os.path.join(HELPER, "revoke-ssh-key.sh"),
                "-n",
                "-i",
                os.path.join(tmp, ".ssh", "id_ed25519.pub"),
                "t1",
            ]
        else:
            cmd = [
                POWERSHELL,
                "-NoProfile",
                "-ExecutionPolicy",
                "Bypass",
                "-File",
                os.path.join(HELPER, "Revoke-SshKey.ps1"),
                "-n",
                "-i",
                os.path.join(tmp, ".ssh", "id_ed25519.pub"),
                "t1",
            ]
        rc, out = run(cmd, env)
        check(f"{label}-revoke-dryrun", rc == 0 and "grep -v -F" in out, out[-400:])
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def test_remote_hardening(runner, label):
    tmp, env = make_home()
    try:
        if runner == "sh":
            cmd = [SH, os.path.join(HELPER, "register-ssh-key.sh"), "-n", "t1"]
        else:
            cmd = [
                POWERSHELL,
                "-NoProfile",
                "-ExecutionPolicy",
                "Bypass",
                "-File",
                os.path.join(HELPER, "Register-SshKey.ps1"),
                "-n",
                "t1",
            ]
        rc, out = run(cmd, env)
        check(
            f"{label}-remote-tolerant-chmod", "chmod 755 ~ || true" in out, out[-500:]
        )
        check(
            f"{label}-remote-symlink-check",
            "[ -L ~/.ssh/authorized_keys ]" in out,
            out[-500:],
        )
        if runner == "sh":
            cmd = [SH, os.path.join(HELPER, "revoke-ssh-key.sh"), "-n", "t1"]
        else:
            cmd = [
                POWERSHELL,
                "-NoProfile",
                "-ExecutionPolicy",
                "Bypass",
                "-File",
                os.path.join(HELPER, "Revoke-SshKey.ps1"),
                "-n",
                "t1",
            ]
        rc, out = run(cmd, env)
        check(
            f"{label}-revoke-symlink-check",
            "[ -L ~/.ssh/authorized_keys ]" in out,
            out[-500:],
        )
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def test_show(runner, label):
    tmp, env = make_home()
    try:
        cfg = os.path.join(tmp, ".ssh", "config")
        if runner == "sh":
            base = [SH, os.path.join(HELPER, "ssh-show.sh"), "-F", cfg]
        else:
            base = [
                POWERSHELL,
                "-NoProfile",
                "-ExecutionPolicy",
                "Bypass",
                "-File",
                os.path.join(HELPER, "Show-SshConfig.ps1"),
                "-F",
                cfg,
            ]
        rc, out = run(base + ["t1"], env)
        check(f"{label}-show-one", rc == 0 and "h1.invalid" in out, out[-400:])
        rc, out = run(base, env)
        check(f"{label}-show-all", rc == 0 and "t1" in out and "t2" in out, out[-400:])
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def test_audit_unreachable(runner, label):
    tmp, env = make_home()
    try:
        if runner == "sh":
            cmd = [SH, os.path.join(HELPER, "ssh-audit.sh"), "t1"]
        else:
            cmd = [
                POWERSHELL,
                "-NoProfile",
                "-ExecutionPolicy",
                "Bypass",
                "-File",
                os.path.join(HELPER, "Audit-SshKeys.ps1"),
                "t1",
            ]
        rc, out = run(cmd, env)
        check(
            f"{label}-audit-unreachable",
            rc == 0 and "== t1 ==" in out and "UNREACHABLE" in out,
            out[-400:],
        )
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def test_keygen(runner, label):
    tmp, env = make_home()
    try:
        for name in ("id_ed25519", "id_ed25519.pub", "id_rsa", "id_rsa.pub"):
            p = os.path.join(tmp, ".ssh", name)
            if os.path.exists(p):
                os.remove(p)
        if runner == "sh":
            cmd = [SH, os.path.join(HELPER, "ssh-keygen-helper.sh")]
        else:
            cmd = [
                POWERSHELL,
                "-NoProfile",
                "-ExecutionPolicy",
                "Bypass",
                "-File",
                os.path.join(HELPER, "New-SshKey.ps1"),
            ]
        rc, out = run(cmd, env)
        check(
            f"{label}-keygen-create",
            rc == 0 and os.path.exists(os.path.join(tmp, ".ssh", "id_ed25519.pub")),
            out[-400:],
        )
        rc, out = run(cmd, env)
        check(f"{label}-keygen-noop", rc == 0 and "exists" in out, out[-400:])
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def test_agent_status(runner, label):
    tmp, env = make_home()
    try:
        if runner == "sh":
            cmd = [SH, os.path.join(HELPER, "ssh-agent-helper.sh"), "status"]
        else:
            cmd = [
                POWERSHELL,
                "-NoProfile",
                "-ExecutionPolicy",
                "Bypass",
                "-File",
                os.path.join(HELPER, "Sync-SshAgent.ps1"),
                "status",
            ]
        rc, out = run(cmd, env)
        check(f"{label}-agent-status", "agent" in out, out[-400:])
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def test_fingerprint_arg(runner, label):
    tmp, env = make_home()
    try:
        if runner == "sh":
            cmd = [
                SH,
                os.path.join(HELPER, "register-ssh-key.sh"),
                "-n",
                "-F",
                "bogus",
                "t1",
            ]
        else:
            cmd = [
                POWERSHELL,
                "-NoProfile",
                "-ExecutionPolicy",
                "Bypass",
                "-File",
                os.path.join(HELPER, "Register-SshKey.ps1"),
                "-n",
                "-TrustFingerprints",
                "bogus",
                "t1",
            ]
        rc, out = run(cmd, env)
        check(f"{label}-fingerprint-badformat", rc != 0, out[-400:])
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def test_help(runner, label):
    sh_cmds = [
        "register-ssh-key.sh",
        "revoke-ssh-key.sh",
        "ssh-backup.sh",
        "ssh-show.sh",
        "ssh-check.sh",
        "ssh-audit.sh",
        "ssh-keygen-helper.sh",
        "ssh-agent-helper.sh",
        "install.sh",
    ]
    ps_cmds = [
        "Register-SshKey.ps1",
        "Revoke-SshKey.ps1",
        "Test-Ssh.ps1",
        "Backup-SshConfig.ps1",
        "Show-SshConfig.ps1",
        "Audit-SshKeys.ps1",
        "New-SshKey.ps1",
        "Sync-SshAgent.ps1",
    ]
    if runner == "sh":
        for c in sh_cmds:
            rc, out = run([SH, os.path.join(HELPER, c), "-h"], dict(os.environ))
            check(f"{label}-help:{c}", rc == 0 and "usage" in out, out[-300:])
        rc, out = run(
            [SH, os.path.join(HELPER, "register-ssh-key.sh"), "--help"],
            dict(os.environ),
        )
        check(f"{label}-help-long", rc == 0 and "usage" in out, out[-300:])
    else:
        for c in ps_cmds:
            rc, out = run(
                [
                    POWERSHELL,
                    "-NoProfile",
                    "-ExecutionPolicy",
                    "Bypass",
                    "-File",
                    os.path.join(HELPER, c),
                    "-h",
                ],
                dict(os.environ),
            )
            check(f"{label}-help:{c}", rc == 0 and "usage" in out, out[-300:])
        rc, out = run(
            [
                POWERSHELL,
                "-NoProfile",
                "-ExecutionPolicy",
                "Bypass",
                "-File",
                os.path.join(HELPER, "Register-SshKey.ps1"),
                "--help",
            ],
            dict(os.environ),
        )
        check(f"{label}-help-long", rc == 0 and "usage" in out, out[-300:])


def test_wrapper(label):
    tmp, env = make_home()
    try:
        rc, out = run([SH, os.path.join(HELPER, "ssh-helper"), "help"], env)
        check(
            f"{label}-wrapper-help",
            rc == 0 and "register" in out and "audit" in out and "keygen" in out,
            out[-300:],
        )
        rc, out = run([SH, os.path.join(HELPER, "ssh-helper"), "bogus"], env)
        check(f"{label}-wrapper-bogus", rc != 0, out[-300:])
        rc, out = run(
            [SH, os.path.join(HELPER, "ssh-helper"), "register", "-n", "t1"], env
        )
        check(
            f"{label}-wrapper-register",
            rc == 0 and "authorized_keys" in out,
            out[-300:],
        )
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def test_install():
    bindir = tempfile.mkdtemp(prefix="sshhelper-bin-")
    try:
        env = dict(os.environ)
        env["PREFIX"] = bindir.replace(os.sep, "/")
        env["SSH_HELPER_NO_RC"] = "1"
        rc, out = run([SH, os.path.join(HELPER, "install.sh")], env)
        link = os.path.join(bindir, "ssh-helper")
        check("install-rc", rc == 0 and os.path.isfile(link), out[-300:])
        with open(link, encoding="utf-8", errors="replace") as f:
            shim = f.read()
        check("install-shim-path", 'ssh-helper" "$@"' in shim, shim[-300:])
        rc, out = run([SH, link, "help"], env)
        check(
            "install-link-help",
            rc == 0 and "register" in out and "audit" in out,
            out[-300:],
        )
        rc, out = run([SH, link, "register"], env)
        check("install-link-dispatch", rc != 0 and "usage" in out, out[-300:])
    finally:
        shutil.rmtree(bindir, ignore_errors=True)


def main():
    try:
        sys.stdout.reconfigure(encoding="utf-8", errors="backslashreplace")
        sys.stderr.reconfigure(encoding="utf-8", errors="backslashreplace")
    except Exception:
        pass
    if not HAVE_SH:
        print("FAIL: sh が見つかりません")
        sys.exit(1)
    test_sh_syntax()
    test_ps_syntax()
    runners = [("sh", "sh")]
    if HAVE_PS:
        runners.append(("ps", "ps"))
    else:
        print("SKIP ps-runner (powershellなし)")
    for runner, label in runners:
        test_register_dryrun(runner, label)
        test_register_write(runner, label)
        test_backup(runner, label)
        test_check_invalid(runner, label)
        test_revoke_dryrun(runner, label)
        test_remote_hardening(runner, label)
        test_show(runner, label)
        test_audit_unreachable(runner, label)
        test_keygen(runner, label)
        test_agent_status(runner, label)
        test_fingerprint_arg(runner, label)
        test_help(runner, label)
    test_wrapper("sh")
    test_install()
    print(f"--- {PASS} passed / {FAIL} failed ---")
    sys.exit(1 if FAIL else 0)


if __name__ == "__main__":
    main()
