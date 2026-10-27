# shellcheck shell=bash
# shellcheck disable=SC2034  # the paths and settings are for the scripts that source this
# Shared by bin/*: settings, paths, logging, state files, version numbers, input tuples, Releases.
# Sourced, never run.
set -euo pipefail
export LC_ALL=C TZ=UTC
INFRA=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=../build.conf
. "$INFRA/build.conf"
REPO=${GITHUB_REPOSITORY:-$REPO}

# Everything a run writes is under BASE (gitignored). In GitHub Actions each job starts empty: the
# plan job's decisions and the builds reach later jobs as artifacts, the state as the state branch.
BASE=${VIRGL_BASE:-$INFRA/_run}
STATE=${VIRGL_STATE:-$BASE/state}   # checkout of the state branch (see "state files" below)
PLAN=$BASE/plan                     # the plan job's output: decisions, upstream
WORK=$BASE/work                     # one directory per product, mounted as /work in its build container
OUT=$BASE/out                       # finished builds: out/<product>/<version>/
SITE=$BASE/site                     # the Pages site, assembled by bin/site
KEYRINGS=$BASE/keyrings             # public keys only: Proxmox's, Debian's, ours (from node/)
LEDGER=$STATE/n-used                # every build number ever handed out, one line each
SITE_STATE=$STATE/site              # the signed small files of the site: apt dists/, current.asc
DISTS=$SITE_STATE/$APT_PATH/dists
BUNDLE_FILES=$SITE_STATE/files/plex-vaapi
# State files, tracked in the state branch: n-used, <product>.{published,last,rejected,ahead},
# bundles, bundle.MANIFEST, heartbeat, site/. Not tracked (.gitignore): /upstream, /run, /apt/.

PRODUCTS=(qemu virglrenderer mesa bundle)
# Of the debs each product builds, the ones published in the apt repo. -dev and the dbgsym
# packages stay in the product's Release.
declare -A PUBLISH_PKGS=([qemu]="pve-qemu-kvm" [virglrenderer]="libvirglrenderer1 virgl-server")
pkg_product() { # apt package → its product
    case $1 in
        pve-qemu-kvm) echo qemu ;;
        libvirglrenderer1|virgl-server) echo virglrenderer ;;
        *) die "pkg_product: $1 isn't one of ours" ;;
    esac
}

log() { printf '%s\n' "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }
gh_output() { [[ -z ${GITHUB_OUTPUT:-} ]] || printf '%s\n' "$@" >> "$GITHUB_OUTPUT"; }
gh_summary() { if [[ -n ${GITHUB_STEP_SUMMARY:-} ]]; then cat >> "$GITHUB_STEP_SUMMARY"; else cat > /dev/null; fi; }   # always reads stdin: pipefail

# --- state files: key=value lines; a value is everything after the first "="
kv_get() { # file key → the key's value, empty if the file or key is missing
    [[ -f $1 ]] || return 0
    awk -v k="$2" 'index($0, k "=") == 1 { v = substr($0, length(k) + 2) } END { print v }' "$1"
}
kv_set() { # file key value → sets one key, keeps the others
    { [[ ! -f $1 ]] || awk -v k="$2" 'index($0, k "=") != 1' "$1"; printf '%s=%s\n' "$2" "$3"; } > "$1.tmp"
    mv -f "$1.tmp" "$1"
}
kv_write() { # file key=value... → replaces the whole file
    local f=$1; shift
    printf '%s\n' "$@" > "$f.tmp"
    mv -f "$f.tmp" "$f"
}

hash_of() { cat "$@" | sha256sum | cut -c1-16; }

# --- Debian version order (dpkg's rules), for a handful of versions at a time
ver_max() { # versions on stdin → the highest
    local best='' v
    while IFS= read -r v; do
        [[ -n $v ]] || continue
        if [[ -z $best ]] || dpkg --compare-versions "$v" gt "$best"; then best=$v; fi
    done
    printf '%s\n' "$best"
}
ver_sort_desc() { # versions on stdin → highest first
    local -a in=() sorted=()
    local v i
    mapfile -t in < <(grep -v '^$' || true)
    for v in "${in[@]}"; do
        for i in "${!sorted[@]}"; do
            if dpkg --compare-versions "$v" gt "${sorted[i]}"; then
                sorted=("${sorted[@]:0:i}" "$v" "${sorted[@]:i}")
                continue 2
            fi
        done
        sorted+=("$v")
    done
    (( ${#sorted[@]} == 0 )) || printf '%s\n' "${sorted[@]}"
}

# --- build numbers. Debs: <base>virgl<N>. Mesa: <pkgver>-r<100+N>. Bundle: <prefix>_virgl<N>.
# N counts per base. bin/plan hands it out; bin/publish writes it to the ledger whatever the build's
# result, so a failed build's number isn't used again. Only a run cancelled before publish can see its
# number come up again, and such a build left no Release behind.
n_used() { # product base → the highest N handed out for this base, 0 if none
    { printf '%s\n' "$N_USED"; [[ ! -f $LEDGER ]] || cat "$LEDGER"; } |
        awk -v p="$1" -v b="$2" '$1 == p && $2 == b && $3 + 0 > max { max = $3 + 0 } END { print max + 0 }'
}
version_for() { # product base N → the version (the bundle's name) of that build
    case $1 in
        qemu|virglrenderer) echo "${2}virgl$3" ;;
        mesa) echo "$2-r$((100 + $3))" ;;
        bundle) echo "${2}_virgl$3" ;;
        *) die "version_for: unknown product $1" ;;
    esac
}
bundle_prefix() { echo "plex-vaapi_alpine${ALPINE_BRANCH}_mesa$1"; }   # Alpine's mesa version → the bundles' base

