#!/bin/bash
# mock gridSetup.sh
ST=/tmp/dgt/state/standby.json
echo "gridSetup.sh user=$(id -un) args=$*" >> /tmp/dgt/state/calls.log
rsp=""; cfg=0; ign=0
while [[ $# -gt 0 ]]; do case "$1" in -responseFile) rsp=$2; shift;; -executeConfigTools) cfg=1;; -ignorePrereqFailure) ign=1;; esac; shift; done
[[ -r "$rsp" ]] || { echo "[FATAL] [INS-10105] response file not readable"; exit 1; }
grep -E '^oracle.install.asm.diskGroup.disks' "$rsp" > /tmp/dgt/state/last_grid_rsp_disks.txt
grep -q '^oracle.install.option=HA_CONFIG$' "$rsp" || { echo "[FATAL] option"; exit 1; }
grep -qE '^oracle.install.asm.SYSASMPassword=.{8,}' "$rsp" || { echo "[FATAL] [INS-30001] ASM password empty"; exit 1; }
inv=$(grep '^INVENTORY_LOCATION=' "$rsp" | cut -d= -f2)
gh=$(cd "$(dirname "$0")" && pwd)
if [[ $cfg -eq 1 ]]; then
  python3 -c "import json;d=json.load(open('$ST'));assert d.get('has'),'HAS down';d['asm']=1;json.dump(d,open('$ST','w'))" || { echo "[FATAL] configtools need HAS"; exit 1; }
  echo "Successfully Configured Software."; exit 0
fi
if python3 -c "import json,sys;sys.exit(0 if json.load(open('$ST')).get('grid_prereq_fail') else 1)" && [[ $ign -eq 0 ]]; then
  echo "[FATAL] [INS-13013] Target environment does not meet some mandatory requirements."; echo "   CAUSE: Some of the mandatory prerequisites are not met."; exit 1
fi
mkdir -p "$inv/ContentsXML"
[[ -f "$inv/ContentsXML/inventory.xml" ]] || echo '<INVENTORY><HOME_LIST>' > "$inv/ContentsXML/inventory.xml"
echo "<HOME NAME=\"OraGI21Home1\" LOC=\"$gh\" TYPE=\"O\" IDX=\"1\"/>" >> "$inv/ContentsXML/inventory.xml"
printf '#!/bin/bash\necho "inventory_loc=%s" > /etc/oraInst.loc\necho "inst_group=oinstall" >> /etc/oraInst.loc\necho orainstRoot done\n' "$inv" > "$inv/orainstRoot.sh"
chmod 755 "$inv/orainstRoot.sh"; chmod -R g+rwX "$inv"
echo "Successfully Setup Software."; exit 0
