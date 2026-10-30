#!/usr/bin/python3
# Mock Oracle tools for testing dg_standby_setup.sh. One file, dispatched by program name.
import sys, os, re, json, fcntl

STATE_DIR = "/tmp/dgt/state"
PRI = os.path.join(STATE_DIR, "primary.json")
STB = os.path.join(STATE_DIR, "standby.json")
PRI_LOG = os.path.join(STATE_DIR, "primary_sql.log")
CALLS = os.path.join(STATE_DIR, "calls.log")

def load(p):
    with open(p) as f: return json.load(f)
def save(p, d):
    tmp = p + ".tmp"
    with open(tmp, "w") as f: json.dump(d, f, indent=1)
    os.chmod(tmp, 0o666); os.replace(tmp, p)
def logcall(line):
    with open(CALLS, "a") as f: f.write(line + "\n")
    try: os.chmod(CALLS, 0o666)
    except Exception: pass

prog = os.path.basename(sys.argv[0])
args = sys.argv[1:]
logcall(f"{prog} user={os.environ.get('USER')} sid={os.environ.get('ORACLE_SID')} args={args}")
cfg = load(os.path.join(STATE_DIR, "env.json"))

def lsnr_static_ok():
    """returns 'ok', 'wronghome' or 'missing' for the standby static entry"""
    p = cfg["listener_ora"]
    if not os.path.exists(p): return "missing"
    flat = re.sub(r"\s+", "", open(p).read()).upper()
    res = "missing"
    for seg in flat.split("(SID_DESC=")[1:]:
        if f"(SID_NAME={cfg['sid'].upper()})" in seg:
            if f"(ORACLE_HOME={cfg['db_home'].upper()})" in seg: return "ok"
            res = "wronghome"
    return res

def pwfile_ok():
    p = os.path.join(cfg["db_home"], "dbs", "orapw" + cfg["sid"])
    return os.path.exists(p) and open(p).read().startswith("ORAPW-PRIMARY")