# --- input tuples. A product is rebuilt when its tuple differs from the published one and isn't
# rejected. Prints nothing when the inputs aren't known (an upstream check failed).
libs_hash() { # "name version" lines on stdin → one hash for the set
    sort -u | sha256sum | cut -c1-16
}
bundle_sources_key() { # BUNDLE_SOURCE_ORIGINS as one tuple word: gcc,elfutils,xz
    local -a origins
    read -ra origins <<<"$BUNDLE_SOURCE_ORIGINS"
    (IFS=,; echo "${origins[*]}")
}
licenses_key() { # what the bundle copies from the repo into vaapi/licenses/, as one hash
    (cd "$INFRA" && find licenses -mindepth 2 -type f -print0 | sort -z | xargs -0 sha256sum && sha256sum LICENSE) |
        sha256sum | cut -c1-16
}
tuple_of() { # product [Mesa version, for the bundle: default the published one] → its current input tuple
    local up=$STATE/upstream b mesa libs
    case $1 in
        qemu)
            b=$(kv_get "$up" qemu_base); [[ -n $b ]] || return 0
            echo "base=$b patch=$(hash_of "$INFRA/patches/host/9999-virgl-video-get-drm-fd.patch") script=$(hash_of "$INFRA/build/build-qemu.sh")" ;;
        virglrenderer)
            b=$(kv_get "$up" virglrenderer_base); [[ -n $b ]] || return 0
            echo "base=$b patch=$(hash_of "$INFRA/patches/host/9999-virgl-video-fixes.patch") script=$(hash_of "$INFRA/build/build-virglrenderer.sh")" ;;
        mesa)
            b=$(kv_get "$up" mesa_alpine); [[ -n $b ]] || return 0
            echo "alpine=$b patch=$(hash_of "$INFRA/patches/guest/9999-virgl-guest-video.patch") script=$(hash_of "$INFRA/build/build-alpine-mesa.sh")" ;;
        bundle)
            mesa=${2:-$(kv_get "$STATE/mesa.published" version)}; [[ -n $mesa ]] || return 0
            libs=$(kv_get "$up" bundle_libs)
            echo "mesa=$mesa libs=${libs:-unknown} script=$(hash_of "$INFRA/build/make-musl-va.sh") libva_minor=$PLEX_LIBVA_MINOR sources=$(bundle_sources_key) licenses=$(licenses_key)" ;;
        *) die "tuple_of: unknown product $1" ;;
    esac
}
why_unknown() { # product → why tuple_of printed nothing
    local e
    e=$(kv_get "$STATE/upstream" "${1}_error")
    if [[ -n $e ]]; then echo "$e"
    elif [[ $1 == bundle ]]; then echo "no verified Mesa build yet"
    else echo "no upstream check yet"
    fi
}

# --- the apt repo's packages: the state's Packages index is the list of what is published
packages_index() { # → the published Packages file's text, empty if nothing is published
    local d=$DISTS/$DIST/main/binary-amd64
    if [[ -f $d/Packages ]]; then cat "$d/Packages"
    elif [[ -f $d/Packages.gz ]]; then zcat "$d/Packages.gz"
    fi
}
window() { # → "package version filename" for every published deb
    packages_index | awk '
        /^Package: /  { p = $2 } /^Version: /  { v = $2 } /^Filename: / { f = $2 }
        /^$/ { if (p != "") print p, v, f; p = v = f = "" }
        END  { if (p != "") print p, v, f }'
}

