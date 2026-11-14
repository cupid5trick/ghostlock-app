#!/usr/bin/env bash

# =============== Environemnt
export ANDROID_NDK_HOME=~/Android/Sdk/ndk-bundle



SRC=./src
BUILD_DIR=./out

rm -rf $BUILD_DIR && mkdir -p $BUILD_DIR

function say() {
    echo "[$(date -Is)] $1"
}

function make_target() {
    local TARGET=$1
    say "Building $TARGET under $BUILD_DIR"
    BUILD_ROOT=$BUILD_DIR make -C $SRC $TARGET || exit -1
}

make_target native-host-tests
make_target ion_backend_demo

