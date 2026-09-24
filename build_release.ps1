# build_release.ps1
#
# 一键发布 SCUM Mod Manager FD 新版本到你的服务器。
#
# 流程：
#   1. 解析参数（-Version / -Changelog，可选）
#   2. 同步升 pubspec.yaml、lib/services/app_version.dart、make_manifest.js 三个文件的版本号
#   3. flutter build windows --release（**必须**带 --dart-define 注入 APP_VERSION + UPDATE_VERIFY_KEY）
#   4. 清干净 build/windows/x64/runner/Release/（确保无 .bak 残留）
#   5. 打 ZIP（排除 ~mods/、logs/、ue4ss_runtime/、assets/、flutter_assets/、config.json、mods_meta.json、*.bak）
#   6. node make_manifest.js 生成签名 manifest（自验 HMAC）
#   7. scp 上传 ZIP + manifest 到 {SSH_HOST}:{REMOTE_BASE}/data/app/v{version}/
#   8. 验证远端 manifest + ZIP 可达
#
# 用法：
#   powershell -File build_release.ps1 -Version 2.5.7 -Changelog "fix: 某某问题"
#   # 不传 -Version 时默认在当前版本号最后一段 +0.0.1
#
# 前置：
#   - update_secret.json 与本脚本同目录（含 UPDATE_VERIFY_KEY 字段）
#   - node 已装（用于 make_manifest.js）
#   - ssh key 已配（~/.ssh/config 中 SSH_HOST 主机，用 -SshHost 指定别名）
#
# 历史教训（v2.5.5 发布时遗漏）：
#   - 必须传 --dart-define=APP_VERSION=x.y.z，否则客户端版本号永远等于 defaultValue
#   - 必须传 --dart-define-from-file=update_secret.json，否则 verify key 是空 -> 客户端校验失败
#     -> 永远不显示更新按钮
#   - Release 目录必须先清空，否则 .bak 备份文件会随包发出去

param(
    [Parameter(Mandatory=$false)]
    [string]$Version = "",

    [Parameter(Mandatory=$false)]
    [string]$Changelog = "",

    [Parameter(Mandatory=$false)]
        [int]$Build = 0,

        [Parameter(Mandatory=$false)]
        [switch]$SkipUpload,  # 只本地 build + zip + manifest，不上传服务器

        [Parameter(Mandatory=$false)]
        [string]$RegistryUrl = "",  # 云上 mod registry 基础地址（打包默认，注入 REGISTRY_BASE_URL）

        [Parameter(Mandatory=$false)]
        [string]$From = "",  # v3.1 增量基准版本（可选）：提供时对上一版产增量包，否则只产完整包

        [Parameter(Mandatory=$false)]
        [switch]$ForceRegistryUrl   # 强覆盖指令：本次更新强制覆盖用户 config.json 的 cloud_sources.base_url

        ,
        [Parameter(Mandatory=$false)]
        [switch]$MigrationPackage   # v3 迁移版：用迁移包布局作为 scum_mod_manager.zip（旧 updater 信标兼容），
                                    # 并上传 updater_fix.exe（老用户覆盖安装目录用）。仅首个 v3 版本需要.

        [Parameter(Mandatory=$false)]
        [string]$SshHost = "",     # 服务器 SSH 别名（~/.ssh/config 主机名），上传目标。缺省空=不上传

        [Parameter(Mandatory=$false)]
        [string]$ServerDir = "",                        # 服务器端更新根目录（如 /opt/your-registry，含 app/v<ver>/ 等）
    )

$ErrorActionPreference = "Stop"
$ProjectRoot = $PSScriptRoot
Set-Location $ProjectRoot

Write-Host "============================================================" -ForegroundColor Cyan
Write-Host " SCUM Mod Manager FD — Release Build Script" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""

# -- 1. 解析版本号 --
if (-not $Version) {
    # 读 pubspec.yaml 当前 version
    $pubspec = Get-Content "pubspec.yaml" -Raw
    if ($pubspec -match 'version:\s*(\d+)\.(\d+)\.(\d+)') {
        $major = [int]$Matches[1]
        $minor = [int]$Matches[2]
        $patch = [int]$Matches[3] + 1
        $Version = "$major.$minor.$patch"
    } else {
        throw "无法从 pubspec.yaml 解析当前版本号，请用 -Version 显式指定"
    }
}
Write-Host "[1/7] 版本号: $Version" -ForegroundColor Yellow
if ($Build -eq 0) {
    # build 号 = 2.99 亿起 base + 当前 Unix 时间分钟偏移
    $Build = 29900000 + [int][double]::Parse((Get-Date -UFormat %s)) / 60 % 1000000
}
Write-Host "       build 号: $Build" -ForegroundColor Yellow
if (-not $Changelog) { $Changelog = "版本升至 $Version" }
Write-Host "       changelog: $Changelog" -ForegroundColor Yellow
Write-Host ""

