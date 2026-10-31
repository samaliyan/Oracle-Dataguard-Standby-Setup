#!/usr/bin/python3
"""Mock ssh/scp to a fake PRIMARY server.
Every remote command is logged to primary_cmds.log. Anything that is not one of the
expected read-only probes is logged to primary_UNEXPECTED.log and refused."""
import sys, os, re, json, subprocess

ST = "/tmp/dgt/state"
PRI = os.path.join(ST, "primary.json")
CMDLOG = os.path.join(ST, "primary_cmds.log")
BAD = os.path.join(ST, "primary_UNEXPECTED.log")

def load():
    with open(PRI) as f: return json.load(f)
def log(path, line):
    with open(path, "a") as f: f.write(line + "\n")
    try: os.chmod(path, 0o666)
    except Exception: pass

prog = os.path.basename(sys.argv[0])
a = sys.argv[1:]
pri = load()

def opts(args):
    o = {}; rest = []; i = 0
    while i < len(args):
        x = args[i]
        if x == "-o": k, _, v = args[i + 1].partition("="); o[k] = v; i += 2; continue
        if x == "-O" and prog != "scp": o["_O"] = args[i + 1]; i += 2; continue
        if x == "-E": o["_E"] = args[i + 1]; i += 2; continue
        if x.startswith("-"): o[x] = True; i += 1; continue
        rest.append(x); i += 1
    return o, rest

def target_ok(dest):
    user, _, host = dest.partition("@")
    return host == pri["ip"] and user in pri["ssh_users"]

def md5(text):
    import hashlib
    return hashlib.md5(text.encode()).hexdigest()

def files():
    """files that exist on the mock primary: path -> content"""
    P = pri; f = dict(P.get("files", {}))
    if P.get("pwfile") and not P["pwfile"].startswith("+"): f[P["pwfile"]] = P.get("pw_content", "ORAPW-PRIMARY-CONTENT") + "\n"
    if P.get("pw_tmp"): f["/tmp/orapw_for_standby_" + P.get("stby_sid", "PRODDB_STBY")] = P.get("pw_content", "ORAPW-PRIMARY-CONTENT") + "\n"
    return f

