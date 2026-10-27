param(
  [ValidateSet("public", "server", "both")]
  [string]$Edition = "both"
)

$ErrorActionPreference = "Stop"
$root = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$runtimeSecret = Join-Path $root "secrets\runtime.toml"
$outputRoot = Join-Path $root "release-output"

function Build-Edition([string]$Name) {
  if ($Name -eq "server" -and -not (Test-Path -LiteralPath $runtimeSecret -PathType Leaf)) {
    throw "Server build requires secrets/runtime.toml with [cloud].auth_token."
  }
  if ($Name -eq "server") {
    $secretText = Get-Content -LiteralPath $runtimeSecret -Raw
    if ($secretText -notmatch '(?m)^\s*(?:auth_token|catalog_token|gate_token)\s*=\s*"[^"]+"\s*$') {
      throw "Server build requires a non-empty shared key in secrets/runtime.toml."
    }
  }

  $config = Join-Path $root "src-tauri\tauri.$Name.conf.json"
  if (-not (Test-Path -LiteralPath $config -PathType Leaf)) {
    throw "Missing Tauri config: $config"
  }

  $env:SCUM_EDITION = $Name
  try {
    npm run tauri build -- --config $config
    if ($LASTEXITCODE -ne 0) {
      throw "Tauri $Name build failed with exit code $LASTEXITCODE."
    }
  } finally {
    Remove-Item Env:SCUM_EDITION -ErrorAction SilentlyContinue
  }

  $bundleRoot = Join-Path $root "src-tauri\target\release\bundle\nsis"
  $installer = Get-ChildItem -LiteralPath $bundleRoot -Filter "*.exe" -File |
    Sort-Object LastWriteTime -Descending |
    Select-Object -First 1
  if (-not $installer) {
    throw "No NSIS installer was produced for $Name."
  }

  $destination = Join-Path $outputRoot $Name
  New-Item -ItemType Directory -Path $destination -Force | Out-Null
  Copy-Item -LiteralPath $installer.FullName -Destination $destination -Force
  Write-Host "$Name installer: $(Join-Path $destination $installer.Name)"
}

npm run build
if ($LASTEXITCODE -ne 0) {
  throw "Frontend build failed with exit code $LASTEXITCODE."
}

if ($Edition -eq "public" -or $Edition -eq "both") {
  Build-Edition "public"
}
if ($Edition -eq "server" -or $Edition -eq "both") {
  Build-Edition "server"
}
