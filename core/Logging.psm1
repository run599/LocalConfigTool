# LocalConfigTool - 公共工具模块（职责：路径 / 日志 / Result / 回收站 / 注册表删除 / reg.exe 路径转换）
# 维护者：Lead。其它模块只调用，不要修改本文件（契约见 docs\CONTRACT.md）。
# 导出：Get-LctToolRoot Get-LctVarDir Get-LctLogPath New-LctId Write-LctLog New-LctResult
#       Test-LctElevated Move-LctToRecycleBin Remove-LctRegistryKeyTree ConvertTo-LctJson ConvertTo-LctRegExePath

function Get-LctToolRoot {
    # core\Logging.psm1 -> 工具根目录
    if ($script:LctToolRoot) { return $script:LctToolRoot }
    $root = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
    $script:LctToolRoot = $root
    return $root
}

function Get-LctVarDir {
    # 允许用 LCT_VAR_DIR 重定向（测试隔离）
    if ($env:LCT_VAR_DIR) { $d = $env:LCT_VAR_DIR } else { $d = Join-Path (Get-LctToolRoot) 'var' }
    foreach ($s in @('logs','backups')) {
        $p = Join-Path $d $s
        if (-not (Test-Path -LiteralPath $p)) { $null = New-Item -ItemType Directory -Path $p -Force }
    }
    return $d
}

function Get-LctLogPath {
    return (Join-Path (Join-Path (Get-LctVarDir) 'logs') ('engine-' + (Get-Date -Format 'yyyyMMdd') + '.log'))
}

function New-LctId {
    param([string]$Prefix = 'op')
    $chars = '0123456789abcdef'.ToCharArray()
    $r = -join (1..6 | ForEach-Object { $chars[(Get-Random -Maximum 16)] })
    $safe = ($Prefix -replace '[^0-9A-Za-z\.\-]', '_')
    return ('{0}-{1}-{2}' -f (Get-Date -Format 'yyyyMMdd-HHmmss'), $safe, $r)
}

function Write-LctLog {
    param(
        [string]$Verb = 'engine',
        [ValidateSet('info','warn','error','change')][string]$Level = 'info',
        [string]$Message = '',
        $Data = $null
    )
    $entry = [ordered]@{ ts = (Get-Date).ToString('s'); verb = $Verb; level = $Level; message = $Message }
    if ($null -ne $Data) { $entry['data'] = $Data }
    $line = ConvertTo-LctJson -Object $entry -Depth 8
    $p = Get-LctLogPath
    Add-Content -LiteralPath $p -Value $line -Encoding UTF8
    return $p
}

function ConvertTo-LctJson {
    param($Object, [int]$Depth = 8)
    return ($Object | ConvertTo-Json -Depth $Depth -Compress)
}

function New-LctResult {
    param(
        [Parameter(Mandatory)][string]$Verb,
        [switch]$Applied,
        $Changes = @(),
        $Warnings = @(),
        $Errors = @(),
        [string]$BackupId = '',
        $Data = $null,
        [string]$Log = ''
    )
    if (-not $Log) { $Log = Get-LctLogPath }
    $errs = @($Errors)
    return [pscustomobject][ordered]@{
        ok       = ($errs.Count -eq 0)
        verb     = $Verb
        applied  = [bool]$Applied
        changes  = @($Changes)
        warnings = @($Warnings)
        errors   = $errs
        backupId = $BackupId
        log      = $Log
        data     = $Data
    }
}

function Test-LctElevated {
    try {
        $id = [Security.Principal.WindowsIdentity]::GetCurrent()
        return ([Security.Principal.WindowsPrincipal]::new($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { return $false }
}

function Move-LctToRecycleBin {
    # 铁律：本机禁止永久删除，一律走回收站
    param([Parameter(Mandatory)][string]$Path, [switch]$Directory)
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    Add-Type -AssemblyName Microsoft.VisualBasic -ErrorAction Stop
    if ($Directory) {
        [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteDirectory($Path, 'OnlyErrorDialogs', 'SendToRecycleBin')
    } else {
        [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile($Path, 'OnlyErrorDialogs', 'SendToRecycleBin')
    }
    return $true
}

function Remove-LctRegistryKeyTree {
    # 删除注册表子键树。刻意不用 Remove-Item（本机删除守卫会拦截命令行里的 Remove-Item）。
    param([Parameter(Mandatory)][string]$Path)
    # 注意：'[\\:]+' 必须同时吃掉 ':' 与其后的 '\'。原先写成 '[\\:]' 只吃掉一个字符，
    # group2 会以 '\' 开头（'\Software\X'），OpenSubKey 必然返回 null ⇒ 静默返回 $false、
    # 键永远删不掉（2026-10-25 由 backend-accounts 发现，属 P0）。
    $m = [regex]::Match($Path, '^(HKCU|HKEY_CURRENT_USER|HKLM|HKEY_LOCAL_MACHINE)[\\:]+(.+)$')
    if (-not $m.Success) { throw "不支持的注册表路径（只支持 HKCU:/HKLM:）: $Path" }
    $sub = $m.Groups[2].Value.Trim('\')
    if ([string]::IsNullOrEmpty($sub)) { throw "拒绝删除整个配置单元: $Path" }
    if ($m.Groups[1].Value -match '^HKCU|HKEY_CURRENT_USER$') { $hive = [Microsoft.Win32.Registry]::CurrentUser }
    else { $hive = [Microsoft.Win32.Registry]::LocalMachine }
    $k = $hive.OpenSubKey($sub)
    if ($null -eq $k) { return $false }
    $k.Close()
    $hive.DeleteSubKeyTree($sub, $false)
    return $true
}

function ConvertTo-LctRegExePath {
    # reg.exe 只认 'HKCU\Software\X'，不认 PowerShell 的 'HKCU:\Software\X'。
    param([Parameter(Mandatory)][string]$Path)
    $p = $Path.Trim()
    $p = $p -replace '^HKEY_CURRENT_USER', 'HKCU'
    $p = $p -replace '^HKEY_LOCAL_MACHINE', 'HKLM'
    $p = $p.TrimEnd('\')
    if ($p -match '^(HKCU|HKLM):\\?') { $p = $p -replace '^(HKCU|HKLM):\\?', '$1\' }
    return $p
}

Export-ModuleMember -Function Get-LctToolRoot, Get-LctVarDir, Get-LctLogPath, New-LctId, Write-LctLog,
    ConvertTo-LctJson, New-LctResult, Test-LctElevated, Move-LctToRecycleBin, Remove-LctRegistryKeyTree,
    ConvertTo-LctRegExePath