def remote(cmd, stdin_data):
    log(CMDLOG, cmd)
    if cmd.startswith("timeout 120 "): cmd = cmd[len("timeout 120 "):]
    P = pri
    grid = P.get("grid", True)
    if cmd == "hostname -s; hostname -f":
        print(P["host"].split(".")[0]); print(P["host"]); return 0
    if cmd == "cat /etc/oratab":
        print("# oratab")
        if grid and not P.get("oratab_no_asm"): print(f"+ASM:{P['grid_home']}:N")
        [print(x) for x in P.get("extra_oratab", [])]
        if P.get("oratab_has_db", True): print(f"{P['sid']}:{P.get('oratab_home', P['db_home'])}:N")
        return 0
    if cmd == "cat /etc/oraInst.loc":
        print(f"inventory_loc={P['inventory']}"); print("inst_group=oinstall"); return 0
    if cmd == "cat /etc/oracle/olr.loc":
        if not grid: print("cat: /etc/oracle/olr.loc: No such file or directory", file=sys.stderr); return 1
        print(f"crs_home={P['grid_home']}"); return 0
    if cmd == "ps -eo pid,user:32,args":
        print("  PID USER     COMMAND")
        print("    1 root     /usr/lib/systemd/systemd")
        if grid: print(f" {P.get('asm_pid', 4000)} {'oracle' if P.get('single_owner') else 'grid'}     asm_pmon_+ASM")
        print(f" {P.get('db_pid', 4321)} oracle   ora_pmon_{P['sid']}")
        for x in P.get("extra_pmon", []): print(f" 5555 oracle   ora_pmon_{x}")
        lh = P.get("listener_home", P["grid_home"] if grid else P["db_home"])
        print(f" 3000 {'oracle' if (P.get('single_owner') or not grid) else 'grid'}     {lh}/bin/tnslsnr {P.get('listener_name', 'LISTENER')} -no_crs_notify -inherit")
        return 0
    m = re.fullmatch(r"readlink /proc/(\d+)/exe", cmd)
    if m:
        pid = int(m.group(1))
        if pid == P.get("db_pid", 4321) and P.get("exe_readable", True): print(P["db_home"] + "/bin/oracle"); return 0
        if pid == P.get("asm_pid", 4000) and grid and P.get("single_owner"): print(P["grid_home"] + "/bin/oracle"); return 0
        print(f"readlink: /proc/{pid}/exe: Permission denied", file=sys.stderr); return 1
    m = re.fullmatch(r"tr '\\0' '\\n' < /proc/(\d+)/environ \| grep -E '\^\(ORACLE_HOME\|ORACLE_SID\|ORACLE_BASE\|TNS_ADMIN\)='", cmd)
    if m:
        if not P.get("environ_readable", True): print("tr: Permission denied", file=sys.stderr); return 1
        print(f"ORACLE_HOME={P['db_home']}"); print(f"ORACLE_SID={P['sid']}")
        if P.get("tns_admin"): print(f"TNS_ADMIN={P['tns_admin']}")
        return 0
    m = re.fullmatch(r"id (\S+); id (\S+)", cmd)
    if m:
        for u in m.groups():
            if u in P["ids"]: print(P["ids"][u])
        return 0
    m = re.fullmatch(r"sh -c 'timeout 120 test -e (\S+); r=\$\?; \[ \$r -eq 0 \] && echo YES; \[ \$r -eq 1 \] && echo NO; true'", cmd)
    if m:
        f = m.group(1)
        print("YES" if (f in files() or any(f.startswith(d.rstrip("/") + "/") for d in P.get("shared_dirs", [])) and os.path.exists(f)) else "NO"); return 0
    m = re.fullmatch(r"sh -c 'timeout 120 test -d (\S+) -a -x (\S+); r=\$\?; \[ \$r -eq 0 \] && echo YES; \[ \$r -eq 1 \] && echo NO; true'", cmd)
    if m:
        print("YES" if m.group(1) in P.get("canlook_yes", []) else P.get("canlook", "YES")); return 0
    m = re.fullmatch(r"ls -1A (\S+)", cmd)
    if m and m.group(1) in P.get("lsdir", {}):
        print("\n".join(P["lsdir"][m.group(1)])); return 0
    if cmd == """sh -c 'findmnt -rn -o SOURCE,UUID | while read -r s u; do case "$s" in /dev/*) echo "M|$s|$u"; lsblk -nsP -o TYPE,WWN,SERIAL "${s%%\\[*}";; esac; done; echo __DG_MOUNTS_END__'""":
        fs = P.get("fsid", "/dev/mapper/vg_prim-u02 1b2c3d4e-0000-4000-8000-00000000abcd").split()
        print(f"M|{fs[0] if fs else '/dev/mapper/vg_prim-u02'}|{fs[1] if len(fs) > 1 else ''}")
        print(P.get("devid", 'TYPE="lvm" WWN="" SERIAL=""\nTYPE="disk" WWN="0x5000c500aaaa0001" SERIAL="PRIMDISK1"'))
        for n, u in enumerate(P.get("mount_uuids", [])): print(f"M|/dev/sdz{n + 1}|{u}")
        print("__DG_MOUNTS_END__"); return 0
    m = re.fullmatch(r'lsblk -nsP -o TYPE,WWN,SERIAL "\$\(findmnt -n -o SOURCE --target (\S+)\)"', cmd)
    if m:
        print(P.get("devid", 'TYPE="lvm" WWN="" SERIAL=""\nTYPE="disk" WWN="0x5000c500aaaa0001" SERIAL="PRIMDISK1"')); return 0
    m = re.fullmatch(r"findmnt -n -o SOURCE,UUID --target (\S+)", cmd)
    if m:
        print(P.get("fsid", "/dev/mapper/vg_prim-u02 1b2c3d4e-0000-4000-8000-00000000abcd")); return 0
    m = re.fullmatch(r"grep -o 'NAME=\"oracle.crs\" VER=\"\[0-9.\]\*\"' (\S+)/inventory/ContentsXML/comps.xml", cmd)
    if m:
        if not grid: return 2
        print(f'NAME="oracle.crs" VER="{P.get("grid_version", P["version"])}"'); return 0
    if cmd == "date +%s":
        import time
        print(int(time.time()) + int(P.get("clock_offset", 0))); return 0
    def shared(f):
        return any(f.startswith(d.rstrip("/") + "/") for d in P.get("shared_dirs", [])) and os.path.exists(f)
    lu = "oracle" if (P.get("single_owner") or not grid) else "grid"
    m = re.fullmatch(r"stat -c '%U\|%G\|%a\|%F\|%Y' (\S+)", cmd)
    if m:
        import time
        f = m.group(1); t = int(time.time())
        lh = P.get("listener_home", P["grid_home"] if grid else P["db_home"])
        if f == P["db_home"] + "/bin/oracle": print(f"{P.get('db_bin_owner', 'oracle')}|oinstall|{P.get('db_bin_mode', '6751')}|regular file|{t}"); return 0
        if grid and f == P["grid_home"] + "/bin/oracle": print(f"{'oracle' if P.get('single_owner') else 'grid'}|oinstall|6751|regular file|{t}"); return 0
        if f == lh + "/bin/lsnrctl": print(f"{lu}|oinstall|751|regular file|{t}"); return 0
        if f in files():
            if f.startswith("/tmp/orapw_for_standby_"):
                print(f"{P.get('pw_tmp_owner', lu)}|oinstall|{P.get('pw_tmp_mode', '640')}|{P.get('pw_tmp_type', 'regular file')}|{P.get('pw_tmp_mtime', t)}"); return 0
            print(f"oracle|oinstall|600|regular file|{t}"); return 0
        if shared(f): print(f"root|root|600|regular empty file|{t}"); return 0
        print(f"stat: cannot stat '{f}': No such file or directory", file=sys.stderr); return 1
    m = re.fullmatch(r"stat -c '%U %G' (\S+)", cmd)
    if m:
        f = m.group(1)
        if f in (P["db_home"] + "/inventory", P["grid_home"] + "/inventory"): print("oracle oinstall"); return 0
        if f in (P["db_home"] + "/inventory/oneoffs", P["grid_home"] + "/inventory/oneoffs") and P.get("patches"): print("oracle oinstall"); return 0
        if shared(f): print("root root"); return 0
        if f == P["db_home"] + "/bin/oracle": print("oracle oinstall"); return 0
        if grid and f == P["grid_home"] + "/bin/oracle": print("oracle oinstall" if P.get("single_owner") else "grid oinstall"); return 0
        if f in files(): print("oracle oinstall"); return 0
        print(f"stat: cannot stat '{f}': No such file or directory", file=sys.stderr); return 1
    m = re.fullmatch(r"stat -c '%U %Y' (\S+)", cmd)
    if m:
        f = m.group(1)
        if f in files():
            import time
            t = P.get("pw_tmp_mtime", int(time.time())) if f.startswith("/tmp/orapw_for_standby_") else int(time.time())
            print(f"grid {t}"); return 0
        print(f"stat: cannot stat '{f}': No such file or directory", file=sys.stderr); return 1
    m = re.fullmatch(r"md5sum (\S+)", cmd)
    if m:
        f = m.group(1); fs = files()
        if f in fs: print(f"{md5(fs[f])}  {f}"); return 0
        print(f"md5sum: {f}: No such file or directory", file=sys.stderr); return 1
    m = re.fullmatch(r"ls -1A (\S+)/inventory/oneoffs", cmd)
    if m:
        key = "grid_patches" if (grid and m.group(1) == P["grid_home"]) else "patches"
        ids = [x.split(";")[0] for x in P.get(key, P.get("patches", []))]
        if not ids: print("ls: cannot access: No such file or directory", file=sys.stderr); return 2
        print("\n".join(ids)); return 0
    m = re.fullmatch(r"ls -1A (\S+)", cmd)
    if m:
        d = m.group(1).rstrip("/") + "/"; names = sorted({k[len(d):] for k in files() if k.startswith(d) and "/" not in k[len(d):]})
        if not names: print(f"ls: cannot access '{m.group(1)}': No such file or directory", file=sys.stderr); return 2
        print("\n".join(names)); return 0
    if cmd.startswith("grep -sE '^[[:space:]]*(export[[:space:]]+)?(ORACLE_HOME|ORACLE_SID|ORACLE_BASE|TNS_ADMIN)=' $HOME/.bash_profile $HOME/.bashrc"):
        lines = P.get("profile", [f"export ORACLE_HOME={P['db_home']}", f"export ORACLE_SID={P['sid']}"])
        for l in lines: print(f"/home/oracle/.bash_profile:{l}")
        return 0 if lines else 1
    m = re.fullmatch(r"env ORACLE_HOME=(\S+) (\S+)/OPatch/opatch lspatches", cmd)
    if m:
        for x in P.get("patches", ["35643107;Database Release Update : 19.21.0.0.231017 (35643107)"]): print(x)
        print("\nOPatch succeeded."); return 0
    m = re.fullmatch(r"env ORACLE_HOME=(\S+) (\S+)/bin/orabase", cmd)
    if m:
        print(P["oracle_base"] if m.group(1) == P["db_home"] else P["grid_base"]); return 0
    m = re.fullmatch(r"env ORACLE_HOME=(\S+) (\S+)/bin/orabasehome", cmd)
    if m:
        if int(str(P["version"]).split(".")[0]) < 18: print("bash: orabasehome: command not found", file=sys.stderr); return 127
        print(m.group(1)); return 0
    m = re.fullmatch(r"env ORACLE_HOME=(\S+)(?: TNS_ADMIN=\S+)? timeout 120 (\S+)/bin/lsnrctl status (\S+)", cmd)
    if m is None: m = re.fullmatch(r"env ORACLE_HOME=(\S+) (\S+)/bin/lsnrctl status (\S+)", cmd)
    if m:
        lh = P.get("listener_home", P["grid_home"] if grid else P["db_home"])
        if m.group(1) != lh or m.group(3) != P.get("listener_name", "LISTENER"):
            print("TNS-12541: TNS:no listener"); return 1
        print(f"Listening Endpoints Summary...\n  (DESCRIPTION=(ADDRESS=(PROTOCOL=tcp)(HOST={P['host']})(PORT={P.get('port', 1521)})))")
        print(f'Services Summary...\nService "{"other_svc" if P.get("lsnr_no_service") else P["service"]}" has 1 instance(s).\n  Instance "{P["sid"]}", status READY, has 1 handler(s) for this service...')
        if P.get("static"): print(f'  Instance "{P["sid"]}", status UNKNOWN, has 1 handler(s) for this service...')
        print("The command completed successfully"); return 0
    m = re.fullmatch(r"env ORACLE_HOME=(\S+) TNS_ADMIN=(\S+) (\S+)/bin/tnsping (\S+) 1", cmd)
    if m:
        if P.get("tns_stby"):
            h = P.get("tns_stby_host", P["stby_host"])
            print("Used TNSNAMES adapter to resolve the alias")
            print(f"Attempting to contact (DESCRIPTION = (ADDRESS = (PROTOCOL = TCP)(HOST = {h})(PORT = {P.get('port', 1521)})) (CONNECT_DATA = (SERVER = DEDICATED)(SERVICE_NAME = {P['stby_service']})(UR = A)))")
            if P.get("stby_lsnr_down"): print("TNS-12541: TNS:no listener"); return 1
            print("OK (10 msec)"); return 0
        print("TNS-03505: Failed to resolve name"); return 1
    m = re.fullmatch(r"cat (\S+)/ContentsXML/inventory.xml", cmd)
    if m:
        print('<HOME_LIST>'); print(f'<HOME NAME="OraDB19Home1" LOC="{P["db_home"]}" TYPE="O" IDX="2"/>')
        if grid: print(f'<HOME NAME="OraGI19Home1" LOC="{P["grid_home"]}" TYPE="O" IDX="1" CRS="true"/>')
        print('</HOME_LIST>'); return 0
    m = re.fullmatch(r"getent (?:hosts|ahostsv4) (\S+)", cmd)
    if m:
        if P.get("hosts_stby"): print(f"{P['stby_ip']}  {m.group(1)}"); return 0
        return 2
    m = re.fullmatch(r"env (?:-u \w+ )*ORACLE_HOME=(\S+) ORACLE_SID=(\S+) TNS_ADMIN=(\S+) timeout (\d+) (\S+)/bin/sqlplus -S /nolog", cmd)
    if m:
        env = dict(os.environ, DGT_REMOTE="1", ORACLE_SID=m.group(2), USER="oracle")
        r = subprocess.run(["/tmp/dgt/remotebin/sqlplus"], input=stdin_data, text=True, capture_output=True, env=env)
        sys.stdout.write(r.stdout); sys.stderr.write(r.stderr); return r.returncode
    log(BAD, cmd)
    print("mock primary: command not allowed", file=sys.stderr); return 126

