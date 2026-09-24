# make_update_pkg.ps1 —— v3.1 轻量化更新包一键生成器（主人 2026-09-22 定规则）
#
# 产出（全部放 build/dist/）：
#   1. scum_mod_manager.zip                         完整包（新版本全部本体）
#   2. delta_<from>_to_<to>.zip                     增量包（仅变更文件 + 删除清单）
#   3. delta_manifest.json                          增量清单（HMAC 签名，客户端可信入口）
#
# 用法：
#   powershell -File make_update_pkg.ps1 -To 2.6.5 -From 2.6.4
#     -To    必填：新版本号
#     -From  可选：增量基准版本。提供时自动从云端拉 v<From> 完整包对比产增量包；
#           省略则只产完整包（跨版用户/首版场景）。
#
# 前置：
#   - 已 flutter build windows --release（Release 里有 scum_mod_manager_app.exe + data/）
#   - update_secret.json 与本脚本同目录（UPDATE_VERIFY_KEY，签 delta_manifest 用）
#   - 云端可访问（拉旧版本包做对比）

param(
    [Parameter(Mandatory = $false)]
    [string]$To = "",

    [Parameter(Mandatory = $false)]
    [string]$From = "",

    # 云基址：-BaseUrl 参数（build_release.ps1 传入）> $env:CLOUD_BASE_URL > 空。
    # 源码零硬编码域名 —— 内部版由 build_release.ps1 注入，对外版不注入（跳过增量对比）。
    [Parameter(Mandatory = $false)]
    [string]$BaseUrl = ""
)

$ErrorActionPreference = "Stop"
$projectRoot = $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($projectRoot)) {
    throw "无法确定脚本所在目录（`$PSScriptRoot 为空）"
}
# Windows 路径一律正斜杠（反斜杠会被转义层吞字，历史教训）
$releaseDir = Join-Path $projectRoot "build/windows/x64/runner/Release"
$distDir = Join-Path $projectRoot "build/dist"
$workDir = Join-Path $projectRoot "build/pkg_work"
if (-not $BaseUrl) { $BaseUrl = $env:CLOUD_BASE_URL }
$baseUrl = if ($BaseUrl) { $BaseUrl.TrimEnd('/') + "/app" } else { "" }

if (-not $To) { throw "必须指定 -To <新版本号>" }
if (-not (Test-Path (Join-Path $releaseDir "scum_mod_manager_app.exe"))) {
    throw "Release 缺少 scum_mod_manager_app.exe —— 请先 flutter build windows --release"
}
if (-not (Test-Path (Join-Path $projectRoot "update_secret.json"))) {
    throw "找不到 update_secret.json（签 delta_manifest 需要 UPDATE_VERIFY_KEY）"
}

New-Item -ItemType Directory -Path $distDir -Force | Out-Null
if (Test-Path $workDir) { Remove-Item $workDir -Recurse -Force }
New-Item -ItemType Directory -Path $workDir -Force | Out-Null

# ============ 1. 完整包 ============
Write-Host "[1/4] 打完整包 scum_mod_manager.zip ..." -ForegroundColor Yellow
# 输出到 Release 目录 —— make_manifest.js 从这里读 zip 算 sha/大小（与旧流程一致）
$fullZip = Join-Path $releaseDir "scum_mod_manager.zip"
if (Test-Path $fullZip) { Remove-Item $fullZip -Force }
$fullStaging = Join-Path $workDir "full"
New-Item -ItemType Directory -Path $fullStaging -Force | Out-Null
# 新版本本体 = Release 里的 app exe + dll + data/（排除用户数据/引导器/updater/zip/残留）
$excludeNames = @(
    "~mods", "~merged", "logs", "ue4ss_runtime", "assets",
    "config.json", "mods_meta.json", "server_mods.db",
    "scum_mod_manager.zip", "scum_mod_manager.exe.bak",
    "scum_mod_manager.exe", "scum_mod_manager_updater.exe",
    "scum_mod_manager_updater.exe.old-261"
)
Get-ChildItem $releaseDir -Force | ForEach-Object {
    if ($excludeNames -contains $_.Name) { return }
    if ($_.Name -like "*.bak") { return }
    Copy-Item $_.FullName (Join-Path $fullStaging $_.Name) -Recurse -Force
}
Compress-Archive -Path (Join-Path $fullStaging '*') -DestinationPath $fullZip -CompressionLevel Optimal
Write-Host ("       完整包: " + (Get-Item $fullZip).Length + " bytes") -ForegroundColor Green

