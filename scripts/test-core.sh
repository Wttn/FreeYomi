#!/usr/bin/env bash
# Roda os testes do núcleo em Linux/WSL/macOS. Requer Swift 5.9+ e libsqlite3-dev/zlib1g-dev no Linux.
set -euo pipefail
cd "$(dirname "$0")/../Packages/FreeYomiKit"
swift test "$@"
