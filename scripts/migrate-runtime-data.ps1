param(
  [Parameter(Mandatory = $true)]
  [string]$Destination,
  [ValidateSet("full", "public", "server")]
  [string]$Edition = "full",
  [switch]$RemoveOld
)

$ErrorActionPreference = "Stop"

$bundleId = switch ($Edition) {
  "public" { "com.scummod.manager.public" }
  "server" { "com.scummod.manager.server" }
  default { "com.scummod.manager" }
}

if (-not $env:APPDATA) {
  throw "APPDATA is not available."
}

$appDataRoot = [IO.Path]::GetFullPath($env:APPDATA).TrimEnd("\")
$source = Join-Path $appDataRoot $bundleId
if (-not [IO.Path]::IsPathRooted($Destination)) {
  $Destination = Join-Path (Get-Location).Path $Destination
}
$destinationRoot = [IO.Path]::GetFullPath($Destination)

if (-not (Test-Path -LiteralPath $source -PathType Container)) {
  Write-Host "No legacy data found at $source"
  exit 0
}

$sourceRoot = [IO.Path]::GetFullPath($source).TrimEnd("\")
if (
  $destinationRoot.Equals($sourceRoot, [StringComparison]::OrdinalIgnoreCase) -or
  $destinationRoot.StartsWith($sourceRoot + "\", [StringComparison]::OrdinalIgnoreCase)
) {
  throw "Destination must not be inside the legacy data directory: $destinationRoot"
}

New-Item -ItemType Directory -Path $destinationRoot -Force | Out-Null

$copiedFiles = 0
$copiedBytes = 0L
$sourceItems = @(
  "config.json",
  "mods_meta.json",
  "deployment_manifest.json",
  "~mods",
  "~merged",
  "ue4ss_runtime",
  "logs",
  "secrets",
  "server_mods.db",
  "update_secret.json"
)

foreach ($name in $sourceItems) {
  $sourceItem = Join-Path $source $name
  if (-not (Test-Path -LiteralPath $sourceItem)) {
    continue
  }

  if (Test-Path -LiteralPath $sourceItem -PathType Leaf) {
    $destinationFile = Join-Path $destinationRoot $name
    if (-not (Test-Path -LiteralPath $destinationFile)) {
      Copy-Item -LiteralPath $sourceItem -Destination $destinationFile
      $item = Get-Item -LiteralPath $sourceItem
      $copiedFiles++
      $copiedBytes += $item.Length
    }
    continue
  }

  $sourcePrefix = $sourceItem.TrimEnd("\") + "\"
  Get-ChildItem -LiteralPath $sourceItem -File -Recurse -Force | ForEach-Object {
    $relative = $_.FullName.Substring($sourcePrefix.Length)
    $destinationFile = Join-Path (Join-Path $destinationRoot $name) $relative
    if (Test-Path -LiteralPath $destinationFile) {
      return
    }
    $parent = Split-Path -Parent $destinationFile
    if ($parent) {
      New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    Copy-Item -LiteralPath $_.FullName -Destination $destinationFile
    $script:copiedFiles++
    $script:copiedBytes += $_.Length
  }
}

Write-Host "Legacy data copied into $destinationRoot"
Write-Host "Copied files: $copiedFiles"
Write-Host "Copied bytes: $copiedBytes"

if ($RemoveOld) {
  $sourceFull = [IO.Path]::GetFullPath($source).TrimEnd("\")
  $appDataPrefix = $appDataRoot + "\"
  if (
    -not $sourceFull.StartsWith($appDataPrefix, [StringComparison]::OrdinalIgnoreCase) -or
    $sourceFull.Equals($appDataRoot, [StringComparison]::OrdinalIgnoreCase)
  ) {
    throw "Refusing to remove an unexpected legacy path: $sourceFull"
  }
  Remove-Item -LiteralPath $sourceFull -Recurse -Force
  Write-Host "Removed legacy source: $sourceFull"
}
