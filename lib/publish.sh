# shellcheck shell=bash
# Publishing, for bin/publish and bin/rollback (the jobs that hold the key). Sourced after
# lib/common.sh.
# The apt repo has no persistent aptly database: what is published is the state's signed Packages
# index. Each change downloads the published debs from their Releases into a fresh aptly, adds or
# removes builds, snapshots, publishes the snapshot to staging (smoke test) and to $APT_PATH, and
# puts the new dists/ into the state. bin/site later assembles the served tree from dists/ and the
# Releases.

APTLY_ROOT=$BASE/aptly
aptly() { command aptly -config="$BASE/aptly.conf" "$@"; }

need_key() { # the signing key is in $GNUPGHOME and is the one the nodes trust
    [[ -n ${GNUPGHOME:-} ]] || die "GNUPGHOME isn't set (the job imports the key there)"
    ensure_our_pubkey
    gpg --batch --list-secret-keys "$GPG_FPR" >/dev/null 2>&1 || die "no secret key $GPG_FPR in $GNUPGHOME"
}

aptly_init() { # a fresh, empty aptly under $BASE/aptly
    rm -rf "$APTLY_ROOT"
    mkdir -p "$APTLY_ROOT"
    cat > "$BASE/aptly.conf" <<EOF
{
  "rootDir": "$APTLY_ROOT",
  "architectures": ["amd64"],
  "gpgProvider": "gpg",
  "gpgDisableSign": false,
  "gpgDisableVerify": false,
  "downloadSourcePackages": false,
  "skipContentsPublishing": true,
  "dependencyFollowSuggests": false,
  "dependencyFollowRecommends": false,
  "dependencyFollowAllVariants": false,
  "dependencyFollowSource": false
}
EOF
}

fetch_window() { # dest [product version to leave out] → the published debs, downloaded from their Releases
    local dest=$1 skip=${2:-}/${3:-} pkg v f prod
    rm -rf "$dest"   # exactly the window: nothing left from an earlier publish in the same $BASE
    mkdir -p "$dest"
    while read -r pkg v f; do
        prod=$(pkg_product "$pkg")
        [[ $prod/$v != "$skip" ]] || continue
        release_get "$prod/$v" "${f##*/}" "$dest/${f##*/}" || die "can't download ${f##*/} from Release $prod/$v"
    done < <(window)
    # Each product's published version belongs in the repo even when the previous index doesn't
    # list it (run 40555460436: the state had lost its index, and pve-qemu-kvm fell out). A rollback
    # leaves out the version it takes back: that's the published one until it finishes.
    for prod in "${!PUBLISH_PKGS[@]}"; do
        v=$(kv_get "$STATE/$prod.published" version)
        [[ -n $v && $prod/$v != "$skip" ]] || continue
        for pkg in ${PUBLISH_PKGS[$prod]}; do
            f=${pkg}_${v}_amd64.deb
            [[ ! -f $dest/$f ]] || continue
            release_get "$prod/$v" "$f" "$dest/$f" || die "can't download $f from Release $prod/$v"
            log "[publish] $prod $v is published but the apt index didn't list $pkg: added from its Release"
        done
    done
}

