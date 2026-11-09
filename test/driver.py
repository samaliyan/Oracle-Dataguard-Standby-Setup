#!/usr/bin/python3
"""Expect-style driver for dg_standby_setup.sh v3 (stdlib only).
Runs the script in a pty and answers prompts. When the script prints commands for
the PRIMARY and asks '[r] I did it', the driver applies those changes to the mock
primary (as the DBA would) and answers r.

Environment knobs:
  DG_TEST_SKIP=2.9,5.1     answer s at these steps ([y] do it prompts)
  DG_TEST_QUIT_AT=4.1      answer q at this step
  DG_TEST_NOFIX=4.3,...    do NOT apply primary changes at these steps (answer s)
  DG_TEST_HELP_AT=2.1      type h once at this step
  DG_TEST_CTRLC_AT=3.2     send Ctrl-C at this step
  DG_TEST_SETTINGS=a|e     answer to the settings question
  DG_TEST_MENU=8,2         answers at the start menu, in order (default Enter = 1)
  DG_TEST_MENU_YES=y       answer to the --yes question of the menu (default n)
  DG_TEST_MENU_STEPS, DG_TEST_MENU_REC, DG_TEST_MENU_UNDO   menu item 6 and 8 answers
  DG_TEST_OSPW, DG_TEST_PW, DG_TEST_ASMPW, DG_TEST_ASMPW2, DG_TEST_IP, DG_TEST_DUP, DG_TEST_DISK_PICKS=1,2
"""
import os, pty, re, sys, json, time, select

ANSI = re.compile(r"\x1b\[[0-9;]*m")
STATE = "/tmp/dgt/state"
E = os.environ.get

def load(n):
    with open(os.path.join(STATE, n)) as f: return json.load(f)
def save(n, d):
    p = os.path.join(STATE, n)
    with open(p, "w") as f: json.dump(d, f, indent=1)
    os.chmod(p, 0o666)
def lst(name): return [x for x in E(name, "").split(",") if x]

def fix_primary(text):
    pri = load("primary.json"); p = pri["params"]
    if "alter database force logging" in text: pri["force_logging"] = "YES"
    if "alter database archivelog" in text: pri["log_mode"] = "ARCHIVELOG"
    if "add standby logfile" in text: pri["srl"] = pri["orl"] + 1; pri["srl_bytes"] = pri["orl_bytes"]
    m = re.search(r"log_archive_config='(dg_config=\([^)]*\))'", text)
    if m: p["log_archive_config"] = m.group(1)
    for m in re.finditer(r"log_archive_dest_(\d+)='([^']*)'", text): p[f"log_archive_dest_{m.group(1)}"] = m.group(2)
    if "set log_archive_dest=''" in text: p.pop("log_archive_dest", None)
    if "standby_file_management=auto" in text: p["standby_file_management"] = "AUTO"
    if "db_recovery_file_dest='" in text: p["db_recovery_file_dest"] = "+FRA"
    if "remote_login_passwordfile=exclusive" in text: p["remote_login_passwordfile"] = "EXCLUSIVE"
    if "alter user sys identified" in text: pri["sys_in_pwfile"] = True
    m = re.search(r"fal_server=('[^;]*') scope", text)
    if m: p["fal_server"] = m.group(1).replace("'", "")
    if "tnsnames.ora" in text and ("cat >>" in text or "entry must be" in text): pri["tns_stby"] = 1; pri.pop("tns_stby_host", None)
    if "SID_LIST_" in text and "lsnrctl reload" in text: pri["static"] = 1
    if ">> /etc/hosts" in text: pri["hosts_stby"] = 1
    if "rm -f /tmp/orapw_for_standby" in text: pri["pw_tmp"] = 0
    if "asmcmd pwcopy" in text: pri["pw_tmp"] = 1; pri.pop("pw_tmp_mtime", None)
    for m in re.finditer(r"log_archive_dest_state_(\d+)=enable", text): p[f"log_archive_dest_state_{m.group(1)}"] = "ENABLE"; pri.pop("dest2_error", None)
    save("primary.json", pri)