# -- 2. 同步版本号到三处 --
Write-Host "[2/7] 同步版本号..." -ForegroundColor Yellow

# UTF-8 读写（PS5.1 的 Get-Content/Set-Content 默认按 ANSI/GBK，
# 会破坏 pubspec.yaml / app_version.dart 的中文注释 —— 必须显式 UTF-8 无 BOM）。
function Read-Utf8([string]$p) { [System.IO.File]::ReadAllText($p) }
function Write-Utf8([string]$p, [string]$c) {
    [System.IO.File]::WriteAllText($p, $c, (New-Object System.Text.UTF8Encoding($false)))
}

# pubspec.yaml
$pubspecPath = "pubspec.yaml"
$pubspec = Read-Utf8 $pubspecPath
$pubspecNew = $pubspec -replace 'version:\s*\d+\.\d+\.\d+\+\d+', "version: ${Version}+0"
Write-Utf8 $pubspecPath $pubspecNew

# lib/services/app_version.dart
$appVerPath = "lib/services/app_version.dart"
$appVer = Read-Utf8 $appVerPath
$appVerNew = $appVer -replace "defaultValue:\s*'\d+\.\d+\.\d+'", "defaultValue: '$Version'"
Write-Utf8 $appVerPath $appVerNew

# make_manifest.js 改为读环境变量（不再 regex patch 它）

Write-Host "       pubspec.yaml  -> version: ${Version}+0" -ForegroundColor Green
Write-Host "       app_version.dart -> defaultValue: '$Version'" -ForegroundColor Green
Write-Host "       make_manifest.js -> 用环境变量驱动（无需 patch）" -ForegroundColor Green
Write-Host ""

# -- 3. 校验 update_secret.json --
Write-Host "[3/7] 校验 update_secret.json ..." -ForegroundColor Yellow
if (-not (Test-Path "update_secret.json")) {
    throw "找不到 update_secret.json，发布前必须准备好（含 UPDATE_VERIFY_KEY 字段）"
}
$secretJson = Get-Content "update_secret.json" -Raw | ConvertFrom-Json
if (-not $secretJson.UPDATE_VERIFY_KEY -or $secretJson.UPDATE_VERIFY_KEY.Length -ne 64) {
    throw "update_secret.json 中 UPDATE_VERIFY_KEY 缺失或长度不是 64 字符（hex）"
}
Write-Host "       UPDATE_VERIFY_KEY OK ($($secretJson.UPDATE_VERIFY_KEY.Length) hex chars)" -ForegroundColor Green
Write-Host ""

# -- 4. 清理旧 release 目录（★ 用户数据必须让路，绝不能删）--
# 历史教训：旧版这里直接 `Remove-Item -Recurse -Force $releaseDir`，会连带抹掉
# 主人的本地 mod 库（~mods/ 十几个 PAK）、UE4SS 运行时（ue4ss_runtime/，含全部
# 已装 UE4SS mod）、config.json（游戏路径与启动选项）、mods_meta.json（标签/备注）。
# 这些是用户数据，不是构建产物 —— 改为「挪到暂存区 → 清空 → 构建后原样放回」。
Write-Host "[4/7] 清理 release 目录（用户数据让路）..." -ForegroundColor Yellow
$releaseDir = "build/windows/x64/runner/Release"
$preserveDir = "build\_preserve"
$userDataNames = @(
    "~mods", "ue4ss_runtime", "~merged", "logs", "assets",
    "config.json", "mods_meta.json", "server_mods.db"
)
# 自愈：上次运行若在归位前失败，用户数据会留在暂存区里 —— 先搬回去再继续，
# 否则本次会把它当垃圾清掉（那就真丢了）。
if (Test-Path $preserveDir) {
    $healed = 0
    foreach ($n in $userDataNames) {
        $stale = Join-Path $preserveDir $n
        if (Test-Path $stale) {
            $back = Join-Path $releaseDir $n
            if (Test-Path $back) { Remove-Item $back -Recurse -Force }
            Move-Item $stale $back -Force
            $healed++
        }
    }
    Remove-Item $preserveDir -Recurse -Force
    Write-Host "       自愈：归位上次残留的用户数据 $healed 项" -ForegroundColor Yellow
}
if (Test-Path $preserveDir) { Remove-Item $preserveDir -Recurse -Force }
New-Item -ItemType Directory -Path $preserveDir -Force | Out-Null
$preserved = 0
if (Test-Path $releaseDir) {
    foreach ($n in $userDataNames) {
        $p = Join-Path $releaseDir $n
        if (Test-Path $p) {
            Move-Item $p (Join-Path $preserveDir $n) -Force
            $preserved++
        }
    }
    Remove-Item -Recurse -Force $releaseDir
    Write-Host "       已清空 $releaseDir（暂存用户数据 $preserved 项）" -ForegroundColor Green
}
# 同时清掉旧的发布产物（避免 scp 推新覆盖旧时残留）
$oldZip = Join-Path $releaseDir "scum_mod_manager.zip"
if (Test-Path $oldZip) { Remove-Item -Force $oldZip }
$oldManifest = "build\dist\manifest.json"
if (Test-Path $oldManifest) { Remove-Item -Force $oldManifest }
Write-Host ""

