#!/usr/bin/env bash
# Builds Debian's virglrenderer <VERSION> (trixie, trixie-updates or trixie-security) with
# 9999-virgl-video-fixes.patch, as <VERSION><SUFFIX>. From build-virglrenderer.sh (2026-10-16,
# which built 1.1.0-2+virgl5).
# Runs as root in a throwaway debian:trixie container started by bin/build-one, with this repo at
# /infra (read-only) and the product's work directory at /work.
# Environment: VERSION (Debian's, e.g. 1.1.0-2), SUFFIX (virgl<N>), JOBS, DEBFULLNAME, DEBEMAIL.
# Output in /work/out: the .debs (+ dbgsym, .buildinfo, .changes), Debian's source package (.dsc,
# orig and debian tarballs) and our patch (the source of the public debs), build.log,
# deb-info.txt, info.txt.
set -euo pipefail
: "${VERSION:?}" "${SUFFIX:?}" "${DEBFULLNAME:?}" "${DEBEMAIL:?}"
PATCH=/infra/patches/host/9999-virgl-video-fixes.patch
OUT=/work/out
export DEBIAN_FRONTEND=noninteractive DEBFULLNAME DEBEMAIL
export DEB_BUILD_OPTIONS="parallel=${JOBS:-8} nocheck"

mkdir -p "$OUT"
exec > >(tee "$OUT/build.log") 2>&1

echo "===== apt: Debian $(cat /etc/debian_version) with deb-src (the image lists trixie, trixie-updates, trixie-security)"
sed -i 's/^Types: deb$/Types: deb deb-src/' /etc/apt/sources.list.d/debian.sources
grep -E '^(Types|Suites):' /etc/apt/sources.list.d/debian.sources
apt-get update
apt-get install -y --no-install-recommends ca-certificates devscripts equivs build-essential \
    dpkg-dev quilt

echo "===== source virglrenderer $VERSION"
rm -rf /tmp/src && mkdir -p /tmp/src && cd /tmp/src
apt-get source "virglrenderer=$VERSION"
dirs=(virglrenderer-*/)
(( ${#dirs[@]} == 1 )) || { echo "expected one source directory, got: ${dirs[*]}"; exit 1; }
cp -v ./*.dsc ./*.orig.tar.* ./*.debian.tar.* "$PATCH" "$OUT/"
cd "${dirs[0]}"
[[ $(dpkg-parsechangelog -SVersion) == "$VERSION" ]] || { echo "changelog is not $VERSION"; exit 1; }
cat debian/source/format
grep -n -- '-Dvideo' debian/rules

echo "===== build dependencies"
mk-build-deps -ir -t 'apt-get -y --no-install-recommends' debian/control
rm -f virglrenderer-build-deps_*

echo "===== patch and version"
mkdir -p debian/patches
cp "$PATCH" debian/patches/
basename "$PATCH" >> debian/patches/series
cat debian/patches/series
dch -v "${VERSION}${SUFFIX}" -D trixie --force-distribution \
    "VA-API video fixes for virgl on AMD (9999-virgl-video-fixes.patch), local build."

echo "===== build"
dpkg-buildpackage -b -uc -us

cd ..
for f in ./*"_${VERSION}${SUFFIX}"_*; do cp -v "$f" "$OUT/"; done
echo "patch_sha256=$(sha256sum "$PATCH" | cut -d' ' -f1)" > "$OUT/info.txt"
{
    for d in ./*"_${VERSION}${SUFFIX}"_amd64.deb; do
        echo "--- $d"
        dpkg-deb -I "$d" | grep -E ' (Package|Version|Depends):'
    done
    echo "--- patches applied in the build:"
    grep -E "applying 9999-virgl-video-" "$OUT/build.log" | head -4
    echo "--- compiler warnings in the patched files:"
    grep -E "(virgl_video|vrend_video)\.[ch]:[0-9]+:[0-9]+: warning" "$OUT/build.log" | sort -u || echo "(none)"
} | tee "$OUT/deb-info.txt"
echo "===== done"
