#!/usr/bin/python3
"""Mock Oracle installers: gridSetup.sh, runInstaller (image and staged 12.x), configToolAllCommands.
They check the response file the way the real installers need it and change the mock state."""
import sys, os, json, shutil, time

ST = "/tmp/dgt/state/standby.json"
ENV = "/tmp/dgt/state/env.json"
CALLS = "/tmp/dgt/state/calls.log"
prog = os.path.basename(sys.argv[0]); args = sys.argv[1:]
here = os.path.dirname(os.path.abspath(sys.argv[0]))
with open(CALLS, "a") as f: f.write(f"{prog} user={os.environ.get('USER')} dir={here} args={args}\n")
try:
    _sl = int(json.load(open(ENV)).get("installer_sleep", 0))
except Exception:
    _sl = 0
if _sl and prog in ("gridSetup.sh", "runInstaller") and "-executeConfigTools" not in args:
    print("Launching Oracle Grid Infrastructure Setup Wizard...", flush=True); time.sleep(_sl)

def load(p):
    with open(p) as f: return json.load(f)
def save(p, d):
    with open(p + ".tmp", "w") as f: json.dump(d, f, indent=1)
    os.chmod(p + ".tmp", 0o666); os.replace(p + ".tmp", p)
def fatal(msg, code=1):
    print(f"[FATAL] {msg}"); sys.exit(code)

def rsp_read(path):
    if not path or not os.access(path, os.R_OK): fatal("[INS-10105] The given response file is not accessible")
    d = {}
    for line in open(path):
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line: continue
        k, v = line.split("=", 1); d[k] = v
    return d
def get(d, *keys):
    for k in keys:
        if d.get(k): return d[k]
    return ""

def opt(name):
    return name in args
def optval(name):
    return args[args.index(name) + 1] if name in args else ""

def add_inventory(inv, home, name):
    os.makedirs(os.path.join(inv, "ContentsXML"), exist_ok=True)
    x = os.path.join(inv, "ContentsXML", "inventory.xml")
    if not os.path.exists(x): open(x, "w").write("<INVENTORY><HOME_LIST>\n")
    with open(x, "a") as f: f.write(f'<HOME NAME="{name}" LOC="{home}" TYPE="O" IDX="1"/>\n')
    os.system(f"chmod -R g+rwX '{inv}' 2>/dev/null")
    if not os.path.exists("/etc/oraInst.loc"):
        s = os.path.join(inv, "orainstRoot.sh")
        open(s, "w").write(f'#!/bin/bash\necho "inventory_loc={inv}" > /etc/oraInst.loc\necho "inst_group=oinstall" >> /etc/oraInst.loc\necho orainstRoot done\n')
        os.chmod(s, 0o755)

def copy_payload(src, home):
    if not os.path.isdir(src): fatal(f"[INS-32025] The installation media is incomplete: {src} not found (all zip files unpacked?)")
    for root, dirs, files in os.walk(src):
        rel = os.path.relpath(root, src); dst = os.path.join(home, rel) if rel != "." else home
        os.makedirs(dst, exist_ok=True)
        for f in files:
            shutil.copy2(os.path.join(root, f), os.path.join(dst, f))

def prereq_check(kind):
    st = load(ST)
    if st.get(kind + "_prereq_fail") and not (opt("-ignorePrereqFailure") or opt("-ignorePrereq")):
        print("[FATAL] [INS-13013] Target environment does not meet some mandatory requirements.")
        print("   CAUSE: Some of the mandatory prerequisites are not met. See logs for details. /u01/app/oraInventory/logs/InstallActions2026.log")
        sys.exit(1)