# ============ 2. 拉取旧版本（增量基准） ============
$deltaZip = ""
$deltaManifest = ""
if ($From) {
    if (-not $baseUrl) {
        Write-Host "       [WARN] 未配置云基址（对外版），跳过增量包（仅完整包）" -ForegroundColor Red
        $From = ""
    } else {
        Write-Host "[2/4] 拉取 v$From 完整包做增量对比 ..." -ForegroundColor Yellow
        $fromZip = Join-Path $workDir "from_$From.zip"
        $fromDir = Join-Path $workDir "from_$From"
        $url = "$baseUrl/v$From/scum_mod_manager.zip"
        curl.exe -sL --max-time 600 -o $fromZip $url
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path $fromZip)) {
            Write-Host "       [WARN] 云端拉取 v$From 失败，跳过增量包（仅完整包）" -ForegroundColor Red
            $From = ""
        } else {
            Expand-Archive -LiteralPath $fromZip -DestinationPath $fromDir -Force
            # 云端 v<From> 包可能是迁移包布局（zip 根=安装根：引导器/app.json/updater/
            # versions/<From>/）—— 对比基准必须取「版本内容」而非安装根，否则引导器/
            # app.json/updater 全部变成伪差异。
            $nestedVer = Join-Path $fromDir "versions/$From"
            if (Test-Path $nestedVer) { $fromDir = $nestedVer }
            Write-Host (        "       已解压 v$From 基准: " + (Get-ChildItem $fromDir -Recurse -File).Count + " 个文件") -ForegroundColor Green
        }
    }
}

