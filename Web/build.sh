#!/bin/zsh
# Builds the WebAssembly core with the swift.org toolchain and its WebAssembly SDK.
TC=~/Library/Developer/Toolchains/swift-6.4.2-RELEASE.xctoolchain
cd "${0:A:h}"
./prepare.sh
$TC/usr/bin/swift build --swift-sdk swift-6.4.2-RELEASE_wasm "$@"
