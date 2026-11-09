#!/bin/bash
echo "db root.sh user=$(id -un)" >> /tmp/dgt/state/calls.log
[[ $(id -u) -eq 0 ]] || { echo "must be root"; exit 1; }
d=$(cd "$(dirname "$0")" && pwd); chown root "$d/bin/oradism"; chmod 4750 "$d/bin/oradism"
# role separation: the installer gives the oracle binary the ASM admin group
id grid >/dev/null 2>&1 && getent group asmadmin >/dev/null && chgrp asmadmin "$d/bin/oracle"
echo done
