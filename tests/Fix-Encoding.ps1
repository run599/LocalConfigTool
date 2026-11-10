# LocalConfigTool - encoding normaliser (ASCII-only on purpose: it must be safe to run
# even when every other file in the tree is temporarily mis-encoded).
#
# WHY: Windows PowerShell 5.1 reads a BOM-less file as ANSI/GBK, so any .ps1/.psm1/.md/.json
# that contains Chinese and lost its BOM will be mis-decoded and can even fail to parse.
# The `edit`/`write` tooling rewrites files without a BOM, so this pass must be re-run
# after any edit to a file that contains non-ASCII text.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File tests\Fix-Encoding.ps1
#
# It also reports .cmd files that are not pure ASCII (those must stay ASCII because
# cmd.exe reads them with the OEM code page).
param([switch]$Quiet)

$root = Split-Path -Parent $PSScriptRoot
if (-not $root) { $root = Split-Path -Parent $MyInvocation.MyCommand.Path }
$utf8Bom = New-Object System.Text.UTF8Encoding($true)
$exts = @('.ps1', '.psm1', '.md', '.json')
$checked = 0
$fixed = 0

foreach ($f in @(Get-ChildItem -LiteralPath $root -Recurse -File -ErrorAction SilentlyContinue)) {
    if ($f.FullName -like '*\var\*') { continue }
    if ($exts -notcontains $f.Extension.ToLower()) { continue }
    $checked++
    $b = [IO.File]::ReadAllBytes($f.FullName)
    $hasBom = ($b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF)
    if (-not $hasBom) {
        $text = [IO.File]::ReadAllText($f.FullName, [Text.Encoding]::UTF8)
        [IO.File]::WriteAllText($f.FullName, $text, $utf8Bom)
        $fixed++
        if (-not $Quiet) { Write-Host ('  +BOM ' + $f.FullName.Substring($root.Length)) }
    }
}

$badCmd = @()
foreach ($f in @(Get-ChildItem -LiteralPath $root -Recurse -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -eq '.cmd' })) {
    $b = [IO.File]::ReadAllBytes($f.FullName)
    if (@($b | Where-Object { $_ -gt 127 }).Count -gt 0) { $badCmd += $f.FullName }
}
foreach ($f in $badCmd) { Write-Warning ('non-ASCII byte in .cmd (must stay ASCII): ' + $f) }

Write-Host ("Fix-Encoding: checked={0} addedBom={1} badCmd={2} root={3}" -f $checked, $fixed, @($badCmd).Count, $root)
if (@($badCmd).Count -gt 0) { exit 1 }
exit 0