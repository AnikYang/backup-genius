#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build
fixture="$(mktemp -d "$PWD/.build/volume-tests.XXXXXX")"
apfs="$fixture/APFS"
exfat_disk=""
cleanup() {
    local detached=1
    if mount | rg -F -- " on $apfs " >/dev/null; then
        hdiutil detach "$apfs" >/dev/null 2>&1 || detached=0
    fi
    if [[ -n "$exfat_disk" ]]; then
        hdiutil detach "$exfat_disk" >/dev/null 2>&1 || detached=0
    fi
    if [[ "$detached" == 1 ]]; then
        rm -rf "$fixture"
    fi
}
trap cleanup EXIT
mkdir "$apfs"
hdiutil create -type SPARSE -size 2g -fs APFS -volname BG-APFS "$fixture/apfs.sparseimage"
hdiutil create -type SPARSE -size 2g -fs ExFAT -layout GPTSPUD -volname "BGX$RANDOM" "$fixture/exfat.sparseimage"
hdiutil attach "$fixture/apfs.sparseimage" -mountpoint "$apfs" -nobrowse
attached="$(hdiutil attach -nomount "$fixture/exfat.sparseimage")"
exfat_disk="$(printf '%s\n' "$attached" | awk '/GUID_partition_scheme/{print $1; exit}')"
partition="$(printf '%s\n' "$attached" | awk '/Microsoft Basic Data/{print $1; exit}')"
[[ -n "$exfat_disk" && -n "$partition" ]]
diskutil mount "$partition"
exfat="$(diskutil info -plist "$partition" | plutil -extract MountPoint raw -)"
export BACKUP_GENIUS_TEST_APFS="$apfs" BACKUP_GENIUS_TEST_EXFAT="$exfat"
if [[ "$#" -gt 0 && "$1" == -- ]]; then
    shift
    "$@"
else
    Scripts/swift-local.sh test "$@"
fi
