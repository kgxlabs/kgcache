# check=skip=InvalidDefaultArgInFrom
# Supply the pinned base from tools/release/settings.sh.
ARG RUNTIME_BASE
FROM --platform=$BUILDPLATFORM ${RUNTIME_BASE} AS builder
ARG BUILDARCH
ARG TARGETOS
ARG TARGETARCH
ARG RUNTIME_BASE
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl xz-utils file jq \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /build
COPY build.zig build.zig.zon ./
COPY tools/release/ tools/release/
COPY tools/container/build.sh tools/container/build.sh
RUN --mount=type=cache,id=kgcache-zig-0.16.0-${BUILDARCH},target=/build/.zig-cache/toolchains,sharing=locked \
    bash tools/release/zig.sh version
COPY src/ src/
COPY tests/integration/ tests/integration/
ARG SOURCE_REVISION
ARG SOURCE_DIRTY=true
ARG VERSION
RUN --mount=type=cache,id=kgcache-zig-0.16.0-${BUILDARCH},target=/build/.zig-cache/toolchains,sharing=locked \
    --mount=type=cache,id=kgcache-objects-0.16.0-${BUILDARCH}-${TARGETOS}-${TARGETARCH},target=/build/.zig-cache/objects,sharing=locked \
    --mount=type=cache,id=kgcache-global-0.16.0-${BUILDARCH}-${TARGETOS}-${TARGETARCH},target=/root/.cache/zig,sharing=locked \
    IMAGE_RUNTIME_BASE="$RUNTIME_BASE" bash tools/container/build.sh

FROM ${RUNTIME_BASE} AS service
RUN groupadd --gid 10001 kgcache \
    && useradd --uid 10001 --gid 10001 --no-create-home --home-dir /data --shell /usr/sbin/nologin kgcache \
    && install -d -o 10001 -g 10001 -m 0750 /data \
    && install -d -o 0 -g 0 -m 0755 /etc/kgcache /usr/share/kgcache
COPY --from=builder --chown=0:0 --chmod=0755 /out/bin/kgcache /usr/local/bin/kgcache
COPY --from=builder --chown=0:0 --chmod=0444 /out/build-info.json /usr/share/kgcache/build-info.json
COPY --chown=0:0 --chmod=0444 containers/kgcache.conf /etc/kgcache/kgcache.conf
ARG SOURCE_REVISION
ARG VERSION
LABEL org.opencontainers.image.title="kgcache" \
      org.opencontainers.image.source="https://github.com/kgxlabs/kgcache" \
      org.opencontainers.image.revision="${SOURCE_REVISION}" \
      org.opencontainers.image.version="${VERSION}"
WORKDIR /data
USER 10001:10001
EXPOSE 6379/tcp
STOPSIGNAL SIGTERM
ENTRYPOINT ["/usr/local/bin/kgcache"]
CMD ["/etc/kgcache/kgcache.conf"]

# Inspection tools are available only with --target diagnostic.
FROM service AS diagnostic
USER 0:0
RUN apt-get update \
    && apt-get install -y --no-install-recommends binutils file procps \
    && rm -rf /var/lib/apt/lists/*
USER 10001:10001

FROM service AS runtime
