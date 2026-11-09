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
    if l.strip().startswith("alter ") and os.environ.get("DGT_REMOTE") == "1":
        # a change sent by the script itself (PRIMARY_RUN=yes): applied like the DBA would (as the driver does)
        p = pri["params"]
        if "alter database force logging" in l: pri["force_logging"] = "YES"
        if "add standby logfile" in l: pri["srl"] = pri["orl"] + 1; pri["srl_bytes"] = pri["orl_bytes"]
        m = re.search(r"log_archive_config='(dg_config=\([^)]*\))'", q, re.I)
        if m: p["log_archive_config"] = m.group(1)
        for m in re.finditer(r"log_archive_dest_(\d+)='([^']*)'", q): p[f"log_archive_dest_{m.group(1)}"] = m.group(2)
        for m in re.finditer(r"log_archive_dest_state_(\d+)=enable", l): p[f"log_archive_dest_state_{m.group(1)}"] = "ENABLE"; pri.pop("dest2_error", None)
        if "standby_file_management=auto" in l: p["standby_file_management"] = "AUTO"
        m = re.search(r"fal_server=('[^;]*') scope", q, re.I)
        if m: p["fal_server"] = m.group(1).replace("'", "")
        save(PRI, pri)
        return "System altered." if "alter system" in l else "Database altered."
    if "select log_mode||'|'||force_logging||'|'||flashback_on from v$database" in l:
        return f"{pri.get('log_mode', 'ARCHIVELOG')}|{pri.get('force_logging', 'YES')}|{pri.get('flashback', 'NO')}"
    if "select lower(value) from v$parameter where name='service_names'" in l:
        return str(pri["params"].get("service_names", pri.get("service", ""))).lower()
    if "from v$active_services where con_id in (0,1)" in l:
        return "\n".join(pri.get("active_services", [pri.get("service", "")]))
    major = int(str(pri["version"]).split(".")[0])
    if "d.name||'|'||d.db_unique_name||'|'||d.database_role||'|'||d.cdb||'|'||i.version" in l:
        base = pri["version"] if major < 18 else f"{major}.0.0.0.0"
        return f"{pri['name']}|{pri['unique']}|{pri['role']}|{pri['cdb']}|{base}|{pri.get('domain') or '-'}|{'TRUE' if pri.get('rac') else 'FALSE'}|READ WRITE"
    if l.strip() == "select version_full from v$instance;":
        if major < 18: return "ORA-00904: \"VERSION_FULL\": invalid identifier"
        return pri["version"]
    if "group by loc" in l:
        return "\n".join(pri["locs"])
    if "redo_day_max" in l:
        return str(pri.get("redo_day_mb", 2000))
    if "from v$archived_log where first_time > sysdate-7" in l:
        return str(pri.get("arch_mb_day", 0))
    if l.strip() == "select name from v$asm_diskgroup_stat order by name;":
        return "\n".join(pri.get("dg_names", ["DATA", "FRA"]))
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
    if "from v$sgainfo where name='maximum sga size'" in l:
        m = pri.get("mem", {})
        if "sgainfo" in pri: return str(pri["sgainfo"])
        return str(max(int(m.get("sga_target", 0) or 0), int(m.get("sga_max_size", 0) or 0), 1024**3) if m else 1024**3)
    if "from v$logfile where member like '+%'" in l:
        dgs = pri.get("log_dgs")
        if dgs is None: dgs = sorted({loc.split(":")[0].lstrip("+").split("/")[0].upper() for loc in pri["locs"] if loc.startswith("+")})
        return "\n".join(dgs)
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
    if "from v$encryption_wallet" in l and pri.get("tde_fail"):
        return "ORA-00942: table or view does not exist"
    if "from v$encryption_wallet" in l:
        return "\n".join(pri.get("tde", ["FILE|-|NOT_AVAILABLE"]))
    if "select name from v$controlfile;" in l:
        return "\n".join(pri.get("controlfiles", ["+DATA/PRODDB/CONTROLFILE/current.261.1", "+FRA/PRODDB/CONTROLFILE/current.256.1"]))
    if "from v$log group by thread# order by thread#" in l:
        return "\n".join(f"{t}|{pri['orl']}|{pri['orl_bytes']}" for t in range(1, pri.get("threads", 1) + 1))
    if "count(*)+count(distinct thread#) from v$log" in l:
        th = pri.get("threads", 1); need = (pri["orl"] + 1) * th
        have = pri["srl"] * th if (pri["srl"] and pri["srl_bytes"] >= pri["orl_bytes"]) else 0
        omf = pri["params"].get("db_create_file_dest", "+DATA") or "-"
        return f"{need}|{have}|{pri['orl_bytes']}|{pri.get('online_log_dests', 0)}|{omf}|{pri.get('redo_dir', '+DATA/PRODDB/ONLINELOG')}"
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
    if l.strip() == "select force_logging from v$database;": return pri.get("force_logging_now", pri["force_logging"])
    if "from gv$archive_dest where upper(db_unique_name)" in l:
        d = pri.get("dest_err")
        return "" if d is None else f"DEST:{d}"
    if "select round(max(bytes)/1048576) from v$datafile;" in l: return str(pri.get("max_df_mb", 1000))
    if "'f:'||file#||'|'||name from v$datafile" in l:
        if "pfiles" in pri: return "\n".join(f"F:{r}" for r in pri["pfiles"])
        return "\n".join(f"F:{i}|+DATA/PRODDB/DATAFILE/f{i}.{255+i}.1" for i in range(1, 4))
    m = re.search(r"from v\$archived_log where thread#=(\d+) and sequence# between (\d+) and (\d+) and deleted='no'", l)
    if m: return str(pri.get("gap_have", int(m.group(3)) - int(m.group(2)) + 1))
    m = re.search(r"from v\$archive_dest where dest_id=(\d+)", l)
    if m and m.group(1) != "2":
        en = pri["params"].get(f"log_archive_dest_state_{m.group(1)}", "").upper() == "ENABLE"
        return "VALID|-"
    if "v$parameter where name='spfile'" in l: return pri.get("spfile", "+DATA/PRODDB/PARAMETERFILE/spfile.270.1")
    m = re.search(r"v\$parameter where name='([a-z_0-9]+)'", l)
    if m:
        v = pri["params"].get(m.group(1), {"compatible": "19.0.0"}.get(m.group(1)))
        if "upper(value)" in l: return (v or "").upper()
        return v if v else "-"
    if "v$pwfile_users" in l: return "1" if pri["sys_in_pwfile"] else "0"
    m = re.search(r"from v\$spparameter where name='([a-z_0-9]+)'", l)
    if m: return pri.get("spparams", {}).get(m.group(1), pri["params"].get(m.group(1), "-")) or "-"
    if "thread#||' '||max(sequence#)" in l:
        return "\n".join(f"{t} {q}" for t, q in sorted(pri.get("seq_t", {"1": pri["seq"]}).items()))
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
    if inst.get("hung"):
        if l.startswith("shutdown immediate") and inst.get("hung") == "sleep":
            import time; time.sleep(30)
        return "ERROR:\nORA-01012: not logged on"
    # after a shutdown immediate that did not finish (set "shut_hangs"): the instance hangs from then on
    if l.startswith("shutdown immediate") and inst.get("shut_hangs"):
        inst["hung"] = inst.pop("shut_hangs"); st["instances"][sid] = inst
        if inst["hung"] == "sleep":
            save(STB, st); import time; time.sleep(30)
        return "ERROR:\nORA-01012: not logged on"
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
        fake_pmon_stop(sid)
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
    if "select upper(value) from v$parameter where name='db_unique_name'" in l:
        return inst.get("unique", sid).upper()
    if "from v$recovery_area_usage" in l:
        return inst.get("fra_usage", "35|30")
    if "select nvl(max(value),'-') from v$parameter where name='db_recovery_file_dest'" in l:
        return inst.get("fra_param", "+FRA")
    if "where name like 'log_archive_dest_%' and upper(value) like '%location=%'" in l:
        return inst.get("arch_param", "location=use_db_recovery_file_dest valid_for=(all_logfiles,all_roles) db_unique_name=PRODDB_STBY")
    if "select database_role from v$database" in l:
        return "ORA-01507: database not mounted" if s == "started" else inst.get("role", "PHYSICAL STANDBY")
    if "i.instance_name||'|'||i.status" in l:
        return f"{sid}|MOUNTED|PHYSICAL STANDBY" if s == "mounted" else "ORA-01507: database not mounted"
    # a release without v$managed_standby (set "no_ms"): only v$dataguard_process answers
    if inst.get("no_ms") and "v$managed_standby" in l: return "ORA-00942: table or view does not exist"
    if "v$dataguard_process where upper(name) like 'mrp%'" in l: return str(inst.get("mrp", 0))
    if "v$dataguard_process where upper(role) like 'rfs%'" in l:
        pri = load(PRI)
        en = any(k.startswith("log_archive_dest_state_") and str(v).upper() == "ENABLE" for k, v in pri["params"].items())
        return "1" if en and inst.get("mrp") else "0"
    if "v$managed_standby where process like 'mrp%'" in l: return str(inst.get("mrp", 0))
    if "recovery_mode" in l and "v$archive_dest_status" in l:
        return inst.get("recovery_mode", "MANAGED REAL TIME APPLY")
    if "v$parameter where name='spfile'" in l:
        return inst.get("spfile_param", "-")
    if "v$standby_log where status='active'" in l:
        return str(inst.get("srl_active", 1))
    if "select message from" in l and "v$dataguard_status" in l:
        pre = "DGMSG:" if "'dgmsg:'||" in l else ""
        return "\n".join(pre + m for m in inst.get("dg_msgs", ["ORA-16401: archive log rejected by Remote File Server (RFS)"])[:3])
    if "from v$dataguard_status" in l and "to_char(max(timestamp)" in l:
        return inst.get("dg_err_last", "-")
    if "from v$dataguard_status" in l and "count(*)" in l and inst.get("dgs_fail"):
        return "ORA-01219: database or pluggable database not open: queries allowed on fixed tables or views only"
    if "from v$dataguard_status" in l and "1/96" in l:
        return str(inst.get("dg_errors_recent", 0))
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
    if "thread#||' '||max(sequence#)" in l and "applied in" in l:
        pri = load(PRI); seqs = pri.get("applied_t", pri.get("seq_t", {"1": pri["seq"]}))
        return "\n".join(f"{t} {q}" for t, q in sorted(seqs.items()))
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
    if "v$dataguard_stats" in l:
        seq = inst.get("dg_stats_seq")
        if seq and "datum_time" in l:
            inst["dg_stats_seq"] = seq[1:] or seq; st["instances"][sid] = inst; save(STB, st)
            return seq[0]
        v = inst.get("dg_stats", "+00 00:00:00|+00 00:00:01|5")
        return v if "datum_time" in l else "|".join(v.split("|")[:2])
    m = re.search(r"'m:'\|\|member from v\$logfile where group#=(\d+) and type='standby'", l)
    if m: return f"M:+DATA/PRODDB/ONLINELOG/group_{m.group(1)}.300.1"
    if "from v$nonlogged_block" in l: return inst.get("nonlogged", "0 0")
    if "select upper(value) from v$parameter where name='dg_broker_start'" in l: return inst.get("broker", "FALSE")
    if "from v$session where upper(program) like 'rman%'" in l: return str(inst.get("rman_sessions", 0))
    if "name in ('db_create_file_dest','db_file_name_convert')" in l:
        return "\n".join([f"db_create_file_dest|{inst.get('cfd', '+DATA')}", f"db_file_name_convert|{inst.get('dfnc', '-')}"])
    if "'f:'||file#||'|'||name from v$datafile" in l:
        if "sfiles" in inst: return "\n".join(f"F:{r}" for r in inst["sfiles"])
        return "\n".join(f"F:{i}|+DATA/PRODDB_STBY/DATAFILE/f{i}.{255+i}.1" for i in range(1, 4))
    if "wallet_type||'|'||status from v$encryption_wallet" in l: return inst.get("wallet", "AUTOLOGIN|OPEN")
    if "'w:'||con_id||'|'||wallet_type||'|'||status" in l:
        if "wallet_rows" in inst: return "\n".join("W:" + r for r in inst["wallet_rows"])
        return "W:0|" + inst.get("wallet", "AUTOLOGIN|OPEN") + "|NONE"
    if l == "select version from v$instance;":
        if inst.get("version_fail"): return "ORA-00942: table or view does not exist"
        v = cfg.get("local_version", "19.21.0.0.0"); mj = int(v.split(".")[0])
        return v if mj < 18 else f"{mj}.0.0.0.0"
    if "select flashback_on from v$database" in l: return inst.get("flashback", "NO")
    if "database_role||'|'||controlfile_type from v$database" in l: return inst.get("role_cf", "PHYSICAL STANDBY|STANDBY")
    if "select count(*) from v$datafile_header where error is not null;" in l:
        if inst.get("hdr_fail"): return "ORA-00210: cannot open the specified control file"
        return str(inst.get('df_errors', 0))
    if "(select count(*) from v$datafile)||'|'||" in l:
        return f"{inst.get('datafiles', 0)}|{inst.get('df_errors', 0)}"
    if "instance_name||'|'||host_name||'|'||status" in l:
        import socket
        host = "otherhost" if st.get("stby_tns_wrong") else socket.gethostname()
        return f"{sid}|{host}|" + {"started": "STARTED", "mounted": "MOUNTED"}[s]
    if "count(*) from v$archive_gap" in l: return str(len(inst.get("gap_rows", [])))
    if "thread#||' '||low_sequence#||'-'||high_sequence# from v$archive_gap" in l: return "\n".join(inst.get("gap_rows", []))
    if "max(sequence#)" in l: return str(load(PRI)["seq"])
    return "MOCK-UNKNOWN-LOCAL ORA-00900: invalid SQL statement"

