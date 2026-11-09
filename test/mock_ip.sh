#!/bin/bash
# mock "ip" for the test container (iproute is not installed here)
ips=$(hostname -I 2>/dev/null)
case "$*" in
  "-o addr show"*|"-o addr"*) n=1; echo "1: lo    inet 127.0.0.1/8 scope host lo"; for a in $ips; do n=$((n+1)); echo "$n: eth0    inet $a/24 brd + scope global eth0"; done ;;
  "-o route get"*) echo "$4 via 0.0.0.0 dev eth0 src $(awk '{print $1}' <<< "$ips") uid 0" ;;
  *) exit 1 ;;
esac
