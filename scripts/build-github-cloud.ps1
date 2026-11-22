[CmdletBinding()]
param(
    [string]$SourceDir = '',
    [string]$OutputDir = '',
    [string]$CloudBaseUrl = 'https://raw.githubusercontent.com/LHuiMeng/SCUM-Mod-Desk-Cloud/main/cloud'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$scriptRoot = $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($SourceDir)) {
    $SourceDir = Join-Path $scriptRoot '..\src-tauri\target\release\app-data\~mods'
}
if ([string]::IsNullOrWhiteSpace($OutputDir)) {
    $OutputDir = Join-Path $scriptRoot '..\cloud'
}

$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $scriptRoot '..'))
$sourceRoot = [System.IO.Path]::GetFullPath($SourceDir)
$cloudRoot = [System.IO.Path]::GetFullPath($OutputDir)
$pakRoot = Join-Path $cloudRoot 'paks'
$catalogPath = Join-Path $cloudRoot 'mods'
$githubFileLimit = 100 * 1024 * 1024

$repoRootPrefix = $repoRoot.TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
if (-not $cloudRoot.StartsWith($repoRootPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "OutputDir must stay inside the repository: $repoRoot"
}
if (-not (Test-Path -LiteralPath $sourceRoot -PathType Container)) {
    throw "Source directory not found: $sourceRoot"
}

# This is intentionally a strict allowlist. Never discover PAK files automatically.
$allowlist = @(
    [pscustomobject]@{
        FileName = '弹匣容量全面增容 + 背包优化.pak'
        Description = '提升弹匣容量并优化背包使用体验。'
    }
    [pscustomobject]@{
        FileName = '动物帽子无限耐久.pak'
        Description = '动物主题帽子不再损耗耐久。'
    }
    [pscustomobject]@{
        FileName = '堆叠上限提升.pak'
        Description = '提高可堆叠物品的上限。'
    }
    [pscustomobject]@{
        FileName = '发电机静音.pak'
        Description = '降低或消除发电机运行噪音。'
    }
    [pscustomobject]@{
        FileName = '海水变淡水.pak'
        Description = '将海水调整为可直接使用的淡水。'
    }
    [pscustomobject]@{
        FileName = '黄金武士刀替换赛博武士刀.pak'
        Description = '用黄金武士刀外观替换赛博武士刀。'
    }
    [pscustomobject]@{
        FileName = '军包01-06换皮Tyrone（四效合一）.pak'
        Description = '军包 01 至 06 统一替换为 Tyrone 风格外观。'
    }
    [pscustomobject]@{
        FileName = '可制作现代厨房.pak'
        Description = '加入可制作的现代厨房设施。'
    }
    [pscustomobject]@{
        FileName = '螺丝刀与开锁工具合并.pak'
        Description = '将螺丝刀与开锁工具整合使用。'
    }
    [pscustomobject]@{
        FileName = '取消负重惩罚.pak'
        Description = '移除负重超限带来的移动惩罚。'
    }
    [pscustomobject]@{
        FileName = '全手套无限耐久.pak'
        Description = '所有手套不再损耗耐久。'
    }
    [pscustomobject]@{
        FileName = '人偶服最高档防弹.pak'
        Description = '将人偶服防护提升至最高档防弹等级。'
    }
    [pscustomobject]@{
        FileName = '容器最大负重.pak'
        Description = '提高容器可承载的最大负重。'
    }
    [pscustomobject]@{
        FileName = '弯草叉→Thornblade 剑(移速+20%_一刀秒_永固).pak'
        Description = '将弯草叉替换为 Thornblade 剑，并调整移速、伤害与耐久。'
    }
    [pscustomobject]@{
        FileName = '鞋丝袜五合一(无限耐久+储物+嵌套+防脏+受击免疫).pak'
        Description = '鞋袜整合无限耐久、储物、嵌套、防脏与受击免疫。'
    }
    [pscustomobject]@{
        FileName = '衣物容器嵌套.pak'
        Description = '允许衣物容器之间相互嵌套。'
    }
    [pscustomobject]@{
        FileName = '载具最大负重.pak'
        Description = '提高载具的最大载重。'
    }
    [pscustomobject]@{
        FileName = '装填速度x4.pak'
        Description = '将武器装填速度提升至四倍。'
    }
    [pscustomobject]@{
        FileName = 'Rager跑车极速300.pak'
        Description = '将 Rager 跑车的最高速度调整为 300。'
    }
)

if ($allowlist.Count -ne 19) {
    throw "Expected exactly 19 allowlisted mods, found $($allowlist.Count)."
}

$allowedNames = [System.Collections.Generic.HashSet[string]]::new(
    [System.StringComparer]::OrdinalIgnoreCase
)
foreach ($entry in $allowlist) {
    if (-not $allowedNames.Add($entry.FileName)) {
        throw "Duplicate allowlist entry: $($entry.FileName)"
    }
    $sourcePath = Join-Path $sourceRoot $entry.FileName
    if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
        throw "Allowlisted source file not found: $sourcePath"
    }
}

