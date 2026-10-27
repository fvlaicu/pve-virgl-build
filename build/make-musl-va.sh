#!/bin/sh
# Builds the musl VA-API bundle for Plex, whose transcoder is built against musl and can't load the
# system's glibc Mesa drivers: our Mesa's VA driver (virtio_gpu for the virgl VM, and the same
# megadriver as radeonsi for an LXC on the real GPU), every library it needs, Alpine's libva and
# Alpine's musl loader. Same idea as jefflessard/plex-vaapi-amdgpu-mod (2023). From make-musl-va.sh
# (2026-10-16); new here: the MANIFEST names the package behind every file, and the init-symbol check.
# Runs as root in a throwaway alpine:<ALPINE_BRANCH> container started by bin/build-one, with this
# repo at /infra (read-only) and the product's work directory at /work.
# Environment: NAME (bundle name, e.g. plex-vaapi_alpine3.22_mesa25.1.9-r0_virgl3), MESA_APKS
#   (directory with our mesa-<v>.apk and mesa-va-gallium-<v>.apk, and the Mesa build's info.txt),
#   PLEX_LIBVA_MINOR, BUNDLE_SOURCE_ORIGINS, APORTS_URL, ALPINE_DISTFILES, REPO (build.conf).
# Output in /work/out: <NAME>.tar.gz (vaapi/lib/{dri/,*.so*}, vaapi/MANIFEST, vaapi/licenses/), MANIFEST, SOURCES
# (where the source of each Alpine package in the bundle is), source-<origin>-<version>.tar (the
# source of the copyleft ones, BUNDLE_SOURCE_ORIGINS), build.log.
set -eu
# shellcheck disable=SC3040  # busybox ash has pipefail
set -o pipefail
: "${NAME:?}" "${MESA_APKS:?}" "${PLEX_LIBVA_MINOR:?}" "${BUNDLE_SOURCE_ORIGINS?}" "${APORTS_URL:?}" "${ALPINE_DISTFILES:?}" "${REPO:?}"
OUT=/work/out
mkdir -p "$OUT"

