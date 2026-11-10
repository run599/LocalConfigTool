# LocalConfigTool - static lint (ASCII only on purpose: safe even when the tree is mid-edit).
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File tests\Lint-PowerShell.ps1
#   powershell -NoProfile -ExecutionPolicy Bypass -File tests\Lint-PowerShell.ps1 -SelfTest
#
# Catches the SILENT PowerShell traps this project hit at runtime, where -SelfCheck /
# SelfTest passed but the GUI broke on a real click:
#   1) assigning to a READ-ONLY automatic variable ($pid, $host, $home, $true, $false,
#      $ExecutionContext, $PSVersionTable, $PSCulture, $PSUICulture, $PSHome, $ShellId,
#      $ConsoleFileName) -> SessionStateUnauthorizedAccessException at runtime
#      (real incident: ui\ConfigUI.ps1 assigned $pid on the preset page)
#   2) using $Args as a parameter name in a SIMPLE function: the automatic $args shadows it,
#      -Args <object> binds to an empty Object[] and the parameter silently arrives EMPTY.
#      Real incidents: (a) account snapshot restore no-op; (b) ui\ConfigUI.ps1
#      Add-LctPending -> EVERY page's pending item carried {} so every "apply" sent the
#      engine an empty argument package, while all 7 gates stayed green.
#   plus encoding hygiene: non-ASCII bytes in .cmd, and files that lost their UTF-8 BOM.
#
# NOTE on the advanced-function test below (a blind spot found the hard way): whether a
# function is "advanced" must be decided by the presence of [CmdletBinding()] or a
# [Parameter()] attribute — NOT by "has any attribute", because the PowerShell AST also
# records TYPE CONSTRAINTS such as [string] in $p.Attributes. The earlier version treated
# `param([string]$Page, $Args, ...)` as advanced and therefore never flagged it.
#
# Exit code = number of problems found (0 = clean).
param([switch]$Quiet, [switch]$SelfTest)

$root = Split-Path -Parent $PSScriptRoot
$readonly = @('pid', 'host', 'home', 'true', 'false', 'ExecutionContext', 'PSVersionTable',
    'PSCulture', 'PSUICulture', 'PSHome', 'ShellId', 'ConsoleFileName')
$problems = New-Object System.Collections.ArrayList

function Add-Problem([string]$Message) {
    $null = $problems.Add($Message)
    if (-not $Quiet) { Write-Host ('  [LINT] ' + $Message) }
}

function Test-LctArgsShadow {
    # Rule 2, factored out so -SelfTest can exercise the very same logic.
    param($Ast, [string]$Rel = '')
    if ($null -eq $Ast) { return }
    $fns = $Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)
    foreach ($fn in $fns) {
        $pb = $fn.Body.ParamBlock
        if ($null -eq $pb) { continue }
        $isAdvanced = $false
        foreach ($a in @($pb.Attributes)) { if ($a.TypeName.Name -eq 'CmdletBinding') { $isAdvanced = $true } }
        if ($fn.PSObject.Properties['Attributes']) {
            foreach ($a in @($fn.Attributes)) { if ($a.TypeName.Name -eq 'CmdletBinding') { $isAdvanced = $true } }
        }
        foreach ($p in @($pb.Parameters)) {
            foreach ($a in @($p.Attributes)) { if ($a.TypeName.Name -eq 'Parameter') { $isAdvanced = $true } }
        }
        foreach ($p in @($pb.Parameters)) {
            if ($p.Name.VariablePath.UserPath -eq 'Args' -and -not $isAdvanced) {
                Add-Problem ($Rel + ' 簡單函數(simple function) ' + $fn.Name + ' 用 $Args 作參數名 -> 會被自動變量靜默頂掉')
            }
        }
    }
}