def fake_pmon_stop(sid):
    """the process ora_pmon_<SID> that a test started for a hung instance"""
    import subprocess
    subprocess.run(["pkill", "-f", "^ora_pmon_" + sid + "( |$)"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

def sqlplus():
    if "-V" in args:
        v = cfg.get("local_version", "19.21.0.0.0"); major = v.split(".")[0]
        rel = v if major == "12" else f"{major}.0.0.0.0"
        print(f"\nSQL*Plus: Release {rel} - Production\nVersion {v}\n"); return 0
    data = sys.stdin.read()
    lines = data.split("\n")
    while lines and lines[0].strip().lower().startswith("set "):   # e.g. "set define off" before connect
        lines = lines[1:]
    # "sqlplus -S / as sysdba" (the login in the arguments) and "sqlplus -S -prelim / as sysdba"
    a2 = [x for x in args if x not in ("-S", "-s", "-prelim")]
    if a2[-3:] == ["/", "as", "sysdba"]:
        lines = ["connect / as sysdba"] + lines
    if "-prelim" in args:
        # a preliminary connection: only shutdown abort works (it attaches without a session)
        q = "\n".join(x for x in lines[1:] if x.strip() and x.strip().lower() != "exit")
        with open(STB + ".lock", "w") as lk:
            fcntl.flock(lk, fcntl.LOCK_EX)
            st = load(STB); sid = os.environ.get("ORACLE_SID", "")
            inst = st["instances"].get(sid, {"state": "idle"})
            st.setdefault("prelim_cmds", []).append(q)
            if q.lower().startswith("shutdown abort"):
                inst["state"] = "idle"; inst["mrp"] = 0; inst.pop("hung", None); st["instances"][sid] = inst
                save(STB, st); fake_pmon_stop(sid); print("ORACLE instance shut down."); return 0
            save(STB, st)
        print("ORA-01012: not logged on"); return 0
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
            m = re.search(r"name=upper\('([^']*)'\)", ql)
            out.append(str(st.get("sector_sizes", {}).get((m.group(1) if m else "").upper(), st.get("sector_size", 512))))
        elif "select free_mb||'|'||total_mb from v$asm_diskgroup" in ql:
            out.append(st.get("dg_free_total", "300000|400000"))
        elif "select usable_file_mb from v$asm_diskgroup" in ql:
            out.append(str(cfg.get("fra_usable", cfg["data_free"])))
        elif "select total_mb from v$asm_diskgroup" in ql:
            out.append(str(cfg.get("fra_total", 400000)))
        elif ql.strip().startswith("select name from v$asm_diskgroup") and "state in" not in ql:
            out.append("ORA-15018: diskgroup cannot be created" if st.get("asm_fail") else "\n".join(st.get("dgs", ["DATA"])))
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
              f"Password file: {reg['pwfile']}\nStart options: {reg.get('startopt', 'mount')}\nDatabase role: {reg['role']}\nDatabase instance: {reg['instance']}")
        print(f"Disk Groups: {reg.get('dg', ','.join(st.get('dgs', [])))}")
        print(f"Domain: {reg.get('domain', '')}")
        if reg.get("policy"): print(f"Management policy: {reg['policy']}")
        if reg.get("stopopt"): print(f"Stop options: {reg['stopopt']}")
        return 0
    if a[:2] == ["add", "database"]:
        if reg: print("PRCS-1007 : Server pool already exists"); return 1
        d = dict(zip(a[2::2], a[3::2]))
        st["srvctl"] = {"home": d["-oraclehome"], "spfile": d["-spfile"], "pwfile": d["-pwfile"], "role": d["-role"], "instance": d["-instance"], "running": 0}
        if "-policy" in d: st["srvctl"]["policy"] = d["-policy"]
        if "-stopoption" in d: st["srvctl"]["stopopt"] = d["-stopoption"]
        if "-diskgroup" in d: st["srvctl"]["dg"] = d["-diskgroup"]
        if "-domain" in d: st["srvctl"]["domain"] = d["-domain"]
        st.setdefault("srvctl_add_args", []).append(a)
        save(STB, st); return 0
    if a[:2] == ["modify", "database"]:
        if not reg: print("PRCD-1120"); return 1
        d = dict(zip(a[2::2], a[3::2]))
        if "-startoption" in d: reg["startopt"] = d["-startoption"].lower()
        if "-pwfile" in d: reg["pwfile"] = d["-pwfile"]
        if "-oraclehome" in d: reg["home"] = d["-oraclehome"]
        if "-diskgroup" in d: reg["dg"] = d["-diskgroup"]
        if "-domain" in d: reg["domain"] = d["-domain"]
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
    if a[:2] == ["start", "asm"]:
        st.pop("asm_down", None); save(STB, st); return 0
    if a[:2] == ["start", "diskgroup"]:
        dg = a[a.index("-diskgroup") + 1]; st["dg_off"] = [x for x in st.get("dg_off", []) if x != dg]; save(STB, st); return 0
    if a[:2] == ["start", "listener"]:
        st.pop("lsnr_off", None)
        if not lsnr_cause(st): st.pop("lsnr_stale", None)
        st["lsnr_starts"] = st.get("lsnr_starts", 0) + 1
        save(STB, st); return 0
    if a[:2] in (["stop", "listener"], ["add", "listener"]): return 0
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
    if "crosscheck archivelog all" in data.lower() and "connect" not in data.lower():
        with open(os.path.join(STATE_DIR, "calls.log"), "a") as f: f.write("rman crosscheck\n")
        print("validation succeeded for archived log\nCrosschecked 3 objects"); return 0
    if "recover standby database from service" in data.lower():
        pw = re.search(r'connect target sys/"([^"]*)"@(\S+)', data)
        with open(os.path.join(STATE_DIR, "calls.log"), "a") as f: f.write("rman rollforward\n")
        if not pw or pw.group(1) != cfg["pw"]: print("RMAN-00571: ===\nORA-01017: invalid username/password; logon denied"); return 1
        # RECOVER STANDBY DATABASE needs the standby as target
        if pw.group(2).lower() != cfg["stby_tns"]: print("RMAN-05146: must be connected to standby database to issue RECOVER STANDBY DATABASE"); return 1
        if cfg.get("rf_fail"):
            print("Starting recover at 24-OCT-26\nRMAN-00571: ===\nRMAN-00569: =============== ERROR MESSAGE STACK FOLLOWS ===============\nRMAN-03002: failure of recover command\nORA-19573: cannot obtain exclusive enqueue")
            return 1
        inst = st["instances"].get(cfg["sid"], {"state": "idle"})
        inst["state"] = "mounted"; inst["mrp"] = 0; inst["rolled"] = inst.get("rolled", 0) + 1
        st["instances"][cfg["sid"]] = inst
        st["rman_adp"] = "-"     # the primary's control file came with the primary's RMAN settings
        save(STB, st)
        print("Starting recover at 24-OCT-26\nrestoring the standby control file\nchannel ORA_DISK_1: restore complete\nstarting media recovery\nFinished recover at 24-OCT-26")
        return 0
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
    if st.get("rman_fra_full"):
        # the error stack of the real run: the recovery area filled while the archived logs were restored
        st["rman_fra_full"] -= 1
        m = re.search(r"db_recovery_file_dest_size='(\d+)G'", data); st["fra_size_tried"] = int(m.group(1)) if m else 0
        inst = st["instances"].get(cfg["sid"], {"state": "idle"}); inst["state"] = "mounted"; inst["datafiles"] = 10; inst["df_errors"] = 7
        st["instances"][cfg["sid"]] = inst; st["asm_leftovers"] = True; st["fra_full_errs"] = 1; st["asm_leftover_mb"] = 52000
        open(os.path.join(cfg["db_home"], "dbs", "spfile" + cfg["sid"] + ".ora"), "w").write("mock spfile\n")
        save(STB, st)
        print("Starting Duplicate Db at 24-OCT-26\nchannel a1: restoring archived log\n"
              "RMAN-00571: ===========================================================\n"
              "RMAN-00569: =============== ERROR MESSAGE STACK FOLLOWS ===============\n"
              "RMAN-00571: ===========================================================\n"
              "RMAN-03002: failure of Duplicate Db command at 11/08/2026 18:02:11\n"
              "RMAN-05501: aborting duplication of target database\n"
              "RMAN-03015: error occurred in stored script Memory Script\n"
              "ORA-19809: limit exceeded for recovery files\n"
              "ORA-19804: cannot reclaim 32505856 bytes disk space from 41142976512 bytes limit\n"
              "ORA-19849: error while reading backup piece from service proddb\n"
              "ORA-19660: some files in the backup set could not be verified\n"
              "ORA-19662: archived log thread 1 sequence 1234 could not be verified")
        return 1
    if cfg.get("rman_sleep"):
        import time
        print("Starting Duplicate Db at 24-OCT-26", flush=True); time.sleep(int(cfg["rman_sleep"]))
    inst = st["instances"].get(cfg["sid"], {"state": "idle"})
    if inst["state"] != "started":
        print("RMAN-03002: failure of Duplicate Db command\nRMAN-05501: auxiliary not started"); return 1
    print("Starting Duplicate Db at 24-OCT-26\nchannel a1: restored backup piece 1\nFinished Duplicate Db at 24-OCT-26")
    inst["state"] = "mounted"; inst["srl"] = st.get("srl_after_dup", 0); inst["datafiles"] = load(PRI).get("datafiles", 10)
    if st.pop("fra_full_errs", None): inst["df_errors"] = 0
    st["instances"][cfg["sid"]] = inst
    spf = os.path.join(cfg["db_home"], "dbs", "spfile" + cfg["sid"] + ".ora")
    open(spf, "w").write("mock spfile\n")
    st["duplicated"] = st.get("duplicated", 0) + 1
    save(STB, st)
    if cfg.get("rman_error_after_finish"):
        print("RMAN-00571: ===========================================================\nRMAN-00569: =============== ERROR MESSAGE STACK FOLLOWS ===============\nRMAN-05158: WARNING: auxiliary file conversion failed")
        return 1
    return 0

def lsnrctl():
    st = load(STB)
    dbhome = os.environ.get("ORACLE_HOME") == cfg["db_home"]
    up = st.get("lsnr_up") if dbhome else (st.get("asm") and not st.get("lsnr_down"))
    if args[:1] == ["start"]:
        if not dbhome: print("TNS-01106: Listener using listener name LISTENER has already been started"); return 1
        lf = os.path.join(cfg["db_home"], "network", "admin", "listener.ora")
        if not os.path.exists(lf) or "DESCRIPTION" not in open(lf).read().upper(): print("TNS-12557: protocol adapter not loadable"); return 1
        st["lsnr_up"] = 1; save(STB, st); print("The command completed successfully"); return 0
    if args[:1] == ["stop"]:
        pid = st.get("fake_lsnr_pid")
        if dbhome and pid:
            try: os.kill(int(pid), 15)
            except Exception: pass
            import time; time.sleep(0.3)
            print("The command completed successfully"); return 0
        print("TNS-12541: TNS:no listener"); return 1
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

def orapki():
    # orapki wallet create -wallet <dir> -auto_login|-auto_login_local ; the password comes on stdin
    with open(os.path.join(STATE_DIR, "calls.log"), "a") as f: f.write(f"orapki args={args}\n")
    if args[:2] != ["wallet", "create"] or "-wallet" not in args: print("PKI-01001: bad arguments"); return 1
    d = args[args.index("-wallet") + 1]
    pw = sys.stdin.readline().rstrip("\n")
    print("Oracle PKI Tool Release 19.0.0.0.0"); print("Enter wallet password:")
    if pw != load(PRI).get("tde_pw", "Wallet_pw1"): print("PKI-03001: The password is incorrect."); return 1
    opt = "-auto_login_local" if "-auto_login_local" in args else "-auto_login"
    open(os.path.join(d, "cwallet.sso"), "w").write(f"MOCK-ORAPKI {opt}\n")
    print("Operation is successfully completed."); return 0

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

def lsnr_cause(st):
    """what keeps the Grid listener INTERMEDIATE (only in tests that ask for it)"""
    if not st.get("lsnr_check"): return ""
    import socket
    h = socket.gethostname().split(".")[0]
    ok = False
    for ln in open("/etc/hosts").read().splitlines():
        f = ln.split("#")[0].split()
        if len(f) >= 2 and h in f[1:] and re.fullmatch(r"[0-9.]+", f[0]) and not f[0].startswith("127."): ok = True; break
        if len(f) >= 2 and h in f[1:]: break
    if not ok: return "hosts"
    pid = st.get("fake_lsnr_pid")
    if pid and os.path.exists(f"/proc/{pid}"): return "port"
    return ""

def crsctl():
    st = load(STB)
    if args[:2] == ["check", "has"]:
        if st.get("has") or st.get("crs_weird"): print("CRS-4638: Oracle High Availability Services is online"); return 0
        print("CRS-4639: Could not contact Oracle High Availability Services"); return 1
    if args[:2] == ["start", "has"]:
        st["has"] = 1; save(STB, st); print("CRS-4123: Oracle High Availability Services has been started."); return 0
    if args[:2] == ["start", "res"]:
        if args[2].startswith("ora."):
            print(f"CRS-4995:  The command 'Start   resource' is invalid in crsctl. Use srvctl for this command."); return 1
        print(f"CRS-2676: Start of '{args[2]}' succeeded"); return 0
    if args[:2] == ["stat", "res"]:
        name = args[2]
        if not st.get("has") or st.get("crs_weird"): print("CRS-4535: Cannot communicate with Cluster Ready Services"); return 1
        m = re.fullmatch(r"ora\.(\w+)\.dg", name)
        if m: exists = st.get("asm") and m.group(1) in st.get("dgs", ["DATA"])
        else: exists = {"ora.asm": st.get("asm"), "ora.LISTENER.lsnr": st.get("asm")}.get(name)
        if not exists: print(f"CRS-2613: Could not find resource '{name}'."); return 1
        state = "OFFLINE" if (name == "ora.asm" and st.get("asm_down")) else "ONLINE"
        detail = ""
        if m and m.group(1) in st.get("dg_off", []): state = "OFFLINE"
        if name == "ora.LISTENER.lsnr":
            if st.get("lsnr_off"): state = "OFFLINE"
            elif lsnr_cause(st):
                st["lsnr_stale"] = 1; save(STB, st); state = "INTERMEDIATE"
            elif st.get("lsnr_stale"): state = "INTERMEDIATE"
            if state == "INTERMEDIATE": detail = "Not All Endpoints Registered"
        print(f"NAME={name}\nTYPE=mock\nTARGET=ONLINE\nSTATE={state} on stby01")
        if "-v" in args: print(f"STATE_DETAILS={detail}")
        return 0
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

sys.exit({"opatch": opatch, "sqlplus": sqlplus, "srvctl": srvctl, "rman": rman, "lsnrctl": lsnrctl, "tnsping": tnsping, "orapki": orapki,
          "crsctl": crsctl, "orapwd": orapwd, "oraversion": oraversion, "orabasehome": orabasehome, "roohctl": roohctl, "asmcmd": asmcmd, "setasmgidwrap": setasmgidwrap}[prog]() or 0)