# --- Releases: the archive, one per published build, tagged <product>/<version>. In GitHub Actions
# through gh; elsewhere (tests: VIRGL_RELEASES=<dir>) a directory per tag.
releases_local() { [[ -n ${VIRGL_RELEASES:-} ]]; }
release_exists() { # tag
    if releases_local; then [[ -d $VIRGL_RELEASES/$1 ]]
    else gh release view "$1" --repo "$REPO" --json tagName >/dev/null 2>&1
    fi
}
release_create() { # tag title notes-file file... → a new Release with these assets
    local tag=$1 title=$2 notes=$3
    shift 3
    if releases_local; then
        mkdir -p "$VIRGL_RELEASES/$tag"
        cp "$@" "$VIRGL_RELEASES/$tag/"
        printf '%s\n' "$title" > "$VIRGL_RELEASES/$tag/.title"
        cp "$notes" "$VIRGL_RELEASES/$tag/.notes"
    else
        gh release create "$tag" --repo "$REPO" --target "${GITHUB_SHA:?}" --title "$title" \
            --notes-file "$notes" --latest=false "$@" >/dev/null
    fi
}
release_get() { # tag asset dest → downloads one asset to dest (a file path)
    if releases_local; then
        cp "$VIRGL_RELEASES/$1/$2" "$3"
    else
        gh release download "$1" --repo "$REPO" --pattern "$2" --output "$3" --clobber
    fi
}
release_title() { # tag title → renames a Release (rollback marks its own)
    if releases_local; then printf '%s\n' "$2" > "$VIRGL_RELEASES/$1/.title"
    else gh release edit "$1" --repo "$REPO" --title "$2" >/dev/null
    fi
}

# --- keyrings
ensure_proxmox_keyring() { # downloads Proxmox's archive key once and checks it against build.conf
    local k=$KEYRINGS/proxmox-archive-keyring.gpg
    mkdir -p "$KEYRINGS"
    if [[ -f $k ]] && echo "$PROXMOX_KEYRING_SHA256  $k" | sha256sum -c --quiet - >/dev/null 2>&1; then return 0; fi
    curl -fsSL --max-time 60 "$PROXMOX_KEYRING_URL" -o "$k.tmp" || { log "download of the Proxmox keyring failed"; return 1; }
    if ! echo "$PROXMOX_KEYRING_SHA256  $k.tmp" | sha256sum -c --quiet - >/dev/null 2>&1; then
        rm -f "$k.tmp"
        log "Proxmox keyring: checksum mismatch against build.conf"
        return 1
    fi
    mv -f "$k.tmp" "$k"
}
DEBIAN_KEYRING=$KEYRINGS/debian-archive-keyring.pgp
ensure_debian_keyring() { # Debian's archive keyring from the debian:trixie image (Ubuntu's copy predates trixie's key)
    local k=$DEBIAN_KEYRING
    [[ ! -s $k ]] || return 0
    mkdir -p "$KEYRINGS"
    if podman run --rm "$IMAGE_DEBIAN" cat /usr/share/keyrings/debian-archive-keyring.pgp > "$k.tmp" 2>/dev/null && [[ -s $k.tmp ]]; then
        mv -f "$k.tmp" "$k"
    else
        rm -f "$k.tmp"
        log "can't read Debian's archive keyring from $IMAGE_DEBIAN"
        return 1
    fi
}
ensure_our_pubkey() { # node/pve-virgl.asc → KEYRINGS, after checking it is GPG_FPR's key
    local fpr
    [[ -n $GPG_FPR ]] || die "GPG_FPR is empty in build.conf (bin/make-key prints it)"
    [[ -f $INFRA/node/pve-virgl.asc ]] || die "no node/pve-virgl.asc (README, \"Signing key\")"
    fpr=$(gpg --batch --with-colons --show-keys "$INFRA/node/pve-virgl.asc" 2>/dev/null | awk -F: '/^fpr:/ { print $10; exit }')
    [[ $fpr == "$GPG_FPR" ]] || die "node/pve-virgl.asc is key ${fpr:-?}, build.conf says $GPG_FPR"
    mkdir -p "$KEYRINGS"
    cp "$INFRA/node/pve-virgl.asc" "$KEYRINGS/pve-virgl.asc"
}

# Private apt trees in $STATE/apt/<name>, separate from the runner's own apt: the lists of one
# repository each, for check-upstream. Every source line carries its own signed-by.
# The state branch's .gitignore: this run's upstream facts and run record, and check-upstream's apt
# trees. Anchored to the top: an unanchored apt/ also matched site/apt/, so the signed indexes were
# never committed. Written before every commit, so a branch with an older one is corrected.
state_gitignore() { printf '%s\n' /upstream /run /apt/ > "$STATE/.gitignore"; }
apt_tree_init() { # name sources.list-text
    local t=$STATE/apt/$1
    mkdir -p "$t/state/lists/partial" "$t/cache/archives/partial" "$t/sources.list.d" "$t/preferences.d"
    : > "$t/state/status"
    printf '%s\n' "$2" > "$t/sources.list"
}
apt_tree() { # name apt-get|apt-cache args... → runs it against that tree only
    local t=$STATE/apt/$1 cmd=$2
    shift 2
    "$cmd" -o Dir::State="$t/state" -o Dir::State::status="$t/state/status" -o Dir::Cache="$t/cache" \
        -o Dir::Etc::SourceList="$t/sources.list" -o Dir::Etc::SourceParts="$t/sources.list.d" \
        -o Dir::Etc::Preferences="$t/preferences" -o Dir::Etc::PreferencesParts="$t/preferences.d" \
        -o APT::Architecture=amd64 -o Acquire::Languages=none -o Debug::NoLocking=true "$@"
}
