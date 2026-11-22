param(
  [string]$Notes = "稳定性与使用体验更新",
  [switch]$SkipVerification
)

$ErrorActionPreference = "Stop"
$root = (Resolve-Path (Split-Path -Parent $PSScriptRoot)).Path.TrimEnd("\")
Set-Location $root

$runtimePath = Join-Path $root "secrets\runtime.toml"
if (-not (Test-Path -LiteralPath $runtimePath)) {
  throw "Missing secrets/runtime.toml. Copy secrets/example.toml and fill the update section."
}

git check-ignore --quiet -- "secrets/runtime.toml"
if ($LASTEXITCODE -ne 0) {
  throw "secrets/runtime.toml is not ignored by Git."
}

function Read-TomlString([string]$sectionName, [string]$key, [string]$default = "") {
  $text = [IO.File]::ReadAllText($runtimePath)
  $section = [regex]::Match(
    $text,
    "(?ms)^\[$([regex]::Escape($sectionName))\]\s*(.*?)(?=^\[|\z)"
  )
  if (-not $section.Success) { return $default }
  $value = [regex]::Match(
    $section.Groups[1].Value,
    "(?m)^\s*$([regex]::Escape($key))\s*=\s*`"((?:\\.|[^`"])*)`""
  )
  if (-not $value.Success) { return $default }
  return [regex]::Unescape($value.Groups[1].Value)
}

$endpoint = Read-TomlString "update" "endpoint"
$publicKey = Read-TomlString "update" "public_key"
$privateKeySetting = Read-TomlString "update" "private_key_path" "secrets/update.key"
$privateKeyPassword = Read-TomlString "update" "private_key_password"
$downloadBaseUrl = Read-TomlString "update" "download_base_url"

if (-not $endpoint.StartsWith("https://")) {
  throw "The update endpoint must use HTTPS."
}
if ([string]::IsNullOrWhiteSpace($publicKey)) {
  throw "The update public key is empty."
}
if ([string]::IsNullOrWhiteSpace($downloadBaseUrl) -or -not $downloadBaseUrl.StartsWith("https://")) {
  throw "download_base_url must be an HTTPS URL."
}

$privateKeyPath = if ([IO.Path]::IsPathRooted($privateKeySetting)) {
  $privateKeySetting
} else {
  Join-Path $root $privateKeySetting
}
if (-not (Test-Path -LiteralPath $privateKeyPath)) {
  throw "Update signing key was not found at its configured secrets path."
}
git check-ignore --quiet -- $privateKeyPath
if ($LASTEXITCODE -ne 0) {
  throw "The update signing key is not ignored by Git."
}

$env:SCUM_UPDATE_ENDPOINT = $endpoint
$env:SCUM_UPDATE_PUBLIC_KEY = $publicKey
$env:TAURI_SIGNING_PRIVATE_KEY = (Resolve-Path -LiteralPath $privateKeyPath).Path
if (-not [string]::IsNullOrEmpty($privateKeyPassword)) {
  $env:TAURI_SIGNING_PRIVATE_KEY_PASSWORD = $privateKeyPassword
}

try {
  if (-not $SkipVerification) {
    npm run typecheck
    if ($LASTEXITCODE -ne 0) { throw "TypeScript check failed." }
    npm run test
    if ($LASTEXITCODE -ne 0) { throw "Frontend tests failed." }
    npm run build
    if ($LASTEXITCODE -ne 0) { throw "Frontend build failed." }
    cargo test --manifest-path src-tauri/Cargo.toml
    if ($LASTEXITCODE -ne 0) { throw "Rust tests failed." }
  }

  npm run tauri -- build --config src-tauri/tauri.release.conf.json
  if ($LASTEXITCODE -ne 0) { throw "Tauri release build failed." }

  $package = Get-Content (Join-Path $root "package.json") -Raw | ConvertFrom-Json
  $version = [string]$package.version
  $bundleDir = Join-Path $root "src-tauri\target\release\bundle\nsis"
  $installer = Get-ChildItem -LiteralPath $bundleDir -Filter "*_${version}_x64-setup.exe" |
    Sort-Object LastWriteTime -Descending |
    Select-Object -First 1
  if ($null -eq $installer) {
    throw "NSIS installer for version $version was not found."
  }
  $signaturePath = "$($installer.FullName).sig"
  if (-not (Test-Path -LiteralPath $signaturePath)) {
    throw "Updater signature was not generated."
  }

  $outputDir = Join-Path $root "release-output\$version"
  New-Item -ItemType Directory -Force -Path $outputDir | Out-Null
  Copy-Item -LiteralPath $installer.FullName -Destination $outputDir -Force
  Copy-Item -LiteralPath $signaturePath -Destination $outputDir -Force

  $manifest = [ordered]@{
    version = $version
    notes = $Notes
    pub_date = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
    platforms = [ordered]@{
      "windows-x86_64" = [ordered]@{
        signature = (Get-Content -LiteralPath $signaturePath -Raw).Trim()
        url = "$($downloadBaseUrl.TrimEnd('/'))/$version/$($installer.Name)"
        size = $installer.Length
      }
    }
  }
  $manifestPath = Join-Path $outputDir "latest.json"
  $manifestJson = $manifest | ConvertTo-Json -Depth 6
  [IO.File]::WriteAllText(
    $manifestPath,
    $manifestJson,
    [Text.UTF8Encoding]::new($false)
  )

  Write-Host "Release artifacts written to release-output\$version"
  Write-Host "Upload the installer and .sig to: $downloadBaseUrl/$version/"
  Write-Host "Upload latest.json to the exact manifest endpoint."
} finally {
  Remove-Item Env:SCUM_UPDATE_ENDPOINT -ErrorAction SilentlyContinue
  Remove-Item Env:SCUM_UPDATE_PUBLIC_KEY -ErrorAction SilentlyContinue
  Remove-Item Env:TAURI_SIGNING_PRIVATE_KEY -ErrorAction SilentlyContinue
  Remove-Item Env:TAURI_SIGNING_PRIVATE_KEY_PASSWORD -ErrorAction SilentlyContinue
}
