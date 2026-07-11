FROM debian:13-slim

SHELL ["/bin/bash", "-o", "pipefail", "-c"]
ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        7zip \
        asciidoc \
        autoconf \
        automake \
        autopoint \
        bash \
        binutils \
        bison \
        build-essential \
        bzip2 \
        ca-certificates \
        ccache \
        clang \
        cmake \
        curl \
        device-tree-compiler \
        file \
        flex \
        g++ \
        gawk \
        gettext \
        git \
        gperf \
        help2man \
        libelf-dev \
        libglib2.0-dev \
        libncurses-dev \
        libssl-dev \
        libtool \
        libtool-bin \
        libz-dev \
        llvm \
        make \
        msmtp \
        ninja-build \
        patch \
        perl \
        pkgconf \
        python3 \
        python3-docutils \
        python3-pyelftools \
        python3-setuptools \
        python3-yaml \
        qemu-utils \
        rsync \
        squashfs-tools \
        subversion \
        swig \
        tar \
        texinfo \
        time \
        uglifyjs \
        unzip \
        upx-ucl \
        wget \
        xmlto \
        xz-utils \
        zlib1g-dev \
        zstd \
    && rm -rf /var/lib/apt/lists/*

ARG HOST_UID=1000
ARG HOST_GID=1000
RUN set -eux; \
    if ! getent group "${HOST_GID}" >/dev/null; then \
        groupadd --gid "${HOST_GID}" builder; \
    fi; \
    useradd --uid "${HOST_UID}" --gid "${HOST_GID}" --create-home --shell /bin/bash builder

USER builder
WORKDIR /work