def fix_local(text):
    env = load("env.json")
    if "listener.ora" in text and "SID_DESC" in text:
        f = env["listener_ora"]
        s = open(f).read().replace(f"(ORACLE_HOME = {env['grid_home']})", f"(ORACLE_HOME = {env['db_home']})")
        open(f, "w").write(s)
    if "opatchauto" in text or "OPatch/opatch apply" in text:
        import shutil
        pri = load("primary.json")
        homes = [env["db_home"]] + ([env["grid_home"]] if pri.get("grid", True) else [])
        for h in homes:
            key = "grid_patches" if h == env["grid_home"] else "patches"
            want = {x.split(";")[0] for x in pri.get(key, pri["patches"])}
            d = os.path.join(h, "inventory", "oneoffs"); os.makedirs(d, exist_ok=True)
            for x in os.listdir(d):
                if x not in want: shutil.rmtree(os.path.join(d, x))
            for x in want: os.makedirs(os.path.join(d, x), exist_ok=True)
        env["local_version"] = pri["version"]; save("env.json", env)
    if "opatch napply -oh" in text and "18370031" in text:
        os.makedirs(os.path.join(env["grid_home"], "inventory", "oneoffs", "18370031"), exist_ok=True)
    if "crsctl start has" in text and "root.sh may have failed" in text:
        st = load("standby.json"); st["has"] = 1; save("standby.json", st)
    if "setasmgidwrap" in text:
        os.system(f"chgrp asmadmin {env['db_home']}/bin/oracle")

def cur_step(full):
    # the title of the step: "  Step N.N  " (on the screen layout it may follow a cursor move, not a newline)
    m = re.findall(r"  Step (\d+\.\d+)  ", full)
    return m[-1] if m else ""

