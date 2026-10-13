# Roda os testes do núcleo (FreeYomiKit) no Windows usando Docker Desktop.
# Uso: powershell -ExecutionPolicy Bypass -File scripts/test-core.ps1 [-Live]
param([switch]$Live)
$root = Split-Path -Parent $PSScriptRoot
$envArgs = @()
if ($Live) { $envArgs = @("-e", "FY_LIVE_TESTS=1") }
docker run --rm @envArgs -v "${root}:/src" -w /src/Packages/FreeYomiKit swift:6.1-noble `
  bash -c "apt-get update -qq && apt-get install -y -qq libsqlite3-dev zlib1g-dev >/dev/null && swift test"