function Test-LctParamShadow {
    # Rule 2c: an exported function WITHOUT a param block that references a name which some other function
    # in the same file declares as a parameter. Real incident (2026-10-26, core\Drivers.psm1):
    #   function Get-LctDriverFileInfo { $info = Get-LctDrvFileInfoInternal -Path $Path ... }   # no param block!
    # PowerShell validates unbound named args only for ADVANCED functions; a SIMPLE function silently
    # swallows `-Path <x>` into $args, so $Path stayed $null and the verb always said "missing path"
    # while every gate was green. Same class as the $Args-shadowing bug: parameters that never arrive.
    param($Ast, [string]$Rel = '')
    if ($null -eq $Ast) { return }
    $fns = @($Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true))
    if (@($fns).Count -lt 2) { return }
    $paramNames = New-Object System.Collections.Generic.HashSet[string]
    foreach ($fn in $fns) {
        $pb = $fn.Body.ParamBlock
        if ($null -eq $pb) { continue }
        foreach ($pp in @($pb.Parameters)) { $null = $paramNames.Add($pp.Name.VariablePath.UserPath) }
    }
    if ($paramNames.Count -eq 0) { return }
    $auto = @('_', 'args', 'input', 'null', 'true', 'false', 'pid', 'host', 'home', 'PSItem', 'PSScriptRoot',
        'PSCommandPath', 'MyInvocation', 'ExecutionContext', 'PSVersionTable', 'PSCulture', 'PSUICulture', 'PSHome',
        'ShellId', 'ConsoleFileName', 'Error', 'Matches', 'LASTEXITCODE', 'StackTrace', 'PWD', 'PSBoundParameters',
        'this', 'OFS', 'PROFILE', 'NestedPromptLevel', 'PSModulePath', 'PID', 'IsCoreCLR', 'IsWindows', 'IsLinux',
        'IsMacOS', 'PSDefaultParameterValues', 'WhatIfPreference', 'VerbosePreference', 'DebugPreference',
        'ErrorActionPreference', 'WarningPreference', 'InformationPreference', 'ProgressPreference', 'ConfirmPreference')
    foreach ($fn in $fns) {
        if ($null -ne $fn.Body.ParamBlock) { continue }
        $assigned = New-Object System.Collections.Generic.HashSet[string]
        foreach ($a in $fn.Body.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] }, $true)) {
            $l = $a.Left
            if ($l -is [System.Management.Automation.Language.VariableExpressionAst]) { $null = $assigned.Add($l.VariablePath.UserPath) }
        }
        foreach ($fe in $fn.Body.FindAll({ param($n) $n -is [System.Management.Automation.Language.ForEachStatementAst] }, $true)) {
            if ($fe.Variable) { $null = $assigned.Add($fe.Variable.VariablePath.UserPath) }
        }
        $hit = ''
        foreach ($v in $fn.Body.FindAll({ param($n) $n -is [System.Management.Automation.Language.VariableExpressionAst] }, $true)) {
            $vp = $v.VariablePath
            # 注意：VariablePath.IsUnscopedVariable 对「普通变量」（如 $Path）也是 True —— 最初把它当异常前缀排除，
            # 导致规则永远不可能触发（实测踩过）。这里只排除真正的跨作用域/驱动限定前缀。
            if ($vp.IsGlobal -or $vp.IsScript -or $vp.IsPrivate -or $vp.IsDriveQualified) { continue }
            $nm = $vp.UserPath
            if ($nm -like '*:*') { continue }
            if ($auto -contains $nm) { continue }
            if ($assigned.Contains($nm)) { continue }
            if (-not $paramNames.Contains($nm)) { continue }
            # 只算「最近的 FunctionDefinitionAst 就是它自己」的引用，避免把嵌套函数的形参算在外层头上
            $owner = $v.Parent
            while ($null -ne $owner -and $owner -isnot [System.Management.Automation.Language.FunctionDefinitionAst]) { $owner = $owner.Parent }
            if ($owner -ne $fn) { continue }
            $hit = $nm
            break
        }
        if ($hit -ne '') {
            Add-Problem ($Rel + ' 函數 ' + $fn.Name + ' 沒有 param 塊卻引用 $' + $hit + '（本檔其他函數把它聲明為形參）-> PowerShell 會把 -' + $hit + ' 靜默吞進 $args，值永遠是空的')
        }
    }
}
function Invoke-LctSelfTest {
    # Directly exercise rule 2 through the AST: the bad shapes must be caught, the two
    # legitimate workarounds must NOT be reported.
    $cases = @(
        @{ name = 'BAD  param([string]$Page, $Args, $More)'; code = 'function T1 { param([string]$Page, $Args, $More) }'; expect = $true },
        @{ name = 'BAD  param($Args) in simple fn'; code = 'function T4 { param($Args) }'; expect = $true },
        @{ name = 'BAD  param([int]$N, [object]$Args)'; code = 'function T5 { param([int]$N, [object]$Args) }'; expect = $true },
        @{ name = 'GOOD advanced [Parameter(Mandatory)][string]$Args'; code = 'function T2 { param([Parameter(Mandatory = $true)][string]$Args) }'; expect = $false },
        @{ name = 'GOOD [CmdletBinding()] with $Args param'; code = 'function T6 { [CmdletBinding()] param([string]$Args) }'; expect = $false },
        @{ name = 'GOOD [Alias(Args)][object]$ArgBag'; code = 'function T3 { param([Alias(''Args'')][object]$ArgBag) }'; expect = $false }
    )
    $bad = 0
    foreach ($c in $cases) {
        $e = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseInput($c.code, [ref]$null, [ref]$e)
        $problems.Clear()
        Test-LctArgsShadow -Ast $ast -Rel '[selftest]'
        $hit = (@($problems).Count -gt 0)
        $ok = ($hit -eq [bool]$c.expect)
        Write-Host ('    ' + $(if ($ok) { 'PASS' } else { 'FAIL' }) + ' ' + $c.name + '  -> flagged=' + $hit + ' expect=' + [bool]$c.expect)
        if (-not $ok) { $bad++ }
    }
    return $bad
}

