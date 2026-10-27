# pve-virgl-build

Builds, checks and publishes the three patched products behind hardware video (VA-API) in virgl guests on Proxmox VE with an AMD GPU, and gets them onto the hosts and into a Plex container. Everything runs in GitHub Actions; GitHub Pages and Releases serve the results.

| Product | Base | Our patch | Delivered as |
|---|---|---|---|
| `qemu` | Proxmox's `pve-qemu-kvm`, newest in `pve-no-subscription` | `patches/host/9999-virgl-video-get-drm-fd.patch` | apt repo: `pve-qemu-kvm` |
| `virglrenderer` | Debian trixie's `virglrenderer` source (trixie, -updates, -security) | `patches/host/9999-virgl-video-fixes.patch` | apt repo: `libvirglrenderer1`, `virgl-server` |
| `mesa` | Alpine 3.22's `main/mesa` from aports `3.22-stable` | `patches/guest/9999-virgl-guest-video.patch` | a Release: the bundle's input |
| `bundle` | our Mesa's VA driver, its libraries, Alpine's libva and musl loader | | `<site>/files/plex-vaapi/`, fetched by the Plex container at start |

Why it's built this way: [docs/DESIGN.md](docs/DESIGN.md).

## How a run works

`.github/workflows/virgl-build.yml` runs hourly, on a push to `main` that touches the patches or scripts, and by hand (Actions → virgl-build → Run workflow: `force`, `dry_run`, `deploy`).

