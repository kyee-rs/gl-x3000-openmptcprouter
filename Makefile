SHELL := /bin/sh
.DEFAULT_GOAL := build

IMAGE ?= gl-x3000-omr-builder:debian13
BUILD_DIR ?= $(CURDIR)/.build
DIST_DIR ?= $(CURDIR)/dist
JOBS ?= 8
HOST_UID := $(shell id -u)
HOST_GID := $(shell id -g)

DOCKER_RUN = docker run --rm --init \
	--cap-drop=ALL \
	--security-opt=no-new-privileges \
	--pids-limit=4096 \
	--shm-size=1g \
	-e JOBS=$(JOBS) \
	-v "$(CURDIR):/src:ro" \
	-v "$(BUILD_DIR):/work:rw" \
	-v "$(DIST_DIR):/out:rw" \
	$(IMAGE)

.PHONY: image prepare build validate lint preflight shell

image:
	docker build \
		--build-arg HOST_UID=$(HOST_UID) \
		--build-arg HOST_GID=$(HOST_GID) \
		-t $(IMAGE) .

prepare: image
	mkdir -p "$(BUILD_DIR)" "$(DIST_DIR)"
	$(DOCKER_RUN) env PREPARE_ONLY=1 /src/build.sh

build: image
	mkdir -p "$(BUILD_DIR)" "$(DIST_DIR)"
	$(DOCKER_RUN) /src/build.sh

validate: image
	mkdir -p "$(BUILD_DIR)" "$(DIST_DIR)"
	$(DOCKER_RUN) /src/validate.sh /work/openmptcprouter /work/openmptcprouter-feed

lint:
	bash -n build.sh validate.sh scripts/public-release-preflight.sh
	sh -n overlays/openmptcprouter/common/package/base-files/files/etc/uci-defaults/99-cellular-control-owner
	sh -n overlays/openmptcprouter/common/package/base-files/files/etc/uci-defaults/99-fw4-videochat-compat
	sh -n overlays/openmptcprouter/common/package/base-files/files/etc/hotplug.d/iface/31-mptcp-modemmanager-endpoint-sync
	git apply --numstat < patches/kernel/499-bus-mhi-host-pci-generic-gl-x3000-rm520n-mbim.patch
	git apply --numstat < patches/modemmanager/010-broadband-modem-mbim-handle-mhi-pci-generic.patch
	git apply --numstat < patches/modemmanager/011-quectel-disable-at-over-mbim-on-wwan.patch
	git apply --numstat < patches/openmptcprouter/0001-build-recognize-gl-x3000-aarch64.patch
	git apply --numstat < patches/openmptcprouter/0002-build-use-versioned-https-apk-feeds.patch
	git apply --numstat < patches/openmptcprouter/0003-linux-6.18-fix-bbr-div-u64.patch
	git apply --numstat < patches/openmptcprouter-feed/0001-modemmanager-bump-release.patch

preflight: lint
	scripts/public-release-preflight.sh

shell: image
	mkdir -p "$(BUILD_DIR)" "$(DIST_DIR)"
	docker run --rm -it --init \
		--cap-drop=ALL \
		--security-opt=no-new-privileges \
		--shm-size=1g \
		-v "$(CURDIR):/src:ro" \
		-v "$(BUILD_DIR):/work:rw" \
		-v "$(DIST_DIR):/out:rw" \
		$(IMAGE) /bin/bash
