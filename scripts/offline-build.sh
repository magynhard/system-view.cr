#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
prefix="${1:-/usr}"
patch --forward --batch -p1 -d lib/gi-crystal < packaging/patches/gi-crystal-offline-version.patch
for directory in lib/*/; do
    ln -sfn .. "${directory}lib"
done
mkdir -p bin
export CRYSTAL_LIBRARY_PATH="$(pkg-config --variable=libdir bdw-gc)"
(cd lib/gi-crystal && crystal build src/generator/main.cr --no-debug -o ../../bin/gi-crystal)
./bin/gi-crystal
crystal tool format --check src/ spec/ tests/ui_smoke.cr
make test
cpu=x86-64
if [[ "$(uname -m)" == aarch64 ]]; then cpu=generic; fi
make install PREFIX="$prefix" CRYSTAL_FLAGS="--release --no-debug --mcpu $cpu"
for database in /usr/share/hwdata/pci.ids /usr/share/misc/pci.ids; do
    if [[ -f "$database" ]]; then
        install -Dm644 "$database" "${DESTDIR:-}$prefix/share/hwdata/pci.ids"
        break
    fi
done
if [[ -f /usr/share/libdrm/amdgpu.ids ]]; then
    install -Dm644 /usr/share/libdrm/amdgpu.ids "${DESTDIR:-}$prefix/share/libdrm/amdgpu.ids"
fi
python3 scripts/packaging.py licenses "${DESTDIR:-}$prefix"
