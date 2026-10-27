#!/usr/bin/env bash
# Local test steps, run inside the test container by test/local.sh: /src is this repo (read-only),
# /t the test dir. The steps run the real scripts against a copy of the repo (/t/repo) with a
# throwaway key; Releases are a directory (/t/releases) and a site that bin/site assembles is
# "deployed" by copying it to /t/live (the previous one is kept as /t/live.<n>).
#   setup                      the copy of the repo, the test key, test settings in build.conf
#   run [virgl-build args]     one workflow run: plan, builds, publish, site (bin/virgl-build)
#   expect <product> <version> the state says <version> is published
#   apt                        a debian:trixie node with the pin installs our debs from /t/live
#   byhash                     apt update against /t/live with the previous deploy's InRelease
#   plex                       the Plex init script against /t/live: fetch, restart, tampered index,
#                              replayed older index, corrupt tarball, unreachable, hold
#   node                       the nodes' apt check: stale and fresh status.json
#   sources                    the published bundle's Release has its copyleft sources and the bundle
#                              its license texts; verify fails on a changed file, a missing tar, an
#                              unreviewed license, a symlink, a library without license texts
#   rollback <product> <version>   bin/rollback, then the site (deploy forced)
#   site                       bin/site --deploy on the current state (as the site job), then deploy
#   committed                  the state as the next job sees it: a fresh clone of the pushed state
#                              branch has every file of the local state except the three ignored ones
#   fresh-job <product>        one build as a GitHub job runs it: its own empty _run with only the
#                              state and its plan (bin/plan --force), nothing left by other builds
#   break <patch|mesa-patch|smoke>, unbreak <...>   make the virglrenderer patch, the Mesa patch or
#                              the smoke test fail
#   inputs change|restore      a comment appended to build/build-virglrenderer.sh: new inputs that
#                              build as before (for a rollback of a build whose inputs differ)
#   held <product>             after such a rollback: the next plan doesn't build the rejected inputs
#                              again, and the deployed status says "held"
#   aports-mirror              take aports from Alpine's GitHub mirror (when GitLab is unreachable)
# shellcheck disable=SC2015,SC2016  # pass only echoes; the container scripts are single-quoted on purpose
set -euo pipefail
T=/t
R=$T/repo
export VIRGL_BASE=$T/run VIRGL_RELEASES=$T/releases VIRGL_LIVE_URL=file://$T/live GNUPGHOME=$T/key/gnupg
pass() { echo "PASS  $*"; }
fail() { echo "FAIL  $*"; exit 1; }
kv() { awk -v k="$2" 'index($0, k "=") == 1 { v = substr($0, length(k) + 2) } END { print v }' "$1" 2>/dev/null; }
deb() { # the nested debian:trixie container: the live site at /live, keyrings at /keyrings, the repo at /repo
    podman run --rm --security-opt label=disable -v "$T":/t:ro -v "$T/live":/live:ro -v "$VIRGL_BASE/keyrings":/keyrings:ro \
        -v "$R":/repo:ro "$@"
}
deploy() {
    [[ -d $VIRGL_BASE/site ]] || { echo "(site unchanged, not deployed)"; return 0; }
    local n
    n=$(find "$T" -maxdepth 1 -name 'live.*' | wc -l)
    if [[ -d $T/live ]]; then mv "$T/live" "$T/live.$n"; fi
    cp -a "$VIRGL_BASE/site" "$T/live"
    echo "deployed to /t/live$( [[ -d $T/live.$n ]] && echo ", previous kept as /t/live.$n" || true)"
}