# ---------------------------------------------------------------- sqlplus
def primary_sql(q, pri):
    l = q.lower()
    with open(PRI_LOG, "a") as f: f.write(q + "\n")
    try: os.chmod(PRI_LOG, 0o666)
    except Exception: pass
    major = int(str(pri["version"]).split(".")[0])
    if "d.name||'|'||d.db_unique_name||'|'||d.database_role||'|'||d.cdb||'|'||i.version" in l:
        base = pri["version"] if major < 18 else f"{major}.0.0.0.0"
        return f"{pri['name']}|{pri['unique']}|{pri['role']}|{pri['cdb']}|{base}|{pri.get('domain') or '-'}|{'TRUE' if pri.get('rac') else 'FALSE'}|READ WRITE"
    if l.strip() == "select version_full from v$instance;":
        if major < 18: return "ORA-00904: \"VERSION_FULL\": invalid identifier"
        return pri["version"]
    if "group by loc" in l:
        return "\n".join(pri["locs"])
    if "max(blocksize)" in l:
        return f"{pri.get('blocksize', 512)}|{pri.get('srl_small', 0)}"
    if "'d|'||file#||'|'||name from v$datafile" in l:
        rows = []; n = 0
        for loc in pri["locs"]:
            d = loc.split(":")[0]; n += 1
            rows.append(f"D|{n}|{d}/PRODDB/DATAFILE/system.{256+n}.1" if d.startswith("+") else f"D|{n}|{d}/system{n:02d}.dbf")
        d0 = pri["locs"][0].split(":")[0]
        rows.append(f"T|1|{d0}/PRODDB/TEMPFILE/temp.300.1" if d0.startswith("+") else f"T|1|{d0}/temp01.dbf")
        return "\n".join(rows)
    if "select name from v$datafile union all select name from v$tempfile union all select member from v$logfile" in l:
        rows = []
        for loc in pri["locs"]:
            d = loc.split(":")[0]
            if d.startswith("/"): rows += [f"{d}/system01.dbf", f"{d}/temp01.dbf", f"{d}/redo01.log"]
        return "\n".join(rows + pri.get("controlfiles", []))
    if "name in ('wallet_root','tde_configuration')" in l:
        return f"wallet_root|{pri.get('wallet_root', '-')}\ntde_configuration|-"
    if "name in ('db_create_file_dest','db_recovery_file_dest'" in l:
        p = pri["params"]
        rows = {"db_create_file_dest": p.get("db_create_file_dest", "+DATA"), "db_recovery_file_dest": p.get("db_recovery_file_dest", "-"),
                "db_recovery_file_dest_size": p.get("db_recovery_file_dest_size", "-"),
                "log_archive_dest": p.get("log_archive_dest", "-"), "audit_file_dest": pri.get("audit_dest", "-"), "diagnostic_dest": pri.get("diag_dest", "-")}
        for k, v in p.items():
            if re.fullmatch(r"log_archive_dest_\d+", k) and v and "location" in str(v).lower(): rows[k] = v
        return "\n".join(f"{k}|{v or '-'}" for k, v in rows.items())
    if "from v$encryption_wallet" in l:
        return "\n".join(pri.get("tde", ["FILE|-|NOT_AVAILABLE"]))
    if "select name from v$controlfile;" in l:
        return "\n".join(pri.get("controlfiles", ["+DATA/PRODDB/CONTROLFILE/current.261.1", "+FRA/PRODDB/CONTROLFILE/current.256.1"]))
    if "from v$log group by thread# order by thread#" in l:
        return "\n".join(f"{t}|{pri['orl']}|{pri['orl_bytes']}" for t in range(1, pri.get("threads", 1) + 1))
    if "from v$standby_log where bytes>=(select max(bytes) from v$log) group by thread#" in l:
        if pri["srl"] and pri["srl_bytes"] >= pri["orl_bytes"]:
            return "\n".join(f"{t}|{pri['srl']}" for t in range(1, pri.get("threads", 1) + 1))
        return ""
    if "name in ('db_create_file_dest','db_create_online_log_dest_1')" in l:
        omf = pri["params"].get("db_create_file_dest", "+DATA") or "-"
        return f"{omf}|{pri['orl'] * pri.get('threads', 1) + pri['srl']}|{pri.get('redo_dir', '+DATA/PRODDB/ONLINELOG')}"
    if l.strip() == "select 1 from dual;": return "1"
    if "select db_unique_name||' '||database_role from v$database" in l: return f"{pri['unique']} {pri['role']}"
    if "from v$tempfile" in l: return f"{pri['data_mb']}|{pri['temp_mb']}"
    if "name in ('sga_target'" in l:
        p = pri.get("mem", {"sga_target": "1073741824", "sga_max_size": "1073741824", "memory_target": "0", "memory_max_target": "0", "pga_aggregate_target": "536870912", "use_large_pages": "TRUE", "db_recovery_file_dest_size": str(50 * 1024**3)})
        return "\n".join(f"{k}|{v}" for k, v in p.items())
    if "name like 'log_archive_dest_%'" in l and "db_create" not in l:
        rows = [f"{k}|{v}" for k, v in pri["params"].items() if re.fullmatch(r"log_archive_dest_\d+", k)]
        return "\n".join(rows) if rows else "log_archive_dest_1|-"
    if "d.db_unique_name||'|'||d.database_role" in l:
        base = f"{pri['unique']}|{pri['role']}|{pri['name']}|{pri['host']}"
        return base + (f"|{pri['cdb']}" if "d.cdb" in l else "")
    if "select count(*) from v$datafile;" in l:
        if pri.get("df_count_fail"): return "ORA-03113: end-of-file on communication channel"
        return str(pri.get("datafiles", 10))
    if "name like 'db_create_online_log_dest%'" in l:
        rows = [f"{k}|{v}" for k, v in pri["params"].items() if v and v != "-" and (k.startswith("db_create_online_log_dest") or k.startswith("log_archive_dest") or k in ("log_archive_duplex_dest", "remote_listener", "local_listener", "fal_client", "db_file_name_convert", "log_file_name_convert", "dg_broker_start", "instance_name", "service_names"))]
        return "\n".join(rows)
    if "version_full" in l: return pri["version"]
    if "from v$version" in l: return pri.get("banner", "Oracle Database 21c Enterprise Edition Release 21.0.0.0.0 - Production")
    if "log_mode||'|'||force_logging" in l: return f"{pri['log_mode']}|{pri['force_logging']}"
    m = re.search(r"from v\$archive_dest where dest_id=(\d+)", l)
    if m and m.group(1) != "2":
        en = pri["params"].get(f"log_archive_dest_state_{m.group(1)}", "").upper() == "ENABLE"
        return "VALID|-"
    if "v$parameter where name='spfile'" in l: return pri.get("spfile", "+DATA/PRODDB/PARAMETERFILE/spfile.270.1")
    m = re.search(r"v\$parameter where name='([a-z_0-9]+)'", l)
    if m:
        v = pri["params"].get(m.group(1), None)
        if "upper(value)" in l: return (v or "").upper()
        return v if v else "-"
    if "v$pwfile_users" in l: return "1" if pri["sys_in_pwfile"] else "0"
    m = re.search(r"from v\$spparameter where name='([a-z_0-9]+)'", l)
    if m: return pri.get("spparams", {}).get(m.group(1), pri["params"].get(m.group(1), "-")) or "-"
    if "standby_dest='no'" in l: return str(pri["seq"])
    if "v$passwordfile_info" in l:
        if str(pri["version"]).startswith("12.1") and "format" in l: return "ORA-00904: \"FORMAT\": invalid identifier"
        return f"{pri['pwfile']}|12.2" if "format" in l else pri['pwfile']
    if "select database_role from v$database" in l: return pri["role"]
    if "sum(bytes) from v$datafile" in l: return f"{pri['data_mb']}|{pri['temp_mb']}|{pri['role']}"
    if "from v$archive_dest where dest_id=2" in l:
        en = pri["params"].get("log_archive_dest_state_2", "").upper() == "ENABLE"
        if en and pri.get("dest2_error"):
            e = pri['dest2_error'].replace("ORA-", "ORA_") if "replace(error" in l else pri['dest2_error']
            return f"ERROR|{e}"
        return "VALID|-"
    if "max(sequence#)" in l: return str(pri["seq"])
    return "MOCK-UNKNOWN-PRIMARY ORA-00900: invalid SQL statement"

