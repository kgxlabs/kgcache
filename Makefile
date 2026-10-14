.DEFAULT_GOAL := build

ZIG ?= zig
GO ?= go
NODE ?= node

REPO_ROOT := $(shell CDPATH= cd "$$(dirname '$(MAKEFILE_LIST)')" && pwd -P)
CLIENT_ROOT := $(REPO_ROOT)/tests/integration/clients
CLIENT_TOOL_ROOT := $(REPO_ROOT)/.client-tools
export PATH := $(CLIENT_TOOL_ROOT)/go/bin:$(CLIENT_TOOL_ROOT)/node/bin:$(PATH)
override KGCACHE_BIN := $(REPO_ROOT)/zig-out/bin/kgcache

ifneq ($(strip $(KGCACHE_TEST_ARTIFACT_DIR)),)
override KGCACHE_TEST_ARTIFACT_DIR := $(shell case "$(KGCACHE_TEST_ARTIFACT_DIR)" in (/*) printf '%s' "$(KGCACHE_TEST_ARTIFACT_DIR)" ;; (*) printf '%s/%s' "$(REPO_ROOT)" "$(KGCACHE_TEST_ARTIFACT_DIR)" ;; esac)
endif

export GO
export GOTOOLCHAIN := local
export GOWORK := off
export KGCACHE_BIN KGCACHE_TEST_ARTIFACT_DIR
export GO_TEST_ARGS NODE_TEST_ARGS

CLIENT_SELECTOR = --profile "$(CLIENT_PROFILE)" --library "$(CLIENT_LIBRARY)"
GO_RUN = $(GO) run "$(CLIENT_ROOT)/go/run.go"
NODE_RUN = $(NODE) --experimental-strip-types "$(CLIENT_ROOT)/node/run.ts"

.PHONY: build test test-zig test-unit test-integration test-go test-node test-clients \
	deps-go deps-node deps-clients list-clients check-go check-node check-clients \
	fmt-go fmt-node

build:
	cd "$(REPO_ROOT)" && $(ZIG) build -Doptimize=Debug

test-zig: test-unit test-integration

test-unit:
	cd "$(REPO_ROOT)" && $(ZIG) build test

test-integration:
	cd "$(REPO_ROOT)" && $(ZIG) build test-integration

deps-go:
	$(GO_RUN) deps $(CLIENT_SELECTOR)

deps-node:
	$(NODE_RUN) deps $(CLIENT_SELECTOR)

deps-clients: deps-go deps-node

list-clients:
	$(GO_RUN) list
	$(NODE_RUN) list

check-go:
	$(GO_RUN) check $(CLIENT_SELECTOR)

fmt-go:
	$(GO_RUN) fmt $(CLIENT_SELECTOR)

check-node:
	$(NODE_RUN) validate $(CLIENT_SELECTOR)
	cd "$(CLIENT_ROOT)/node" && npm run check

fmt-node:
	$(NODE_RUN) validate $(CLIENT_SELECTOR)
	cd "$(CLIENT_ROOT)/node" && npm run format

check-clients: check-go check-node

test-go: build deps-go
	@test -f "$(KGCACHE_BIN)" && test -x "$(KGCACHE_BIN)"
	$(GO_RUN) test $(CLIENT_SELECTOR)

test-node: build deps-node
	@test -f "$(KGCACHE_BIN)" && test -x "$(KGCACHE_BIN)"
	$(NODE_RUN) test $(CLIENT_SELECTOR)

test-clients: test-go test-node

test:
	$(MAKE) -C "$(REPO_ROOT)" -k test-zig test-go test-node
