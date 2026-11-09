#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/cache
export CLANG_MODULE_CACHE_PATH="$PWD/.build/cache/clang"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/cache/swiftpm"
command="$1"
shift
if [[ "$command" == test ]]; then
    macros="$(xcode-select -p)/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib"
    if [[ -f "$macros" ]]; then
        set -- --disable-xctest -Xswiftc -load-plugin-library -Xswiftc "$macros" "$@"
    fi
fi
exec swift "$command" --disable-sandbox --cache-path "$PWD/.build/cache" "$@"
