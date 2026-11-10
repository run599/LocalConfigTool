# LocalConfigTool - 备份模块（职责：写入前留痕 / 列举 / 还原 / 回收）
# 维护者：Lead。契约见 docs\CONTRACT.md §4。
# 导出：New-LctBackup Get-LctBackupList Get-LctBackup Restore-LctBackup Remove-LctBackup
# 注意：reg.exe 只认 'HKCU\Software\X'，不认 'HKCU:\Software\X'，统一走 ConvertTo-LctRegExePath。

# 依赖：Logging.psm1（Get-LctVarDir/New-LctId/New-LctResult/Move-LctToRecycleBin/ConvertTo-LctRegExePath）。
# 显式导入一次，保证本模块单独 Import 时也能工作（模块作用域不会嵌套继承）。
$lctLoggingModule = Join-Path $PSScriptRoot 'Logging.psm1'
if ((Test-Path -LiteralPath $lctLoggingModule) -and (-not (Get-Command New-LctResult -ErrorAction SilentlyContinue))) {
    # 必须带 -Global：模块作用域内的 -Force 重导会把全局注册“抢走”，导致 Logging 的全局导出集体消失
    Import-Module $lctLoggingModule -Force -Global -ErrorAction Stop
}

function Get-LctBackupDir {
    return (Join-Path (Get-LctVarDir) 'backups')
}

function Invoke-LctRegExe {
    # 统一封装 reg.exe：避免 $ErrorActionPreference='Stop' 把 native stderr 变成终止错误（NativeCommandError）
    param([string[]]$Arguments)
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $out = & reg.exe @Arguments 2>&1
        return [pscustomobject]@{ exitCode = $LASTEXITCODE; output = ($out | Out-String).Trim() }
    } catch {
        return [pscustomobject]@{ exitCode = 1; output = $_.Exception.Message }
    } finally {
        $ErrorActionPreference = $prev
    }
}

function New-LctBackup {
    param(
        [Parameter(Mandatory)][string]$Verb,
        $Args = $null,
        [string[]]$RegistryPaths = @(),
        $AccountSnapshot = $null
    )
    $id = New-LctId -Prefix $Verb
    $dir = Join-Path (Get-LctBackupDir) $id
    $regDir = Join-Path $dir 'reg'
    $null = New-Item -ItemType Directory -Path $regDir -Force

    $files = New-Object System.Collections.ArrayList
    $notes = New-Object System.Collections.ArrayList
    $i = 0
    foreach ($rp in @($RegistryPaths)) {
        if ([string]::IsNullOrWhiteSpace($rp)) { continue }
        $i++
        $base = Join-Path $regDir ('{0:d2}-{1}' -f $i, ($rp -replace '[\\:\s]', '_'))
        if (Test-Path -LiteralPath $rp) {
            $out = $base + '.reg'
            $r = Invoke-LctRegExe -Arguments @('export', (ConvertTo-LctRegExePath -Path $rp), $out, '/y')
            if ($r.exitCode -eq 0 -and (Test-Path -LiteralPath $out)) {
                $null = $files.Add($out)
            } else {
                $null = $notes.Add("导出失败: $rp (rc=$($r.exitCode)) $($r.output)")
            }
        } else {
            # 原本不存在：还原时应当把这个键删掉
            $out = $base + '.reg.absent'
            # 不写 BOM：读回时要用 ^HKCU 匹配路径，前导 BOM 会让正则失配
            [IO.File]::WriteAllText($out, $rp, (New-Object System.Text.UTF8Encoding($false)))
            $null = $files.Add($out)
            $null = $notes.Add("原本不存在: $rp")
        }
    }

    $hasAccount = $false
    if ($null -ne $AccountSnapshot) {
        $hasAccount = $true
        $ap = Join-Path $dir 'account-before.json'
        (ConvertTo-LctJson -Object $AccountSnapshot -Depth 10) | Set-Content -LiteralPath $ap -Encoding UTF8
        $null = $files.Add($ap)
    }

    $meta = [ordered]@{
        id              = $id
        verb            = $Verb
        created         = (Get-Date).ToString('s')
        user            = "$env:USERDOMAIN\$env:USERNAME"
        elevated        = (Test-LctElevated)
        args            = $Args
        registryPaths   = @($RegistryPaths)
        hasAccountState = $hasAccount
        files           = @($files)
        notes           = @($notes)
    }
    (ConvertTo-LctJson -Object $meta -Depth 10) | Set-Content -LiteralPath (Join-Path $dir 'meta.json') -Encoding UTF8

    Write-LctLog -Verb $Verb -Level info -Message "已创建备份" -Data @{ id = $id; dir = $dir } | Out-Null
    return [pscustomobject]@{ id = $id; dir = $dir; files = @($files); notes = @($notes) }
}