step=${1:?step}
shift
case $step in
setup)
    rm -rf "$R"
    mkdir -p "$R" "$T/releases"
    (cd /src && tar --exclude=./_run -cf - .) | (cd "$R" && tar -xf -)
    live=$(. "$R/build.conf" && echo "$PAGES_URL")
    sed -i -e 's|^REPO=.*|REPO=test/pve-virgl-build|' -e "s|^PAGES_URL=.*|PAGES_URL=file://$T/live|" \
        -e 's|^DEBEMAIL=.*|DEBEMAIL=virgl-test@example.invalid|' "$R/build.conf"
    sed -i "s|$live/files/plex-vaapi|file://$T/live/files/plex-vaapi|" "$R/guest/plex-musl-va-init.sh"
    grep -qF "file://$T/live/files/plex-vaapi" "$R/guest/plex-musl-va-init.sh"
    [[ -d $T/key ]] || "$R/bin/make-key" "$T/key" | grep fingerprint
    fpr=$(gpg --batch --with-colons --show-keys "$T/key/pve-virgl.asc" | awk -F: '/^fpr:/ { print $10; exit }')
    sed -i "s|^GPG_FPR=.*|GPG_FPR=$fpr|" "$R/build.conf"
    cp "$T/key/pve-virgl.asc" "$R/node/"
    cp "$T/key/pve-virgl.gpg" "$R/guest/"
    (cd "$R" && make -s check-config)
    # The state as a checkout of a "state" branch, pushed to a local bare repo, so bin/state-commit
    # commits and pushes as on GitHub (and the committed step can see what git leaves out).
    if [[ ! -d $VIRGL_BASE/state/.git ]]; then
        mkdir -p "$VIRGL_BASE/state"
        rm -rf "$T/state.git"
        git init -q --bare "$T/state.git"
        git -C "$VIRGL_BASE/state" init -q -b state
        git -C "$VIRGL_BASE/state" remote add origin "$T/state.git"
        git -C "$VIRGL_BASE/state" -c user.name=test -c user.email=test@example.invalid commit -q --allow-empty -m "state: local test"
        git -C "$VIRGL_BASE/state" push -q origin HEAD:state
    fi
    pass "setup: key $fpr"
    ;;
run)
    rc=0
    "$R/bin/virgl-build" "$@" || rc=$?
    deploy
    echo "virgl-build exit $rc"
    ;;
expect)
    got=$(kv "$VIRGL_BASE/state/$1.published" version)
    [[ $got == "$2" ]] && pass "$1 published: $got" || fail "$1 published: '$got', expected $2"
    ;;
apt)
    q=$(kv "$VIRGL_BASE/state/qemu.published" version) l=$(kv "$VIRGL_BASE/state/virglrenderer.published" version)
    deb -e Q="$q" -e L="$l" docker.io/library/debian:trixie bash -euc '
        cat > /etc/apt/sources.list.d/proxmox.sources <<EOF
Types: deb
URIs: http://download.proxmox.com/debian/pve
Suites: trixie
Components: pve-no-subscription
Signed-By: /keyrings/proxmox-archive-keyring.gpg
EOF
        cat > /etc/apt/sources.list.d/pve-virgl.sources <<EOF
Types: deb
URIs: file:/live/apt/virgl
Suites: trixie
Components: main
Signed-By: /repo/node/pve-virgl.asc
EOF
        cp /repo/node/pve-virgl.pref /etc/apt/preferences.d/
        apt-get update -q >/dev/null
        apt-cache policy pve-qemu-kvm libvirglrenderer1 | grep -E "^[a-z]|Candidate"
        DEBIAN_FRONTEND=noninteractive apt-get install -y -q --no-install-recommends pve-qemu-kvm libvirglrenderer1 >/dev/null
        [ "$(dpkg-query -W -f="\${Version}" pve-qemu-kvm)" = "$Q" ] && [ "$(dpkg-query -W -f="\${Version}" libvirglrenderer1)" = "$L" ]
        kvm --version | head -n 1'
    pass "a node with the pin installs pve-qemu-kvm $q and libvirglrenderer1 $l from the deployed site"
    ;;
byhash)
    prev=$(find "$T" -maxdepth 1 -name 'live.*' | sort -V | tail -n 1)
    [[ -n $prev ]] || fail "no previous deploy"
    rm -rf "$T/mixed"
    cp -a "$T/live" "$T/mixed"
    cp "$prev/apt/virgl/dists/trixie/InRelease" "$T/mixed/apt/virgl/dists/trixie/InRelease"
    cmp -s "$T/mixed/apt/virgl/dists/trixie/InRelease" "$T/live/apt/virgl/dists/trixie/InRelease" && fail "the previous InRelease is the same as the live one"
    podman run --rm --security-opt label=disable -v "$T/mixed":/live:ro -v "$R":/repo:ro docker.io/library/debian:trixie bash -euc '
        cat > /etc/apt/sources.list.d/pve-virgl.sources <<EOF
Types: deb
URIs: file:/live/apt/virgl
Suites: trixie
Components: main
Signed-By: /repo/node/pve-virgl.asc
EOF
        apt-get update -q -o Acquire::By-Hash=force 2>&1 | tail -n 3
        apt-get update -q -o Acquire::By-Hash=force 2>&1 | grep -qiE "^(E|W):" && exit 1
        apt-cache policy libvirglrenderer1 | grep -E "Candidate"'
    pass "apt update with the previous InRelease finds its index files under by-hash/"
    ;;
