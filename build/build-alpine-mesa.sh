#!/bin/sh
# Builds Alpine's mesa from aports <ALPINE_BRANCH>-stable main/mesa with
# 9999-virgl-guest-video.patch, as <pkgver>-r<PKGREL> (Alpine's own is -r0 or so). Tests (check())
# are skipped; nothing else in the recipe changes. From build-alpine-mesa.sh (2026-10-16, r101),
# which used a hand-copied recipe.
# Runs as root in a throwaway alpine:<ALPINE_BRANCH> container started by bin/build-one, with this
# repo at /infra (read-only) and the product's work directory at /work.
# Environment: ALPINE_BRANCH, MESA_VERSION (the index's, e.g. 25.1.9-r0; the recipe must match it),
#   PKGREL (100 + N), APORTS_URL.
# Output in /work/out: the .apk files, build.log, info.txt (key=value), expected-apks.txt (abuild
# listpkg), expected-patches.txt (the recipe's patches in source order, ours last).
# Kept between runs: /work/src/aports (sparse clone), /work/cache (distfiles, apk cache).
# Exit 75: the recipe and the index disagree (aports is ahead of Alpine's builders); try again later.
set -eu
# shellcheck disable=SC3040  # busybox ash has pipefail
set -o pipefail
: "${ALPINE_BRANCH:?}" "${MESA_VERSION:?}" "${PKGREL:?}" "${APORTS_URL:?}"
PATCH=/infra/patches/guest/9999-virgl-guest-video.patch
P=${PATCH##*/}
OUT=/work/out
mkdir -p "$OUT" /work/src /work/cache/distfiles /work/cache/apk

main() {
    echo "===== Alpine $(cat /etc/alpine-release)"
    export SRCDEST=/work/cache/distfiles
    ln -sfn /work/cache/apk /etc/apk/cache
    apk update    # abuild installs the build dependencies with plain apk, which needs the index
    apk upgrade   # the image's own packages can be older than the index
    apk add alpine-sdk

    echo "===== recipe: aports $ALPINE_BRANCH-stable main/mesa"
    a=/work/src/aports
    if [ ! -d "$a/.git" ]; then
        rm -rf "$a"
        git clone -q --depth 1 --filter=blob:none --sparse -b "$ALPINE_BRANCH-stable" "$APORTS_URL" "$a"
        git -C "$a" sparse-checkout set main/mesa
    else
        git -C "$a" fetch -q --depth 1 origin "$ALPINE_BRANCH-stable"
        git -C "$a" checkout -q -f FETCH_HEAD
    fi
    commit=$(git -C "$a" rev-parse HEAD)
    git -C "$a" log -1 --format='aports %h %cd %s'
    rm -rf /tmp/build && mkdir -p /tmp/build/mesa && cd /tmp/build/mesa
    cp "$a"/main/mesa/* .
    pkgver=$(sed -n 's/^pkgver=//p' APKBUILD)
    pkgrel=$(sed -n 's/^pkgrel=//p' APKBUILD)
    if [ "$pkgver-r$pkgrel" != "$MESA_VERSION" ]; then
        echo "the recipe is $pkgver-r$pkgrel, the index has $MESA_VERSION: try again later"
        exit 75
    fi

    echo "===== Alpine's checksums, checked before anything changes"
    abuild -F fetch verify

    echo "===== our changes: pkgrel, the patch after Alpine's own, no test suite"
    cp "$PATCH" .
    sed -i "s/^pkgrel=$pkgrel\$/pkgrel=$PKGREL/" APKBUILD
    grep -qx "pkgrel=$PKGREL" APKBUILD
    # default_prepare applies the patches in $source order, so appending puts ours last.
    cat >> APKBUILD <<EOF

# pve-virgl-build: the virgl guest video patch, applied after Alpine's own; no test suite
source="\$source
	$P
	"
options="\$options !check"
EOF
    # Alpine's sources are verified above, so regenerating only adds the patch's checksum.
    abuild -F checksum
    # shellcheck disable=SC1091,SC2154  # the recipe, sourced in a subshell only to read $source
    ( set +u; . ./APKBUILD; for s in $source; do case $s in *.patch) echo "${s##*/}" ;; esac; done ) \
        > "$OUT/expected-patches.txt"
    [ "$(tail -n 1 "$OUT/expected-patches.txt")" = "$P" ] || { echo "$P is not the last patch"; exit 1; }
    abuild -F listpkg > "$OUT/expected-apks.txt"
    cat "$OUT/expected-patches.txt" "$OUT/expected-apks.txt"

    echo "===== signing key (throwaway: the apks are build input only, never published)"
    abuild-keygen -a -n
    cp -v /root/.abuild/*.rsa.pub /etc/apk/keys/    # abuild-keygen -i would need doas
    {
        echo "alpine_release=$(cat /etc/alpine-release)"
        echo "alpine_mesa=$MESA_VERSION"
        echo "aports_commit=$commit"
        echo "version=$pkgver-r$PKGREL"
        echo "patch=$P"
        echo "patch_sha256=$(sha256sum "$PATCH" | cut -d' ' -f1)"
    } > "$OUT/info.txt"

    echo "===== build"
    rc=0
    abuild -F -r || rc=$?
    echo "===== packages (copied even if a step after packaging failed; abuild exit $rc)"
    cp -v /root/packages/build/x86_64/*-"$pkgver-r$PKGREL".apk "$OUT/" || true
    [ "$rc" = 0 ] || exit "$rc"
    echo "===== done"
}

# Not inside || or if: set -e would be ignored in main. pipefail passes main's exit code on.
main 2>&1 | tee "$OUT/build.log"
