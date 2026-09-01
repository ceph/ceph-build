# Build environment for cross-compiling Ceph for Windows (ceph.git's
# win32_build.sh) on a builder host, replacing the throwaway libvirt Ubuntu
# VM the windows CI used historically.
#
# Only the toolchain packages live here, mirroring the "ubuntu" branch of
# win32_deps_build.sh (plus make/perl, which the Ubuntu cloud image shipped
# implicitly).  The compiled dependencies themselves (mingw-llvm, boost,
# openssl, ...) are branch-specific, so they are built at run time by
# win32_build.sh and persisted in a host-mounted cache keyed by the deps
# script's hash -- see win32_build_container.
FROM docker.io/library/ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        autoconf \
        bzip2 \
        ca-certificates \
        ccache \
        cmake \
        g++ \
        gcc \
        git \
        libtool \
        make \
        mingw-w64 \
        ninja-build \
        patch \
        perl \
        pkg-config \
        python3-dev \
        python3-yaml \
        sudo \
        wget \
        xz-utils \
        zip \
    && rm -rf /var/lib/apt/lists/*
