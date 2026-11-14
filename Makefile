# sdk-ios developer tasks. Mirrors the proto vendoring of sdk-android and Pug's other SDKs: proto/
# and the code generated from it are committed, so builds never touch the Buf Schema Registry. The
# tools come through SwiftPM, pinned by Package.resolved and Tools/Package.resolved, except Swift
# itself and buf, which only re-vendoring proto/ needs.

.PHONY: sync-protos proto-latest check-proto-pin protos protoc reference descriptors typed-track check-codegen verify-version fmt lint build test api-dump api-check check ci build-ios test-ios build-sample tsan check-ios docker-image xtool-image xtool-sdk xtool-build-ios

# `ci` must run `protos` before `check-codegen` diffs the generated files. Keep everything serial
# even under `make -jN`.
.NOTPARALLEL:

# BSR module, pinned commit and paths that proto/ is vendored from: the same as sdk-android. To
# bump: `make proto-latest`, set PROTO_COMMIT, then `make sync-protos protos` and review the diff.
# These three targets need the buf CLI (`brew install bufbuild/buf/buf`); nothing else does.
PROTO_MODULE := buf.build/pugsh/pug
PROTO_COMMIT := 8b5d0680b10c4693b4d9d15d3dbfc663
# An allowlist: buf adds the transitive imports (buf/validate). sdk/devices is left out on purpose,
# since this SDK does no device registration.
PROTO_PATHS := --path sdk/events/v1 --path sdk/profiles/v1 --path common/events/v1 --path common/v1/property_value.proto

SWIFT ?= swift
BUF ?= buf
SWIFTLINT := $(SWIFT) package --package-path Tools --disable-sandbox plugin --allow-writing-to-package-directory swiftlint

