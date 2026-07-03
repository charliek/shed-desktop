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
build: core  ## swift build the package
	swift build

bundle:  ## Build + assemble ShedDesktop.app (debug)
	./scripts/bundle.sh debug

dmg:  ## Build a release bundle + package a drag-install DMG
	./scripts/bundle.sh release
	./scripts/make-dmg.sh

run: bundle  ## Build the bundle and launch it
	open $(APP)

# ---- rust core --------------------------------------------------------
# The Swift package links a static xcframework generated from the Rust core, so
# `core` must run before any bare `swift build`/`swift test` (build/test depend
# on it; bundle.sh builds it itself). See plans/phase-1-rust-core.md.

.PHONY: core core-test core-lint core-fmt core-linux
core:  ## Build the Rust core + generate Swift UniFFI bindings (xcframework)
	./scripts/build-core.sh debug

core-test:  ## cargo test the Rust core workspace
	cd core && cargo test

core-lint:  ## cargo clippy the Rust core (deny warnings; excludes GTK)
	cd core && cargo clippy --workspace --exclude shed-gtk --all-targets -- -D warnings

core-fmt:  ## cargo fmt the Rust core
	cd core && cargo fmt --all

# ---- shed-gtk (Linux client; also builds on macOS via Homebrew GTK) ----
# shed-gtk is a workspace member but NOT a default member, so the targets above
# never build GTK. Building it is opt-in. On macOS: `brew install gtk4 libadwaita`.

DEB_VERSION ?= 0.0.1-dev

.PHONY: gtk-build gtk-run gtk-lint gtk-build-linux deb deb-validate
gtk-build:  ## Build shed-gtk (Homebrew GTK on macOS; libgtk-4-dev on Linux)
	cd core && cargo build -p shed-gtk

gtk-run: gtk-build  ## Build + launch shed-gtk (native window on macOS/Linux)
	cd core && cargo run -p shed-gtk --bin shed-desktop

gtk-lint:  ## clippy shed-gtk (needs GTK dev libs)
	cd core && cargo clippy -p shed-gtk --all-targets -- -D warnings

gtk-build-linux:  ## Build + clippy shed-gtk on Linux in Docker (ubuntu:24.04 + GTK)
	docker build -t shed-core-linux:latest - < Dockerfile.linux
	docker run --rm \
	  -v "$(CURDIR)/core:/work:ro" \
	  -v shed-core-linux-target:/target \
	  -v shed-core-linux-cargo:/usr/local/cargo/registry \
	  -e CARGO_TARGET_DIR=/target \
	  -w /work shed-core-linux:latest \
	  bash -lc 'cargo build -p shed-gtk --locked && \
	            cargo clippy -p shed-gtk --all-targets --locked -- -D warnings && \
	            cargo test -p shed-gtk --lib --locked'

deb:  ## Build the shed-desktop .deb in Docker (ubuntu:24.04 + GTK + nfpm) → out/ (DEB_VERSION=x)
	docker build -t shed-core-linux:latest - < Dockerfile.linux
	docker run --rm \
	  -v "$(CURDIR):/repo" \
	  -v shed-core-linux-target:/target \
	  -v shed-core-linux-cargo:/usr/local/cargo/registry \
	  -e CARGO_TARGET_DIR=/target \
	  -w /repo shed-core-linux:latest \
	  bash -lc 'echo "deb [trusted=yes] https://repo.goreleaser.com/apt/ /" > /etc/apt/sources.list.d/goreleaser.list && \
	            apt-get update -qq && apt-get install -y -qq nfpm >/dev/null && \
	            ./linux/scripts/build-deb.sh $(DEB_VERSION)'

deb-validate: deb  ## Build + install-validate the .deb in a clean ubuntu:24.04 container
	./linux/scripts/validate-deb.sh $$(ls -t out/shed-desktop_*.deb | head -1)

# ---- tauri (Phase A: a real Linux client toward Mac parity) -----------

.PHONY: tauri-build tauri-run tauri-lint tauri-ui-build
tauri-ui-build:  ## Build the Vite/React frontend bundle (tauri/ui/dist)
	cd tauri/ui && npm run build

tauri-build: tauri-ui-build  ## Build the Tauri client: the frontend bundle + the standalone Rust workspace
	cd tauri/src-tauri && cargo build

tauri-run:  ## Launch the Tauri client via the dev loop (Vite dev server + WKWebView/WebKitGTK)
	cd tauri/src-tauri && cargo tauri dev

tauri-lint:  ## clippy the Tauri client (its own standalone workspace; kept out of core-lint)
	cd tauri/src-tauri && cargo clippy --all-targets -- -D warnings

core-linux:  ## Build+test shed-core on Linux in Docker (ubuntu:24.04; ring needs build-essential)
	docker build -t shed-core-linux:latest - < Dockerfile.linux
	docker run --rm \
	  -v "$(CURDIR)/core:/work:ro" \
	  -v shed-core-linux-target:/target \
	  -v shed-core-linux-cargo:/usr/local/cargo/registry \
	  -e CARGO_TARGET_DIR=/target \
	  -w /work shed-core-linux:latest \
	  bash -lc 'cargo test -p shed-core --all-targets --locked && \
	            cargo clippy -p shed-core --all-targets --locked -- -D warnings'

# ---- test -------------------------------------------------------------

.PHONY: test e2e e2e-ci e2e-swift e2e-gtk e2e-tauri m0-gates smoke smoke-real-launch smoke-launch-window
test: core  ## swift test (ShedKit unit tests + Rust FFI canary)
	swift test

e2e:  ## pytest functional harness against a running/auto-launched app
	uv run --group test pytest tools/shedtest

e2e-ci: bundle  ## E2E at CI parity: fresh, test-mode, hermetic mock (Rust core, default)
	SHED_DESKTOP_TEST_MODE=1 SHED_DESKTOP_TEST_TIMEOUT_SCALE=4 uv run --group test pytest tools/shedtest -q

e2e-swift: bundle  ## E2E with the Rust core forced off (SHED_DESKTOP_RUST_CORE=0 fallback leg)
	SHED_DESKTOP_TEST_MODE=1 SHED_DESKTOP_RUST_CORE=0 SHED_DESKTOP_TEST_TIMEOUT_SCALE=4 uv run --group test pytest tools/shedtest -q

m0-gates:  ## M0 ship-gates (release bundle): arm64/size/cold-launch + golden cross-backend byte-diff
	./scripts/bundle.sh release
	SHED_DESKTOP_SIZE_BUDGET_MB=20 uv run --group test python tools/shedtest/m0_ship_gates.py

e2e-gtk: gtk-build  ## GTK e2e: the shared suite at --target gtk (needs a display; Xvfb on Linux)
	uv run --group test pytest tools/shedtest --target gtk -q

e2e-tauri: tauri-build  ## Tauri e2e: shared suite + test_tauri at --target tauri (needs a display; Xvfb on Linux)
	uv run --group test pytest tools/shedtest --target tauri -q

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