main() {
    # Our mesa and mesa-va-gallium from the files, libva and patchelf from the index, in one
    # transaction. A second "apk add mesa-va-gallium" afterwards could swap in a newer Alpine build.
    set -- "$MESA_APKS"/mesa-[0-9]*.apk "$MESA_APKS"/mesa-va-gallium-[0-9]*.apk
    [ "$#" = 2 ] && [ -f "$1" ] && [ -f "$2" ] || { echo "expected one mesa and one mesa-va-gallium apk in $MESA_APKS"; exit 1; }
    # The image's own packages (musl, zlib, ...) can be older than the index: upgrade first, so the
    # bundle carries the index's versions, the ones the MANIFEST and check-upstream compare.
    apk upgrade --no-cache
    apk add --no-cache --allow-untrusted "$@" libva patchelf
    local_names=$(for f in "$@"; do basename "$f" .apk | sed 's/-[0-9][^-]*-r[0-9]*$//'; done)
    root=/tmp/bundle/vaapi
    rm -rf /tmp/bundle
    mkdir -p "$root/lib/dri"
    : > /tmp/sources    # "<path in the tarball> <file it was copied from>"

    # One Mesa megadriver under two names (hard link: the tarball stores it once).
    cp -L /usr/lib/dri/virtio_gpu_drv_video.so "$root/lib/dri/"
    ln -f "$root/lib/dri/virtio_gpu_drv_video.so" "$root/lib/dri/radeonsi_drv_video.so"
    echo "vaapi/lib/dri/virtio_gpu_drv_video.so /usr/lib/dri/virtio_gpu_drv_video.so" >> /tmp/sources
    echo "vaapi/lib/dri/radeonsi_drv_video.so /usr/lib/dri/virtio_gpu_drv_video.so" >> /tmp/sources
    # The driver finds its libraries in /vaapi/lib (absolute: Plex loads it through a symlink in its
    # Cache dir, and musl takes $ORIGIN from the path it was opened by), else next to it. musl
    # searches the RUNPATH of the module that needs a library and of its parents, so this covers
    # libLLVM's own dependencies too. Plex then needs only LIBVA_DRIVERS_PATH, no LD_LIBRARY_PATH
    # (which would break the container's glibc programs).
    # shellcheck disable=SC2016  # $ORIGIN is for the loader
    patchelf --set-rpath '/vaapi/lib:$ORIGIN/..' "$root/lib/dri/virtio_gpu_drv_video.so"
    # Every library the drivers and libva pull in (musl's loader lists them), except libc itself:
    # the loader Plex runs under is its own musl.
    for f in /usr/lib/dri/virtio_gpu_drv_video.so /usr/lib/dri/radeonsi_drv_video.so \
             /usr/lib/libva.so.2 /usr/lib/libva-drm.so.2; do
        /lib/ld-musl-x86_64.so.1 --list "$f" 2>/dev/null | awk '/=>/ {print $3}'
    done | sort -u | grep -v 'ld-musl\|libc.musl' | while read -r lib; do
        cp -L "$lib" "$root/lib/"
        echo "vaapi/lib/${lib##*/} $lib" >> /tmp/sources
    done
    for lib in /usr/lib/libva.so.2 /usr/lib/libva-drm.so.2; do
        cp -L "$lib" "$root/lib/"
        echo "vaapi/lib/${lib##*/} $lib" >> /tmp/sources
    done
    # Alpine's musl loader: Plex's bundled musl is older than 1.2.3 (no qsort_r, which Mesa needs),
    # so the transcoder has to run under this one.
    cp -L /lib/ld-musl-x86_64.so.1 "$root/lib/"
    echo "vaapi/lib/ld-musl-x86_64.so.1 /lib/ld-musl-x86_64.so.1" >> /tmp/sources

    # Check: through the RUNPATH alone (no LD_LIBRARY_PATH), every dependency resolves inside the bundle.
    echo "RUNPATH: $(patchelf --print-rpath "$root/lib/dri/virtio_gpu_drv_video.so")"
    /lib/ld-musl-x86_64.so.1 --list "$root/lib/dri/virtio_gpu_drv_video.so" 2>&1 | awk '/=>/ {print $3}' \
        | grep -v "^$root/lib/\|ld-musl" && { echo "^ resolved outside the bundle"; exit 1; }
    missing=0
    for f in "$root"/lib/dri/*.so "$root"/lib/*.so*; do
        out=$(LD_LIBRARY_PATH="$root/lib" /lib/ld-musl-x86_64.so.1 --list "$f" 2>&1) || true
        if echo "$out" | grep -q 'not found\|Error'; then
            echo "unresolved in $f:"; echo "$out" | grep 'not found\|Error'; missing=1
        fi
    done
    [ "$missing" = 0 ] || { echo "SOME DEPENDENCIES MISSING"; exit 1; }
    echo "all dependencies resolve inside the bundle"

    # Plex's libva looks for its own minor and lower ones only (libva 2.22.0 va.c:422-425), and
    # Mesa names the symbol after the libva it was built against.
    sym=$(grep -ao '__vaDriverInit_1_[0-9]*' "$root/lib/dri/virtio_gpu_drv_video.so" | sort -u)
    [ "$(echo "$sym" | wc -l)" = 1 ] || { echo "expected one VA init symbol, got: $sym"; exit 1; }
    [ "${sym##*_}" -le "$PLEX_LIBVA_MINOR" ] || { echo "$sym: Plex's libva 2.$PLEX_LIBVA_MINOR wouldn't load it"; exit 1; }

    # The package behind each file, from the file the copy followed (the drivers are symlinks to
    # /usr/lib/libgallium-<ver>.so, which the mesa package owns).
    awk '!seen[$1]++' /tmp/sources | while read -r path src; do
        real=$(readlink -f "$src")
        o=$(apk info --who-owns "$real" 2>/dev/null | sed -n 's/.* is owned by //p')
        [ -n "$o" ] || { echo "no package owns $real"; exit 1; }
        name=$(echo "$o" | sed 's/-[0-9][^-]*-r[0-9]*$//')
        where=index
        for l in $local_names; do [ "$l" = "$name" ] && where=local; done
        echo "$path $(wc -c < "/tmp/bundle/$path") $name ${o#"$name"-} $where"
    done > /tmp/owners
    mi=$MESA_APKS/info.txt
    {
        echo "bundle=$NAME"
        echo "built=$(date -u +%FT%TZ)"
        echo "alpine_release=$(cat /etc/alpine-release)"
        echo "mesa=$(sed -n 's/^version=//p' "$mi")"
        echo "alpine_mesa=$(sed -n 's/^alpine_mesa=//p' "$mi")"
        echo "aports_commit=$(sed -n 's/^aports_commit=//p' "$mi")"
        echo "guest_patch=$(sed -n 's/^patch=//p' "$mi")"
        echo "guest_patch_sha256=$(sed -n 's/^patch_sha256=//p' "$mi")"
        echo "plex_libva_minor=$PLEX_LIBVA_MINOR"
        echo "va_init_symbol=$sym"
        echo "runpath=$(patchelf --print-rpath "$root/lib/dri/virtio_gpu_drv_video.so")"
        echo "# owner <package> <version> <index|local>: the packages the files come from"
        awk '{ print "owner", $3, $4, $5 }' /tmp/owners | sort -u
        echo "# file <size> <path> <package>-<version>"
        awk '{ print "file", $2, $1, $3 "-" $4 }' /tmp/owners | sort -k3
    } > "$root/MANIFEST"
    cp "$root/MANIFEST" "$OUT/MANIFEST"
    # SOURCES: each package's origin, version, license and the aports commit it was built from, out
    # of apk's database of installed packages (fields P, V, o, L, c).
    {
        echo "# Sources of the Alpine $(cat /etc/alpine-release) packages in $NAME."
        echo "# Each package's recipe is in aports at its commit, under main/<origin> or community/<origin>:"
        echo "#   https://git.alpinelinux.org/aports/tree/main/<origin>?id=<commit> (or community/<origin>)"
        echo "# and the upstream source files are on Alpine's distfiles mirror:"
        echo "#   https://distfiles.alpinelinux.org/distfiles/v$(cut -d. -f1,2 /etc/alpine-release)/"
        echo "# Our Mesa (local) is aports $(sed -n 's/^aports_commit=//p' "$mi") main/mesa plus $(sed -n 's/^patch=//p' "$mi") from this repo."
        echo "# The copyleft packages' source is attached to this Release, as source-<origin>-<version>.tar:"
        echo "#   their aports directory at the commit and the upstream files, checked against the APKBUILD."
        echo "# <package> <version> origin=<origin> commit=<aports commit> license=<license>"
        awk '{ print $3 }' /tmp/owners | sort -u | while read -r n; do
            awk -v n="$n" 'BEGIN { RS = ""; FS = "\n" }
                { delete f; for (i = 1; i <= NF; i++) f[substr($i, 1, 1)] = substr($i, 3)
                  if (f["P"] == n) { printf "%s %s origin=%s commit=%s license=%s\n", f["P"], f["V"], f["o"], f["c"] == "" ? "-" : f["c"], f["L"]; exit } }' \
                /lib/apk/db/installed
        done
    } > "$OUT/SOURCES"
    [ "$(grep -vc '^#' "$OUT/SOURCES")" = "$(awk '{ print $3 }' /tmp/owners | sort -u | wc -l)" ] || { echo "SOURCES misses a package"; exit 1; }
    licenses
    tar -C /tmp/bundle -czf "$OUT/$NAME.tar.gz" vaapi
    sources
    head -n 12 "$OUT/MANIFEST"
    du -sh "$OUT/$NAME.tar.gz"
}

# License texts into vaapi/licenses/: each library's, collected once into the repo's licenses/<origin>/
# (bin/collect-licenses, licenses/collect-all.sh), and a README saying which is which. A library
# without them stops the build.
licenses() {
    mkdir -p "$root/licenses"
    awk '!/^#/ { sub(/^origin=/, "", $3); print $3 }' "$OUT/SOURCES" | sort -u > /tmp/origins
    while read -r o; do
        [ -f "/infra/licenses/$o/FROM" ] || { echo "no license texts for $o in the repo's licenses/: bin/collect-licenses get $o ..."; exit 1; }
        cp -R "/infra/licenses/$o" "$root/licenses/"
    done < /tmp/origins
    cp /infra/LICENSE "$root/licenses/pve-virgl-build.LICENSE"
    {
        echo "License texts of the libraries in $NAME, each from its upstream source"
        echo "(<origin>/FROM says which file of which version)."
        echo
        echo "  <package> <version> <origin>/ (<license, as Alpine's index has it>)"
        awk '!/^#/ { o = $3; sub(/^origin=/, "", o); l = $0; sub(/^.* license=/, "", l)
                     printf "  %s %s %s/ (%s)\n", $1, $2, o, l }' "$OUT/SOURCES"
        echo
        echo "Mesa here carries 9999-virgl-guest-video.patch from https://github.com/$REPO,"
        echo "under GPL-2.0-or-later: pve-virgl-build.LICENSE."
        echo "The source: this bundle's Release, https://github.com/$REPO/releases/tag/bundle/$NAME"
        echo "(SOURCES for every library, and the copyleft ones' source as source-<origin>-<version>.tar)."
    } > "$root/licenses/README"
    echo "licenses: $(find "$root/licenses" -type f | wc -l) files for $(find "$root/licenses" -mindepth 1 -maxdepth 1 -type d | wc -l) origins"
}

# The source of the copyleft packages in the bundle (BUNDLE_SOURCE_ORIGINS): per origin, one tar with
# SOURCE-INFO, its aports directory at the commit its packages were built from, and the upstream files
# its APKBUILD's sha512sums name, from Alpine's distfiles mirror, each checked against those sums.
# bin/verify checks them again. Runs after the bundle and SOURCES are written, so the git and curl
# it installs can't change them.
sources() {
    apk add --no-cache git curl > /dev/null
    for origin in $BUNDLE_SOURCE_ORIGINS; do
        # "<version> <commit>" of the origin's packages in the bundle: none, or exactly one
        vc=$(awk -v o="origin=$origin" '$3 == o { sub(/^commit=/, "", $4); print $2, $4 }' "$OUT/SOURCES" | sort -u)
        [ -n "$vc" ] || { echo "source $origin: no package of it in the bundle"; continue; }
        [ "$(echo "$vc" | wc -l)" = 1 ] || { echo "source $origin: its packages differ in version or commit: $vc"; exit 1; }
        version=${vc% *} commit=${vc#* }
        s=/tmp/src/$origin
        rm -rf "$s"
        mkdir -p "$s/aports" "$s/distfiles"
        git -C "$s/aports" init -q
        git -C "$s/aports" fetch -q --depth 1 "$APORTS_URL" "$commit"
        git -C "$s/aports" sparse-checkout set --no-cone "/main/$origin/" "/community/$origin/"
        git -C "$s/aports" checkout -q FETCH_HEAD
        rm -rf "$s/aports/.git"
        set -- "$s"/aports/*/"$origin"/APKBUILD
        [ "$#" = 1 ] && [ -f "$1" ] || { echo "source $origin: not one APKBUILD at aports $commit"; exit 1; }
        dir=${1%/APKBUILD}
        apkbuild_sums "$dir/APKBUILD" > "$s/sums"
        [ -s "$s/sums" ] || { echo "source $origin: no sha512sums in its APKBUILD"; exit 1; }
        # Local files are in the aports directory; the others are upstream's, from the mirror.
        while read -r sum f; do
            case $f in */*|.*|'') echo "source $origin: odd file name '$f' in sha512sums"; exit 1 ;; esac
            if [ -f "$dir/$f" ]; then p=$dir/$f
            else
                p=$s/distfiles/$f
                curl -fsSL --retry 3 -o "$p" "$ALPINE_DISTFILES/$f" || { echo "source $origin: can't download $ALPINE_DISTFILES/$f"; exit 1; }
            fi
            [ "$(sha512sum "$p" | cut -d' ' -f1)" = "$sum" ] || { echo "source $origin: $f doesn't match the APKBUILD's sha512sums"; exit 1; }
        done < "$s/sums"
        rm "$s/sums"
        {
            echo "origin=$origin"
            echo "version=$version"
            echo "aports_commit=$commit"
            echo "aports_dir=${dir#"$s/aports/"}"
            echo "aports_url=$APORTS_URL"
            echo "distfiles_url=$ALPINE_DISTFILES"
        } > "$s/SOURCE-INFO"
        tar -C "$s" -cf "$OUT/source-$origin-$version.tar" SOURCE-INFO aports distfiles
        echo "source $origin $version: aports $(echo "$commit" | cut -c1-12), $(find "$s/distfiles" -type f | wc -l) upstream files, $(du -h "$OUT/source-$origin-$version.tar" | cut -f1)"
    done
}
apkbuild_sums() { # APKBUILD → "<sha512> <file>" for each entry of its sha512sums="..."
    awk '/^sha512sums="/ { on = 1; sub(/^sha512sums="/, "") }
         on { last = sub(/".*$/, ""); if (NF == 2) print $1, $2; if (last) exit }' "$1"
}

# Not inside || or if: set -e would be ignored in main. pipefail passes main's exit code on.
main 2>&1 | tee "$OUT/build.log"
