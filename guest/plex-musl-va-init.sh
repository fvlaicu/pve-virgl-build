#!/usr/bin/with-contenv bash
# shellcheck shell=bash
# Plex hardware transcoding through a musl Mesa VA driver (virgl in a VM, or radeonsi on AMD), for
# the linuxserver/plex container. LSIO runs it at every container start (custom-cont-init.d), after
# its own init, including Plex updates. It can also be run by hand (docker exec plex bash
# /custom-cont-init.d/90-plex-musl-va), then restart Plex.
# 1. The bundle (docs/DESIGN.md, "Plex"), checked for at every start. current.asc names the published
#    bundle; it is clearsigned with the repo key and checked with gpgv. A bundle not in the store
#    yet is downloaded, checked against the sha256 in current.asc, unpacked and made current. The
#    previous one stays; older ones go. On any failure (repo unreachable, bad signature, bad
#    checksum) the bundle already in use stays. An index older than the last one taken (its
#    Serial) is refused, so a replayed old index can't switch Plex back.
#    PLEX_VAAPI_BUNDLE=<name> holds that bundle from the store and fetches nothing (rollback).
# 2. Plex's bundled musl (1.2.2) lacks qsort_r, which Mesa needs: all of Plex runs on the bundle's
#    musl loader instead (1.2.5; musl keeps old binaries working). Plex's own copy is kept as .plex.
# 3. Plex points libva at its Cache/va-dri-linux-x86_64 (it overrides LIBVA_DRIVERS_PATH), so the
#    driver is linked in there. Its own libraries resolve through its RUNPATH, /vaapi/lib, and
#    /vaapi is a symlink to the current bundle.
#    /config persists, the container filesystem doesn't: the loader swap and /vaapi are redone at
#    every start; without a bundle, the script removes its own links so none point at nothing.
# Mounts (guest/compose-snippet.yml):
#   /opt/plex-vaapi/store:/vaapi-store                                 read-write: the bundles
#   /opt/plex-vaapi/pve-virgl.gpg:/etc/pve-virgl.gpg:ro         the repo's public key
#   /opt/plex-vaapi/plex-musl-va-init.sh:/custom-cont-init.d/90-plex-musl-va:ro   this script (root-owned)
# The older setup, an unpacked bundle mounted read-only at /vaapi, still works: it's used as is.
set -eu
STORE=/vaapi-store
KEYRING=/etc/pve-virgl.gpg
URL=${PLEX_VAAPI_URL:-https://fvlaicu.github.io/pve-virgl-build/files/plex-vaapi}   # build.conf's PAGES_URL + /files/plex-vaapi
HOLD=${PLEX_VAAPI_BUNDLE:-}
L=/usr/lib/plexmediaserver/lib
V=/vaapi/lib
D="${PLEX_MEDIA_SERVER_APPLICATION_SUPPORT_DIR:-/config/Library/Application Support}/Plex Media Server/Cache/va-dri-linux-x86_64"
say() { echo "**** plex-musl-va: $* ****"; }
why=""

name_ok() { [[ $1 =~ ^plex-vaapi_[A-Za-z0-9._+-]+$ ]]; }
current() { readlink "$STORE/current" 2>/dev/null || echo "no bundle"; }
set_current() { # name → $STORE/current points at it; the rename makes the switch atomic
    ln -sfn "$1" "$STORE/.current.new" && mv -Tf "$STORE/.current.new" "$STORE/current"
}

fetch_into() { # temp dir in the store → 0 if the published bundle is current now; else sets why
    local t=$1 serial name sha last prev keep d
    curl -fsSL --proto-redir =https --connect-timeout 5 --max-time 20 -o "$t/current.asc" "$URL/current.asc" 2>"$t/curl.log" \
        || { why="can't fetch $URL/current.asc: $(tail -n 1 "$t/curl.log")"; return 1; }
    # gpgv writes its --output even when the signature is BAD: only its exit status counts.
    gpgv --keyring "$KEYRING" --output "$t/index" "$t/current.asc" 2>"$t/gpgv.log" \
        || { why="current.asc: bad or unknown signature"; return 1; }
    serial=$(sed -n 's/^Serial: //p' "$t/index")
    name=$(sed -n 's/^Bundle: //p' "$t/index")
    sha=$(sed -n 's/^SHA256: //p' "$t/index")
    if ! [[ $serial =~ ^[0-9]{8}T[0-9]{6}Z$ && $sha =~ ^[0-9a-f]{64}$ ]] || ! name_ok "$name"; then
        why="current.asc: malformed"; return 1
    fi
    last=$(cat "$STORE/serial" 2>/dev/null || true)
    if [[ -n $last && $serial < $last ]]; then
        why="current.asc (serial $serial) is older than the last one taken ($last)"; return 1
    fi
    if [[ ! -d $STORE/$name/vaapi ]]; then
        say "downloading $name"
        curl -fsSL --proto-redir =https --connect-timeout 5 --max-time 600 -o "$t/b.tar.gz" "$URL/$name.tar.gz" 2>"$t/curl.log" \
            || { why="download of $name failed: $(tail -n 1 "$t/curl.log")"; return 1; }
        echo "$sha  $t/b.tar.gz" | sha256sum -c --quiet - >/dev/null 2>&1 || { why="$name: checksum mismatch"; return 1; }
        tar -tzf "$t/b.tar.gz" > "$t/list" 2>/dev/null || { why="$name: not a tarball"; return 1; }
        if grep -qvE '^vaapi(/|$)' "$t/list" || grep -qE '(^|/)\.\.(/|$)' "$t/list"; then
            why="$name: entries outside vaapi/"; return 1
        fi
        if ! { mkdir "$t/x" && tar -xzf "$t/b.tar.gz" -C "$t/x" --no-same-owner; }; then
            why="$name: unpacking failed"; return 1
        fi
        [[ -f $t/x/vaapi/lib/ld-musl-x86_64.so.1 && -f $t/x/vaapi/lib/dri/virtio_gpu_drv_video.so ]] \
            || { why="$name: incomplete"; return 1; }
        rm -rf "${STORE:?}/$name"
        mv "$t/x" "$STORE/$name" || { why="$name: can't move into the store"; return 1; }
    fi
    prev=$(readlink "$STORE/current" 2>/dev/null || true)
    set_current "$name" || { why="can't switch current to $name"; return 1; }
    echo "$serial" > "$STORE/serial"
    if [[ -n $prev && $prev != "$name" ]]; then
        echo "$prev" > "$STORE/previous"
        say "switched from $prev to $name"
    fi
    keep=$(cat "$STORE/previous" 2>/dev/null || true)
    for d in "$STORE"/plex-vaapi_*; do
        [[ -d $d ]] || continue
        [[ ${d##*/} == "$name" || ${d##*/} == "$keep" ]] || rm -rf "$d"
    done
}
fetch() {
    local t rc=0
    if ! command -v curl >/dev/null || ! command -v gpgv >/dev/null; then why="curl or gpgv missing in the image"; return 1; fi
    [[ -r $KEYRING ]] || { why="no key at $KEYRING"; return 1; }
    t=$(mktemp -d "$STORE/.fetch.XXXXXX") || { why="$STORE isn't writable"; return 1; }
    fetch_into "$t" || rc=$?
    rm -rf "$t"
    return "$rc"
}

use_bundle() { # → /vaapi points at a bundle; 1 if there is none
    if [[ -d /vaapi && ! -L /vaapi ]]; then
        say "using the bundle mounted at /vaapi"
        return 0
    fi
    [[ -d $STORE ]] || { say "no $STORE mount"; return 1; }
    rm -rf "$STORE"/.fetch.* "$STORE/.current.new"    # left by an interrupted start
    if [[ -n $HOLD ]]; then
        if name_ok "$HOLD" && [[ -d $STORE/$HOLD/vaapi ]]; then
            set_current "$HOLD"
            say "held at $HOLD (PLEX_VAAPI_BUNDLE), not checking for updates"
        else
            say "PLEX_VAAPI_BUNDLE=$HOLD isn't in the store; staying on $(current)"
        fi
    elif fetch; then
        say "bundle $(current) is current"
    else
        say "update check failed ($why); staying on $(current)"
    fi
    [[ -d $STORE/current/vaapi ]] || return 1
    ln -sfn "$STORE/current/vaapi" /vaapi
}

if ! use_bundle || [[ ! -f $V/ld-musl-x86_64.so.1 || ! -f $V/dri/virtio_gpu_drv_video.so ]]; then
    # /config persists: remove only this script's own links (symlinks into /vaapi), nothing else.
    for drv in virtio_gpu radeonsi; do
        f="$D/${drv}_drv_video.so"
        if [[ -L $f && $(readlink "$f") == /vaapi/* ]]; then rm -f "$f"; fi
    done
    say "no bundle, skipping (own driver links removed); Plex transcodes in software"
    exit 0
fi
if ! cmp -s "$V/ld-musl-x86_64.so.1" "$L/ld-musl-x86_64.so.1"; then
    [[ -e $L/ld-musl-x86_64.so.1.plex ]] || cp -a "$L/ld-musl-x86_64.so.1" "$L/ld-musl-x86_64.so.1.plex"
    cp "$V/ld-musl-x86_64.so.1" "$L/ld-musl-x86_64.so.1.new"
    chmod 755 "$L/ld-musl-x86_64.so.1.new"
    mv -f "$L/ld-musl-x86_64.so.1.new" "$L/ld-musl-x86_64.so.1"   # new inode: running processes keep the old one
    say "Plex now runs on the bundle's musl loader"
fi
mkdir -p "$D"
for drv in virtio_gpu radeonsi; do
    ln -sfn "$V/dri/${drv}_drv_video.so" "$D/${drv}_drv_video.so"
done
chown -h abc:abc "$D" "$D"/*_drv_video.so 2>/dev/null || true
say "VA drivers linked into $D"