def local_sql(q, st, sid):
    inst = st["instances"].get(sid, {"state": "idle"})
    s = inst["state"]
    l = q.lower().strip()
    if l.startswith("startup nomount"):
        if s != "idle": return "ORA-01081: cannot start already-running ORACLE - shut it down first"
        inst["state"] = "started"; st["instances"][sid] = inst
        return "ORACLE instance started.\nTotal System Global Area 1073741824 bytes"
    if l.startswith("startup mount"):
        if s != "idle": return "ORA-01081: cannot start already-running ORACLE - shut it down first"
        if not os.path.exists(os.path.join(cfg["db_home"], "dbs", "spfile" + sid + ".ora")): return "ORA-01078: failure in processing system parameters"
        inst["state"] = "mounted"; st["instances"][sid] = inst
        return "ORACLE instance started.\nDatabase mounted."
    if l.startswith("shutdown abort"):
        if s == "idle": return "ORACLE instance shut down."
        inst["state"] = "idle"; inst["mrp"] = 0; st["instances"][sid] = inst
        return "ORACLE instance shut down."
    if l.startswith("shutdown immediate"):
        if s == "idle": return "ORA-01034: ORACLE not available"
        inst["state"] = "idle"; inst["mrp"] = 0; st["instances"][sid] = inst
        return "ORACLE instance shut down."
    if s == "idle":
        return "Connected to an idle instance.\nORA-01034: ORACLE not available"
    if "select instance_name||' '||status from v$instance" in l:
        return f"{sid} " + {"started": "STARTED", "mounted": "MOUNTED"}[s]
    if "select status from v$instance" in l:
        return {"started": "STARTED", "mounted": "MOUNTED"}[s]
    if "select database_role from v$database" in l:
        return "ORA-01507: database not mounted" if s == "started" else "PHYSICAL STANDBY"
    if "i.instance_name||'|'||i.status" in l:
        return f"{sid}|MOUNTED|PHYSICAL STANDBY" if s == "mounted" else "ORA-01507: database not mounted"
    if "v$managed_standby where process like 'mrp%'" in l: return str(inst.get("mrp", 0))
    if "recovery_mode" in l and "v$archive_dest_status" in l:
        return inst.get("recovery_mode", "MANAGED REAL TIME APPLY")
    if "v$parameter where name='spfile'" in l:
        return inst.get("spfile_param", "-")
    if "v$standby_log where status='active'" in l:
        return str(inst.get("srl_active", 1))
    if "from v$dataguard_status" in l:
        return str(inst.get("dg_errors", 0))
    if "v$rman_configuration" in l:
        return st.get("rman_adp", "-")
    if "select group# from v$standby_log order by group#" in l:
        pri = load(PRI); n = inst.get("srl", 0) * pri.get("threads", 1)
        base = pri['orl'] * pri.get('threads', 1)
        return "\n".join(str(base + i + 1) for i in range(n))
    if "v$managed_standby where process like 'rfs%'" in l:
        pri = load(PRI)
        en = any(k.startswith("log_archive_dest_state_") and str(v).upper() == "ENABLE" for k, v in pri["params"].items())
        return "1" if en and inst.get("mrp") else "0"
    if "from v$log group by thread# order by thread#" in l:
        pri = load(PRI); return "\n".join(f"{t}|{pri['orl']}|{pri['orl_bytes']}" for t in range(1, pri.get("threads", 1) + 1))
    if "from v$standby_log where bytes>=(select max(bytes) from v$log) group by thread#" in l:
        pri = load(PRI); n = inst.get("srl", 0)
        return "\n".join(f"{t}|{n}" for t in range(1, pri.get("threads", 1) + 1)) if n else ""
    if "max(blocksize)" in l:
        return "512|0"
    if "name in ('db_create_file_dest','db_create_online_log_dest_1')" in l:
        pri = load(PRI); omf = pri["params"].get("db_create_file_dest", "+DATA") or "-"
        return f"{omf}|{pri['orl'] * pri.get('threads', 1) + inst.get('srl', 0)}|{pri.get('redo_dir', '+DATA/PRODDB/ONLINELOG')}"
    if l.strip().startswith("select nvl(max(sequence#),0) from v$archived_log where applied"):
        return str(load(PRI)["seq"])
    if "standby_file_management=manual" in l:
        inst["sfm"] = "MANUAL"; st["instances"][sid] = inst
        if "add standby logfile" not in l: return "System altered."
    if "standby_file_management=auto" in l and "add standby logfile" not in l:
        inst["sfm"] = "AUTO"; st["instances"][sid] = inst; return "System altered."
    if "select group#||'|'||status from v$standby_log" in l:
        pri = load(PRI); n = inst.get("srl", 0) * pri.get("threads", 1)
        base = pri['orl'] * pri.get('threads', 1)
        return "\n".join(f"{base + i + 1}|UNASSIGNED" for i in range(n))
    m = re.search(r"drop standby logfile group (\d+)", l)
    if m:
        if inst.get("sfm", "AUTO") != "MANUAL": return "ORA-01275: Operation DROP LOGFILE is not allowed if standby file management is automatic."
        inst["srl"] = max(0, inst.get("srl", 0) - 1); inst.setdefault("dropped", []).append(int(m.group(1))); st["instances"][sid] = inst
        return "Database altered."
    if "add standby logfile" in l:
        if inst.get("mrp"): return "ORA-01156: recovery or flashback in progress may need access to files"
        pri = load(PRI); omf = pri["params"].get("db_create_file_dest", "+DATA")
        for stmt in [x for x in l.split("\n") if "add standby logfile" in x]:
            if (not omf or omf == "-") and "(" not in stmt: return "ORA-02236: invalid file name"
        threads = pri.get("threads", 1)
        inst["srl"] = inst.get("srl", 0) + l.count("add standby logfile") // threads; st["instances"][sid] = inst
        return ""
    if "recover managed standby database cancel" in l:
        inst["mrp"] = 0; st["instances"][sid] = inst; return ""
    if "recover managed standby database disconnect" in l:
        inst["mrp"] = 1; st["instances"][sid] = inst; return ""
    if "v$dataguard_stats" in l: return "+00 00:00:00|+00 00:00:01"
    if "select count(*) from v$datafile_header where error is not null;" in l:
        return str(inst.get('df_errors', 0))
    if "(select count(*) from v$datafile)||'|'||" in l:
        return f"{inst.get('datafiles', 0)}|{inst.get('df_errors', 0)}"
    if "instance_name||'|'||host_name||'|'||status" in l:
        import socket
        host = "otherhost" if st.get("stby_tns_wrong") else socket.gethostname()
        return f"{sid}|{host}|" + {"started": "STARTED", "mounted": "MOUNTED"}[s]
    if "count(*) from v$archive_gap" in l: return "0"
    if "max(sequence#)" in l: return str(load(PRI)["seq"])
    return "MOCK-UNKNOWN-LOCAL ORA-00900: invalid SQL statement"

