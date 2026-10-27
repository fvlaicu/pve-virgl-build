#!/usr/bin/env bash
# Copies this tree into a new directory for a scratch repo on GitHub (plan Phase B), pointed at
# that repo's Pages site, so the real tree's build.conf stays as it is.
#   test/scratch.sh <new dir> <owner/repo>
# Then, in <new dir>: a test key (bin/make-key), git init, push, bin/setup-github, the secret, as in
# the README's "Setting up the repo".
set -euo pipefail
export LC_ALL=C
src=$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)
(( $# == 2 )) || { echo "usage: scratch.sh <new dir> <owner/repo>"; exit 1; }
dest=$1 repo=$2
[[ $repo =~ ^([A-Za-z0-9-]+)/([A-Za-z0-9._-]+)$ ]] || { echo "not owner/repo: $repo"; exit 1; }
pages=https://${BASH_REMATCH[1],,}.github.io/${BASH_REMATCH[2]}
[[ ! -e $dest ]] || { echo "$dest exists; give a new directory"; exit 1; }
old=$(. "$src/build.conf" && echo "$PAGES_URL")

mkdir -p "$dest"
(cd "$src" && tar --exclude=./_run --exclude=./.git -cf - .) | (cd "$dest" && tar -xf -)
sed -i -e "s|^REPO=.*|REPO=$repo|" -e "s|^PAGES_URL=.*|PAGES_URL=$pages|" -e 's|^GPG_FPR=[^ ]*|GPG_FPR=|' "$dest/build.conf"
sed -i "s|$old/files/plex-vaapi|$pages/files/plex-vaapi|" "$dest/guest/plex-musl-va-init.sh"
rm -f "$dest/node/pve-virgl.asc" "$dest/guest/pve-virgl.gpg"   # the real key's, if there
make -s -C "$dest" check-config
echo "$dest: REPO=$repo PAGES_URL=$pages"