plex)
    name=$(sed -n 's/^Bundle: //p' "$T/live/files/plex-vaapi/current.asc")
    [[ -n $name ]] || fail "no current bundle"
    rm -rf "$T/plex" "$T/tampered" "$T/corrupt"
    mkdir -p "$T/plex/store"
    cp -a "$T/live/files/plex-vaapi" "$T/tampered"
    sed -i 's/^SHA256: ./SHA256: 0/' "$T/tampered/current.asc"
    cp -a "$T/live/files/plex-vaapi" "$T/corrupt"
    printf 'x' | dd of="$T/corrupt/$name.tar.gz" bs=1 seek=1000 conv=notrunc status=none
    rm -rf "$T/corrupt-store"
    plex() { # [env...] → the init script's output, in a debian container laid out like LSIO's
        podman run --rm --security-opt label=disable -v "$T":/t:ro -v "$T/plex/store":/vaapi-store \
            -v "$R/guest/pve-virgl.gpg":/etc/pve-virgl.gpg:ro "$@" localhost/virgl-plex-test:latest \
            bash -c 'mkdir -p /usr/lib/plexmediaserver/lib && echo plex > /usr/lib/plexmediaserver/lib/ld-musl-x86_64.so.1 && getent passwd abc >/dev/null || useradd abc; bash /t/repo/guest/plex-musl-va-init.sh' 2>&1
    }
    podman image exists localhost/virgl-plex-test:latest ||
        printf 'FROM docker.io/library/debian:trixie\nRUN apt-get update && apt-get install -y --no-install-recommends curl gpgv ca-certificates && rm -rf /var/lib/apt/lists/*\n' |
        podman build -q -t localhost/virgl-plex-test:latest -f - >/dev/null
    o=$(plex); echo "$o" | grep -q "downloading $name" && echo "$o" | grep -q "bundle $name is current" && echo "$o" | grep -q "VA drivers linked" \
        && pass "plex: first start fetches $name" || { echo "$o"; fail "plex: first start"; }
    o=$(plex); echo "$o" | grep -q "downloading" && { echo "$o"; fail "plex: restart downloaded again"; }
    echo "$o" | grep -q "bundle $name is current" && pass "plex: restart keeps $name, no download" || { echo "$o"; fail "plex: restart"; }
    o=$(plex -e PLEX_VAAPI_URL=file:///t/tampered); echo "$o" | grep -q "bad or unknown signature" && pass "plex: tampered index refused" || { echo "$o"; fail "plex: tampered index"; }
    o=$(plex -e PLEX_VAAPI_URL=file:///t/nowhere); echo "$o" | grep -q "update check failed (can't fetch" && echo "$o" | grep -q "VA drivers linked" \
        && pass "plex: unreachable repo keeps $name" || { echo "$o"; fail "plex: unreachable"; }
    o=$(plex -e PLEX_VAAPI_BUNDLE="$name"); echo "$o" | grep -q "held at $name" && pass "plex: hold" || { echo "$o"; fail "plex: hold"; }
    # The newest earlier index that differs from the live one (older ones may be signed by an earlier test key).
    old=$(find "$T" -maxdepth 1 -name 'live.*' | sort -rV | while read -r d; do
        if [[ -f $d/files/plex-vaapi/current.asc ]] && ! cmp -s "$d/files/plex-vaapi/current.asc" "$T/live/files/plex-vaapi/current.asc"; then
            echo "$d"
        fi    # not "cond && echo": a false last iteration would end the step under set -e
    done | sed -n 1p)   # sed reads to the end: no SIGPIPE
    if [[ -n $old ]]; then
        o=$(plex -e PLEX_VAAPI_URL="file://$old/files/plex-vaapi"); echo "$o" | grep -q "older than the last one taken" && pass "plex: replayed older index refused" || { echo "$o"; fail "plex: replayed index"; }
    else
        echo "SKIP  plex: replayed older index (no older current.asc deployed yet)"
    fi
    rm -rf "$T/plex/store" && mkdir -p "$T/plex/store"
    o=$(plex -e PLEX_VAAPI_URL=file:///t/corrupt); echo "$o" | grep -q "checksum mismatch" && pass "plex: corrupt tarball refused" || { echo "$o"; fail "plex: corrupt tarball"; }
    ;;
node)
    mkdir -p "$T/nodetest/files/status"
    for age in 0 5; do
        gen=$(( $(date +%s) - age * 86400 ))
        printf '{\n  "generated": %s,\n  "checked": "",\n  "overall": "ok"\n}\n' "$gen" > "$T/nodetest/files/status/status.json"
        o=$(podman run --rm --security-opt label=disable -v "$T/nodetest":/live:ro -v "$R":/repo:ro docker.io/library/debian:trixie bash -c '
            apt-get update -qq >/dev/null 2>&1; apt-get install -y -qq curl >/dev/null 2>&1
            printf "Types: deb\nURIs: file:///live/apt/virgl\nSuites: trixie\nComponents: main\n" > /etc/apt/sources.list.d/pve-virgl.sources
            bash /repo/node/pve-virgl-check' 2>&1)
        if (( age == 0 )); then [[ -z $o ]] && pass "node check: fresh status.json, silent" || { echo "$o"; fail "node check: fresh"; }
        else echo "$o" | grep -q "haven't run since" && pass "node check: 5-day-old status.json warns" || { echo "$o"; fail "node check: stale"; }
        fi
    done
    ;;
rollback)
    "$R/bin/rollback" "$@"
    "$R/bin/site" --deploy
    deploy
    ;;
aports-mirror)
    # For tests while git.alpinelinux.org is unreachable: Alpine's read-only GitHub mirror.
    sed -i -e 's|^APORTS_URL=.*|APORTS_URL=https://github.com/alpinelinux/aports.git|' \
        -e 's|^MESA_RECIPE_URL=.*|MESA_RECIPE_URL=https://raw.githubusercontent.com/alpinelinux/aports/$ALPINE_BRANCH-stable/main/mesa/APKBUILD|' "$R/build.conf"
    grep -E '^(APORTS_URL|MESA_RECIPE_URL)=' "$R/build.conf"
    ;;
site)
    "$R/bin/site" --deploy
    deploy
    ;;