def sqlplus():
    if "-V" in args:
        v = cfg.get("local_version", "19.21.0.0.0"); major = v.split(".")[0]
        rel = v if major == "12" else f"{major}.0.0.0.0"
        print(f"\nSQL*Plus: Release {rel} - Production\nVersion {v}\n"); return 0
    data = sys.stdin.read()
    lines = data.split("\n")
    while lines and lines[0].strip().lower().startswith("set "):   # e.g. "set define off" before connect
        lines = lines[1:]
    conn = lines[0].strip()
    marks = [x.strip()[7:] for x in lines[1:] if x.strip().lower().startswith("prompt ")]
    stmts = [x for x in lines[1:] if x.strip() and not x.lower().startswith(("set ", "whenever", "exit", "prompt "))]
    banner = load(PRI).get("glogin_noise") if os.environ.get("DGT_REMOTE") == "1" else None
    if banner: print(banner)
    # like sqlplus: the connect line runs BEFORE the marker prompt; a failed connect prints its error first,
    # then every later statement fails with SP2-0640
    def connfail(e):
        print(e)
        for mk in marks: print(mk)
        print("SP2-0640: Not connected"); return 0
    q = "\n".join(stmts)
    se = sql_shape_error(q)
    out = []
    if conn == "connect / as sysasm":
        st = load(STB)
        ql = q.lower()
        if not st.get("asm"): out.append("Connected to an idle instance.\nORA-01034: ORACLE not available")
        elif ql.startswith("create diskgroup"):
            ok = True
            for stmt in [x for x in ql.split("\n") if x.strip()]:
                m = re.match(r"create diskgroup (\w+) external redundancy disk ('[^']+'(,'[^']+')*)( attribute 'compatible.asm'='[0-9.]+', 'compatible.rdbms'='[0-9.]+')?;$", stmt)
                if not m or any(not d.strip("'").startswith(("/dev/oracleasm/disks/", "/dev/oraasm/")) for d in m.group(2).split(",")):
                    out.append(f"ORA-15018: diskgroup cannot be created\nORA-15031: disk specification matches no disks ({stmt})"); ok = False; break
                st["dgs"] = sorted(set(st.get("dgs", []) + [m.group(1).upper()])); st.setdefault("dg_sql", []).append(stmt)
            if ok: save(STB, st); out.append("")
        elif "from v$asm_alias a, v$asm_diskgroup g" in ql and "count(*)" in ql:
            out.append("1" if st.get("asm_leftovers") else "0")
        elif "sum(f.bytes)" in ql:
            out.append(str(st.get("asm_leftover_mb", 0)))
        elif "from v$asm_attribute" in ql:
            out.append("19.0.0.0.0|19.0.0.0.0")
        elif "select sector_size from v$asm_diskgroup" in ql:
            out.append(str(st.get("sector_size", 512)))
        elif "select total_mb from v$asm_diskgroup" in ql:
            out.append(str(cfg.get("fra_total", 400000)))
        elif "v$asm_diskgroup" in ql:
            if "free_mb from" in ql: out.append(str(cfg["data_free"]))
            else:
                out.append("\n".join(f"{d}|MOUNTED|{cfg['data_free']}|900000" for d in st.get("dgs", ["DATA"])))
        else: out.append("MOCK-UNKNOWN-ASM ORA-00900")
    elif conn == "connect / as sysdba" and os.environ.get("DGT_REMOTE") == "1":
        pri = load(PRI)
        if not pri.get("os_auth", True): return connfail("ERROR:\nORA-01031: insufficient privileges")
        out.append(primary_sql(q, pri))
    elif conn == "connect / as sysdba":
        with open(STB + ".lock", "w") as lk:
            fcntl.flock(lk, fcntl.LOCK_EX)
            st = load(STB)
            out.append(local_sql(q, st, os.environ.get("ORACLE_SID", "")))
            save(STB, st)
    else:
        m = re.match(r'connect sys/"(.*)"@(\S+) as sysdba', conn)
        if not m:
            print("SP2-0306: Invalid option."); return 1
        pw, target = m.group(1), m.group(2)
        pri = load(PRI)
        if pw != cfg["pw"]: return connfail("ERROR:\nORA-01017: invalid username/password; logon denied")
        remote = os.environ.get("DGT_REMOTE") == "1"
        if remote and target == cfg["stby_tns"] and not pri.get("tns_stby"):
            return connfail("ERROR:\nORA-12154: TNS:could not resolve the connect identifier specified")
        if target.startswith("//") or (target == cfg["prim_tns"] and not remote):
            out.append(primary_sql(q, pri))
        elif target == cfg["stby_tns"]:
            st = load(STB)
            s = st["instances"].get(cfg["sid"], {"state": "idle"})["state"]
            lst = lsnr_static_ok()
            if lst == "missing": return connfail("ERROR:\nORA-12514: TNS:listener does not currently know of service")
            if lst == "wronghome" or not pwfile_ok(): return connfail("ERROR:\nORA-01017: invalid username/password; logon denied")
            out.append(local_sql(q, st, cfg["sid"]) if s != "idle" else "ORA-01034: ORACLE not available")
        else:
            return connfail("ERROR:\nORA-12154: TNS:could not resolve the connect identifier specified")
    for mk in marks: print(mk)
    print(se if se else "\n".join(out))
    return 0