cand_prune() { # keeps the newest $KEEP versions of each package in the repo cand
    local pkg v n
    for pkg in $(aptly repo search -format='{{.Package}}' cand 2>/dev/null | sort -u); do
        n=0
        while read -r v; do
            n=$((n + 1))
            if (( n > KEEP )); then aptly repo remove cand "$pkg (= $v)"; fi
        done < <(aptly repo search -format='{{.Version}}' cand "$pkg" 2>/dev/null | ver_sort_desc)
    done
}
snapshot_of() { # deb... → SNAP: a snapshot of exactly these debs, pruned to KEEP versions per package
    aptly repo create -distribution="$DIST" -component=main cand >/dev/null
    (( $# == 0 )) || aptly repo add cand "$@" >/dev/null
    cand_prune
    SNAP=virgl-$(date -u +%Y%m%dT%H%M%SZ)
    aptly snapshot create "$SNAP" from repo cand >/dev/null
    log "[publish] $SNAP: $(aptly snapshot search -format='{{.Package}} {{.Version}}' "$SNAP" 2>/dev/null | sort | paste -sd',' | sed 's/,/, /g')"
}
newest_in() { # snapshot package → its highest version in the snapshot, empty if none
    { aptly snapshot search -format='{{.Version}}' "$1" "$2" 2>/dev/null || true; } | ver_max
}
publish_snap() { # prefix snapshot → signed, by-hash indexes in $APTLY_ROOT/public/<prefix>
    aptly publish snapshot -batch -gpg-key="$GPG_FPR" -distribution="$DIST" -component=main \
        -origin="$ORIGIN" -label="$ORIGIN" -acquire-by-hash -skip-contents "$2" "$1" >/dev/null
}

# Smoke test of the snapshot published at staging, in a clean debian:trixie container with the
# nodes' own pin (build/smoke-test.sh). The container reads staging from disk and gets only the
# public key.
smoke() { # snapshot
    local q l
    q=$(newest_in "$1" pve-qemu-kvm)
    l=$(newest_in "$1" libvirglrenderer1)
    ensure_proxmox_keyring || return 1
    podman run --rm --security-opt label=disable \
        -v "$APTLY_ROOT/public/$STAGING_PREFIX":/staging:ro -v "$KEYRINGS":/keyrings:ro -v "$INFRA":/infra:ro \
        -e EXPECT_QEMU="$q" -e EXPECT_VIRGL="$l" -e TRACK_SUITE="$TRACK_SUITE" \
        "$IMAGE_DEBIAN" bash /infra/build/smoke-test.sh
}

# Pages caches for 10 minutes, so for a while a node can get the previous InRelease. The new
# dists/ therefore keeps the previous generation's index files under by-hash/: those the live
# InRelease names. Older generations drop out, because only the live InRelease's are carried.
carry_by_hash() { # old dists/ new dists/
    local old=$1 new=$2 rel f h
    rel=$old/$DIST/InRelease
    [[ -f $rel ]] || return 0
    while IFS= read -r f; do
        h=${f##*/}
        grep -qF " $h " "$rel" || continue
        [[ -e $new/${f#"$old"/} ]] && continue
        mkdir -p "$(dirname "$new/${f#"$old"/}")"
        cp -a "$f" "$new/${f#"$old"/}"
    done < <(find "$old" -path '*/by-hash/*' -type f)
}
install_dists() { # → $APTLY_ROOT/public/$APT_PATH/dists, with the carried by-hash files, becomes the state's dists/
    local new=$APTLY_ROOT/public/$APT_PATH/dists
    [[ ! -d $DISTS ]] || carry_by_hash "$DISTS" "$new"
    rm -rf "$DISTS.new"
    mkdir -p "$(dirname "$DISTS")"
    cp -a "$new" "$DISTS.new"
    # aptly's by-hash/<algorithm>/<index> links point into this runner's aptly root, which no other
    # job has (the site job's upload follows links and fails on them). apt only asks for
    # by-hash/<algorithm>/<hash>, so these go; any other link stops the publish.
    find "$DISTS.new" -type l -path '*/by-hash/*' \( -name Packages -o -name Packages.gz -o -name Packages.bz2 -o -name Release \) -delete
    if [[ -n $(find "$DISTS.new" -type l) ]]; then die "links left in dists/: $(find "$DISTS.new" -type l | head -n 3)"; fi
    rm -rf "$DISTS"
    mv "$DISTS.new" "$DISTS"
}

# --- the bundle. current.asc is one clearsigned file, so swapping it is atomic:
#   Serial: <UTC, never goes backwards>   the Plex VM refuses an index older than the last it took
#   Bundle: <name>                        <name>.tar.gz next to it
#   SHA256: <hex>
#   Size: <bytes>
# $STATE/bundles lists the published bundles, oldest first: "<name> <sha256> <size>". SHA256SUMS
# lists them for people; the Plex VM reads only current.asc.
bundle_list() { [[ ! -f $STATE/bundles ]] || cat "$STATE/bundles"; }
bundle_list_set() { # lines on stdin → the new list
    cat > "$STATE/bundles.tmp"
    mv -f "$STATE/bundles.tmp" "$STATE/bundles"
}
bundle_index() { # bundle name → current.asc naming it, with a new serial; SHA256SUMS
    local name=$1 sha size
    read -r _ sha size < <(awk -v n="$name" '$1 == n' "$STATE/bundles")
    [[ -n ${sha:-} ]] || die "$name isn't in $STATE/bundles"
    mkdir -p "$BUNDLE_FILES"
    printf 'Serial: %s\nBundle: %s\nSHA256: %s\nSize: %s\n' "$(date -u +%Y%m%dT%H%M%SZ)" "$name" "$sha" "$size" > "$BASE/current"
    gpg --batch --yes --local-user "$GPG_FPR" --clearsign -o "$BUNDLE_FILES/current.asc.new" "$BASE/current"
    mv -f "$BUNDLE_FILES/current.asc.new" "$BUNDLE_FILES/current.asc"
    awk '{ print $2 "  " $1 ".tar.gz" }' "$STATE/bundles" > "$BUNDLE_FILES/SHA256SUMS"
}

release_notes() { # product version dir → notes for its Release, on stdout
    local p=$1 v=$2 d=$3
    echo "Built by run $(cat "$d/run" 2>/dev/null || echo ?) from \`${GITHUB_SHA:-local}\`."
    echo
    echo "Inputs: \`$(cat "$d/tuple")\`"
    echo
    echo '```'
    if [[ -f $d/deb-info.txt ]]; then cat "$d/deb-info.txt"; fi
    if [[ -f $d/info.txt ]]; then cat "$d/info.txt"; fi
    if [[ $p == bundle ]]; then head -n 12 "$d/MANIFEST"; fi
    cat "$d/verify-publish.txt" 2>/dev/null || cat "$d/verify.txt"
    echo '```'
    case $p in
        qemu) echo; echo "Corresponding source: \`pve-qemu-kvm_${v}.source.tar.zst\` (the pve-qemu tree as built, with submodules, meson subprojects and our patch)." ;;
        virglrenderer) echo; echo "Source: Debian's source package (\`.dsc\`, orig and debian tarballs) and \`9999-virgl-video-fixes.patch\`." ;;
        bundle) echo; echo "Sources of the Alpine packages in the bundle: \`SOURCES\`. The copyleft ones' source is attached: \`source-<origin>-<version>.tar\` (their aports directory and upstream files)." ;;
    esac
}