def ssh():
    if a == ["-V"]:
        print("OpenSSH_7.4p1, OpenSSL 1.0.2k-fips  26 Jan 2017", file=sys.stderr); return 0
    if a and a[0] == "-G":
        dest = a[1]; print(f"user {dest.partition('@')[0]}"); print(f"hostname {dest.partition('@')[2]}"); print("port 22"); return 0
    o, rest = opts(a)
    # behave like OpenSSH 7.4 (Oracle Linux 7): option values it does not know stop ssh at once
    if o.get("StrictHostKeyChecking") == "accept-new":
        msg = "command-line line 0: unsupported option \"accept-new\"."
        if o.get("_E"): open(o["_E"], "a").write(msg + "\n")
        else: print(msg, file=sys.stderr)
        return 255
    ctl = o.get("ControlPath", "")
    if o.get("_O") == "check":
        return 0 if ctl and os.path.exists(ctl) else 255
    if o.get("_O") == "exit":
        if ctl and os.path.exists(ctl): os.remove(ctl)
        return 0
    if o.get("ControlMaster") == "yes":
        dest = rest[0]
        if not target_ok(dest):
            msg = f"ssh: connect to host {dest.split('@')[1]} port 22: Connection refused"
            if o.get("_E"): open(o["_E"], "a").write(msg + "\n")
            else: print(msg, file=sys.stderr)
            return 255
        # the script must check the host key itself: ssh may not ask, and only a known key is accepted
        k = known(o)
        if o.get("StrictHostKeyChecking") != "yes" or k != "ok":
            msg = ("@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@\n"
                   "@    WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!     @\n"
                   "Host key verification failed.") if k == "changed" else "Host key verification failed."
            if o.get("StrictHostKeyChecking") != "yes": log(BAD, "[master without StrictHostKeyChecking=yes]")
            if o.get("_E"): open(o["_E"], "a").write(msg + "\n")
            else: print(msg, file=sys.stderr)
            return 255
        for _ in range(3):
            sys.stderr.write(f"{dest}'s password: "); sys.stderr.flush()
            pw = sys.stdin.readline().rstrip("\n")
            sys.stderr.write("\n")
            if pw == pri["os_pw"]:
                open(ctl, "w").close(); log(CMDLOG, f"[master opened by {dest}]"); return 0
            sys.stderr.write("Permission denied, please try again.\n")
        msg = f"{dest}: Permission denied (publickey,gssapi-keyex,gssapi-with-mic,password)."
        if o.get("_E"): open(o["_E"], "a").write(msg + "\n")
        else: print(msg, file=sys.stderr)
        return 255
    dest, cmd = rest[0], " ".join(rest[1:])
    if not ctl:
        # a plain connection test (no master): it never logs in; with known_hosts /dev/null it stops at the host key
        msg = "Host key verification failed." if target_ok(dest) else f"ssh: connect to host {dest.split('@')[1]} port 22: Connection refused"
        if o.get("_E"): open(o["_E"], "a").write(msg + "\n")
        else: print(msg, file=sys.stderr)
        return 255
    if not ctl or not os.path.exists(ctl) or o.get("BatchMode") != "yes":
        print("Permission denied (publickey,password).", file=sys.stderr); return 255
    data = sys.stdin.read() if "sqlplus" in cmd else ""
    if pri.get("login_noise"): print(pri["login_noise"]); print("stty: 'standard input': Inappropriate ioctl for device", file=sys.stderr)
    mark = "echo __DG_PROBE_OUTPUT__; "
    if cmd.startswith(mark):
        print("__DG_PROBE_OUTPUT__"); cmd = cmd[len(mark):]
    elif "sqlplus" not in cmd:
        log(BAD, "[probe without marker] " + cmd)
    return remote(cmd, data)