def sql_shape_error(q):
    # a query Oracle refuses: an aggregate next to a scalar subquery without GROUP BY (ORA-00937)
    for l in q.lower().split("\n"):
        l = l.strip()
        if re.match(r"select (max|min|count|sum|avg)\(", l) and "(select" in l and " group by " not in l and not l.endswith("from dual;"):
            head = l.split(" from ")[0]
            if "(select" in head: return "ORA-00937: not a single-group group function"
    return ""

# ---------------------------------------------------------------- others
def srvctl():
    st = load(STB)
    reg = st.get("srvctl")
    a = args
    if a[:2] == ["config", "database"]:
        if not reg: print(f"PRCD-1120 : The resource for database {a[-1]} could not be found."); return 1
        print(f"Database unique name: {a[-1]}\nDatabase name: proddb\nOracle home: {reg['home']}\nSpfile: {reg['spfile']}\n"
              f"Password file: {reg['pwfile']}\nStart options: mount\nDatabase role: {reg['role']}\nDatabase instance: {reg['instance']}")
        return 0
    if a[:2] == ["add", "database"]:
        if reg: print("PRCS-1007 : Server pool already exists"); return 1
        d = dict(zip(a[2::2], a[3::2]))
        st["srvctl"] = {"home": d["-oraclehome"], "spfile": d["-spfile"], "pwfile": d["-pwfile"], "role": d["-role"], "instance": d["-instance"], "running": 0}
        save(STB, st); return 0
    if a[:2] == ["status", "database"]:
        if not reg: print("PRCD-1120"); return 1
        print("Database is running." if reg["running"] else "Database is not running."); return 0
    if a[:2] == ["start", "database"]:
        inst = st["instances"].get(reg["instance"], {"state": "idle"})
        if inst["state"] != "idle": print("PRCC-1014 : already running"); return 1
        inst["state"] = "mounted"; inst.setdefault("srl", st.get("srl_after_dup", 0)); inst.setdefault("datafiles", load(PRI).get("datafiles", 10))
        st["instances"][reg["instance"]] = inst
        reg["running"] = 1; save(STB, st); return 0
    if a[:2] == ["stop", "database"]:
        if reg:
            reg["running"] = 0
            old = st["instances"].get(reg["instance"], {})
            st["instances"][reg["instance"]] = {"state": "idle", "srl": old.get("srl", 0), "datafiles": old.get("datafiles", 10)}
            save(STB, st)
        return 0
    if a[:2] == ["modify", "listener"]:
        st["lsnr_port"] = int(a[a.index("-endpoints") + 1].split(":")[1]); save(STB, st); return 0
    if a[:2] in (["stop", "listener"], ["start", "listener"], ["add", "listener"]): return 0
    if a[:2] == ["remove", "database"]:
        st["srvctl"] = None; save(STB, st); return 0
    print("mock srvctl: unknown"); return 1

