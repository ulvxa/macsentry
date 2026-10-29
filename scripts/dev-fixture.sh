#!/bin/bash
# Builds the fake home the Debug scheme scans. Only creates files, never deletes. No-op if the root already exists.
set -euo pipefail

root="${1:?usage: dev-fixture.sh <root>}"
[[ -d "$root" ]] && exit 0
mkdir -p "$root"
cd "$root"

blob() { # path, size in MB, optional age in days
    mkdir -p "$(dirname "$1")"
    dd if=/dev/zero of="$1" bs=1m count="$2" status=none
    if [[ -n "${3:-}" ]]; then touch -t "$(date -v-"$3"d +%Y%m%d%H%M)" "$1"; fi
}

support="Library/Application Support"
blob "$support/Notion/Partitions/notion/Cache/Cache_Data/data_0" 40
blob "$support/Notion/Partitions/notion/Code Cache/js/index" 20
blob "$support/Notion/Partitions/notion/Service Worker/CacheStorage/entry" 30
blob "$support/Notion/Partitions/notion/Local Storage/leveldb/000003.log" 1
blob "$support/Google/Chrome/Default/Service Worker/CacheStorage/entry" 25
blob "$support/Google/Chrome/Default/GPUCache/data_1" 5
blob "$support/Google/Chrome/Default/IndexedDB/db/000001.log" 1
blob "$support/RealtimeBoard/Cache/Cache_Data/data_0" 15
blob "$support/Figma/DesktopProfile/v43/Code Cache/js/index" 15
blob "$support/Caches/example-updater/pending/update.zip" 20
blob "$support/com.deleted.legacyapp/store.bin" 30 400

blob "Library/Caches/com.example.tool/cache.db" 12
blob "Library/Caches/com.example.tool.ShipIt/update.zip" 18
blob "Library/Caches/Homebrew/downloads/pkg.tar.gz" 25
blob "Library/Caches/com.apple.Safari/Cache.db" 3
blob "Library/Containers/com.example.sandboxed/Data/Library/Caches/blob" 10
blob "Library/Containers/com.example.sandboxed/Data/Library/Preferences/prefs.bin" 1
blob "Library/Developer/Xcode/DerivedData/Demo-abcdef/Build/out.o" 40
blob "Library/Logs/old-tool.log" 2 90
blob ".npm/_cacache/content-v2/sha512/blob" 15

blob "Projects/webapp/node_modules/left-pad/index.js" 20 300
echo '{"name":"webapp"}' > Projects/webapp/package.json
git -C Projects/webapp init -q
touch -t "$(date -v-300d +%Y%m%d%H%M)" Projects/webapp Projects/webapp/package.json

blob "Downloads/Old Installer.dmg" 520 400
blob "Documents/report-final.bin" 8
cp "Documents/report-final.bin" "Documents/report-final copy.bin"
