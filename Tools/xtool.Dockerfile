# The iOS build on a Linux host: Swift 6.4 and xtool, which turns an Xcode.xip into a Darwin Swift SDK
# (`make xtool-sdk`) that SwiftPM then builds for iOS against (`make xtool-build-ios`). It cannot run
# the simulator; `make check-ios` on a Mac remains the check for the tests.
FROM swift:6.4.2

ARG XTOOL_VERSION=1.24.0

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl make \
    && rm -rf /var/lib/apt/lists/* \
    && case "$(uname -m)" in \
      x86_64) sum=dbfd9d7216f077c84c171b688c4173c37c23ca76bf7fd185d1a9ae8a53dab59f ;; \
      aarch64) sum=4bc0515fed71efb86e82564f358efa0c4c6d76bf1bcfd4c5f256727b53ec59c8 ;; \
      *) echo "no xtool for $(uname -m)"; exit 1 ;; \
    esac \
    && curl -fsSL -o /tmp/xtool.AppImage \
      "https://github.com/xtool-org/xtool/releases/download/${XTOOL_VERSION}/xtool-$(uname -m).AppImage" \
    && echo "${sum}  /tmp/xtool.AppImage" | sha256sum -c - \
    && chmod +x /tmp/xtool.AppImage \
    && cd /tmp && ./xtool.AppImage --appimage-extract > /dev/null \
    && mv /tmp/squashfs-root /usr/local/xtool \
    && chmod -R a+rX /usr/local/xtool \
    && ln -s /usr/local/xtool/AppRun /usr/local/bin/xtool \
    && rm /tmp/xtool.AppImage

# swift-build 6.4 cannot bundle the tests without a bitcode_strip, which Linux lacks; llvm-objcopy is one by that name.
RUN ln -s llvm-objcopy /usr/bin/bitcode_strip