# -- 5. flutter build windows --release（带 dart-define 注入）--
Write-Host "[5/7] flutter build windows --release ..." -ForegroundColor Yellow
# 项目已从 C: 迁到 W:（2026-09 起），此处必须跟随 —— 旧路径会让脚本直接 throw。
$flutter = $env:FLUTTER_BAT; if (-not $flutter) { $flutter = "flutter.bat" }
if (-not (Test-Path $flutter)) { throw "找不到 flutter.bat: $flutter" }
$buildArgs = @(
    "build", "windows", "--release",
    "--dart-define=APP_VERSION=$Version",
    "--dart-define-from-file=update_secret.json"
)
if ($RegistryUrl) {
    $buildArgs += "--dart-define=REGISTRY_BASE_URL=$RegistryUrl"
    Write-Host "       注入云源打包默认地址: $RegistryUrl" -ForegroundColor Green
    # 更新 manifest 与云源同域（/app/manifest.json）—— 源码已不含任何
    # 硬编码域名，此处由发布脚本注入（不注入 = 对外版无更新源）。
    $ManifestUrl = $RegistryUrl.TrimEnd('/') + "/app/manifest.json"
    $buildArgs += "--dart-define=UPDATE_MANIFEST_URL=$ManifestUrl"
    Write-Host "       注入更新 manifest 地址: $ManifestUrl" -ForegroundColor Green
}
if ($ForceRegistryUrl) {
    $buildArgs += "--dart-define=REGISTRY_FORCE_OVERRIDE=true"
    Write-Host "       强覆盖指令已注入: REGISTRY_FORCE_OVERRIDE=true（启动将强制覆盖用户 base_url）" -ForegroundColor Yellow
}
& $flutter @buildArgs
if ($LASTEXITCODE -ne 0) {
    throw "flutter build 失败，退出码 $LASTEXITCODE"
}
Write-Host "       build OK" -ForegroundColor Green

# 验证注入真的进了 app.so
$appSo = Join-Path $releaseDir "data\app.so"
if (Test-Path $appSo) {
    $verFound = $false
    $keyFound = $false
    # 跨平台：直接读 bytes
    $bytes = [System.IO.File]::ReadAllBytes($appSo)
    $text = [System.Text.Encoding]::UTF8.GetString($bytes)
    if ($text.Contains($Version)) { $verFound = $true }
    if ($text.Contains($secretJson.UPDATE_VERIFY_KEY)) { $keyFound = $true }
    if (-not $verFound) {
        throw "app.so 中找不到版本号 '$Version' —— dart-define=APP_VERSION 注入失败！"
    }
    if (-not $keyFound) {
        throw "app.so 中找不到 UPDATE_VERIFY_KEY —— dart-define-from-file 注入失败！"
    }
    Write-Host "       验证 app.so 含 '$Version' + verify key" -ForegroundColor Green
}
Write-Host ""

# -- 5.5 用户数据归位（配对第 4 步的让路）--
if (Test-Path $preserveDir) {
    $restored = 0
    foreach ($n in $userDataNames) {
        $p = Join-Path $preserveDir $n
        if (Test-Path $p) {
            $dest = Join-Path $releaseDir $n
            if (Test-Path $dest) { Remove-Item $dest -Recurse -Force }
            Move-Item $p $dest -Force
            $restored++
        }
    }
    Remove-Item $preserveDir -Recurse -Force
    Write-Host "[5.5/7] 用户数据已归位（$restored 项）：本地 mod 库 / UE4SS 运行时 / 配置 / 元数据" -ForegroundColor Green
    Write-Host ""
}

