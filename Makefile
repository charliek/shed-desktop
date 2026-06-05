# shed-desktop — common dev tasks. Run `make` (or `make help`) to list them.
#
# A native macOS menu-bar app for the shed toolchain. SwiftUI + an
# in-process JSON IPC socket that `shedctl` and the pytest harness drive,
# so changes can be verified (and screenshotted) without a human clicking.

.DEFAULT_GOAL := help

APP := build/ShedDesktop.app

.PHONY: help
help:  ## List available targets
	@echo "shed-desktop dev tasks:"
	@grep -hE '^[a-zA-Z0-9_-]+:.*?## ' $(MAKEFILE_LIST) \
	  | sort \
	  | awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'

# ---- build ------------------------------------------------------------

.PHONY: build bundle dmg run
build:  ## swift build the package
	swift build

bundle:  ## Build + assemble ShedDesktop.app (debug)
	./scripts/bundle.sh debug

dmg:  ## Build a release bundle + package a drag-install DMG
	./scripts/bundle.sh release
	./scripts/make-dmg.sh

run: bundle  ## Build the bundle and launch it
	open $(APP)

# ---- test -------------------------------------------------------------

.PHONY: test e2e e2e-ci smoke smoke-real-launch smoke-launch-window
test:  ## swift test (ShedKit unit tests)
	swift test

e2e:  ## pytest functional harness against a running/auto-launched app
	uv run --group test pytest tools/shedtest

e2e-ci: bundle  ## E2E at CI parity: fresh, test-mode, hermetic mock server
	SHED_DESKTOP_TEST_MODE=1 SHED_DESKTOP_TEST_TIMEOUT_SCALE=4 uv run --group test pytest tools/shedtest -q

smoke:  ## Drive the app and capture labeled screenshots
	tools/screenshot/smoke.sh

smoke-real-launch: bundle  ## Non-test launch survival check (real notification path, issue #2)
	./scripts/smoke-real-launch.sh

smoke-launch-window: bundle  ## Non-test launch/reopen window behavior (issue #4)
	./scripts/smoke-launch-window.sh

# ---- docs -------------------------------------------------------------

.PHONY: docs docs-serve
docs:  ## Build the mkdocs site into site-build/
	uv run --group docs mkdocs build

docs-serve:  ## Serve the docs locally with live reload
	uv run --group docs mkdocs serve

# ---- lint / format ----------------------------------------------------

.PHONY: fmt lint clean
fmt:  ## Format Swift sources with swift-format
	swift format format -i -r Sources Tests

lint:  ## Lint Swift sources with swift-format
	swift format lint -r Sources Tests

clean:  ## Remove build artifacts
	rm -rf .build build site-build
