# make_migration_pkg.ps1 —— 老用户（2.6.1/2.6.2）迁移包生成器。
#
# 迁移包 zip 布局 = **安装根**（与常规更新包 versions/<ver>/ 布局不同）：
#   旧版 updater（2.6.1/2.6.2，无自我放逐）把 zip 内容整体解压到新建的
#   targetDir，随后回迁用户数据、启动 scum_mod_manager.exe —— 因此 zip 根
#   必须直接是安装根内容，且**必须含 scum_mod_manager.exe**（旧 updater 的
#   解压信标检查）与**新 updater**（迁移后兼容壳，新架构不再调用它）。
#
# 布局：
#   {zip}/
#   ├── scum_mod_manager.exe          ← 新引导器（v3，信标）
#   ├── app.json                      ← {"current":"vX.Y.Z"}
#   ├── scum_mod_manager_updater.exe  ← 新 updater（55296，兼容壳）
#   └── versions/vX.Y.Z/
#       ├── scum_mod_manager_app.exe
#       ├── flutter_windows.dll
#       └── data/…
#
# 用法：
#   powershell -NoProfile -File make_migration_pkg.ps1 -Version 2.6.4
# 前置：先跑完 flutter build windows --release（Release 里有引导器 + app + data/）。
#
# 老用户触发路径（一次手动动作）：
#   1. 下载云端 updater_fix.exe（= 新 updater 单文件）覆盖安装目录 updater.exe
#   2. 打开管理器点更新 → 新 updater 自我放逐到 %TEMP% → 不锁目录 → 解压迁移包
#      → 回迁用户数据（~mods/ue4ss_runtime/config.json…）→ 启动新引导器 → 迁移完成
#   此后升级走 v3 新链路（Dart 内原子提交），updater 不再参与。

param(
    [Parameter(Mandatory = $false)]
    [string]$Version = ""
)

$ErrorActionPreference = "Stop"
$projectRoot = $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($projectRoot)) {
    throw "无法确定脚本所在目录（`$PSScriptRoot 为空）——请用 -File 方式运行本脚本"
}
if (-not $Version) {
    $Version = $env:APP_VERSION
}
if ([string]::IsNullOrWhiteSpace($Version)) {
    throw "请用 -Version x.y.z 指定版本号（或先设置环境变量 APP_VERSION）"
}

# Windows 路径一律正斜杠（反斜杠会被转义层吞字，历史教训）
$releaseDir = Join-Path $projectRoot "build/windows/x64/runner/Release"
$outDir = Join-Path $projectRoot "build/dist"
$stagingDir = Join-Path $projectRoot "build/migration_staging"
$outZip = Join-Path $outDir "scum_mod_manager_migration_$Version.zip"

foreach ($need in @("scum_mod_manager.exe", "scum_mod_manager_app.exe",
                    "flutter_windows.dll", "scum_mod_manager_updater.exe")) {
    if (-not (Test-Path (Join-Path $releaseDir $need))) {
        throw "Release 缺少 $need —— 请先 flutter build windows --release"
    }
}

if (Test-Path $stagingDir) { Remove-Item $stagingDir -Recurse -Force }
if (Test-Path $outZip) { Remove-Item $outZip -Force }
New-Item -ItemType Directory -Path (Join-Path $stagingDir "versions/$Version") -Force | Out-Null

# 1) 安装根三件套：引导器（信标）+ app.json + 新 updater 兼容壳
Copy-Item (Join-Path $releaseDir "scum_mod_manager.exe") $stagingDir
Copy-Item (Join-Path $releaseDir "scum_mod_manager_updater.exe") $stagingDir
$appJson = '{"current":"' + $Version + '"}'
[System.IO.File]::WriteAllText(
    (Join-Path $stagingDir "app.json"), $appJson,
    (New-Object System.Text.UTF8Encoding($false)))

# 2) versions/<ver>/ 应用本体（app exe + DLL + data/，排除用户数据与残留）
$verDir = Join-Path $stagingDir "versions/$Version"
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

# 3) 打 zip（根 = 安装根）
Compress-Archive -Path (Join-Path $stagingDir '*') -DestinationPath $outZip -CompressionLevel Optimal
Remove-Item $stagingDir -Recurse -Force

$z = Get-Item $outZip
Write-Host ("迁移包: " + $z.Length + " bytes -> " + $outZip)
Write-Host "布局 = 安装根（引导器 + app.json + updater 兼容壳 + versions/$Version/）"
Write-Host ""
Write-Host "配套：把 Release/scum_mod_manager_updater.exe 作为 updater_fix.exe 上传云端，"
Write-Host "指引老用户覆盖安装目录 updater.exe 后点更新即可自动迁移。"
