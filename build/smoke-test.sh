#!/usr/bin/env bash
# Smoke test of the staged apt snapshot, in a throwaway debian:trixie container started by
# bin/publish: aptly's staging tree at /staging, the keyrings ($KEYRINGS) at /keyrings, this repo at
# /infra (all read-only). Installs with the nodes' own pin (node/pve-virgl.pref), so it also
# shows that our builds win over Proxmox's and Debian's. No VM is started: that needs a GPU.
# Environment: EXPECT_QEMU, EXPECT_VIRGL (the newest versions in the snapshot; empty if none),
#   TRACK_SUITE.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
fail() { echo "SMOKE: FAIL: $*"; exit 1; }
installed() { dpkg-query -W -f='${Version}' "$1" 2>/dev/null || true; }

cat > /etc/apt/sources.list.d/proxmox.sources <<EOF
Types: deb
URIs: http://download.proxmox.com/debian/pve
Suites: trixie
Components: $TRACK_SUITE
Signed-By: /keyrings/proxmox-archive-keyring.gpg
EOF
cat > /etc/apt/sources.list.d/pve-virgl.sources <<'EOF'
Types: deb
URIs: file:/staging
Suites: trixie
Components: main
Signed-By: /keyrings/pve-virgl.asc
EOF
cp /infra/node/pve-virgl.pref /etc/apt/preferences.d/
apt-get update
apt-cache policy pve-qemu-kvm libvirglrenderer1 virgl-server

pkgs=()
[[ -z $EXPECT_VIRGL ]] || pkgs+=(libvirglrenderer1 virgl-server)
[[ -z $EXPECT_QEMU ]] || pkgs+=(pve-qemu-kvm)
(( ${#pkgs[@]} )) || fail "the snapshot has neither pve-qemu-kvm nor libvirglrenderer1"
apt-get install -y --no-install-recommends "${pkgs[@]}"

if [[ -n $EXPECT_VIRGL ]]; then
    [[ $(installed libvirglrenderer1) == "$EXPECT_VIRGL" ]] || fail "libvirglrenderer1 is $(installed libvirglrenderer1), expected $EXPECT_VIRGL"
    [[ $(installed virgl-server) == "$EXPECT_VIRGL" ]] || fail "virgl-server is $(installed virgl-server), expected $EXPECT_VIRGL"
    echo "ok    libvirglrenderer1 and virgl-server $EXPECT_VIRGL installed through the pin"
fi
if [[ -n $EXPECT_QEMU ]]; then
    [[ $(installed pve-qemu-kvm) == "$EXPECT_QEMU" ]] || fail "pve-qemu-kvm is $(installed pve-qemu-kvm), expected $EXPECT_QEMU"
    echo "ok    pve-qemu-kvm $EXPECT_QEMU installed through the pin"
    v=$(kvm --version | head -n 1)
    [[ $v == *"pve-qemu-kvm_$EXPECT_QEMU"* ]] || fail "kvm --version: $v"
    echo "ok    kvm --version: $v"
    qemu-system-x86_64 -device help | grep -q 'name "virtio-vga-gl"' || fail "kvm -device help lists no virtio-vga-gl"
    echo "ok    virtio-vga-gl is a device"
    lib=$(ldd /usr/bin/qemu-system-x86_64 | awk '$1 == "libvirglrenderer.so.1" { print $3 }')
    [[ -n $lib ]] || fail "QEMU doesn't link libvirglrenderer.so.1"
    owner=$(dpkg -S "$(readlink -f "$lib")" 2>/dev/null | cut -d: -f1)
    echo "ok    QEMU links $lib (package ${owner:-?} $(installed libvirglrenderer1))"
fi
echo "SMOKE: PASS"
