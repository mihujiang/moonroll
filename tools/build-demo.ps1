# Builds the wasm-gc demo behind docs/ and drops it next to the page.
#
# The built module is committed so GitHub Pages can serve it without a MoonBit
# toolchain; rerun this script after touching demo/ or adapters/.
$ErrorActionPreference = "Stop"
Push-Location (Join-Path $PSScriptRoot "..")
try {
  moon build --target wasm-gc --release
  # Inside a moon.work workspace the artifacts land in the workspace root
  # _build; a standalone checkout uses the module-local _build.
  $candidates = @(
    "..\_build\wasm-gc\release\build\weopqrst\moonroll\demo\demo.wasm",
    "..\_build\wasm-gc\release\build\demo\demo.wasm",
    "_build\wasm-gc\release\build\weopqrst\moonroll\demo\demo.wasm",
    "_build\wasm-gc\release\build\demo\demo.wasm"
  )
  $source = $candidates | Where-Object { Test-Path $_ } | Select-Object -First 1
  if (-not $source) {
    throw "demo.wasm not found; looked in: $($candidates -join ', ')"
  }
  Copy-Item $source "docs\engine.wasm" -Force
  Write-Host "docs\engine.wasm updated from $source"
} finally {
  Pop-Location
}