committed)
    rm -rf "$T/state-clone"
    git clone -q -b state "$T/state.git" "$T/state-clone"
    # Every file but .git/ and the state's three untracked paths, with its sha256.
    files() { (cd "$1" && find . -type f ! -path './.git/*' | sed 's|^\./||' | grep -vxE 'upstream|run' | grep -vE '^apt/' | sort | xargs -r sha256sum); }
    if diff <(files "$VIRGL_BASE/state") <(files "$T/state-clone") > "$T/committed.diff"; then
        pass "the pushed state branch has all $(files "$T/state-clone" | wc -l) files of the state"
    else
        head -n 10 "$T/committed.diff"
        fail "the pushed state branch differs from the state ($T/committed.diff)"
    fi
    ;;
fresh-job)
    p=${1:?fresh-job <product>}
    F=$T/fresh-$p
    rm -rf "$F" "$F.plan"
    mkdir -p "$F" "$F.plan"
    # The plan job, on its own runner; the build job gets only the state and the plan (the artifact).
    cp -a "$VIRGL_BASE/state" "$F.plan/state"
    VIRGL_BASE=$F.plan VIRGL_STATE=$F.plan/state "$R/bin/plan" --force "$p" > "$F.plan/plan.log" 2>&1 || { cat "$F.plan/plan.log"; fail "plan in a fresh job directory"; }
    cp -a "$VIRGL_BASE/state" "$F/state"
    cp -a "$F.plan/plan" "$F/plan"
    VIRGL_BASE=$F VIRGL_STATE=$F/state "$R/bin/build-one" "$p"
    r=$(cat "$F"/out/"$p"/*/result 2>/dev/null || echo "no result")
    [[ $r == ok ]] && pass "$p builds in a fresh job directory" || { cat "$F"/out/"$p"/*/podman.log 2>/dev/null | head -n 3; fail "$p in a fresh job directory: $r"; }
    ;;
