# Everyday development tasks. Nothing here changes the Mac's live setup: the live tests,
# Scripts/verify-tweaks.sh, and Scripts/release.sh stay manual (see docs/DEVELOPMENT.md).

# The release Xcode at /Applications/Xcode.app, never a beta. On a Mac without it, the selected Xcode
# (xcode-select -p). The scripts keep a DEVELOPER_DIR that is already set.
DEVELOPER_DIR ?= $(if $(wildcard /Applications/Xcode.app/Contents/Developer),/Applications/Xcode.app/Contents/Developer,$(shell xcode-select -p))
export DEVELOPER_DIR

ARCH       := $(shell uname -m)
DERIVED    := .build/Xcode
PACKAGES   := .build/SourcePackages
DEBUG_APP  := $(DERIVED)/Build/Products/Debug/Scene.app
SNAPSHOT  ?= /tmp/scene-snap
# Optional: FILTER=<test or suite> for kit-test, THEME=<theme id> and APPEARANCE=light|dark for snapshot.
FILTER    ?=
THEME     ?=
APPEARANCE ?=

# Debug builds sign with Apple Development for team 539293JFA3. A Mac without a development certificate
# signs them to run locally (ad hoc) instead.
LOCAL_SIGN := $(if $(shell security find-identity -v -p codesigning 2>/dev/null | grep -E '"(Apple|Mac) Development'),,\
	CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM=)

XCODEBUILD := xcodebuild -project Scene.xcodeproj -scheme Scene \
	-destination "platform=macOS,arch=$(ARCH)" \
	-derivedDataPath $(DERIVED) -clonedSourcePackagesDirPath $(PACKAGES) $(LOCAL_SIGN)

.DEFAULT_GOAL := help
.PHONY: help build test kit-test app run snapshot themes clean

help: ## List the targets
	@grep -E '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  make %-10s %s\n", $$1, $$2}'

build: ## Debug build of the app and the helper
	$(XCODEBUILD) -configuration Debug -quiet build

test: ## Every SceneKit test through the Scene scheme (Scripts/test.sh)
	./Scripts/test.sh $(LOCAL_SIGN)

kit-test: ## SceneKit tests with Swift Package Manager; FILTER= narrows them
	swift test --package-path Packages/SceneKit $(if $(FILTER),--filter '$(FILTER)')

app: ## Release bundle in build/Scene.app (Scripts/package_app.sh)
	./Scripts/package_app.sh

run: build ## Build, then open the Debug app
	open "$(DEBUG_APP)"

snapshot: build ## Render the app windows to SNAPSHOT= (default /tmp/scene-snap) in the background, without the real switcher
	rm -rf "$(SNAPSHOT)"
	open -W -n -g -a "$(CURDIR)/$(DEBUG_APP)" \
		--env SCENE_SNAPSHOT="$(SNAPSHOT)" --env SCENE_SNAPSHOT_SWITCHER=0 \
		$(if $(THEME),--env SCENE_SNAPSHOT_THEME="$(THEME)") \
		$(if $(APPEARANCE),--env SCENE_SNAPSHOT_APPEARANCE="$(APPEARANCE)") \
		--args -ApplePersistenceIgnoreState YES
	@echo "Snapshots in $(SNAPSHOT)"

themes: ## Generate the bundled themes (Scripts/make-bundled-themes.py)
	python3 Scripts/make-bundled-themes.py

clean: ## Remove build output (.build, build)
	rm -rf .build build