REFERENCE := Tests/PugTests/Reference
# What the reference messages cover: the requests the SDK encodes and the response it decodes.
REFERENCE_PROTOS := proto/sdk/events/v1/events.proto proto/sdk/profiles/v1/profiles.proto proto/common/v1/property_value.proto
# The well-known events, sorted so the descriptor sets come out the same everywhere.
EVENT_PROTOS := $(sort $(wildcard proto/common/events/v1/*.proto))
# What WellKnownEventsTests checks the generated registry against, without source info.
EVENT_DESCRIPTORS := Tests/PugTests/Resources/events.binpb
# gen-track's input keeps the source comments, which the generated docs copy.
TYPED_TRACK_INPUT := .build/typed-track/events.binpb
TYPED_TRACK := Sources/Pug/Generated
GENERATED := $(REFERENCE) $(EVENT_DESCRIPTORS) $(TYPED_TRACK)
# The well-known types the SwiftProtobuf runtime is generated from, for protoc's import path.
WELL_KNOWN_TYPES := .build/checkouts/swift-protobuf/Protos/Sources/SwiftProtobuf
# What swift-format owns. The reference messages opt out with a swift-format-ignore-file comment;
# gen-track writes what swift-format would.
FORMATTED := Package.swift Tools/Package.swift Tools/Sources Sources Tests Examples
WARNINGS_AS_ERRORS := -Xswiftc -warnings-as-errors
EM_DASH := $(shell printf '\342\200\224')

sync-protos:
	rm -rf proto
	$(BUF) export $(PROTO_MODULE):$(PROTO_COMMIT) --output proto $(PROTO_PATHS)
	@echo "Synced SDK protos into proto/ at $(PROTO_COMMIT). Run 'make protos' to regenerate."

proto-latest:
	@$(BUF) registry module commit resolve $(PROTO_MODULE):main

# Release gate (needs network): proves proto/ is exactly what the pinned commit exports. CI cannot
# see a hand-patched proto/, because `protos` regenerates consistently from whatever is committed.
check-proto-pin:
	@rm -rf .build/proto-pin-check
	@$(BUF) export $(PROTO_MODULE):$(PROTO_COMMIT) --output .build/proto-pin-check $(PROTO_PATHS)
	@diff -r proto .build/proto-pin-check \
	  && echo "proto/ matches $(PROTO_MODULE):$(PROTO_COMMIT)." \
	  || { echo "proto/ diverges from $(PROTO_COMMIT); re-run 'make sync-protos protos'."; exit 1; }

# Everything generated from proto/.
protos: reference descriptors typed-track

# protoc and protoc-gen-swift come from the swift-protobuf that Package.resolved pins, so the reference
# messages match the runtime the tests link. protoc builds from source the first time, which takes a
# few minutes.
protoc:
	$(SWIFT) build -c release --product protoc
	$(SWIFT) build -c release --product protoc-gen-swift

# The swift-protobuf messages the wire tests compare the SDK's own codec with.
reference: protoc
	rm -rf $(REFERENCE)
	mkdir -p $(REFERENCE)
	bin="$$($(SWIFT) build -c release --show-bin-path)"; \
	"$$bin/protoc" --plugin="$$bin/protoc-gen-swift" --swift_opt=FileNaming=PathToUnderscores --swift_out=$(REFERENCE) \
	  --proto_path=proto --proto_path=$(WELL_KNOWN_TYPES) $(REFERENCE_PROTOS)

descriptors: protoc
	mkdir -p $(dir $(EVENT_DESCRIPTORS))
	"$$($(SWIFT) build -c release --show-bin-path)/protoc" --descriptor_set_out=$(EVENT_DESCRIPTORS) \
	  --proto_path=proto --proto_path=$(WELL_KNOWN_TYPES) $(EVENT_PROTOS)

# The typed track API from the event protos: Pug.track's methods, Pug.Events and the WellKnownEvents
# registry, written by Tools/gen-track.
typed-track: protoc
	mkdir -p $(dir $(TYPED_TRACK_INPUT))
	"$$($(SWIFT) build -c release --show-bin-path)/protoc" --include_source_info \
	  --descriptor_set_out=$(TYPED_TRACK_INPUT) --proto_path=proto --proto_path=$(WELL_KNOWN_TYPES) $(EVENT_PROTOS)
	$(SWIFT) run --package-path Tools -c release gen-track $(TYPED_TRACK_INPUT) $(TYPED_TRACK)

# CI gate: the committed generated files must match a fresh `make protos`, new files included.
check-codegen:
	@drift="$$(git status --porcelain -- $(GENERATED))" || exit 1; \
	test -z "$$drift" \
	  || { git status --short -- $(GENERATED); echo "codegen drift: run 'make protos' and commit"; exit 1; }

# $sdkVersion and the User-Agent come from sdkVersion in Version.swift, which the README's install
# line and the release tag must name too: the release workflow passes the tag as RELEASE_TAG.
verify-version:
	@version="$$(sed -n 's/^let sdkVersion = "\(.*\)"$$/\1/p' Sources/Pug/Version.swift)"; \
	test -n "$$version" || { echo "no sdkVersion in Sources/Pug/Version.swift"; exit 1; }; \
	grep -qF ".package(url: \"https://github.com/pug-sh/sdk-ios.git\", from: \"$$version\")" README.md \
	  || { echo "README.md does not install $$version"; exit 1; }; \
	test -z "$(RELEASE_TAG)" || test "$(RELEASE_TAG)" = "$$version" \
	  || { echo "The tag $(RELEASE_TAG) does not match sdkVersion $$version"; exit 1; }

fmt:
	$(SWIFT) format --in-place --parallel --recursive $(FORMATTED)

# proto/ is vendored and the reference messages copy its comments, so both may hold em dashes.
lint:
	$(SWIFT) format lint --strict --parallel --recursive $(FORMATTED)
	$(SWIFTLINT) lint --strict --quiet --config "$(CURDIR)/.swiftlint.yml" "$(CURDIR)"
	@if git grep -n --untracked -e '$(EM_DASH)' -- ':!proto' ':!$(REFERENCE)'; then \
	  echo "No em dashes in code, comments or docs."; exit 1; \
	fi

build:
	$(SWIFT) build $(WARNINGS_AS_ERRORS)

test:
	$(SWIFT) test $(WARNINGS_AS_ERRORS)

# The public API, as api/Pug.api records it: Tools/api-dump renders the symbol graph of the module
# `build` compiled. After a change to the API, `make api-dump` rewrites the file, to review and commit
# with the change; `api-check` fails until then. CI's Swift 6.2 writes it, since compilers print some
# declarations differently.
API := api/Pug.api
API_DUMP := .build/api-dump
DUMP_API = rm -rf $(API_DUMP) && mkdir -p $(API_DUMP) $(dir $(1)) \
  && bin="$$($(SWIFT) build --show-bin-path)" \
  && triple="$$($(SWIFT) -print-target-info | sed -n 's/^ *"triple": "\(.*\)",$$/\1/p' | head -n 1)" \
  && sdk="$$(xcrun --show-sdk-path 2>/dev/null || true)" \
  && $(SWIFT) symbolgraph-extract -module-name Pug -target "$$triple" $${sdk:+-sdk "$$sdk"} -I "$$bin/Modules" \
    -minimum-access-level public -skip-synthesized-members -output-dir $(API_DUMP) \
  && $(SWIFT) run --package-path Tools -c release api-dump $(API_DUMP)/Pug.symbols.json $(1)

api-dump: build
	$(call DUMP_API,$(API))

api-check: build
	$(call DUMP_API,$(API_DUMP)/Pug.api)
	@diff -u $(API) $(API_DUMP)/Pug.api \
	  || { echo "The public API is not what $(API) records: review the diff, run 'make api-dump' and commit it."; \
	    exit 1; }

check: verify-version lint build api-check test

ci: protos check-codegen check

# macOS only, from here to the Docker targets: the SDK for an iOS device with warnings as errors, the
# sample app, the tests on the first iPhone simulator available, and under Thread Sanitizer.
SAMPLE := Examples/PugSample
build-ios:
	xcodebuild build -quiet -scheme Pug -destination 'generic/platform=iOS' SWIFT_TREAT_WARNINGS_AS_ERRORS=YES

# The sample app for the simulator, which needs no signing. The project turns SAMPLE_WARNINGS_AS_ERRORS into
# warnings as errors for the sample's own code: Xcode builds the Pug package with its warnings suppressed, and
# rejects both flags at once.
build-sample:
	xcodebuild build -quiet -project $(SAMPLE)/PugSample.xcodeproj -scheme PugSample \
	  -destination 'generic/platform=iOS Simulator' SAMPLE_WARNINGS_AS_ERRORS=YES CODE_SIGNING_ALLOWED=NO

# In the recipe's shell rather than $(shell): make counts the sed expression's parentheses.
test-ios:
	id="$$(xcrun simctl list devices available | sed -n 's/^ *iPhone[^(]*(\([0-9A-F-]\{36\}\)).*/\1/p' | head -n 1)"; \
	test -n "$$id" || { echo "no iPhone simulator available"; exit 1; }; \
	xcodebuild test -quiet -scheme Pug -destination "platform=iOS Simulator,id=$$id"

tsan:
	$(SWIFT) test --sanitize=thread

check-ios: build test build-ios build-sample test-ios tsan

# The Linux CI job's container, for a host without Swift: `make docker-<target>` runs `make <target>`
# in it, as in `make docker-check` or `make docker-fmt`.
DOCKER_IMAGE := pug-sdk-ios-linux

docker-image:
	docker build --quiet --tag $(DOCKER_IMAGE) - < Tools/linux.Dockerfile > /dev/null

docker-%: docker-image
	docker run --rm --user "$$(id -u):$$(id -g)" --env HOME=/tmp --volume "$(CURDIR):/src" --workdir /src $(DOCKER_IMAGE) make $*

# The SDK for an iOS device, and its tests for the simulator, without a Mac, in xtool's container
# (Tools/xtool.Dockerfile). Install the Darwin Swift SDK once, from an Xcode.xip downloaded with an Apple ID,
# with `make xtool-sdk XIP=/path/to/Xcode.xip`: it lands in ~/.swiftpm, where SwiftPM looks for it. Builds go
# to .build/xtool, apart from the Linux ones, since the toolchain is newer than CI's.
XTOOL_IMAGE := pug-sdk-ios-xtool
XTOOL_SDK := /tmp/.config/swiftpm/swift-sdks/darwin.artifactbundle
# Through the XDG variables, since Foundation reads the home directory from /etc/passwd, not HOME.
XTOOL_RUN = docker run --rm --user "$$(id -u):$$(id -g)" --env HOME=/tmp --env XDG_CONFIG_HOME=/tmp/.config \
  --env XDG_CACHE_HOME=/tmp/.cache --volume "$(HOME)/.swiftpm:/tmp/.config/swiftpm" --volume "$(CURDIR):/src" \
  --workdir /src
# swift-build, SwiftPM's default, as xtool runs it: it fails with --swift-sdk.
XTOOL_BUILD = $(XTOOL_RUN) --env XCODE_EXTRA_PLATFORM_FOLDERS=$(XTOOL_SDK)/Developer/Platforms $(XTOOL_IMAGE) \
  swift build --scratch-path .build/xtool --toolset $(XTOOL_SDK)/toolset-swb.json $(WARNINGS_AS_ERRORS)

xtool-image:
	docker build --quiet --tag $(XTOOL_IMAGE) - < Tools/xtool.Dockerfile > /dev/null

xtool-sdk: xtool-image
	@test -f "$(XIP)" || { echo "usage: make xtool-sdk XIP=/path/to/Xcode.xip"; exit 1; }
	mkdir -p "$(HOME)/.swiftpm"
	$(XTOOL_RUN) --volume "$(abspath $(XIP)):/tmp/Xcode.xip:ro" $(XTOOL_IMAGE) xtool sdk install --slim /tmp/Xcode.xip

# Then the sample's sources are typechecked against the SDK built for a device: only Xcode builds
# the app.
xtool-build-ios: xtool-image
	mkdir -p "$(HOME)/.swiftpm"
	$(XTOOL_BUILD) --triple arm64-apple-ios --target Pug
	$(XTOOL_BUILD) --triple arm64-apple-ios-simulator --build-tests
	$(XTOOL_RUN) $(XTOOL_IMAGE) swiftc -typecheck -parse-as-library -swift-version 6 -warnings-as-errors \
	  -target arm64-apple-ios15.0 -sdk $(XTOOL_SDK)/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS.sdk \
	  -resource-dir $(XTOOL_SDK)/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift \
	  -Xfrontend -enable-cross-import-overlays -I .build/xtool/out/Products/Debug-iphoneos \
	  $(wildcard $(SAMPLE)/PugSample/*.swift)
