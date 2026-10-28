#!/bin/bash
# Opts this Proxmox node out (docs/DESIGN.md, "Nodes"; e.g. a node moving to Intel): removes
# the repo files, the pin and the apt check, then installs Proxmox's and Debian's builds of
# pve-qemu-kvm, libvirglrenderer1 and virgl-server (those installed), the newest in the suites the
# builds follow (tracked_versions), by explicit version with --allow-downgrades, since ours sort
# above the stock version they're built on. Run as root:
#   bash node/opt-out.sh          shows what it would install; changes nothing
#   bash node/opt-out.sh --yes    removes the files, runs apt update, installs the stock versions
set -euo pipefail
export LC_ALL=C
yes=0
[[ ${1:-} != --yes ]] || yes=1
(( EUID == 0 )) || { echo "run as root"; exit 1; }
here=$(cd "$(dirname "$(readlink -f "$0")")" && pwd)
# shellcheck source=../build.conf
. "$here/../build.conf"

newest() { # stdin: versions → the highest by dpkg's rules
    local best='' v
    while read -r v; do
        [[ -n $v ]] || continue
        if [[ -z $best ]] || dpkg --compare-versions "$v" gt "$best"; then best=$v; fi
    done
    echo "$best"
}
# The versions of $1 in the suites the builds follow (bin/check-upstream): Proxmox's $DIST
# $TRACK_SUITE, and Debian's $DIST, $DIST-updates and $DIST-security (main). Matched by the Release
# fields apt-cache policy shows (origin, codename, component), not by the sources' suite names, so a
# mirror or "stable" in a sources file is still the same suite, and forky, sid or backports never
# counts as stock.
tracked_versions() {
    awk -v dist="$DIST" -v track="$TRACK_SUITE" '
        FILENAME == ARGV[1] {   # apt-cache policy: each index, then the Release fields it came from
            if ($0 == "Package files:") { files = 1; next }
            if (!files || $0 !~ /^ /) { files = 0; next }
            if ($1 == "release") rel[key] = substr($0, index($0, "release ") + 8)
            else if ($1 ~ /^-?[0-9]+$/) { key = $0; sub(/^ *-?[0-9]+ /, "", key) }
            next
        }
        # apt-cache policy <pkg>: "     <version> <prio>" (" *** " when installed), then its indexes
        /^ \*\*\* / { ver = $2; next }
        /^     [^ ]/ { ver = $1; next }
        /^      / {
            key = $0; sub(/^ *-?[0-9]+ /, "", key)
            o = ""; cn = ""; c = ""
            n = split(rel[key], f, ",")
            for (i = 1; i <= n; i++) {
                if (f[i] ~ /^o=/) o = substr(f[i], 3)
                else if (f[i] ~ /^n=/) cn = substr(f[i], 3)
                else if (f[i] ~ /^c=/) c = substr(f[i], 3)
            }
            if ((o == "Proxmox" && cn == dist && c == track) ||
                (o == "Debian" && c == "main" && (cn == dist || cn == dist "-updates" || cn == dist "-security"))) print ver
        }
    ' <(apt-cache policy 2>/dev/null) <(apt-cache policy "$1" 2>/dev/null)
}

pkgs=()
for p in pve-qemu-kvm libvirglrenderer1 virgl-server; do
    if [[ $(dpkg-query -W -f='${db:Status-Status}' "$p" 2>/dev/null) == installed ]]; then pkgs+=("$p"); fi
done
plan() {
    args=()
    for p in "${pkgs[@]}"; do
        v=$(tracked_versions "$p" | newest)
        [[ -n $v ]] || { echo "no $p in the suites the builds follow (Proxmox $DIST $TRACK_SUITE; Debian $DIST, $DIST-updates, $DIST-security) among this node's sources"; exit 1; }
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
