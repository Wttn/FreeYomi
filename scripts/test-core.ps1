# Roda os testes do núcleo (FreeYomiKit) no Windows usando Docker Desktop.
# Uso: powershell -ExecutionPolicy Bypass -File scripts/test-core.ps1 [-LiveIndexUrl <endereço de um índice seu>]
param([string]$LiveIndexUrl = "")
$root = Split-Path -Parent $PSScriptRoot
$envArgs = @()
if ($LiveIndexUrl) { $envArgs = @("-e", "FY_LIVE_INDEX_URL=$LiveIndexUrl") }
docker run --rm @envArgs -v "${root}:/src" -w /src/Packages/FreeYomiKit swift:6.1-noble `
  bash -c "apt-get update -qq && apt-get install -y -qq libsqlite3-dev zlib1g-dev >/dev/null && swift test"
