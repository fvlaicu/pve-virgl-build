#!/usr/bin/env bash
# Runs test/run.sh in the runner-like test container (test/Containerfile), on this machine, without
# GitHub. Everything it writes is under <test dir>: a copy of the repo with a throwaway key, the
# state, the Releases (a directory), the "live" site, the nested podman's images.
#   test/local.sh <test dir> <step> [args]      steps: see test/run.sh
# Needs rootless podman; the container runs --privileged (nested podman), as your user.
set -euo pipefail
repo=$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)
(( $# >= 2 )) || { echo "usage: test/local.sh <test dir> <step> [args]"; exit 1; }
t=$(readlink -f "$1")
shift
mkdir -p "$t/containers"
podman image exists localhost/virgl-runner-test:latest ||
    podman build -q -t localhost/virgl-runner-test:latest -f "$repo/test/Containerfile" "$repo/test"
exec podman run --rm --privileged --security-opt label=disable \
    -v "$repo":/src:ro -v "$t":/t -v "$t/containers":/var/lib/containers \
    localhost/virgl-runner-test:latest bash /src/test/run.sh "$@"
