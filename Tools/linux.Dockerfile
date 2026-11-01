# The Linux CI job's environment, for `make docker-<target>` on a host without Swift: the official
# Swift 6.2 image plus make. Every other tool comes through SwiftPM.
FROM swift:6.2

RUN apt-get update \
    && apt-get install -y --no-install-recommends make \
    && rm -rf /var/lib/apt/lists/*
