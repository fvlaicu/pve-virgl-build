SCRIPTS := bin/* lib/*.sh build/*.sh node/*.sh node/pve-virgl-check guest/plex-musl-va-init.sh test/*.sh licenses/*.sh

.PHONY: lint check-config actionlint
lint: check-config
	shellcheck $(SCRIPTS)

# Settings that have to be repeated outside build.conf, because the files they're in run where the
# repo isn't: the Plex init script's default URL and the nodes' staleness threshold.
check-config:
	@. ./build.conf; \
	want="$$PAGES_URL/files/plex-vaapi"; \
	grep -qF "URL=\$${PLEX_VAAPI_URL:-$$want}" guest/plex-musl-va-init.sh || { echo "guest/plex-musl-va-init.sh: default URL isn't $$want"; exit 1; }; \
	grep -qx "STALE_DAYS=$$STALE_DAYS   # build.conf's STALE_DAYS (make lint checks that they agree)" node/pve-virgl-check || { echo "node/pve-virgl-check: STALE_DAYS isn't $$STALE_DAYS"; exit 1; }; \
	echo "config: PAGES_URL and STALE_DAYS agree"

# The workflows, with actionlint's own shellcheck pass over the run: blocks (needs podman).
actionlint:
	podman run --rm --security-opt label=disable -v "$(CURDIR)":/repo:ro -w /repo docker.io/rhysd/actionlint:1.7.7 .github/workflows/*.yml