if ($SelfTest) {
    Write-Host 'Lint-PowerShell self-test: AST rule for $Args shadowing (rule 2)'
    $bad = Invoke-LctSelfTest
    $cases2 = @(
        @{ name = 'BAD  no param block but uses $Path (declared elsewhere)'; code = 'function A { param([string]$Path) $Path } function B { $q = $Path }'; expect = $true },
        @{ name = 'BAD  no param block but uses $Name'; code = 'function A { param([string]$Name) $Name } function C { if ($Name) { 1 } }'; expect = $true },
        @{ name = 'GOOD each function declares its own param'; code = 'function A { param([string]$Path) $Path } function B { param([string]$Path) $Path }'; expect = $false },
        @{ name = 'GOOD assigns it locally first'; code = 'function A { param([string]$Path) $Path } function B { $Path = ''x''; $Path }'; expect = $false },
        @{ name = 'GOOD script-scoped variable'; code = 'function A { param([string]$Path) $Path } function B { $script:Path }'; expect = $false }
    )
    foreach ($c2 in $cases2) {
        $e2 = $null
        $a2 = [System.Management.Automation.Language.Parser]::ParseInput($c2.code, [ref]$null, [ref]$e2)
        $problems.Clear()
        Test-LctParamShadow -Ast $a2 -Rel '[selftest]'
        $hit2 = (@($problems).Count -gt 0)
        $ok2 = ($hit2 -eq [bool]$c2.expect)
        Write-Host ('    ' + $(if ($ok2) { 'PASS' } else { 'FAIL' }) + ' ' + $c2.name + '  -> flagged=' + $hit2 + ' expect=' + [bool]$c2.expect)
        if (-not $ok2) { $bad++ }
    }
    Write-Host ('Lint-PowerShell self-test: ' + $(if ($bad -eq 0) { 'ALL PASS' } else { ([string]$bad + ' FAILED') }))
    exit $bad
}

$psExts = @('.ps1', '.psm1')
$files = @(Get-ChildItem -LiteralPath $root -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object { $psExts -contains $_.Extension.ToLower() -and $_.FullName -notlike '*\var\*' })
$rxAssign = '\$(' + ($readonly -join '|') + ')\s*=[^=]'

foreach ($f in $files) {
    $rel = $f.FullName.Substring($root.Length)
    # ---- 1. read-only automatic variable assignment ----
    $lines = @(Get-Content -LiteralPath $f.FullName -Encoding UTF8)
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match $rxAssign) {
            Add-Problem ($rel + ':' + ($i + 1) + ' 對只讀自動變數賦值(ASCII: read-only auto var assigned): ' + $lines[$i].Trim())
        }
    }
    # ---- 2. $Args as a parameter name of a simple function ----
    $errs = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$null, [ref]$errs)
    # ---- 2a. parse errors: a file that does not parse is the loudest problem of all ----
    if (@($errs).Count -gt 0) {
        Add-Problem ($rel + ' 解析失敗 PARSE ERRORS=' + @($errs).Count + ' -> ' + (@($errs)[0].Message))
    }
    # ---- 2b. $Args as a parameter name of a simple function ----
    if (@($errs).Count -eq 0) { Test-LctArgsShadow -Ast $ast -Rel $rel }
    if (@($errs).Count -eq 0) { Test-LctParamShadow -Ast $ast -Rel $rel }
    # ---- 3. BOM lost on a file that contains non-ASCII ----
    $bytes = [IO.File]::ReadAllBytes($f.FullName)
    $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
    $nonAscii = @($bytes | Where-Object { $_ -gt 127 }).Count
    if ($nonAscii -gt 0 -and -not $hasBom) {
        Add-Problem ($rel + ' 含非 ASCII 但缺 UTF-8 BOM -> PS5.1 會按 GBK 解析(whole file may fail to parse)')
    }
}

# ---- 4. .cmd must stay pure ASCII ----
foreach ($f in @(Get-ChildItem -LiteralPath $root -Recurse -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension.ToLower() -eq '.cmd' })) {
    $bytes = [IO.File]::ReadAllBytes($f.FullName)
    if (@($bytes | Where-Object { $_ -gt 127 }).Count -gt 0) {
        Add-Problem ($f.FullName.Substring($root.Length) + ' .cmd 含非 ASCII 字節(cmd.exe reads it as OEM)')
    }
}

Write-Host ('Lint-PowerShell: files=' + @($files).Count + ' problems=' + @($problems).Count + ' root=' + $root)
if (@($problems).Count -eq 0) { Write-Host 'Lint-PowerShell: CLEAN' }
exit @($problems).Count