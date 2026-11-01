# sdk-ios developer tasks. Mirrors the proto vendoring of sdk-android and Pug's other SDKs: proto/
# and the code generated from it are committed, so builds never touch the Buf Schema Registry. The
# tools come through SwiftPM, pinned by Package.resolved and Tools/Package.resolved, except Swift
# itself and buf, which only re-vendoring proto/ needs.

.PHONY: sync-protos proto-latest check-proto-pin protos reference check-codegen verify-version fmt lint build test check ci build-ios test-ios tsan check-ios docker-image

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
GENERATED := $(REFERENCE)
# What the reference messages cover: the requests the SDK encodes and the response it decodes.
REFERENCE_PROTOS := proto/sdk/events/v1/events.proto proto/sdk/profiles/v1/profiles.proto proto/common/v1/property_value.proto
# The well-known types the SwiftProtobuf runtime is generated from, for protoc's import path.
WELL_KNOWN_TYPES := .build/checkouts/swift-protobuf/Protos/Sources/SwiftProtobuf
# What swift-format owns. Generated files opt out with a swift-format-ignore-file comment.
FORMATTED := Package.swift Tools/Package.swift Sources Tests
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
protos: reference

# The swift-protobuf messages the wire tests compare the SDK's own codec with. protoc and
# protoc-gen-swift come from the swift-protobuf that Package.resolved pins, so the messages match
# the runtime the tests link. protoc builds from source the first time, which takes a few minutes.
reference:
	$(SWIFT) build -c release --product protoc
	$(SWIFT) build -c release --product protoc-gen-swift
	rm -rf $(REFERENCE)
	mkdir -p $(REFERENCE)
	bin="$$($(SWIFT) build -c release --show-bin-path)"; \
	"$$bin/protoc" --plugin="$$bin/protoc-gen-swift" --swift_opt=FileNaming=PathToUnderscores --swift_out=$(REFERENCE) \
	  --proto_path=proto --proto_path=$(WELL_KNOWN_TYPES) $(REFERENCE_PROTOS)

# CI gate: the committed generated files must match a fresh `make protos`, new files included.
check-codegen:
	@drift="$$(git status --porcelain -- $(GENERATED))" || exit 1; \
	test -z "$$drift" \
	  || { git status --short -- $(GENERATED); echo "codegen drift: run 'make protos' and commit"; exit 1; }

# $sdkVersion and the User-Agent come from sdkVersion in Version.swift, which the README's install
# line and the release tag must name too.
verify-version:
	@version="$$(sed -n 's/^let sdkVersion = "\(.*\)"$$/\1/p' Sources/Pug/Version.swift)"; \
	test -n "$$version" || { echo "no sdkVersion in Sources/Pug/Version.swift"; exit 1; }; \
	grep -qF ".package(url: \"https://github.com/pug-sh/sdk-ios.git\", from: \"$$version\")" README.md \
	  || { echo "README.md does not install $$version"; exit 1; }

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

check: verify-version lint build test

ci: protos check-codegen check

# macOS only, from here to the Docker targets: the SDK for an iOS device with warnings as errors (the
# CI floor job runs it under Xcode 16.0), the tests on an iOS simulator, and under Thread Sanitizer.
IOS_SIMULATOR = $(shell xcrun simctl list devices available | sed -n 's/^ *iPhone[^(]*(\([0-9A-F-]\{36\}\)).*/\1/p' | head -n 1)

build-ios:
	xcodebuild build -quiet -scheme Pug -destination 'generic/platform=iOS' SWIFT_TREAT_WARNINGS_AS_ERRORS=YES

test-ios:
	@test -n "$(IOS_SIMULATOR)" || { echo "no iPhone simulator available"; exit 1; }
	xcodebuild test -quiet -scheme Pug -destination 'platform=iOS Simulator,id=$(IOS_SIMULATOR)'

tsan:
	$(SWIFT) test --sanitize=thread

check-ios: build test build-ios test-ios tsan

# The Linux CI job's container, for a host without Swift: `make docker-<target>` runs `make <target>`
# in it, as in `make docker-check` or `make docker-fmt`.
DOCKER_IMAGE := pug-sdk-ios-linux

docker-image:
	docker build --quiet --tag $(DOCKER_IMAGE) - < Tools/linux.Dockerfile > /dev/null

docker-%: docker-image
	docker run --rm --user "$$(id -u):$$(id -g)" --env HOME=/tmp --volume "$(CURDIR):/src" --workdir /src $(DOCKER_IMAGE) make $*
