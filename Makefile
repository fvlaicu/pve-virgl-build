SCRIPTS := bin/* lib/*.sh build/*.sh node/*.sh node/pve-virgl-check guest/plex-musl-va-init.sh test/*.sh licenses/*.sh

.PHONY: lint check-config actionlint
lint: check-config
	shellcheck $(SCRIPTS)

# Settings that have to be repeated outside build.conf, because the files they're in run where the
# repo isn't: the Plex init script's default URL, and the nodes' staleness threshold and tracked
# suites. Also the two copies of tracked_versions (opt-out.sh and the apt check), which must match.
check-config:
	@. ./build.conf; \
	want="$$PAGES_URL/files/plex-vaapi"; \
	grep -qF "URL=\$${PLEX_VAAPI_URL:-$$want}" guest/plex-musl-va-init.sh || { echo "guest/plex-musl-va-init.sh: default URL isn't $$want"; exit 1; }; \
	grep -qx "STALE_DAYS=$$STALE_DAYS   # build.conf's STALE_DAYS (make lint checks that they agree)" node/pve-virgl-check || { echo "node/pve-virgl-check: STALE_DAYS isn't $$STALE_DAYS"; exit 1; }; \
	grep -qx "DIST=$$DIST   # build.conf's DIST (make lint checks that they agree)" node/pve-virgl-check || { echo "node/pve-virgl-check: DIST isn't $$DIST"; exit 1; }; \
	grep -qx "TRACK_SUITE=$$TRACK_SUITE   # build.conf's TRACK_SUITE (make lint checks that they agree)" node/pve-virgl-check || { echo "node/pve-virgl-check: TRACK_SUITE isn't $$TRACK_SUITE"; exit 1; }; \
	a=$$(sed -n '/^tracked_versions() {/,/^}/p' node/opt-out.sh); b=$$(sed -n '/^tracked_versions() {/,/^}/p' node/pve-virgl-check); \
	[ -n "$$a" ] && [ "$$a" = "$$b" ] || { echo "tracked_versions differs between node/opt-out.sh and node/pve-virgl-check"; exit 1; }; \
	echo "config: PAGES_URL, STALE_DAYS, DIST and TRACK_SUITE agree; tracked_versions is the same in both node scripts"

# The workflows, with actionlint's own shellcheck pass over the run: blocks (needs podman).
actionlint:
	podman run --rm --security-opt label=disable -v "$(CURDIR)":/repo:ro -w /repo docker.io/rhysd/actionlint:1.7.7 .github/workflows/*.yml
