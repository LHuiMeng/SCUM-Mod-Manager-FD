$ErrorActionPreference = "Stop"
$root = (Resolve-Path (Split-Path -Parent $PSScriptRoot)).Path.TrimEnd("\")
$rootPrefix = "$root\"
$secretsRoot = Join-Path $root "secrets"
$allowed = @("secrets/README.md", "secrets/example.toml")
$sensitive = @(Get-ChildItem -LiteralPath $secretsRoot -File -Recurse |
  ForEach-Object {
    $_.FullName.Substring($rootPrefix.Length).Replace("\", "/")
  } |
  Where-Object { $_ -notin $allowed })

$tracked = @(git -C $root ls-files -- secrets)
$trackedViolations = @($tracked | Where-Object { $_ -notin $allowed })
if ($trackedViolations.Count -gt 0) {
  throw "A real secret file is tracked by Git."
}

if ($sensitive.Count -gt 0) {
  Write-Host "Sensitive files exist locally and are not automatically staged:"
  foreach ($relativePath in $sensitive) {
    git -C $root check-ignore --quiet -- $relativePath
    if ($LASTEXITCODE -ne 0) {
      throw "Secret file is not ignored by Git: $relativePath"
    }
    Write-Host "  $relativePath"
  }
} else {
  Write-Host "No local secret files found."
}

Write-Host "Secret isolation check passed."
