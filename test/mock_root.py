#!/usr/bin/python3
# Mock root-level OS tools for testing an EMPTY standby. Dispatched by program name.
import sys, os, json, re

S = "/tmp/dgt/state/os.json"
CALLS = "/tmp/dgt/state/calls.log"
def load():
    with open(S) as f: return json.load(f)
def save(d):
    with open(S + ".tmp", "w") as f: json.dump(d, f, indent=1)
    os.chmod(S + ".tmp", 0o666); os.replace(S + ".tmp", S)
prog = os.path.basename(sys.argv[0]); a = sys.argv[1:]
with open(CALLS, "a") as f: f.write(f"{prog} user=root args={a}\n")
st = load()

def rpm():
    if a[:1] == ["-q"]:
        return 0 if a[1] in st["rpms"] else 1
    return 1
def dnf():
    if a[:2] == ["install", "-y"]:
        bad = [p for p in a[2:] if p in st.get("unavailable", [])]
        if bad: print(f"No package {bad[0]} available.\nError: Unable to find a match: {bad[0]}"); return 1
        for p in a[2:]: st["rpms"].append(p)
        save(st); print("Complete!"); return 0
    return 1
def oracleasm():
    asm = st["asm"]
    if a == ["configure"]:
        print(f"ORACLEASM_ENABLED={'true' if asm['enabled'] else 'false'}\nORACLEASM_UID={asm['uid']}\nORACLEASM_GID={asm['gid']}\nORACLEASM_SCANBOOT=true")
        return 0
    if a[:1] == ["configure"]:
        d = dict(zip(a[1::2], a[2::2])) if "-e" not in a else None
        args = a[1:]
        if "-u" in args: asm["uid"] = args[args.index("-u") + 1]
        if "-g" in args: asm["gid"] = args[args.index("-g") + 1]
        if "-e" in args: asm["enabled"] = True
        save(st); print("Writing Oracle ASM library driver configuration: done"); return 0
    if a == ["init"]:
        if not asm["enabled"]: print("not configured"); return 1
        asm["loaded"] = True; save(st); print("Mounting ASMlib driver filesystem: /dev/oracleasm"); return 0
    if a == ["status"]:
        y = "yes" if asm["loaded"] else "no"
        print(f"Checking if ASM is loaded: {y}\nChecking if /dev/oracleasm is mounted: {y}"); return 0
    if a == ["listdisks"]:
        for d in asm["disks"]: print(d)
        return 0
    if a[:1] == ["createdisk"]:
        label, part = a[1], a[2]
        if part not in st["parts"]: print(f"Unable to open device \"{part}\""); return 1
        asm["disks"][label] = part; save(st); print("Writing disk header: done\nInstantiating disk: done"); return 0
    if a == ["scandisks"]: print("Scanning system for ASM disks..."); return 0
    if a[:2] == ["querydisk", "-p"]:
        lab = a[2]
        if lab in asm["disks"]: print(f'{asm["disks"][lab]}: LABEL="{lab}" TYPE="oracleasm"'); return 0
        return 1
    if a == ["configure", "-d"]: asm["enabled"] = False; save(st); return 0
    return 1
def parted():
    disk = a[1]
    if disk not in st["disks"]: print("Error: Could not stat device"); return 1
    part = disk + ("p1" if disk[-1].isdigit() else "1")
    st["parts"][part] = disk; st["disks"][disk]["parts"] = 1; save(st); return 0
def lsblk():
    flags = "".join(x[1:] for x in a if x.startswith("-") and not x.startswith("--") and x != "-o")
    cols = a[a.index("-o") + 1].split(",") if "-o" in a else ["NAME"]
    devs = [x for x in a if x.startswith("/dev/")]
    def size(d):
        mb = st["disks"].get(d, {}).get("size_mb", 102400)
        return str(mb * 1048576) if "b" in flags else f"{mb // 1024}G"
    def rows_for(dev):
        if dev in st["parts"]:
            return [{"NAME": dev[5:], "TYPE": "part", "MOUNTPOINT": "", "SIZE": size(st["parts"][dev]), "FSTYPE": "", "RM": "0", "TRAN": "", "WWN": ""}]
        d = st["disks"][dev]
        r = [{"NAME": dev[5:], "TYPE": "disk", "MOUNTPOINT": d.get("mnt", ""), "SIZE": size(dev), "FSTYPE": d.get("fs", ""),
              "RM": "1" if d.get("removable") else "0", "TRAN": d.get("tran", ""), "WWN": d.get("wwn", ""), "SERIAL": d.get("serial", "")}]
        if d.get("parts") and "d" not in flags:
            pn = dev + ("p1" if dev[-1].isdigit() else "1")
            r.append({"NAME": pn[5:], "TYPE": "part", "MOUNTPOINT": d.get("pmnt", ""), "SIZE": size(dev), "FSTYPE": "", "RM": "0", "TRAN": "", "WWN": ""})
        return r
    rows = []
    if not devs:
        for dev in sorted(st["disks"]): rows += rows_for(dev)
    else:
        dev = devs[-1]
        if dev not in st["parts"] and dev not in st["disks"]:
            print(f"lsblk: {dev}: not a block device", file=sys.stderr); return 32
        rows = rows_for(dev)
    if "P" in flags:
        for r in rows: print(" ".join(f'{x}="{r.get(x, "")}"' for x in cols))
        return 0
    if "n" not in flags: print(" ".join(cols))
    for r in rows: print(" ".join(r.get(x, "") for x in cols))
    return 0
