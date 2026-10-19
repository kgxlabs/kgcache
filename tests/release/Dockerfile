# check=skip=InvalidDefaultArgInFrom
# The runner supplies the pinned base from tools/release/settings.sh.
ARG RUNTIME_BASE
FROM ${RUNTIME_BASE} AS runtime
COPY artifact/bin/kgcache /usr/local/bin/kgcache
COPY runtime.sh /checks/runtime.sh
ENTRYPOINT ["bash", "/checks/runtime.sh"]
CMD []

FROM runtime AS inspection
RUN apt-get update \
    && apt-get install -y --no-install-recommends binutils file jq \
    && rm -rf /var/lib/apt/lists/*
COPY artifact /release
COPY tools/release /probe/tools/release
ENTRYPOINT ["bash", "/probe/tools/release/inspect.sh", "/release"]

FROM runtime AS tests
COPY test-tools /tests
RUN mkdir -p /evidence/process
WORKDIR /work
ENV KGCACHE_TEST_ARTIFACT_DIR=/evidence/process
# A normal server must ignore the test control setting. Controlled test servers
# receive their own settings from the integration harness.
ENV KGCACHE_TEST_CONTROL=invalid-release-control
ENTRYPOINT ["timeout", "--signal=TERM", "--kill-after=5s", "180s", "/tests/kgcache-integration", "/usr/local/bin/kgcache", "/tests/kgcache-fake-server", "/tests/kgcache-controlled-server"]