def rman():
    if any(x == "checksyntax" for x in args):
        cf = [x for x in args if x.startswith("cmdfile=")]
        txt = open(cf[0][8:]).read() if cf else ""
        bad = [ln for ln in txt.split("\n") if ln.strip().startswith("set ") and not ln.strip().startswith("set newname") and "=" not in ln]
        if bad or "duplicate target database" not in txt: print("RMAN-00558: error encountered while parsing input commands"); return 1
        print("The cmdfile has no syntax errors"); return 0
    data = sys.stdin.read()
    st = load(STB)
    if "configure archivelog deletion policy" in data.lower():
        st["rman_adp"] = "TO APPLIED ON STANDBY"; save(STB, st)
        print("new RMAN configuration parameters:\nCONFIGURE ARCHIVELOG DELETION POLICY TO APPLIED ON STANDBY;\nnew RMAN configuration parameters are successfully stored"); return 0
    if 'connect target sys/"' not in data or 'connect auxiliary sys/"' not in data:
        print("RMAN-00571: no connect"); return 1
    if "duplicate target database" not in data and "run {" not in data:
        # login test only
        pw = re.search(r'connect target sys/"([^"]*)"@(\S+)', data)
        if not pw or pw.group(1) != cfg["pw"]: print("RMAN-00571: ===\nORA-01017: invalid username/password; logon denied"); return 1
        inst = st["instances"].get(cfg["sid"], {"state": "idle"})
        if inst["state"] == "idle": print("RMAN-04006: error from auxiliary database: ORA-12528: TNS:listener: all appropriate instances are blocking new connections"); return 1
        print("connected to target database: PRODDB (DBID=1)\nconnected to auxiliary database: PRODDB (not mounted)"); return 0
    if cfg.get("rman_fail"):
        print("Starting Duplicate Db at 24-OCT-26\nRMAN-03002: failure of Duplicate Db command at 10/24/2026\nRMAN-05501: aborting duplication of target database\nORA-19504: failed to create file \"+DATA\"")
        return 1
    if "duplicate target database for standby from active database" not in data:
        print("RMAN-00558: error"); return 1
    if cfg.get("rman_sleep"):
        import time
        print("Starting Duplicate Db at 24-OCT-26", flush=True); time.sleep(int(cfg["rman_sleep"]))
    inst = st["instances"].get(cfg["sid"], {"state": "idle"})
    if inst["state"] != "started":
        print("RMAN-03002: failure of Duplicate Db command\nRMAN-05501: auxiliary not started"); return 1
    print("Starting Duplicate Db at 24-OCT-26\nchannel a1: restored backup piece 1\nFinished Duplicate Db at 24-OCT-26")
    inst["state"] = "mounted"; inst["srl"] = st.get("srl_after_dup", 0); inst["datafiles"] = load(PRI).get("datafiles", 10)
    st["instances"][cfg["sid"]] = inst
    spf = os.path.join(cfg["db_home"], "dbs", "spfile" + cfg["sid"] + ".ora")
    open(spf, "w").write("mock spfile\n")
    st["duplicated"] = st.get("duplicated", 0) + 1
    save(STB, st); return 0