New-Item -ItemType Directory -Force -Path $pakRoot | Out-Null
$staleFiles = Get-ChildItem -LiteralPath $pakRoot -File |
    Where-Object { -not $allowedNames.Contains($_.Name) }
foreach ($staleFile in $staleFiles) {
    Remove-Item -LiteralPath $staleFile.FullName -Force
}

$items = [System.Collections.Generic.List[object]]::new()
$ids = [System.Collections.Generic.HashSet[string]]::new(
    [System.StringComparer]::OrdinalIgnoreCase
)
$totalBytes = 0L

foreach ($entry in $allowlist) {
    $sourcePath = Join-Path $sourceRoot $entry.FileName
    $destinationPath = Join-Path $pakRoot $entry.FileName
    Copy-Item -LiteralPath $sourcePath -Destination $destinationPath -Force

    $file = Get-Item -LiteralPath $destinationPath
    if ($file.Length -ge $githubFileLimit) {
        throw "File reaches GitHub's 100 MiB limit: $($entry.FileName) ($($file.Length) bytes)"
    }

    $sha256 = (Get-FileHash -LiteralPath $destinationPath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($sha256 -notmatch '^[0-9a-f]{64}$') {
        throw "Unexpected SHA-256 value for $($entry.FileName): $sha256"
    }
    $id = $sha256.Substring(0, 12)
    if (-not $ids.Add($id)) {
        throw "Catalog id collision for $($entry.FileName): $id"
    }

    $encodedName = [System.Uri]::EscapeDataString($entry.FileName)
    $downloadUrl = "$($CloudBaseUrl.TrimEnd('/'))/paks/$encodedName"
    $name = [System.IO.Path]::GetFileNameWithoutExtension($entry.FileName)
    $updatedAt = $file.LastWriteTimeUtc.ToString('o', [System.Globalization.CultureInfo]::InvariantCulture)

    $items.Add([pscustomobject][ordered]@{
        id = $id
        name = $name
        author = 'LHuiMeng'
        version = '1.0.0'
        description = $entry.Description
        fileSize = [long]$file.Length
        downloadUrl = $downloadUrl
        sha256 = $sha256
        tags = @('客户端 PAK', '自制')
        updatedAt = $updatedAt
        type = 'clientPak'
    })
    $totalBytes += $file.Length
}

$json = ConvertTo-Json -InputObject @($items) -Depth 8
if ([string]::IsNullOrWhiteSpace($json)) {
    throw 'Catalog serialization returned no JSON.'
}
$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
[System.IO.File]::WriteAllText(
    $catalogPath,
    $json + [Environment]::NewLine,
    $utf8NoBom
)

$pakFiles = @(Get-ChildItem -LiteralPath $pakRoot -File)
if ($pakFiles.Count -ne $allowlist.Count) {
    throw "Expected $($allowlist.Count) PAK files in cloud/paks, found $($pakFiles.Count)."
}

[pscustomobject]@{
    Catalog = $catalogPath
    PakDirectory = $pakRoot
    ModCount = $items.Count
    TotalBytes = $totalBytes
    LargestBytes = ($pakFiles | Measure-Object -Property Length -Maximum).Maximum
} | Format-List