sources)
    name=$(kv "$VIRGL_BASE/state/bundle.published" version)
    rel=$VIRGL_RELEASES/bundle/$name
    [[ -n $name && -d $rel ]] || fail "no published bundle Release"
    find "$rel" -maxdepth 1 -name 'source-*.tar' -printf '%f %s\n' | sort | awk '{ printf "%s %.1f MB\n", $1, $2 / 1e6 }'
    o=$("$R/bin/verify" bundle "$rel" "$name") && pass "verify passes on $name's Release" || { echo "$o"; fail "verify on $name"; }
    echo "$o" | grep -E 'source-|SOURCES'
    for t in gcc elfutils xz; do compgen -G "$rel/source-$t-*.tar" >/dev/null && pass "source tar for $t" || fail "no source tar for $t"; done
    small=$(find "$rel" -maxdepth 1 -name 'source-*.tar' -printf '%s %p\n' | sort -n | head -n 1 | cut -d' ' -f2-)
    neg() { # what, FAIL pattern, command (run in the copy) → verify must fail with that pattern
        rm -rf "$T/srcneg" && cp -a "$rel" "$T/srcneg"
        (cd "$T/srcneg" && eval "$3")
        o=$("$R/bin/verify" bundle "$T/srcneg" "$name") && { echo "$o"; fail "verify passed with $1"; }
        echo "$o" | grep -qE "^FAIL  .*$2" && pass "verify fails on $1" || { echo "$o"; fail "verify on $1: no FAIL matching '$2'"; }
    }
    neg "a changed upstream file" "doesn't match|not matching" \
        'mkdir x && tar -xf '"${small##*/}"' -C x && f=$(find x/distfiles -type f | head -n 1) && printf x | dd of="$f" bs=1 seek=100 conv=notrunc status=none && tar -C x -cf '"${small##*/}"' SOURCE-INFO aports distfiles && rm -rf x'
    neg "a missing source tar" "missing" 'rm -f source-elfutils-*.tar'
    neg "an unreviewed license" "license 'MIT-test'" 'sed -i "s/^libxau \(.*\) license=MIT$/libxau \1 license=MIT-test/" SOURCES && grep -q "license=MIT-test" SOURCES'
    n=$(tar -tzf "$rel/$name.tar.gz" | grep -c '^vaapi/licenses/.*[^/]$')
    tar -xzOf "$rel/$name.tar.gz" vaapi/licenses/README | head -n 6
    (( n > 40 )) && pass "$n license files in the bundle" || fail "only $n license files in the bundle"
    neg "a library without license texts" "no license texts in the bundle for: fakeorigin" \
        'echo "fakelib 1.0-r0 origin=fakeorigin commit=- license=MIT" >> SOURCES'
    neg "a symlink in a source tar" "isn't a file or directory" \
        'mkdir -p y/aports && ln -s /etc y/aports/evil && tar -C y -rf '"${small##*/}"' aports/evil && rm -rf y'
    rm -rf "$T/srcneg"
    ;;
break|unbreak)
    case $1 in
        patch) f=patches/host/9999-virgl-video-fixes.patch ;;
        mesa-patch) f=patches/guest/9999-virgl-guest-video.patch ;;
        smoke) f=build/smoke-test.sh ;;
        *) fail "break patch|mesa-patch|smoke" ;;
    esac
    cp "/src/$f" "$R/$f"
    if [[ $step == break ]]; then
        case $1 in
            patch) printf -- '--- a/src/virgl_video.c\n+++ b/src/virgl_video.c\n@@ -1,1 +1,1 @@\n-this line is not in the file\n+so the patch fails\n' >> "$R/$f" ;;
            mesa-patch) printf -- '--- a/src/gallium/drivers/virgl/virgl_video.c\n+++ b/src/gallium/drivers/virgl/virgl_video.c\n@@ -1,1 +1,1 @@\n-this line is not in the file\n+so the patch fails\n' >> "$R/$f" ;;
            smoke) sed -i '0,/^set -euo pipefail$/s//set -euo pipefail\necho "SMOKE: FAIL: broken on purpose (test)"; exit 1/' "$R/$f" ;;
        esac
    fi
    echo "$step $1: $f"
    ;;
inputs)
    f=build/build-virglrenderer.sh
    cp "/src/$f" "$R/$f"
    case ${1:-} in
        change) echo "# new inputs (test)" >> "$R/$f" ;;
        restore) ;;
        *) fail "inputs change|restore" ;;
    esac
    echo "inputs $1: $f"
    ;;
held)
    p=${1:?held <product>}
    F=$T/held-$p
    rm -rf "$F"
    mkdir -p "$F"
    cp -a "$VIRGL_BASE/state" "$F/state"
    VIRGL_BASE=$F VIRGL_STATE=$F/state "$R/bin/plan" > "$F/plan.log" 2>&1 || { cat "$F/plan.log"; fail "plan for held"; }
    if grep -qF "[$p] not rebuilt: these inputs were rejected by rollback" "$F/plan.log" && grep -qx "$p=0" "$F/plan/decisions"; then
        pass "the next plan doesn't build $p's rejected inputs again"
    else
        cat "$F/plan.log"; fail "the next plan would build $p's rejected inputs"
    fi
    grep -E "^ +\"$p\": .*\"text\": \"held: " "$T/live/files/status/status.json" && pass "the status says $p is held" ||
        { cat "$T/live/files/status/status.json"; fail "the status doesn't say $p is held"; }
    ;;
*) fail "unknown step $step" ;;
esac