def lsnrctl():
    st = load(STB)
    dbhome = os.environ.get("ORACLE_HOME") == cfg["db_home"]
    up = st.get("lsnr_up") if dbhome else (st.get("asm") and not st.get("lsnr_down"))
    if args[:1] == ["start"]:
        if not dbhome: print("TNS-01106: Listener using listener name LISTENER has already been started"); return 1
        lf = os.path.join(cfg["db_home"], "network", "admin", "listener.ora")
        if not os.path.exists(lf) or "DESCRIPTION" not in open(lf).read().upper(): print("TNS-12557: protocol adapter not loadable"); return 1
        st["lsnr_up"] = 1; save(STB, st); print("The command completed successfully"); return 0
    if args[:1] == ["reload"]:
        if not up: print("TNS-12541: TNS:no listener"); return 1
        print("The command completed successfully"); return 0
    if args[:1] == ["status"]:
        if not up: print("TNS-12541: TNS:no listener"); return 1
        port = st.get('lsnr_port', 1521)
        if dbhome:
            m = re.search(r"\(PORT\s*=\s*(\d+)\)", open(os.path.join(cfg["db_home"], "network", "admin", "listener.ora")).read())
            port = int(m.group(1)) if m else 1521
        print(f"Listening Endpoints Summary...\n  (DESCRIPTION=(ADDRESS=(PROTOCOL=tcp)(HOST=stby01)(PORT={port})))")
        print("Services Summary...")
        if lsnr_static_ok() in ("ok", "wronghome"):
            print(f'Service "{cfg["stby_svc"]}" has 1 instance(s).\n  Instance "{cfg["sid"]}", status UNKNOWN, has 1 handler(s) for this service...')
        print("The command completed successfully"); return 0
    return 1

def tnsping():
    alias = args[0]
    p = os.path.join(os.environ["TNS_ADMIN"], "tnsnames.ora")
    if os.path.exists(p):
        txt = open(p).read()
        m = re.search(r"(?im)^\s*" + re.escape(alias) + r"\s*=\s*(\(.*?)(?=^\S|\Z)", txt, re.S | re.M)
        if m:
            desc = re.sub(r"\s+", " ", m.group(1)).strip()
            down = (os.environ.get("DGT_REMOTE") == "1" and load(PRI).get("stby_lsnr_down")) or (os.environ.get("DGT_REMOTE") != "1" and cfg.get("lsnr_down"))
            if down and alias.lower() == cfg["stby_tns"].lower():
                print(f"Used TNSNAMES adapter to resolve the alias\nAttempting to contact {desc}\nTNS-12541: TNS:no listener"); return 1
            print(f"Used TNSNAMES adapter to resolve the alias\nAttempting to contact {desc}\nOK (10 msec)"); return 0
    print("TNS-03505: Failed to resolve name"); return 1

