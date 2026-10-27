#!/bin/bash
echo "grid root.sh user=$(id -un)" >> /tmp/dgt/state/calls.log
env | grep -q "^DG_" && echo "ENV-LEAK in root.sh" >> /tmp/dgt/state/calls.log
[[ $(id -u) -eq 0 ]] || { echo "must be root"; exit 1; }
mkdir -p /etc/oracle && echo "olrconfig_loc=/tmp/x" > /etc/oracle/olr.loc
python3 -c "import json;f='/tmp/dgt/state/standby.json';d=json.load(open(f));d['has']=1;json.dump(d,open(f,'w'))"
echo "CLSRSC-327: Successfully configured Oracle Restart for a standalone server"