# -- 6. 打 ZIP（完整包 + 可选增量包）+ 签 manifest --
Write-Host "[6/7] 打 ZIP + 签 manifest..." -ForegroundColor Yellow
# v3.1：make_update_pkg.ps1 一键产出完整包（Release/scum_mod_manager.zip）+
# 增量包（-From 提供时）+ 签名 delta_manifest.json（build/dist/）。
$env:APP_VERSION = $Version
$pkgArgs = @("-To", $Version)
if ($From) { $pkgArgs += @("-From", $From) }
if ($RegistryUrl) { $pkgArgs += @("-BaseUrl", $RegistryUrl) }
& powershell -NoProfile -File "make_update_pkg.ps1" @pkgArgs
if ($LASTEXITCODE -ne 0) { throw "make_update_pkg.ps1 失败" }

# v3 迁移版：正式 zip 用迁移包布局（zip 根=安装根，旧 updater 解压时
# 信标 scum_mod_manager.exe 在根才能通过验证）。常规包仅 v3 用户后续升级用。
if ($MigrationPackage) {
    Write-Host "       [迁移包] 生成迁移包并作为 scum_mod_manager.zip ..." -ForegroundColor Yellow
    & powershell -NoProfile -File "make_migration_pkg.ps1" -Version $Version
    if ($LASTEXITCODE -ne 0) { throw "make_migration_pkg.ps1 失败" }
    $migZip = "build/dist/scum_mod_manager_migration_$Version.zip"
    Copy-Item $migZip "build/windows/x64/runner/Release/scum_mod_manager.zip" -Force
    Write-Host "       [迁移包] 已覆盖 Release/scum_mod_manager.zip（manifest 将指向迁移包布局）" -ForegroundColor Green
}
$env:APP_BUILD = $Build
$env:APP_CHANGELOG = $Changelog
& node make_manifest.js
Remove-Item Env:APP_VERSION -ErrorAction SilentlyContinue
Remove-Item Env:APP_BUILD -ErrorAction SilentlyContinue
Remove-Item Env:APP_CHANGELOG -ErrorAction SilentlyContinue
if ($LASTEXITCODE -ne 0) { throw "make_manifest.js 失败" }
Write-Host ""

