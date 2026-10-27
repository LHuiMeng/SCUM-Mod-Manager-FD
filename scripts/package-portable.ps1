param(
  [ValidateSet("public", "server")]
  [string]$Edition = "public",
  [switch]$SkipBuild
)

$ErrorActionPreference = "Stop"
$root = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$runtimeSecret = Join-Path $root "secrets\runtime.toml"
$releaseRoot = [IO.Path]::GetFullPath((Join-Path $root "release-output"))
$destination = Join-Path $root "release-output\portable\$Edition\SCUM Mod Desk"
$destinationFull = [IO.Path]::GetFullPath($destination)

if (-not $destinationFull.StartsWith($releaseRoot + "\", [StringComparison]::OrdinalIgnoreCase)) {
  throw "Portable destination escaped release-output: $destinationFull"
}
if ($Edition -eq "server" -and -not (Test-Path -LiteralPath $runtimeSecret -PathType Leaf)) {
  throw "Server portable package requires secrets/runtime.toml."
}

if (-not $SkipBuild) {
  npm run build
  if ($LASTEXITCODE -ne 0) {
    throw "Frontend build failed with exit code $LASTEXITCODE."
  }

  $env:SCUM_EDITION = $Edition
  try {
    npm run tauri -- build --no-bundle --config "src-tauri/tauri.$Edition.conf.json"
    if ($LASTEXITCODE -ne 0) {
      throw "Tauri $Edition build failed with exit code $LASTEXITCODE."
    }
  } finally {
    Remove-Item Env:SCUM_EDITION -ErrorAction SilentlyContinue
  }
}

$executable = Join-Path $root "src-tauri\target\release\scum-mod-manager.exe"
if (-not (Test-Path -LiteralPath $executable -PathType Leaf)) {
  throw "Release executable was not found: $executable"
}

if (Test-Path -LiteralPath $destinationFull) {
  Remove-Item -LiteralPath $destinationFull -Recurse -Force
}
New-Item -ItemType Directory -Path $destinationFull -Force | Out-Null
Copy-Item -LiteralPath $executable -Destination (Join-Path $destinationFull "scum-mod-manager.exe")

$resourceSource = Join-Path $root "src-tauri\resources"
$resourceDestination = Join-Path $destinationFull "resources"
Copy-Item -LiteralPath $resourceSource -Destination $resourceDestination -Recurse

if ($Edition -eq "server") {
  $secretDestination = Join-Path $destinationFull "runtime-secrets"
  New-Item -ItemType Directory -Path $secretDestination -Force | Out-Null
  Copy-Item -LiteralPath $runtimeSecret -Destination (Join-Path $secretDestination "runtime.toml")
}

$readme = @(
  "SCUM Mod Desk $Edition"
  ""
  "运行方式："
  "1. 将整个文件夹放在非 C 盘的可写目录，例如 R:\SCUM Mod Desk。"
  "2. 双击 scum-mod-manager.exe。"
  "3. 所有配置、模组、日志和凭据都会写入此目录下的 app-data。"
  ""
  "不要放到 Program Files，普通用户无法在那里写入运行数据。"
  "删除程序时先退出应用，再删除整个 SCUM Mod Desk 文件夹即可。"
) -join [Environment]::NewLine
[IO.File]::WriteAllText(
  (Join-Path $destinationFull "README-便携版.txt"),
  $readme,
  [Text.UTF8Encoding]::new($false)
)

$zipPath = Join-Path $root "release-output\portable\SCUM Mod Desk $Edition.zip"
if (Test-Path -LiteralPath $zipPath) {
  Remove-Item -LiteralPath $zipPath -Force
}
Compress-Archive -LiteralPath $destinationFull -DestinationPath $zipPath -CompressionLevel Optimal

Write-Host "Portable directory: $destinationFull"
Write-Host "Portable archive: $zipPath"
