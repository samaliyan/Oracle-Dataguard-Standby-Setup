#!/usr/bin/python3
# mock "ss -ltnp 'sport = :PORT'" for the test container (iproute is not installed here): reads /proc/net/tcp
import sys, os, re
m = re.search(r"sport = :(\d+)", " ".join(sys.argv[1:]))
if not m or "-ltnp" not in sys.argv: sys.exit(1)
port = int(m.group(1)); inodes = set()
for f in ("/proc/net/tcp", "/proc/net/tcp6"):
    try:
        for ln in open(f).read().splitlines()[1:]:
            x = ln.split()
            # 127.0.0.2 is the simulated primary (another server in the tests): not a socket of this server
            if int(x[1].split(":")[1], 16) == port and x[3] == "0A" and x[1].split(":")[0] != "0200007F": inodes.add(x[9])
    except Exception: pass
print("State  Recv-Q Send-Q Local Address:Port  Peer Address:Port")
for pid in filter(str.isdigit, os.listdir("/proc")):
    try:
        for fd in os.listdir(f"/proc/{pid}/fd"):
            l = os.readlink(f"/proc/{pid}/fd/{fd}")
            if l.startswith("socket:[") and l[8:-1] in inodes:
                name = open(f"/proc/{pid}/comm").read().strip()
                print(f'LISTEN 0 128 *:{port} *:* users:(("{name}",pid={pid},fd={fd}))'); raise StopIteration
    except StopIteration: break
    except Exception: pass