# ============ 3. 增量对比 + 增量包 ============
if ($From) {
    Write-Host "[3/4] 对比并生成增量包 ..." -ForegroundColor Yellow
    $deltaStaging = Join-Path $workDir "delta_staging"
    New-Item -ItemType Directory -Path (Join-Path $deltaStaging "files") -Force | Out-Null
    $deleteList = @()
    $fileList = @()

    # 遍历旧版本所有文件（相对路径）
    $oldFiles = Get-ChildItem $fromDir -Recurse -File | ForEach-Object {
        $_.FullName.Substring($fromDir.Length + 1).Replace('\', '/')
    }
    foreach ($rel in $oldFiles) {
        $oldPath = Join-Path $fromDir ($rel.Replace('/', '\'))
        $newPath = Join-Path $fullStaging ($rel.Replace('/', '\'))
        if (-not (Test-Path $newPath)) {
            # 仅旧有 → 删除清单
            $deleteList += $rel
        } else {
            $h1 = (Get-FileHash -LiteralPath $oldPath -Algorithm SHA256).Hash
            $h2 = (Get-FileHash -LiteralPath $newPath -Algorithm SHA256).Hash
            if ($h1 -ne $h2) {
                $dest = Join-Path (Join-Path $deltaStaging "files") ($rel.Replace('/', '\'))
                New-Item -ItemType Directory -Path (Split-Path $dest -Parent) -Force | Out-Null
                Copy-Item $newPath $dest -Force
                $fileList += $rel
            }
        }
    }
    # 新增文件（旧版本没有的）
    $newFiles = Get-ChildItem $fullStaging -Recurse -File | ForEach-Object {
        $_.FullName.Substring($fullStaging.Length + 1).Replace('\', '/')
    }
    foreach ($rel in $newFiles) {
        if ($deleteList -contains $rel) { continue }
        $oldPath = Join-Path $fromDir ($rel.Replace('/', '\'))
        if (-not (Test-Path $oldPath)) {
            $dest = Join-Path (Join-Path $deltaStaging "files") ($rel.Replace('/', '\'))
            New-Item -ItemType Directory -Path (Split-Path $dest -Parent) -Force | Out-Null
            Copy-Item (Join-Path $fullStaging ($rel.Replace('/', '\'))) $dest -Force
            $fileList += $rel
        }
    }

    Write-Host ("       变更文件: " + $fileList.Count + "，删除文件: " + $deleteList.Count) -ForegroundColor Cyan
    if ($fileList.Count -eq 0 -and $deleteList.Count -eq 0) {
        Write-Host "       两版本内容一致，不产增量包" -ForegroundColor Yellow
    } else {
        # 增量 zip 内 manifest.json（必须无 BOM —— PS5.1 的 Set-Content -Encoding
        # UTF8 会写 BOM，Dart jsonDecode 不接受 BOM 头）
        $innerManifest = @{
            from = $From
            to   = $To
            files = $fileList
            delete = $deleteList
        }
        $innerJson = $innerManifest | ConvertTo-Json -Depth 5
        [System.IO.File]::WriteAllText(
            (Join-Path $deltaStaging "manifest.json"), $innerJson,
            (New-Object System.Text.UTF8Encoding($false)))
        # 打增量 zip
        $deltaZip = Join-Path $distDir "delta_${From}_to_${To}.zip"
        if (Test-Path $deltaZip) { Remove-Item $deltaZip -Force }
        Compress-Archive -Path (Join-Path $deltaStaging '*') -DestinationPath $deltaZip -CompressionLevel Optimal
        Write-Host ("       增量包: " + (Get-Item $deltaZip).Length + " bytes -> " + (Split-Path $deltaZip -Leaf)) -ForegroundColor Green

        # delta_manifest.json（HMAC 签名）
        $secret = Get-Content (Join-Path $projectRoot "update_secret.json") -Raw | ConvertFrom-Json
        $keyBytes = [byte[]]::new(32)
        for ($i = 0; $i -lt 32; $i++) {
            $keyBytes[$i] = [Convert]::ToByte($secret.UPDATE_VERIFY_KEY.Substring($i * 2, 2), 16)
        }
        $deltaBytes = [System.IO.File]::ReadAllBytes($deltaZip)
        $sha = [System.Security.Cryptography.SHA256]::Create().ComputeHash($deltaBytes)
        $shaHex = ([System.BitConverter]::ToString($sha)).Replace('-', '').ToLower()
        $deltaUrl = "/app/v$To/" + (Split-Path $deltaZip -Leaf)
        # canonical：字段按字母序（与客户端 update_service 同规则）
        $canon = "base=$From`ndelta_sha256=$shaHex`ndelta_size_bytes=$($deltaBytes.Length)`ndelta_url=$deltaUrl`nto=$To"
        $hmac = New-Object System.Security.Cryptography.HMACSHA256
        $hmac.Key = $keyBytes
        $sig = [Convert]::ToBase64String($hmac.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($canon)))
        $deltaManifest = @{
            to = $To
            base = $From
            delta_url = $deltaUrl
            delta_sha256 = $shaHex
            delta_size_bytes = $deltaBytes.Length
            signature = $sig
        }
        $dmPath = Join-Path $distDir "delta_manifest.json"
        [System.IO.File]::WriteAllText(
            $dmPath, ($deltaManifest | ConvertTo-Json),
            (New-Object System.Text.UTF8Encoding($false)))
        Write-Host ("       delta_manifest.json 已签名: base=$From to=$To sha=$($shaHex.Substring(0,16))...") -ForegroundColor Green
    }
}

# ============ 4. 清理 ============
Write-Host "[4/4] 清理临时目录 ..." -ForegroundColor Yellow
if (Test-Path $workDir) { Remove-Item $workDir -Recurse -Force }

Write-Host ""
Write-Host "============================================" -ForegroundColor Green
Write-Host " 更新包生成完成 (v$To)" -ForegroundColor Green
Write-Host "  完整包: build/dist/scum_mod_manager.zip" -ForegroundColor Green
if ($deltaZip) {
    Write-Host "  增量包: build/dist/$(Split-Path $deltaZip -Leaf)" -ForegroundColor Green
    Write-Host "  增量清单: build/dist/delta_manifest.json（已签名）" -ForegroundColor Green
}
Write-Host "============================================" -ForegroundColor Green