def grid_install(home, rsp, staged):
    d = rsp_read(rsp)
    if get(d, "oracle.install.option", "installOption") != "HA_CONFIG": fatal("[INS-10102] Installation option HA_CONFIG not set")
    for k in ("ORACLE_BASE", "INVENTORY_LOCATION"):
        if not d.get(k): fatal(f"[INS-30131] {k} is empty")
    if len(get(d, "oracle.install.asm.SYSASMPassword")) < 8: fatal("[INS-30001] The ASM SYS password is empty or too short")
    if not get(d, "oracle.install.asm.diskGroup.name"): fatal("[INS-30500] Disk group name is empty")
    disks = get(d, "oracle.install.asm.diskGroup.disks")
    if not disks: fatal("[INS-30508] No disks selected")
    disc = get(d, "oracle.install.asm.diskGroup.diskDiscoveryString")
    for x in disks.split(","):
        if disc.endswith("/*") and not x.startswith(disc[:-1]): fatal(f"[INS-30516] disk {x} is not in the discovery path {disc}")
    with open("/tmp/dgt/state/last_grid_rsp_disks.txt", "w") as f:
        for k in ("oracle.install.asm.diskGroup.disks", "oracle.install.asm.diskGroup.disksWithFailureGroupNames"):
            if k in d: f.write(f"{k}={d[k]}\n")
    prereq_check("grid")
    inv = d.get("INVENTORY_LOCATION", "")
    if not os.path.exists("/etc/oraInst.loc") and inv and os.path.isdir(inv) and os.listdir(inv):
        os.makedirs(os.path.join(inv, "logs"), exist_ok=True)
        fatal(f"[INS-32035] The location ({inv}) specified for the central inventory is not empty.")
    if staged:
        if not opt("-waitforcompletion"):
            print("Launching Oracle Grid Infrastructure Setup Wizard..."); sys.exit(0)   # returns at once, does nothing yet
        home = d.get("ORACLE_HOME", "")
        if not home: fatal("[INS-32012] ORACLE_HOME is empty")
        copy_payload(os.path.join(here, "stage", "payload"), home)
    st = load(ST); st["pending_dg"] = d["oracle.install.asm.diskGroup.name"].upper(); save(ST, st)
    add_inventory(d["INVENTORY_LOCATION"], home, "OraGI19Home1")
    print("Successfully Setup Software."); sys.exit(0)

def grid_config(home, rsp):
    d = rsp_read(rsp)
    if len(get(d, "oracle.install.asm.SYSASMPassword")) < 8: fatal("[INS-30001] ASM password missing")
    st = load(ST)
    if not st.get("has"): fatal("[INS-32091] Oracle High Availability Services is not running")
    st["asm"] = 1; st["dgs"] = sorted(set(st.get("dgs", []) + [d["oracle.install.asm.diskGroup.name"].upper()])); save(ST, st)
    print("Successfully Configured Software."); sys.exit(0)

def db_install(home, rsp, staged):
    d = rsp_read(rsp)
    if get(d, "oracle.install.option", "installOption") != "INSTALL_DB_SWONLY": fatal("[INS-10102] Installation option INSTALL_DB_SWONLY not set")
    if get(d, "oracle.install.db.InstallEdition", "installEdition") != "EE": fatal("[INS-35344] edition not set")
    if not get(d, "oracle.install.db.OSDBA_GROUP", "oracle.install.db.DBA_GROUP", "OSDBA"): fatal("[INS-35341] OSDBA group not set")
    for k in ("UNIX_GROUP_NAME", "INVENTORY_LOCATION", "ORACLE_BASE", "ORACLE_HOME"):
        if not d.get(k): fatal(f"[INS-30131] {k} is empty")
    if "DECLINE_SECURITY_UPDATES" in d and d["DECLINE_SECURITY_UPDATES"] != "true": fatal("[INS-30157] security updates: provide an e-mail or DECLINE_SECURITY_UPDATES=true")
    prereq_check("db")
    if staged:
        if not opt("-waitforcompletion"):
            print("Starting Oracle Universal Installer..."); sys.exit(0)
        home = d["ORACLE_HOME"]
        copy_payload(os.path.join(here, "stage", "payload"), home)
    elif os.path.realpath(d["ORACLE_HOME"]) != os.path.realpath(home):
        fatal(f"[INS-32025] ORACLE_HOME {d['ORACLE_HOME']} is not the location of this image ({home})")
    add_inventory(d["INVENTORY_LOCATION"], home, "OraDB19Home1")
    if int(load(ENV).get("major", 19)) >= 18:
        st = load(ST); st["rooh"] = 1; save(ST, st)       # 18c+ installs a read-only home by default
    print("Successfully Setup Software."); sys.exit(0)

def config_tool_all():
    rf = [x.split("=", 1)[1] for x in args if x.startswith("RESPONSE_FILE=")]
    if not rf or not os.path.exists(rf[0]): fatal("RESPONSE_FILE missing")
    txt = open(rf[0]).read()
    if "oracle.assistants.asm|S_ASMPASSWORD=" not in txt: fatal("ASM password not in the response file")
    st = load(ST)
    if not st.get("has"): fatal("Oracle High Availability Services is not running")
    st["asm"] = 1; st["dgs"] = sorted(set(st.get("dgs", []) + [st.get("pending_dg", "DATA")])); save(ST, st)
    print("Configuration completed."); sys.exit(0)

if prog == "gridSetup.sh":
    if opt("-executeConfigTools"): grid_config(here, optval("-responseFile"))
    grid_install(here, optval("-responseFile"), staged=False)
elif prog == "runInstaller":
    if os.path.basename(here) == "grid": grid_install(here, optval("-responseFile"), staged=True)
    db_install(here, optval("-responseFile"), staged=os.path.basename(here) == "database")
elif prog == "configToolAllCommands":
    config_tool_all()
fatal("unknown mock installer " + prog)
