# Design

Why this repo builds what it builds, the way it does. The how-to is in the [README](../README.md).

## The problem

A Proxmox VE guest with `virtio-vga-gl` (virgl) on an AMD GPU can, in principle, decode and encode video on the host GPU through VA-API. With stock packages it doesn't work: downloads of decoded frames are green, the H.264 the encoder produces is undecodable, and scaling is black. Making it work took fixes in three places, so this repo builds three patched products:

1. **`pve-qemu-kvm`** (Proxmox's package) with `9999-virgl-video-get-drm-fd.patch`: QEMU passes virglrenderer a DRM fd and asks for video (`VIRGL_RENDERER_USE_VIDEO`).
2. **`libvirglrenderer1`, `virgl-server`** (Debian trixie's 1.1.0) with `9999-virgl-video-fixes.patch`: EGL modifier import, read-write exports, `glFinish` before handing frames over, H.264 packed headers.
3. **Guest Mesa** (Alpine 3.22's) with `9999-virgl-guest-video.patch`: NV12/P010 only, readback dirty marking, 2D_ARRAY views. Plex's transcoder is a musl program that can't load the system's glibc drivers, so the guest side ships as a **bundle**: our Mesa's VA driver, every library it needs, Alpine's libva and Alpine's musl loader (Plex's own musl lacks `qsort_r`, which Mesa needs). Plex loads no driver for virtio-gpu by itself, so the bundle is required, not a convenience.

Builds 1 and 2 don't depend on each other: QEMU depends on `libvirglrenderer1 (>= 1.0.0)`, virglrenderer installs only `virglrenderer.h`, and our patch touches only internal files. So each rebuilds only when its own inputs change.

## Versions

| Comparison (`dpkg --compare-versions`) | Result | Meaning |
|---|---|---|
| `1.1.0-2+deb13u1` < `1.1.0-2+virgl5` | true | A `+virglN` suffix would hide Debian's security update… |
| `1.1.0-2+deb13u1+virgl1` < `1.1.0-2+virgl5` | true | …and our own rebuild on top of it |
| `1.1.0-2virgl1` > `1.1.0-2` | true | `virglN` without `+` beats the stock build it's based on |
| `1.1.0-2virgl1` < `1.1.0-2+deb13u1`, `< 1.1.0-2+b1` | true | Debian's next build beats ours… |
| `1.1.0-2+deb13u1virgl1` > `1.1.0-2+deb13u1`, `> 1.1.0-2virgl9` | true | …and our rebuild on it beats both |
| `11.0.3-4virgl1` > `11.0.3-4`, `< 11.0.3-5` | true | Same scheme for QEMU |

So debs are `<base>virgl<N>`: letters sort before non-letters in Debian's version order. N starts at 1 for each base and goes up when our inputs change (patch, build script, flags). Mesa is never published as an apk repo, so its version only has to be unique and traceable: `pkgrel = 100 + N` on Alpine's pkgver. Bundles are `plex-vaapi_alpine<branch>_mesa<Alpine's mesa version>_virgl<N>`. The ledger (`n-used` in the state) records every number handed out, failures included.

## The pin

Opted-in nodes get `pve-virgl.pref`: our repo at 990 for the three packages, stock Proxmox and Debian at 50, no `apt-mark hold`.
- Hardware video stays on: a newer Proxmox or Debian build of these packages waits until our rebuild of it is published (normally within the hour).
- When our build fails (say the patch stops applying), the node stays on the old one, including Debian security fixes for virglrenderer. The nodes' apt check says so at every `apt update`.
- 990 rather than 1001, so our repo can never silently downgrade a node; stock at 50 so a missing index can't swap stock back in.

## Triggers and input tuples

Everything is polled hourly; none of the upstreams offers a webhook.

| Product | Input | Detected by |
|---|---|---|
| qemu | newest `pve-qemu-kvm` in Proxmox's `pve-no-subscription` | Proxmox's signed apt index |
| virglrenderer | highest `virglrenderer` source in trixie, trixie-updates, trixie-security | Debian's signed apt index |
| mesa | `mesa` in Alpine's v3.22 index, once the aports recipe agrees | `apk` (checks the index signature) |
| bundle | our Mesa build, and every Alpine package that owns a file in the bundle | the same index, against the bundle's MANIFEST |
| all | our patch and build script | hashes |

Together these form one input tuple per product. A product is built when its tuple differs from the published one and isn't on the rejected list (rollback). Information only, on the status page: newer upstream virglrenderer and Mesa releases, and Alpine 3.22's end of life (2027-05-01).

## Verify and smoke test

`bin/verify` runs in the build job and again in the publish job (the build job ran upstream code, so its verdict isn't trusted):
- **qemu:** version ends in `virgl<N>`; the log shows our patch applied; the `libvirglrenderer1` floor is met by Debian's version; configure found virglrenderer.
- **virglrenderer:** our patch applied; no compiler warnings in the patched files; video on in meson; the library has the packed-header strings and no diagnostic strings.
- **mesa:** pkgrel is 100 + N; every package abuild listed is there; patches applied in the recipe's order, ours last; the debug info has the function our patch adds.
- **bundle:** only files, directories and hard links under `vaapi/`; the driver comes from our Mesa; the VA init symbol loads with Plex's libva (below); the driver's RUNPATH; every dependency resolves inside the bundle.

The smoke test installs the candidate apt snapshot in a clean `debian:trixie` with Proxmox's repo and the nodes' pin: our versions must win, `kvm --version` must name them, `virtio-vga-gl` must be a device, and QEMU must link our `libvirglrenderer.so.1`. Nothing tests video at runtime automatically (that needs a GPU); a forced transcode in Plex after a change is the check.

## Where it runs, and the trust that costs

GitHub Actions' standard runners are free on public repos; Pages and Releases host the results. The costs, accepted on purpose:
- **The repo is public:** the patches, scripts and builds are visible. The patches are GPL/MIT code anyway.
- **The signing key is an Actions secret,** in environment `publish`, whose deployment branch is `main` only. Only `publish` and `rollback` see it. The jobs that run upstream code (builds: `meson subprojects download`, `abuild`, package builds) have no secrets and read-only tokens, so a compromised upstream build can't sign anything. Actions are GitHub's own, pinned by commit. There is no `pull_request` trigger.
- **What remains:** whoever controls the GitHub account, or can push to `main`, can get a QEMU signed that the nodes install as root.

The key is made once outside GitHub (`bin/make-key`), with a backup and a revocation certificate kept offline.

## State, Releases and Pages

- **Releases** are the archive: one per published build, with everything it produced. They have no total size limit, and each file must be under 2 GiB.
- **The state branch** holds the small facts and the signed small files (`dists/`, `current.asc`). The publish job writes it, then the site job, one after the other; runs never overlap (concurrency group).
- **Pages** is rebuilt from both on each deploy (1 GB per site: `KEEP` debs, `KEEP_BUNDLES` bundles). It deploys only when something changed or the live copy is a day old, so an unchanged hourly run doesn't upload the whole site.
- **Caching:** Pages answers with `cache-control: max-age=600`, so for up to ten minutes a node can get the previous `InRelease`. The apt indexes are published with `Acquire-By-Hash`, and each deploy carries the previous generation's index files under `by-hash/`, so an old `InRelease` still finds matching `Packages`.

## Status

No alerts. Failures show in the Actions tab, on the status page and in the nodes' apt check. The apt check also reads `status.json`: GitHub disables the schedule of a public repo after 60 days without repository activity, and it isn't documented whether the jobs' own commits count. If the page is older than `STALE_DAYS`, the check says the builds have stopped. The site job commits a heartbeat at most once a day.

## The Plex side

`current.asc` is one clearsigned file naming the current bundle, its sha256, size and a serial. The init script checks it with `gpgv` at every container start, refuses a serial older than the last one it took (so a replayed old index can't switch Plex back), downloads a new bundle, checks the sha256 and the tarball's entries, and switches atomically. On any failure it keeps what it has; with no bundle at all, Plex transcodes in software. `PLEX_VAAPI_BUNDLE` holds a bundle. The script and the key are mounted read-only from outside the store, so the container can't rewrite its own init script.

## Licenses

Our own files (scripts, workflows, patches) are GPL-2.0-or-later. Not GPL-3.0: the QEMU patch changes a "GPL, version 2 or later" file, and QEMU as a whole is GPL-2.0, which GPL-3.0-only code can't join. The patched virglrenderer and Mesa therefore contain GPL code next to their MIT code. The debs' copyright files are upstream's and don't mention our patches. Offering a patch upstream means offering it under the upstream's license (MIT for virglrenderer and Mesa), which the patches' author can do.

Publishing binaries is distribution, so each Release carries the corresponding source:
- **qemu** (GPL-2.0): the pve-qemu tree as built, with submodules, meson subprojects and our patch.
- **virglrenderer** (MIT): Debian's source package and our patch.
- **bundle:** `SOURCES` names, for each Alpine package in it, the version, license, origin and the aports commit it was built from. The copyleft libraries' source is attached, so it doesn't depend on Alpine keeping it: `source-<origin>-<version>.tar` for each origin in `BUNDLE_SOURCE_ORIGINS` (gcc for `libstdc++`/`libgcc`, elfutils for `libelf`, xz for `xz-libs`), with its aports directory at that commit and the upstream files, each checked against the APKBUILD's sha512sums, about 106 MB per bundle. Alpine has already removed old releases' source files (v3.0 and v3.5). Every other package's license must be one of `BUNDLE_LICENSES_NO_SOURCE`, exactly as Alpine's index spells it; verify fails otherwise, so a new library or a changed license field gets looked at before it's published. The bundle itself carries every library's license texts in `vaapi/licenses/<origin>/`, with a README saying which package each covers, our patch's GPL text and where the source is. Alpine's packages don't ship license texts (4 of the 22 origins have one, in `-doc`), so the texts come from each upstream source: collected once into the repo's `licenses/` by `bin/collect-licenses` (`licenses/collect-all.sh` names each file; libdrm has none, so the notices of its three libraries' main files, by line range), each with a `FROM` naming the upstream file, its sha512 and the version. A text can lag a newer library version, usually by the copyright years only; verify fails when a library has none.

## Later: newer bases

- **The guest has a deadline:** Alpine 3.22 ends on 2027-05-01. Alpine 3.23 (Mesa 25.2.7, libva 2.22.0) takes the guest patch as is. Alpine 3.24 (Mesa 26.1.6, libva 2.23.0) takes it with fuzz, but Mesa names its VA entry point after the libva it's built against (`__vaDriverInit_1_23`), and Plex's libva 2.22 only tries minors up to 22. So the next move is to 3.23, unless Plex's libva has moved on by then. Verify checks the symbol against `PLEX_LIBVA_MINOR`.
- **The host has no deadline:** it follows trixie. The host patch applies to virglrenderer 1.3.0 and upstream main with the paths moved to `src/vrend/`.
- **Upstreaming** both patches would end the rebuilds, once Debian and Alpine ship versions with the fixes.