# -- 7. 上传服务器 --
if ($SkipUpload) {
    Write-Host "[7/7] 跳过上传（-SkipUpload）" -ForegroundColor Yellow
} else {
    if (-not $SshHost) { throw "未指定 -SshHost（服务器 SSH 别名），无法上传" }
    Write-Host "[7/7] 上传到 $SshHost ..." -ForegroundColor Yellow
    # ssh/scp 的 stderr 会带 OpenSSH 的 pq WARNING（post-quantum 提示），
    # 在 ErrorActionPreference=Stop 下会被当作 NativeCommandError 直接终止。
    # 上传段临时降为 Continue —— 成败完全以显式的 $LASTEXITCODE 检查为准。
    $oldEap = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    $serverDir = "$ServerDir/data/app/v$Version"
    $upDir = "$serverDir/.uploading"

    # ★ 原子上传：先传 staging（.uploading/），全部到位后再 mv 落位。
    # 服务端 manifest 动态扫目录取最高 semver —— 若 v<Version>/ 已存在但 zip
    # 还在传，用户恰在此时点更新会拿到半截/旧包（历史事故：00:08 用户下载到
    # 旧版本包）。.uploading/ 前缀目录不会被当作可用版本。
    & ssh $SshHost "mkdir -p $upDir" 2>&1 | ForEach-Object { Write-Host "       $_" }
    if ($LASTEXITCODE -ne 0) { throw "ssh 失败" }

    # changelog.txt：服务端读取并展示给用户的中文更新说明（先传）
    $chgPath = Join-Path $ProjectRoot "build/dist/changelog.txt"
    New-Item -ItemType Directory -Path (Join-Path $ProjectRoot "build/dist") -Force | Out-Null
    [System.IO.File]::WriteAllText($chgPath, "$Changelog`n", (New-Object System.Text.UTF8Encoding($false)))
    & scp $chgPath "$($SshHost):$upDir/" 2>&1 | ForEach-Object { Write-Host "       $_" }
    if ($LASTEXITCODE -ne 0) { throw "scp changelog 失败" }

    # scp ZIP（staging 目录，正斜杠防转义吞字）
    $zipSrc = "build/windows/x64/runner/Release/scum_mod_manager.zip"
    & scp $zipSrc "$($SshHost):$upDir/" 2>&1 | ForEach-Object { Write-Host "       $_" }
    if ($LASTEXITCODE -ne 0) { throw "scp zip 失败" }

    # scp manifest（本地自验件；服务端动态生成主 manifest 时忽略它，留档用）
    & scp "build/dist/manifest.json" "$($SshHost):$upDir/" 2>&1 | ForEach-Object { Write-Host "       $_" }
    if ($LASTEXITCODE -ne 0) { throw "scp manifest 失败" }

    # 原子落位：mv 到正式目录 + 清 staging
    & ssh $SshHost "mkdir -p $serverDir && mv -f $upDir/* $serverDir/ && rm -rf $upDir" 2>&1 | ForEach-Object { Write-Host "       $_" }
    if ($LASTEXITCODE -ne 0) { throw "原子落位失败" }
    Write-Host "       已原子落位 v$Version（zip + changelog.txt + manifest）" -ForegroundColor Green

    # v3.1 增量产物（增量包 + 签名 delta_manifest.json）—— 存在才上传。
    # 主流程已完成原子落位（.uploading 已删），增量文件是独立补充件：
    # 直接传 $serverDir/，先 zip 后 manifest（客户端探测 delta_manifest 时 zip 必已在）。
    $deltaZipLocal = Join-Path $ProjectRoot "build/dist/delta_${From}_to_${Version}.zip"
    $deltaManifestLocal = Join-Path $ProjectRoot "build/dist/delta_manifest.json"
    if ($From -and (Test-Path $deltaZipLocal)) {
        & scp $deltaZipLocal "$($SshHost):$serverDir/" 2>&1 | ForEach-Object { Write-Host "       $_" }
        if ($LASTEXITCODE -ne 0) { throw "scp delta zip 失败" }
        & scp $deltaManifestLocal "$($SshHost):$serverDir/" 2>&1 | ForEach-Object { Write-Host "       $_" }
        if ($LASTEXITCODE -ne 0) { throw "scp delta_manifest 失败" }
        Write-Host "       已上传增量包 + delta_manifest.json（v$From -> v$Version）" -ForegroundColor Green
    }

    # v3 迁移版：上传 updater_fix.exe（老用户覆盖安装目录 updater.exe 的前置件）
    # ★ 必须放版本目录内 —— 服务端路由只认 /app/v*/ 模式，/app/updater_fix.exe 会 404
    if ($MigrationPackage) {
        & scp "build/windows/x64/runner/Release/scum_mod_manager_updater.exe" "$($SshHost):$serverDir/updater_fix.exe" 2>&1 | ForEach-Object { Write-Host "       $_" }
        if ($LASTEXITCODE -ne 0) { throw "scp updater_fix.exe 失败" }
        Write-Host "       已上传 updater_fix.exe（$serverDir/updater_fix.exe，老用户迁移前置件）" -ForegroundColor Green
    }

    $ErrorActionPreference = $oldEap

    # 验证可达（域名由 $RegistryUrl 派生，源码零硬编码）
    if ($RegistryUrl) {
        $base = $RegistryUrl.TrimEnd('/')
        Write-Host "       验证远端..." -ForegroundColor Green
        $url = "$base/app/v$Version/scum_mod_manager.zip"
        try {
            $resp = Invoke-WebRequest -Uri $url -Method Head -UseBasicParsing -TimeoutSec 15
            $size = $resp.Headers["Content-Length"]
            Write-Host "       HTTP $($resp.StatusCode), size $size bytes" -ForegroundColor Green
        } catch {
            Write-Host "       [WARN]  远端验证失败: $_" -ForegroundColor Red
        }

        $manifestUrl = "$base/app/manifest.json"
        try {
            $mresp = Invoke-WebRequest -Uri $manifestUrl -UseBasicParsing -TimeoutSec 15
            Write-Host "       主 manifest:" -ForegroundColor Green
            Write-Host "       $($mresp.Content)" -ForegroundColor Gray
        } catch {
            Write-Host "       [WARN]  manifest 验证失败: $_" -ForegroundColor Red
        }
    }
}
Write-Host ""

Write-Host "============================================================" -ForegroundColor Green
Write-Host " OK v$Version 发布完成" -ForegroundColor Green
Write-Host "============================================================" -ForegroundColor Green
Write-Host ""
Write-Host "下一步："
Write-Host "  git add -A && git commit -m 'feat: 升版本至 $Version'"
Write-Host "  git push origin feat/launcher-channel-rightdock"