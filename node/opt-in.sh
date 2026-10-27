#!/bin/bash
# Opts this Proxmox node in to the virgl builds (docs/DESIGN.md, "Nodes"): the repo's public key,
# the .sources (written from build.conf's PAGES_URL), the pin and the apt check, then the newest
# virgl builds of pve-qemu-kvm and
# libvirglrenderer1 (and virgl-server, if installed) by explicit version with --allow-downgrades.
# That also moves a node off the hand-built "+virglN" packages, which sort above the repo's
# "virglN" ones. Run as root on the node, from a checkout of the infra repo:
#   bash node/opt-in.sh          installs the repo files, runs apt update, shows what it would install
#   bash node/opt-in.sh --yes    the same, then installs
# Running VMs keep their QEMU until they restart; at the end it lists the virtio-gl ones.
set -euo pipefail
export LC_ALL=C
here=$(cd "$(dirname "$(readlink -f "$0")")" && pwd)
# shellcheck source=../build.conf
. "$here/../build.conf"
[[ $PAGES_URL != *CHANGE-ME* ]] || { echo "build.conf: PAGES_URL isn't set yet"; exit 1; }
yes=0
[[ ${1:-} != --yes ]] || yes=1
(( EUID == 0 )) || { echo "run as root"; exit 1; }
[[ -f $here/pve-virgl.asc ]] || { echo "no $here/pve-virgl.asc: it's committed after bin/make-key (README, \"Signing key\")"; exit 1; }
ours=$PAGES_URL/$APT_PATH   # madison lines from our repo start with it

newest() { # stdin: versions → the highest by dpkg's rules
    local best='' v
    while read -r v; do
        [[ -n $v ]] || continue
        if [[ -z $best ]] || dpkg --compare-versions "$v" gt "$best"; then best=$v; fi
    done
    echo "$best"
}
newest_ours() { apt-cache madison "$1" 2>/dev/null | awk -F' *[|] *' -v o="$ours " 'index($3, o) == 1 { print $2 }' | newest; }

echo "===== repo files"
install -d -m 0755 /etc/apt/keyrings
install -m 0644 "$here/pve-virgl.asc" /etc/apt/keyrings/pve-virgl.asc
cat > /etc/apt/sources.list.d/pve-virgl.sources <<SOURCES
Types: deb
URIs: $ours
Suites: $DIST
Components: main
Architectures: amd64
Signed-By: /etc/apt/keyrings/pve-virgl.asc
SOURCES
chmod 0644 /etc/apt/sources.list.d/pve-virgl.sources
install -m 0644 "$here/pve-virgl.pref" /etc/apt/preferences.d/pve-virgl.pref
install -m 0644 "$here/99pve-virgl-check" /etc/apt/apt.conf.d/99pve-virgl-check
install -m 0755 "$here/pve-virgl-check" /usr/local/sbin/pve-virgl-check
if command -v gpg >/dev/null; then
    echo "repo key: $(gpg --show-keys --with-colons /etc/apt/keyrings/pve-virgl.asc 2>/dev/null | awk -F: '/^fpr:/ { print $10; exit }')"
fi
apt-get update
apt-mark unhold pve-qemu-kvm libvirglrenderer1 virgl-server >/dev/null

pkgs=(pve-qemu-kvm libvirglrenderer1)
if [[ $(dpkg-query -W -f='${db:Status-Status}' virgl-server 2>/dev/null) == installed ]]; then pkgs+=(virgl-server); fi
args=()
for p in "${pkgs[@]}"; do
    v=$(newest_ours "$p")
    [[ -n $v ]] || { echo "the repo has no $p yet"; exit 1; }
    args+=("$p=$v")
done
# qemu-server refuses virtio-gl without libgl1 and libegl1; mesa-va-drivers is the host's VA driver.
args+=(libgl1 libegl1 mesa-va-drivers vainfo)
echo "===== install: ${args[*]}"
if (( ! yes )); then
    apt-get -s install --allow-downgrades "${args[@]}" | grep -E '^(Inst|Remv|Conf) ' || true
    echo "Nothing installed yet. To install: bash $0 --yes"
    exit 0
fi
apt-get install -y --allow-downgrades "${args[@]}"
kvm --version | head -n 1

if command -v qm >/dev/null; then
    for id in $(qm list 2>/dev/null | awk 'NR > 1 && $3 == "running" { print $1 }'); do
        if qm config "$id" | grep -q '^vga: .*virtio-gl'; then
            echo "VM $id uses virtio-gl and still runs the old QEMU: restart it, or reboot the node"
        fi
    done
fi
