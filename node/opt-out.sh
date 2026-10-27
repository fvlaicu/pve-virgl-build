#!/bin/bash
# Opts this Proxmox node out (docs/DESIGN.md, "Nodes"; e.g. a node moving to Intel): removes
# the repo files, the pin and the apt check, then installs Proxmox's and Debian's builds of
# pve-qemu-kvm, libvirglrenderer1 and virgl-server (those installed) by explicit version with
# --allow-downgrades, since ours sort above the stock version they're built on. Run as root:
#   bash node/opt-out.sh          shows what it would install; changes nothing
#   bash node/opt-out.sh --yes    removes the files, runs apt update, installs the stock versions
set -euo pipefail
export LC_ALL=C
yes=0
[[ ${1:-} != --yes ]] || yes=1
(( EUID == 0 )) || { echo "run as root"; exit 1; }
here=$(cd "$(dirname "$(readlink -f "$0")")" && pwd)
src=/etc/apt/sources.list.d/pve-virgl.sources
if [[ -f $src ]]; then
    ours=$(sed -n 's/^URIs: *//p' "$src" | head -n 1)   # madison lines from our repo start with it
else
    # shellcheck source=../build.conf
    . "$here/../build.conf"
    ours=$PAGES_URL/$APT_PATH
fi

newest() { # stdin: versions → the highest by dpkg's rules
    local best='' v
    while read -r v; do
        [[ -n $v ]] || continue
        if [[ -z $best ]] || dpkg --compare-versions "$v" gt "$best"; then best=$v; fi
    done
    echo "$best"
}
newest_stock() { apt-cache madison "$1" 2>/dev/null | awk -F' *[|] *' -v o="$ours " 'index($3, o) != 1 { print $2 }' | newest; }

pkgs=()
for p in pve-qemu-kvm libvirglrenderer1 virgl-server; do
    if [[ $(dpkg-query -W -f='${db:Status-Status}' "$p" 2>/dev/null) == installed ]]; then pkgs+=("$p"); fi
done
plan() {
    args=()
    for p in "${pkgs[@]}"; do
        v=$(newest_stock "$p")
        [[ -n $v ]] || { echo "no stock version of $p in the other sources"; exit 1; }
        args+=("$p=$v")
    done
    echo "===== install: ${args[*]}"
}

if (( ! yes )); then
    plan
    apt-get -s install --allow-downgrades "${args[@]}" | grep -E '^(Inst|Remv|Conf) ' || true
    echo "Nothing changed. To opt out: bash $0 --yes"
    exit 0
fi
echo "===== removing the repo files"
rm -fv /etc/apt/sources.list.d/pve-virgl.sources /etc/apt/preferences.d/pve-virgl.pref \
    /etc/apt/keyrings/pve-virgl.asc /etc/apt/apt.conf.d/99pve-virgl-check /usr/local/sbin/pve-virgl-check
apt-get update
apt-mark unhold "${pkgs[@]}" >/dev/null
plan
apt-get install -y --allow-downgrades "${args[@]}"
apt-cache policy "${pkgs[@]}"
echo "Running VMs keep their QEMU until they restart."