1. **plan** (`bin/plan`): asks each upstream for its current version (`bin/check-upstream`: Proxmox's and Debian's signed apt indexes, Alpine's signed index through `apk`), and decides what to build. A product is built when its **input tuple** (upstream version plus hashes of our patch and build script) differs from the published one and wasn't rejected by a rollback. A failed tuple is retried after 1 h, 2 h, 4 h … then daily.
2. **build-qemu, build-virglrenderer, build-mesa, then build-bundle** (`bin/build-one`): each on its own runner, in a throwaway `debian:trixie` or `alpine:3.22` podman container, then `bin/verify`. These jobs have no secrets and read-only access: they run upstream code.
3. **publish** (`bin/publish`), environment `publish`, the only job with the signing key: verifies each build again, then
   - **debs:** the published debs plus the new ones (pruned to `KEEP` versions per package) go into a fresh aptly, are published to a staging tree, installed by `build/smoke-test.sh` in a clean `debian:trixie` with the nodes' own pin, and only then published with by-hash indexes;
   - **mesa, bundle:** archived; the bundle gets a new clearsigned `current.asc`;
   - every published build gets a Release, tagged `<product>/<version>` at the commit that built it, with its packages, logs, verify results and sources.
4. **site** (`bin/site`, `.github/workflows/site.yml`): records the run in the state, writes the status page, and when anything changed (or once a day) assembles the site from the state and the Releases and deploys it to Pages.

The products are independent: a failure in one doesn't hold back the others. There are no alerts: failures show in the Actions tab, on the status page (`<site>/files/status/`) and in the nodes' apt check.

**State** lives in the `state` branch, committed by the jobs: the build-number ledger (`n-used`), `<product>.{published,last,rejected,ahead}`, the bundle list, the published bundle's MANIFEST, and `site/` (the signed apt `dists/` and `current.asc`).

**Version numbers:** debs are `<Proxmox or Debian version>virgl<N>` (no `+`, so Debian's next security or binNMU build sorts above ours). Mesa is `<pkgver>-r<100+N>`. Bundles are `plex-vaapi_alpine3.22_mesa<Alpine's mesa version>_virgl<N>`. N counts per base, starting above `N_USED` in `build.conf`; every attempted build's number goes into the ledger, so a number never names two builds.

## Setting up the repo

Once, in this order, in your own terminal, with the GitHub CLI logged in as the owner (`gh auth login`). For a scratch repo, first `test/scratch.sh <new dir> fvlaicu/<name>`, then the same steps in that directory, with a test key.

1. **The signing key** (the secret key is written to a new directory and nowhere else):
   ```sh
   bin/make-key ~/virgl-key
   ```
   It prints the fingerprint for `build.conf`'s `GPG_FPR`, where the two public files go (`node/`, `guest/`), the `gh secret set` command for step 4, and what to keep: the secret key and the revocation certificate into the password manager, then `rm -rf ~/virgl-key`.
2. **The repo**, public (free Actions minutes and Pages need that), and `main`:
   ```sh
   git init -b main
   git config user.email "$(. ./build.conf && echo "$DEBEMAIL")"   # GitHub's no-reply address
   git add -A && git status --short          # look: the two public key files, no secret key, no _run/
   git commit -m "pve-virgl-build [skip ci]"
   gh repo create fvlaicu/pve-virgl-build --public --description "virgl video builds for Proxmox VE" \
       --source . --remote origin --push
   ```
   `[skip ci]` keeps the push from starting a run before step 3 has made the settings and the `state` branch. The remote uses gh's protocol (`gh config get git_protocol`); over HTTPS, git needs gh as its credential helper (`gh auth setup-git`) and gh's token the `workflow` scope.
3. **Settings and the state branch:** `bin/setup-github`. It sets Actions to GitHub-owned actions only, with a read-only token by default; Pages to "GitHub Actions"; and the environment `publish` to deployments from `main` only, with no reviewers, so publishing doesn't wait for anyone. It creates the empty `state` branch and prints what's set. Safe to run again.
4. **The secret:** the `gh secret set VIRGL_SIGNING_KEY --env publish …` line `bin/make-key` printed.
5. **First run:** Actions → virgl-build → Run workflow, first with `dry_run`, then without. Compare each product's Release with what you expect (verify results, `deb-info.txt`, the bundle's `MANIFEST`).

If the schedule ever stops (GitHub disables it in a public repo after 60 days without activity; the nodes' apt check says so): `gh workflow enable virgl-build.yml --repo fvlaicu/pve-virgl-build`.

## Nodes

From a checkout of this repo on the node, as root:

```sh
bash node/opt-in.sh           # repo files + apt update, then shows what it would install
bash node/opt-in.sh --yes     # installs the newest virgl builds (--allow-downgrades: also replaces hand-built +virglN ones)
bash node/opt-out.sh          # shows the stock versions it would go back to
bash node/opt-out.sh --yes    # removes the repo files, installs stock
```

- **Opt-in installs:** `/etc/apt/keyrings/pve-virgl.asc`, `/etc/apt/sources.list.d/pve-virgl.sources` (from `build.conf`'s `PAGES_URL`), `/etc/apt/preferences.d/pve-virgl.pref` (ours at 990, stock at 50), and the apt check (`/etc/apt/apt.conf.d/99pve-virgl-check`, `/usr/local/sbin/pve-virgl-check`).
- **Updates:** `apt update && apt full-upgrade`, then reboot the node (or restart the virtio-gl VMs).
- **The apt check:** after each `apt update`, it prints a line when Proxmox or Debian has a newer base than the virgl build the pin keeps (our rebuild isn't out yet), and when the builds haven't run for `STALE_DAYS`.

## Plex VM

One-time setup, with the compose changes in `guest/compose-snippet.yml`:

```sh
install -d -m 0755 /opt/plex-vaapi/store
install -m 0644 guest/pve-virgl.gpg /opt/plex-vaapi/pve-virgl.gpg
install -m 0755 guest/plex-musl-va-init.sh /opt/plex-vaapi/plex-musl-va-init.sh
```

- **Updates:** at every container start, `plex-musl-va-init.sh` checks `current.asc` (gpgv; a serial older than the last one taken is refused). If the bundle is new, it downloads it, checks the sha256 and unpacks it. On any failure it keeps the bundle it has. `docker compose pull && docker compose up -d`, or `docker restart plex`, picks up a new bundle.
- **Hold or roll back:** `PLEX_VAAPI_BUNDLE=<name>` (a directory in `/opt/plex-vaapi/store`) in the compose file.
- **What it did:** `docker logs plex 2>&1 | grep plex-musl-va`.
- **Check after a change:** a forced transcode must show `final decoder: vaapi, final encoder: vaapi` in Plex's log.
- **The script itself** isn't delivered by the bundle. A change to it is copied to `/opt/plex-vaapi/` by hand.

## Rolling back

Actions → rollback → Run workflow: the product (`qemu`, `virglrenderer`, `bundle`) and the version or bundle name. It takes the build out of the apt repo (or points `current.asc` at the previous bundle), marks its input tuple rejected so it isn't rebuilt until an input changes, retitles its Release "(rolled back)", redeploys the site, and says in the run's summary what to do on the nodes or in the Plex VM. A bad Mesa build is rolled back through its bundle; the fix is a patch commit.

If a rollback shows as cancelled: a run of virgl-build queued after it took its place in the concurrency group. Run it again.

## When verify stops a bundle over licenses

The bundle build checks every library it carries (docs/DESIGN.md, "Licenses"), so a new library or a changed license field (at the next Alpine version, say) stops the bundle until it's looked at:
- **"license '…' is neither in BUNDLE_LICENSES_NO_SOURCE nor …":** if the license needs no source (MIT, BSD and the like), add the string exactly as shown to `BUNDLE_LICENSES_NO_SOURCE` in `build.conf`; if it's copyleft, add the origin to `BUNDLE_SOURCE_ORIGINS`.
- **"no license texts for …":** `bin/collect-licenses list <origin>` shows the license-like files in its upstream source; pick the right ones, add a `get` line to `licenses/collect-all.sh`, run it, and commit `licenses/`. When versions change, the paths in `collect-all.sh` name the old versions: edit them and run it again.

Either change goes into the bundle's input tuple, so the next run builds the bundle again.

## Testing locally

`test/local.sh <test dir> <step>` runs the same scripts in a container with the runner's userland (Ubuntu 24.04, podman 4.9.3, aptly 1.5.0), nested podman for the builds, a throwaway key, Releases in a directory and the "live" site in `<test dir>/live`. Steps: `setup`, `run [--dry-run] [--force <product>]`, `expect`, `apt`, `byhash`, `plex`, `node`, `rollback`, `break`/`unbreak` (see `test/run.sh`).

## Development

`make lint` runs shellcheck over all scripts and checks that the settings repeated outside `build.conf` agree with it. `make actionlint` checks the workflows (in a container).

## License

The scripts, workflows, patches and docs in this repo are licensed under the GNU General Public License, version 2 or (at your option) any later version; the text is in [LICENSE](LICENSE). The packages built from them keep their upstream licenses, with our patches added ([docs/DESIGN.md](docs/DESIGN.md), "Licenses"), and each Release carries the corresponding source.