def crsctl():
    st = load(STB)
    if args[:2] == ["check", "has"]:
        if st.get("has") or st.get("crs_weird"): print("CRS-4638: Oracle High Availability Services is online"); return 0
        print("CRS-4639: Could not contact Oracle High Availability Services"); return 1
    if args[:2] == ["start", "has"]:
        st["has"] = 1; save(STB, st); print("CRS-4123: Oracle High Availability Services has been started."); return 0
    if args[:2] == ["start", "res"]:
        st.pop("asm_down", None); save(STB, st); print(f"CRS-2676: Start of '{args[2]}' succeeded"); return 0
    if args[:2] == ["stat", "res"]:
        name = args[2]
        if not st.get("has") or st.get("crs_weird"): print("CRS-4535: Cannot communicate with Cluster Ready Services"); return 1
        m = re.fullmatch(r"ora\.(\w+)\.dg", name)
        if m: exists = st.get("asm") and m.group(1) in st.get("dgs", ["DATA"])
        else: exists = {"ora.asm": st.get("asm"), "ora.LISTENER.lsnr": st.get("asm")}.get(name)
        if not exists: print(f"CRS-2613: Could not find resource '{name}'."); return 1
        state = "OFFLINE" if (name == "ora.asm" and st.get("asm_down")) else "ONLINE"
        print(f"NAME={name}\nTYPE=mock\nTARGET=ONLINE\nSTATE={state}"); return 0
    return 1

def orapwd():
    f = [x for x in args if x.startswith("file=")][0][5:]
    if os.path.exists(f) and open(f).read().startswith("ORAPW"):
        print(f"Password file Description : format={cfg.get('pw_format', '12.2')}"); return 0
    print("OPW-00005: file not valid"); return 1

def oraversion():
    print(cfg["local_version"]); return 0

def orabasehome():
    st = load(STB)
    base = os.environ.get("ORACLE_BASE", "/u01/app/oracle")
    print(f"{base}/homes/OraDB21Home1" if st.get("rooh") else cfg["db_home"]); return 0

def roohctl():
    if args[:1] == ["-disable"]:
        st = load(STB); st["rooh"] = 0; save(STB, st); print("Disabling Read-Only Oracle home.\nUpdate orabasetab file to disable Read-Only Oracle home.\nRead-Only Oracle home disabled successfully."); return 0
    return 1

def opatch():
    if args[:1] == ["lspatches"]:
        pri = load(PRI); e = load(os.path.join(STATE_DIR, "env.json"))
        for x in e.get("local_patches", pri.get("patches", ["35643107;Database Release Update : 19.21.0.0.231017 (35643107)"])): print(x)
        print("\nOPatch succeeded."); return 0
    return 1

def asmcmd():
    # only "rm -rf +DG/NAME" is used: the leftovers of an unfinished copy go away
    if args[:2] == ["rm", "-rf"] and len(args) == 3 and args[2].startswith("+"):
        st = load(os.path.join(STATE_DIR, "standby.json")); st["asm_leftovers"] = 0; st.setdefault("asm_removed", []).append(args[2])
        save(os.path.join(STATE_DIR, "standby.json"), st); return 0
    print("ASMCMD-8001: unknown command"); return 1

def setasmgidwrap():
    # o=<db home>/bin/oracle: the group of the oracle program becomes the group of the ASM disks
    if len(args) == 1 and args[0].startswith("o="):
        os.system(f"chgrp asmadmin {args[0][2:]}"); return 0
    return 1

sys.exit({"opatch": opatch, "sqlplus": sqlplus, "srvctl": srvctl, "rman": rman, "lsnrctl": lsnrctl, "tnsping": tnsping,
          "crsctl": crsctl, "orapwd": orapwd, "oraversion": oraversion, "orabasehome": orabasehome, "roohctl": roohctl, "asmcmd": asmcmd, "setasmgidwrap": setasmgidwrap}[prog]() or 0)
