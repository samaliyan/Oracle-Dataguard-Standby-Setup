#!/usr/bin/python3
"""df and mount for the tests: only /dev/shm is faked (its size is kept in os.json), everything else is the real tool."""
import sys, os, json, re
S = "/tmp/dgt/state/os.json"
prog = os.path.basename(sys.argv[0]); a = sys.argv[1:]
real = {"df": "/usr/bin/df", "mount": "/usr/bin/mount"}[prog]
if not os.path.exists(real): real = "/bin/" + prog
st = json.load(open(S)) if os.path.exists(S) else {}
if prog == "mount" and a[:2] == ["-o", a[1]] and a[-1] == "/dev/shm" and "remount" in a[1]:
    m = re.search(r"size=(\d+)m", a[1])
    with open("/tmp/dgt/state/calls.log", "a") as f: f.write(f"mount user=root args={a}\n")
    if m:
        st["shm_mb"] = int(m.group(1)); json.dump(st, open(S, "w"), indent=1); sys.exit(0)
    sys.exit(1)
if prog == "df" and a and a[-1] == "/dev/shm" and "shm_mb" in st and "--output=size" in a:
    print("1M-blocks"); print(st["shm_mb"]); sys.exit(0)
os.execv(real, [real] + a)
