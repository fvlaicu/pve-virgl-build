#!/usr/bin/env bash
# Builds Proxmox's pve-qemu-kvm <VERSION> with 9999-virgl-video-get-drm-fd.patch, as
# <VERSION><SUFFIX>, against Debian's stock libvirglrenderer-dev 1.1.x. From build-qemu-only.sh
# (2026-10-13), one version per run.
# Runs as root in a throwaway debian:trixie container started by bin/build-one, with this repo at
# /infra (read-only), the keyrings at /keyrings (read-only) and the product's work directory at
# /work.
# Environment: VERSION (Proxmox's, e.g. 11.0.3-4), SUFFIX (virgl<N>), TRACK_SUITE, JOBS,
#   DEBFULLNAME, DEBEMAIL.
# Output in /work/out: pve-qemu-kvm{,-dbgsym}_<VERSION><SUFFIX>_amd64.deb (+ .buildinfo/.changes if
# made), pve-qemu-kvm_<VERSION><SUFFIX>.source.tar.zst (the corresponding source: QEMU is GPL-2.0
# and the debs are public), build.log, deb-info.txt, info.txt. /work/src/pve-qemu stays, so a
# rebuild on the same machine skips the clone.
set -euo pipefail
: "${VERSION:?}" "${SUFFIX:?}" "${TRACK_SUITE:?}" "${DEBFULLNAME:?}" "${DEBEMAIL:?}"
PATCH=/infra/patches/host/9999-virgl-video-get-drm-fd.patch
KEYRING=/usr/share/keyrings/proxmox-archive-keyring.gpg
OUT=/work/out
export DEBIAN_FRONTEND=noninteractive DEBFULLNAME DEBEMAIL
export DEB_BUILD_OPTIONS="parallel=${JOBS:-8} nocheck"

mkdir -p /work/src "$OUT"
exec > >(tee "$OUT/build.log") 2>&1

echo "===== apt: Debian $(cat /etc/debian_version), plus Proxmox $TRACK_SUITE only for libproxmox-backup-qemu0(-dev)"
cp /keyrings/proxmox-archive-keyring.gpg "$KEYRING"    # checked against build.conf's sha256 by bin/build-one
cat > /etc/apt/sources.list.d/proxmox.sources <<EOF
Types: deb
URIs: http://download.proxmox.com/debian/pve
Suites: trixie
Components: $TRACK_SUITE
Signed-By: $KEYRING
EOF
cat > /etc/apt/preferences.d/proxmox <<'EOF'
Package: *
Pin: origin download.proxmox.com
Pin-Priority: 1

Package: libproxmox-backup-qemu0 libproxmox-backup-qemu0-dev
Pin: origin download.proxmox.com
Pin-Priority: 500
EOF
apt-get update
apt-get install -y --no-install-recommends ca-certificates curl git devscripts equivs \
    build-essential lintian quilt zstd

echo "===== pve-qemu at 'bump version to $VERSION'"
cd /work/src
[[ -d pve-qemu ]] || git clone https://git.proxmox.com/git/pve-qemu.git
cd pve-qemu
git fetch -q origin
commit=$(git log --remotes --format=%H -1 --grep="^bump version to ${VERSION}\$")
[[ -n $commit ]] || { echo "no 'bump version to ${VERSION}' commit on any branch"; exit 1; }
git reset -q --hard
git checkout -q -f "$commit"
git clean -q -xdf                      # leaves the qemu submodule alone (no -ff)
git log -1 --format='%h %cd %s'
[[ $(dpkg-parsechangelog -SVersion) == "$VERSION" ]] || { echo "changelog is not $VERSION"; exit 1; }
# A previous version's meson subprojects would survive a submodule switch: clean them first.
git submodule foreach --quiet --recursive 'git clean -q -xdf' 2>/dev/null || true
git submodule update --init --recursive --force

echo "===== build dependencies"
mk-build-deps -ir -t 'apt-get -y --no-install-recommends' debian/control
rm -f pve-qemu-kvm-build-deps_*
v=$(dpkg-query -W -f='${Version}' libvirglrenderer-dev)
echo "libvirglrenderer-dev $v"
[[ $v == 1.1.* ]] || { echo "expected Debian trixie's 1.1.x, got $v"; exit 1; }
(cd qemu && meson subprojects download)   # the Makefile skips this once qemu/configure exists

echo "===== patch and version"
cp "$PATCH" debian/patches/extra/
echo "extra/$(basename "$PATCH")" >> debian/patches/series
dch -v "${VERSION}${SUFFIX}" -D trixie --force-distribution \
    "Enable virglrenderer's VA-API video (get_drm_fd callback, VIRGL_RENDERER_USE_VIDEO)."

echo "===== corresponding source: the tree as it is built (submodules, meson subprojects, our patch), without .git"
src=$OUT/pve-qemu-kvm_${VERSION}${SUFFIX}.source.tar.zst
tar --exclude-vcs -C /work/src -cf - pve-qemu | zstd -q -T0 -12 -o "$src"
ls -l "$src"

echo "===== build"
# git clean -xdfi in the Makefile is interactive; EOF on stdin makes it quit without deleting.
make deb </dev/null || echo "make exited non-zero (lintian runs last); checking for the debs"

deb=pve-qemu-kvm_${VERSION}${SUFFIX}_amd64.deb
[[ -f $deb ]] || { echo "no $deb"; exit 1; }
for f in pve-qemu-kvm*_"${VERSION}${SUFFIX}"_amd64.*; do cp -v "$f" "$OUT/"; done
{
    echo "pve_qemu_commit=$commit"
    echo "libvirglrenderer_dev=$v"
    echo "patch_sha256=$(sha256sum "$PATCH" | cut -d' ' -f1)"
} > "$OUT/info.txt"
{
    dpkg-deb -I "$deb" | grep -E 'Version|Depends'
    echo "--- patch applied in the build:"
    grep -E "9999-virgl-video" "$OUT/build.log" | head -5
} | tee "$OUT/deb-info.txt"
echo "===== done: $deb"