def part_uuid(dev):
    import hashlib
    h = hashlib.md5(dev.encode()).hexdigest()
    return f"{h[:8]}-{h[8:12]}-{h[12:16]}-{h[16:20]}-{h[20:32]}"
def blkid():
    dev = a[-1]
    if "udev" in a:
        if dev in st["parts"]: print("ID_PART_ENTRY_UUID=" + part_uuid(dev)); return 0
        return 2
    if "PART_ENTRY_UUID" in a:
        if st.get("blkid_old"): return 2          # util-linux 2.23 (OL7): nothing for an empty partition
        if dev in st["parts"]: print(part_uuid(dev)); return 0
        return 2
    key = "pttype" if "PTTYPE" in a else "fs"
    v = st["disks"].get(dev, {}).get(key, "")
    if v: print(v); return 0
    return 2
def wipefs():
    if "--help" in a:
        print(" -o, --output <list>  COLUMNS to display"); return 0
    dev = a[-1]; d = st["disks"].get(dev, {})
    rows = [x for x in (d.get("fs"), d.get("pttype")) if x]
    if "-O" in a and "--noheadings" in a:
        for r in rows: print(r)
        return 0
    if rows:
        print("DEVICE OFFSET TYPE UUID LABEL")
        for r in rows: print(f"{dev[5:]} 0x0 {r}")
    return 0
def systemctl():
    if a[:2] == ["is-active", "--quiet"]:
        return 0 if st["services"].get(a[2]) else 3
    if a[:2] == ["enable", "--now"]:
        st["services"][a[2]] = True; save(st); return 0
    if a[:1] == ["daemon-reload"]: return 0
    if a[:1] == ["start"]: return 0 if os.path.exists("/etc/systemd/system/" + a[1]) else 5
    if a[:1] == ["disable"]:
        u = a[2] if len(a) > 2 and a[1] == "--now" else a[1]
        st["enabled"] = [x for x in st.get("enabled", []) if x != u]; save(st); return 0
    if a[:1] == ["enable"]:
        known = a[1] == "oracleasm" and "oracleasm-support" in st["rpms"]
        if not known and not os.path.exists("/etc/systemd/system/" + a[1]): print(f"Failed to enable unit: Unit file {a[1]} does not exist."); return 1
        st.setdefault("enabled", []).append(a[1]); save(st); return 0
    if a[:2] == ["is-enabled", "--quiet"]:
        return 0 if a[2] in st.get("enabled", []) else 1
    return 1
def chronyc():
    if st["services"].get("chronyd"): print("Leap status     : Normal"); return 0
    return 1
def udevadm():
    if a[:1] == ["info"]:
        name = [x.split("=", 1)[1] for x in a if x.startswith("--name=")]
        if name and name[0] in st["parts"] and not st.get("udev_info_fails"): print("DEVTYPE=partition\nID_PART_ENTRY_UUID=" + part_uuid(name[0])); return 0
        return 1
    if a[:1] == ["trigger"]:
        import re, pwd, grp
        rules = "/etc/udev/rules.d/99-oracle-asmdevices.rules"
        if not os.path.exists(rules): return 0
        os.makedirs("/dev/oraasm", exist_ok=True); os.makedirs("/tmp/dgt/devs", exist_ok=True)
        for line in open(rules):
            m = re.search(r'ENV\{ID_PART_ENTRY_UUID\}=="([^"]+)".*SYMLINK\+="oraasm/([^"]+)".*OWNER="([^"]+)".*GROUP="([^"]+)"', line)
            if not m: continue
            for part in st["parts"]:
                if part_uuid(part) == m.group(1):
                    real = "/tmp/dgt/devs/" + part[5:]
                    open(real, "a").close(); os.chmod(real, 0o660)
                    try: os.chown(real, pwd.getpwnam(m.group(3)).pw_uid, grp.getgrnam(m.group(4)).gr_gid)
                    except KeyError: pass
                    link = "/dev/oraasm/" + m.group(2)
                    if not os.path.lexists(link): os.symlink(real, link)
        return 0
    return 0
def uname():
    r = os.environ.get("DGT_UNAME", "5.4.17-2136.330.7.1.el8uek.x86_64")
    print(r if "-r" in a else "Linux"); return 0
def noop(): return 0
def findmnt():
    v = st.get("fsid", "/dev/vdb aaaa1111-2222-3333-4444-555566667777")
    print(v.split()[0] if "SOURCE" in a else v); return 0
def cmp():
    # cmp -s -n 1048576 -- <disk> /dev/zero : 0 when the start of the disk is empty
    dev = [x for x in a if x.startswith("/dev/") and x != "/dev/zero"]
    d = st["disks"].get(dev[0], {}) if dev else {}
    return 1 if (d.get("dirty") or d.get("fs") or d.get("pttype") or d.get("parts")) else 0

sys.exit({"rpm": rpm, "dnf": dnf, "oracleasm": oracleasm, "parted": parted, "lsblk": lsblk, "blkid": blkid,
          "systemctl": systemctl, "chronyc": chronyc, "wipefs": wipefs, "partprobe": noop, "udevadm": udevadm, "pvs": noop, "yum": dnf, "uname": uname, "cmp": cmp, "findmnt": findmnt}[prog]())