def scp():
    o, rest = opts(a)
    ctl = o.get("ControlPath", "")
    if not ctl or not os.path.exists(ctl): print("Permission denied", file=sys.stderr); return 1
    src, dst = rest
    path = src.split(":", 1)[1]
    log(CMDLOG, f"[scp {path}]")
    fs = files()
    if path not in fs: print(f"scp: {path}: No such file or directory", file=sys.stderr); return 1
    with open(dst, "w") as f: f.write(fs[path])
    return 0

def hostkey():
    return "ssh-ed25519 " + pri.get("hostkey", "AAAAC3NzaC1lZDI1NTE5AAAAIMockPrimaryHostKey0001")

def keyscan():
    # ssh-keyscan [-T n] [-t types] host
    host = a[-1]
    log(CMDLOG, f"[ssh-keyscan {host}]")
    if host != pri["ip"] or pri.get("keyscan_fail"): return 1
    print(f"# {host}:22 SSH-2.0-OpenSSH_7.4", file=sys.stderr)
    print(f"{host} {hostkey()}")
    return 0

def keygen():
    # ssh-keygen -F host -f file  |  ssh-keygen -lf file  |  ssh-keygen -R host [-f file]
    if "-F" in a:
        host = a[a.index("-F") + 1]; f = a[a.index("-f") + 1]
        try: lines = open(f).read().splitlines()
        except Exception: return 1
        hit = [l for l in lines if l.split(" ")[0] == host]   # (plain names only; hashed lines are not mocked)
        [print(l) for l in hit]
        return 0 if hit else 1
    if "-lf" in a:
        f = a[a.index("-lf") + 1]
        try: lines = [l for l in open(f).read().splitlines() if l and not l.startswith("#")]
        except Exception: return 1
        for l in lines:
            h, t, k = l.split(" ")[:3]
            if "md5" in a: print(f"256 MD5:{':'.join(md5(k)[i:i+2] for i in range(0, 32, 2))} {h} ({t.replace('ssh-', '').upper()})")
            else: print(f"256 SHA256:{md5(k)[:43]} {h} ({t.replace('ssh-', '').upper()})")
        return 0 if lines else 1
    return 1

def known(o):
    """the primary's current host key is in one of the known_hosts files ssh was given"""
    # like ssh: only lines of the same key type count; another key of that type means "changed"
    t, k = hostkey().split(" ")
    res = "unknown"
    for f in o.get("UserKnownHostsFile", "").split():
        try:
            for l in open(f).read().splitlines():
                x = l.split(" ")
                if len(x) >= 3 and x[0] == pri["ip"] and x[1] == t:
                    if x[2] == k: return "ok"
                    res = "changed"
        except Exception: pass
    return res

sys.exit({"ssh": ssh, "scp": scp, "ssh-keyscan": keyscan, "ssh-keygen": keygen}[prog]())
