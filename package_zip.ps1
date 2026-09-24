# 用脚本自身位置定位工程根，避免硬编码路径在项目迁移（C: → W:）后失效。
$projectRoot = $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($projectRoot)) {
    throw "无法确定脚本所在目录（`$PSScriptRoot 为空）——请用 -File 方式运行本脚本"
}
# 注意：Windows 路径一律用正斜杠 —— 反斜杠在部分调用层会被转义吞掉
# （历史教训：\\runner 被吞成回车，路径静默损坏）。
$releaseDir = Join-Path $projectRoot "build/windows/x64/runner/Release"
$stagingDir = Join-Path $projectRoot "build/update_staging"
$zipPath = Join-Path $releaseDir "scum_mod_manager.zip"

# v3 架构：更新包根 = versions/<ver>/ 的内容（应用本体），由客户端
# update_service.installDownloaded 解压到 versions/.staging/<ver>/ 后原子改名。
# 版本号从环境变量 APP_VERSION 读（build_release.ps1 调用前设置），兜底读 pubspec。
$version = $env:APP_VERSION
if ([string]::IsNullOrWhiteSpace($version)) {
    $pubspec = [System.IO.File]::ReadAllText((Join-Path $projectRoot "pubspec.yaml"))
    if ($pubspec -match 'version:\s*(\d+\.\d+\.\d+)') { $version = $Matches[1] }
}
if ([string]::IsNullOrWhiteSpace($version)) {
    throw "无法确定版本号（需先设置环境变量 APP_VERSION）"
}

if (Test-Path $stagingDir) { Remove-Item $stagingDir -Recurse -Force }
if (Test-Path $zipPath) { Remove-Item $zipPath -Force }
New-Item -ItemType Directory -Path $stagingDir -Force | Out-Null
$verDir = Join-Path $stagingDir "versions/$version"
New-Item -ItemType Directory -Path $verDir -Force | Out-Null

# ★ 排除项＝用户运行时数据 + 发布残留 + v3 架构下不该进更新包的件：
#   ~mods/（本地 PAK 库）、~merged/（冲突合并产物缓存）、ue4ss_runtime/（UE4SS 框架
#   与用户 mod）、assets/（自定义背景图）、logs/、config.json（游戏路径/启动选项）、
#   mods_meta.json（标签/备注）、server_mods.db（服务器 mod 库）、*.bak（发布残留）、
#   ZIP 自身（否则递归打包）、引导器 scum_mod_manager.exe（永不更新，不进包）、
#   updater.exe（v3 新架构不用，仅老用户迁移包会另行打进去）。
$excludeNames = @(
    "~mods", "~merged", "logs", "ue4ss_runtime", "assets",
    "config.json", "mods_meta.json", "server_mods.db",
    "scum_mod_manager.zip", "scum_mod_manager.exe.bak",
    "scum_mod_manager.exe", "scum_mod_manager_updater.exe"
)
Get-ChildItem $releaseDir -Force | ForEach-Object {
    if ($excludeNames -contains $_.Name) { return }
    if ($_.Name -like "*.bak") { return }
    Copy-Item $_.FullName (Join-Path $verDir $_.Name) -Recurse -Force
}

# ★ 剔除调试态产物：kernel_blob.bin 是 Dart 调试/JIT 用的 49MB 大件，
#   release 包由 data/app.so（AOT 快照）承载，绝不该出货。清掉 .dart_tool 的
#   构建缓存后一般不会再生成；此处再加一道保险，避免一个 49MB 的胖包被推给用户。
$kernelBlob = Join-Path $verDir "data/flutter_assets/kernel_blob.bin"
if (Test-Path $kernelBlob) {
    Remove-Item $kernelBlob -Force
    Write-Host "[排除] 已剔除调试态产物 data/flutter_assets/kernel_blob.bin"
}

Compress-Archive -Path (Join-Path $verDir '*') -DestinationPath $zipPath -CompressionLevel Optimal
Remove-Item $stagingDir -Recurse -Force

$z = Get-Item $zipPath
Write-Host ("完整更新包 ZIP: " + $z.Length + " bytes (v3 布局 versions/$version/)")