function Get-LctBackupList {
    $root = Get-LctBackupDir
    $out = New-Object System.Collections.ArrayList
    foreach ($d in @(Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue | Sort-Object Name -Descending)) {
        $metaPath = Join-Path $d.FullName 'meta.json'
        if (-not (Test-Path -LiteralPath $metaPath)) { continue }
        $meta = $null
        try { $meta = (Get-Content -LiteralPath $metaPath -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { }
        if ($meta) {
            $null = $out.Add([pscustomobject]@{
                    id = $meta.id; created = $meta.created; verb = $meta.verb
                    user = $meta.user; elevated = $meta.elevated
                    hasAccountState = $meta.hasAccountState; fileCount = @($meta.files).Count
                })
        }
    }
    return @($out)
}

function Get-LctBackup {
    param([Parameter(Mandatory)][string]$Id)
    $dir = Join-Path (Get-LctBackupDir) $Id
    if (-not (Test-Path -LiteralPath $dir)) { throw "备份不存在: $Id" }
    $metaPath = Join-Path $dir 'meta.json'
    $meta = $null
    if (Test-Path -LiteralPath $metaPath) { $meta = (Get-Content -LiteralPath $metaPath -Raw -Encoding UTF8 | ConvertFrom-Json) }
    $files = @(Get-ChildItem -LiteralPath $dir -Recurse -File -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
    return [pscustomobject]@{ id = $Id; dir = $dir; meta = $meta; files = $files }
}

function Restore-LctBackup {
    # 只还原注册表部分。账户快照由 Engine 交给 Accounts 模块的 Restore-LctAccountState。
    param([Parameter(Mandatory)][string]$Id, [switch]$Apply)
    $b = Get-LctBackup -Id $Id
    $changes = New-Object System.Collections.ArrayList
    $warnings = New-Object System.Collections.ArrayList
    $errors = New-Object System.Collections.ArrayList

    $regFiles = @($b.files | Where-Object { $_ -like '*.reg' })
    $absentFiles = @($b.files | Where-Object { $_ -like '*.reg.absent' })

    foreach ($f in $regFiles) {
        $null = $changes.Add([pscustomobject]@{ kind = 'registry'; target = $f; name = '<import>'; before = '(备份内容)'; after = '(还原为备份时的值)'; note = 'reg import' })
    }
    foreach ($f in $absentFiles) {
        $target = (Get-Content -LiteralPath $f -Raw -Encoding UTF8).Trim().TrimStart([char]0xFEFF)
        $null = $changes.Add([pscustomobject]@{ kind = 'registry'; target = $target; name = '<key>'; before = '(备份时不存在)'; after = '删除该键'; note = 'reg delete' })
    }
    $snapshot = $null
    $ap = Join-Path $b.dir 'account-before.json'
    if (Test-Path -LiteralPath $ap) {
        $snapshot = (Get-Content -LiteralPath $ap -Raw -Encoding UTF8 | ConvertFrom-Json)
        $null = $changes.Add([pscustomobject]@{ kind = 'account'; target = 'account-snapshot'; name = '<state>'; before = '(备份时的账户/UAC/自动登录状态)'; after = '(还原为该状态)'; note = '由 Accounts 模块执行' })
    }

    if (-not $Apply) {
        Write-LctLog -Verb 'backup.restore' -Level change -Message "预览还原 $Id" | Out-Null
        return New-LctResult -Verb 'backup.restore' -Changes @($changes) -Warnings @($warnings) -Errors @($errors) `
            -Data ([pscustomobject]@{ id = $Id; accountSnapshot = $snapshot; regFiles = $regFiles; absentFiles = $absentFiles })
    }

    foreach ($f in $regFiles) {
        $r = Invoke-LctRegExe -Arguments @('import', $f)
        if ($r.exitCode -ne 0) { $null = $errors.Add("reg import 失败: $f ($($r.output))") }
    }
    foreach ($f in $absentFiles) {
        $target = (Get-Content -LiteralPath $f -Raw -Encoding UTF8).TrimStart([char]0xFEFF).Trim()
        try {
            $removed = Remove-LctRegistryKeyTree -Path $target
            if (-not $removed) {
                # 键已经不存在 = 目标状态已达成，不是错误；但留痕以便审计
                Write-LctLog -Verb 'backup.restore' -Level info -Message "键已不存在，无需删除: $target" | Out-Null
            }
        } catch {
            $null = $errors.Add("删除键失败: $target ($($_.Exception.Message))")
        }
    }
    Write-LctLog -Verb 'backup.restore' -Level change -Message "已还原 $Id" | Out-Null
    return New-LctResult -Verb 'backup.restore' -Applied -Changes @($changes) -Warnings @($warnings) -Errors @($errors) `
        -Data ([pscustomobject]@{ id = $Id; accountSnapshot = $snapshot; regFiles = $regFiles; absentFiles = $absentFiles })
}

function Remove-LctBackup {
    param([Parameter(Mandatory)][string]$Id)
    $dir = Join-Path (Get-LctBackupDir) $Id
    if (-not (Test-Path -LiteralPath $dir)) { return $false }
    $null = Move-LctToRecycleBin -Path $dir -Directory
    Write-LctLog -Verb 'backup.remove' -Level change -Message "备份已送回收站: $Id" | Out-Null
    return $true
}

Export-ModuleMember -Function New-LctBackup, Get-LctBackupList, Get-LctBackup, Restore-LctBackup, Remove-LctBackup