def main():
    cmd = sys.argv[1:]
    ui = E("DG_TEST_UI") == "1"
    pid, fd = pty.fork()
    if pid == 0:
        if ui:
            import fcntl, termios, struct
            rows, cols = [int(x) for x in E("DG_TEST_SIZE", "30x100").split("x")]
            fcntl.ioctl(0, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))
            os.environ["TERM"] = "xterm-256color"; os.environ["DG_PLAIN"] = "0"
        os.execvp(cmd[0], cmd)
    vt = None; snaps = lst("DG_TEST_SNAP"); pcount = {}; snapdir = E("DG_TEST_SNAPDIR", "/tmp/dgt/snaps"); snapn = [0]
    keys = [x.split(":", 1) for x in lst("DG_TEST_KEYS")]; jobkeys = [x.split(":", 1) for x in lst("DG_TEST_JOBKEYS")]
    if ui:
        sys.path.insert(0, os.path.dirname(os.path.abspath(__file__))); import vt as vtmod
        rows, cols = [int(x) for x in E("DG_TEST_SIZE", "30x100").split("x")]
        vt = vtmod.VT(rows, cols); os.makedirs(snapdir, exist_ok=True)
    def snap(label):
        snapn[0] += 1
        base = os.path.join(snapdir, "%02d_%s" % (snapn[0], label.replace("/", "_").replace(" ", "_")))
        open(base + ".txt", "w").write(vt.text() + "\n")
        open(base + ".html", "w").write(vt.html())
    ANSI_ALL = re.compile(r"\x1b\[[?0-9;]*[A-Za-z]|\x1b[78]")
    buf = ""; full = ""; ctx = ""; pw_asked = [0]
    deadline = time.time() + int(E("DG_TEST_TIMEOUT", "300"))
    answered = 0; helped = set(); ctrlc = set(); retries = {}; expanded = set()
    disk_picks = [x.replace("+", " ") for x in lst("DG_TEST_DISK_PICKS")]
    settings_answers = lst("DG_TEST_SETTINGS")
    menu_answers = E("DG_TEST_MENU", "").split(",") if E("DG_TEST_MENU") else []
    summary_answers = E("DG_TEST_SUMMARY", "").split(",") if E("DG_TEST_SUMMARY") else []
    menu_steps = lst("DG_TEST_MENU_STEPS")
    def send(s):
        nonlocal answered, buf, ctx
        if s == "<CTRL-C>": os.write(fd, b"\x03")
        else: os.write(fd, (s + "\n").encode())
        answered += 1; buf = ""; ctx = ""
    hup_sent = False
    chan_asked = [0]
    while True:
        r, _, _ = select.select([fd], [], [], 0.5)
        if fd in r:
            try: data = os.read(fd, 65536).decode(errors="replace")
            except OSError: break
            if not data: break
            if ui:
                vt.feed(data); data = ANSI_ALL.sub("", data)
            data = ANSI.sub("", data)
            sys.stdout.write(data); sys.stdout.flush()
            buf += data; full += data; ctx += data
            if E("DG_TEST_HUP_ON_JOB") and not hup_sent and re.search(E("DG_TEST_HUP_ON_JOB") + r" is running \(process \d+\)", full):
                import signal
                time.sleep(1); os.killpg(pid, signal.SIGHUP); hup_sent = True
        if ui:
            # the separate screen (list, details, help): a snapshot when asked for, then q closes it
            if vt.in_alt and "q: close" in vt.text():
                # the page is complete when nothing more arrives for 0.4 s
                while True:
                    r4, _, _ = select.select([fd], [], [], 0.4)
                    if fd not in r4: break
                    try: d4 = os.read(fd, 65536).decode(errors="replace")
                    except OSError: break
                    if not d4: break
                    vt.feed(d4); d4 = ANSI.sub("", ANSI_ALL.sub("", d4)); full += d4; ctx += d4
                if keys and keys[0][1] in ("l", "d", "h"): snap("alt_" + keys[0][0] + "_" + keys[0][1])
                if keys and keys[0][1] in ("l", "d", "h"): keys.pop(0)
                elif jobkeys and jobkeys[0][1] == "d": jobkeys.pop(0); snap("alt_job_output")
                time.sleep(0.2); os.write(fd, b"q"); buf = ""
                # one q only: wait until the separate screen is closed (or 5 s)
                t_end = time.time() + 5
                while vt.in_alt and time.time() < t_end:
                    r3, _, _ = select.select([fd], [], [], 0.2)
                    if fd in r3:
                        try: d3 = os.read(fd, 65536).decode(errors="replace")
                        except OSError: break
                        vt.feed(d3); d3 = ANSI.sub("", ANSI_ALL.sub("", d3)); full += d3; ctx += d3
                continue
            if jobkeys and re.search(re.escape(jobkeys[0][0]) + r"   running, ", full[-400:]):
                os.write(fd, jobkeys[0][1].encode()); jobkeys[0] = (jobkeys[0][0] + " (sent)", jobkeys[0][1]); time.sleep(0.5); continue
        # a question: a line "    ? text >" (or the UTF-8 mark), or a password prompt of ssh
        last = buf.rsplit("\n", 1)[-1]
        q = re.match(r"^\s*\? (.*?)\s*[>\u203a]\s$", last)
        bt = q.group(1).rstrip() if q else buf.rstrip()
        is_prompt = bool(buf) and buf.endswith(" ") and (q is not None or bt.endswith("'s password:"))
        if not is_prompt:
            if time.time() > deadline: print("\nDRIVER TIMEOUT"); os.kill(pid, 9); break
            continue
        step = cur_step(full)
        if answered > int(E("DG_TEST_MAXPROMPTS", "400")):
            print("\nDRIVER TOO MANY PROMPTS"); os.kill(pid, 9); break
        if q and ui:
            pcount[step] = pcount.get(step, 0) + 1
            tag = None
            if step in snaps and pcount[step] == 1: tag = step
            elif "%s#%d" % (step, pcount[step]) in snaps: tag = "%s#%d" % (step, pcount[step])
            if tag:
                snaps.remove(tag)
                # the screen is complete when nothing more arrives for 0.4 s
                while True:
                    r2, _, _ = select.select([fd], [], [], 0.4)
                    if fd not in r2: break
                    d2 = os.read(fd, 65536).decode(errors="replace"); vt.feed(d2)
                    d2 = ANSI.sub("", ANSI_ALL.sub("", d2)); full += d2; ctx += d2
                snap("step_" + tag.replace("#", "_try"))
            if keys and keys[0][0] == step:
                send(keys[0][1]); continue
        if q:
            if step in lst("DG_TEST_CTRLC_AT") and step not in ctrlc:
                ctrlc.add(step); send("<CTRL-C>"); continue
            if step in lst("DG_TEST_HELP_AT") and step not in helped and "[h] Help" in bt:
                helped.add(step); send("h"); continue
        if bt.endswith("'s password:"): send(E("DG_TEST_OSPW", "Oracle_os1")); continue
        if bt == "Choice [1]": send(menu_answers.pop(0) if menu_answers else ""); continue
        if bt.startswith("Steps to run, for example"): send(menu_steps.pop(0) if menu_steps else ""); continue
        if bt.startswith("Answer y automatically for this server"): send(E("DG_TEST_MENU_YES", "n")); continue
        if bt.startswith("[c] Changes made, with undo commands   [u] Undo a step"): send(E("DG_TEST_MENU_REC", "b")); continue
        if bt.startswith("Step to undo, for example"): send(E("DG_TEST_MENU_UNDO", "")); continue
        if bt.startswith("IP address or host name of the primary"): send(E("DG_TEST_IP", "127.0.0.2")); continue
        if bt.startswith("OS user for ssh on the primary"): send(E("DG_TEST_SSHUSER", "")); continue
        if "[w] Keep watching   [d] Leave it running" in bt: send("w"); continue
        if "[4] Do phase 4 (primary) first   [c] Continue in order" in bt: send(E("DG_TEST_P4FIRST", "c")); continue
        if "[r] Done, check all steps   [o] Show the steps one at a time" in bt:
            if E("DG_TEST_BATCH", "o") == "r": fix_primary(ctx)
            send(E("DG_TEST_BATCH", "o")); continue
        if "[y] Undo it   [s] Skip   [q] Quit" in bt: send(E("DG_TEST_UNDO", "y")); continue
        if bt.startswith("Undo it anyway and lose the later change") or bt.startswith("Cut the file at that point anyway"): send("y"); continue
        if bt.startswith("Mark it as undone by you"): send(E("DG_TEST_UNDO_MARK", "n")); continue
        if bt.startswith("sys password"):
            pw_asked[0] += 1
            if pw_asked[0] == 1 and E("DG_TEST_PW1"): send(E("DG_TEST_PW1")); continue
            send(E("DG_TEST_PW", "Welcome_123")); continue
        if bt.startswith("TDE keystore password"): send(E("DG_TEST_TDEPW", "Wallet_pw1")); continue
        if bt.startswith("New ASM password for SYS and ASMSNMP"): send(E("DG_TEST_ASMPW", "Asm_Pass123")); continue
        if bt == "Type it again": send(E("DG_TEST_ASMPW2", E("DG_TEST_ASMPW", "Asm_Pass123"))); continue
        if "Number of the database" in bt: send(E("DG_TEST_DBPICK", "1")); continue
        if "Full path of the database ORACLE_HOME on the primary" in bt: send(E("DG_TEST_HOMEPATH", "")); continue
        if re.search(r"Disk numbers for \+\S+, separated by spaces \(q = stop, nothing is erased\) \[\d+\]$", bt):
            send(disk_picks.pop(0) if disk_picks else ""); continue
        m = re.search(r"Type (\S+) to continue, or n to stop$", bt)
        if m:
            w = m.group(1)
            if w == "DUPLICATE": w = E("DG_TEST_DUP", w)
            elif w == "SEPARATE": w = E("DG_TEST_SEPARATE", "n")
            elif w == "DELETE": w = E("DG_TEST_DELETE", w)
            elif w == "CLEAN": w = E("DG_TEST_CLEAN", "n" if E("DG_TEST_DELETE") == "n" else w)
            elif w == "IGNORE": w = E("DG_TEST_IGNORE", w)
            elif w == "ROLLFORWARD": w = E("DG_TEST_RF", w)
            elif w.startswith("/dev/"): w = E("DG_TEST_DISKWORD", w)
            send(w); continue
        if "[w] Watch until it ends" in bt: send("w"); continue
        if bt.startswith("[k] Keep these   [c] Change"):
            chan_asked[0] += 1
            send(E("DG_TEST_CHAN", "k") if chan_asked[0] == 1 else "k"); continue
        if bt.startswith("Channels on the primary (1-64)"): send(E("DG_TEST_PCH", "")); continue
        if bt.startswith("Channels on this server ("): send(E("DG_TEST_ACH", "")); continue
        if bt.startswith("[y] Clean up for me") or bt.startswith("[m] Show the commands   [s] Skip"):
            if step in lst("DG_TEST_QUIT_AT"): send("q"); continue
            v = E("DG_TEST_L72", "y")
            if v == "y" and "[y]" not in bt: v = "s"
            send("s" if step in lst("DG_TEST_NOFIX") else v); continue
        if bt.startswith("[Enter] Start   [number] Change"):
            if summary_answers: send(summary_answers.pop(0)); continue
            # the older settings answers (a = accept, e = edit) reach the summary as Enter / e
            if settings_answers:
                v = settings_answers.pop(0); send("e" if v == "e" else ""); continue
            send(""); continue
        if bt.startswith("[t] systemd timer   [c] crontab of"):
            send(E("DG_TEST_ARCH", "t")); continue
        if bt.startswith("[y] Stop it with shutdown abort"):
            if step in lst("DG_TEST_QUIT_AT"): send("q"); continue
            send(E("DG_TEST_ABORT", "y")); continue
        if bt.startswith("[m] I installed it myself"): send("s" if step in lst("DG_TEST_NOFIX") else E("DG_TEST_HALF", "c")); continue
        if "[p] Type the sys password" in bt and step in lst("DG_TEST_PSYS"): send("p"); continue
        if bt.endswith("[a] Accept   [e] Edit   [h] Help   [q] Quit"):
            send(settings_answers.pop(0) if settings_answers else "a"); continue
        if bt.startswith("[y] Yes, do it") and "[s] Skip" in bt and bt.endswith("Quit"):
            if step in lst("DG_TEST_QUIT_AT"): send("q"); continue
            if step in lst("DG_TEST_SKIP"): send("s"); continue
            send("a" if (step in lst("DG_TEST_YESALL") and "[a] Yes to all" in bt) else "y"); continue
        if bt.startswith("[y] Run it on the primary for me"):
            if step in lst("DG_TEST_QUIT_AT"): send("q"); continue
            v = E("DG_TEST_ANSWER_PRIM", "y")
            if v == "r": fix_primary(ctx)
            send(v); continue
        if "[r] Done, check it" in bt and bt.endswith("Quit"):
            if step in lst("DG_TEST_QUIT_AT"): send("q"); continue
            # the step text was cut to fit the screen: like a user, d first (the whole text), then the answer
            if ui and "more lines: d shows all" in ctx and (step, retries.get(step, 0)) not in expanded:
                expanded.add((step, retries.get(step, 0))); send("d"); continue
            retries[step] = retries.get(step, 0) + 1
            if step in lst("DG_TEST_NOFIX") or retries[step] > 2: send("s"); continue
            if "Run on the PRIMARY" in ctx: fix_primary(ctx)
            else: fix_local(ctx)
            send("r"); continue
        if ("[r] Check again" in bt or "[r] Try again" in bt) and bt.endswith("Quit"):
            retries[step] = retries.get(step, 0) + 1
            if step in lst("DG_TEST_RETRY") and retries[step] <= 2: send("r"); continue
            send("s" if "[s]" in bt else "q"); continue
        if bt.endswith("[h] Help   [q] Quit") and "[r]" not in bt and "[y]" not in bt and "[s]" not in bt: send("q"); continue
        if bt.startswith("The fingerprints match the primary"): send(E("DG_TEST_HOSTKEY", "y")); continue
        if bt.endswith("[y] Yes   [N] No"): send(E("DG_TEST_YN", "y")); continue
        # any other question while DG_TEST_SUMMARY still has answers (the values a summary change asks for)
        if q and summary_answers: send(summary_answers.pop(0)); continue
        if time.time() > deadline:
            print("\nDRIVER TIMEOUT"); os.kill(pid, 9); break
    _, status = os.waitpid(pid, 0)
    # os.waitstatus_to_exitcode is new in Python 3.9; this also runs on 3.6 (Oracle Linux 7)
    code = os.WEXITSTATUS(status) if os.WIFEXITED(status) else -os.WTERMSIG(status)
    with open(E("DG_TEST_OUT", "/tmp/dgt/last_output.txt"), "w") as f: f.write(full)
    if ui: snap("end")
    print(f"\n[driver] exit={code} prompts_answered={answered}")
    sys.exit(code)

main()
