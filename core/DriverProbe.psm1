# =====================================================================
# LocalConfigTool - DriverProbe.psm1
#
# 职责：**IOCTL 变异生成 + 单驱动探测编排**（阶段 2：动态验证的第一层）。
#
# 为什么需要它：
#   静态分析（profile.draft）只是"猜这个常量可能是 IOCTL"。真正的判定是：
#   把命令发过去，看它执行不执行、崩不崩、越不越界。
#   而"发什么"不能靠人手写——要从 profile 的 in 字段布局自动生成变异包。
#
# 变异层次（按危险度递增，探测时逐级升级）：
#   L1 baseline   合法输入（证明功能存在；失败说明 profile 参数不对）
#   L2 boundary   边界值（size=0 / 1 / expected±1 / 0xFFFFFFFF）→ 测边界检查缺失
#   L3 address    无效地址（0 / -1 / 低地址 / 用户态地址）→ 测参数校验缺失
#   L4 cross-page 跨页边界 → 测 ProbeForRead/Write 缺失
#
# 明确不做的事：
#   * 本模块**默认只生成 + 预览**，不发 IOCTL（`-Apply` 才真发）
#   * 不判断"这是不是漏洞"——它只如实记录"发了什么、系统回什么、有没有崩"
#   * 崩溃/超时是**结论**，不是失败（见 verdict）
#
# 导出（2 个）：
#   New-LctCtlPayloadVariants -Profile -Action
#   Invoke-LctCtlProbe         -Profile -Action -Apply -MaxVariants
# =====================================================================

$script:LctProbeSelf = $MyInvocation.MyCommand.Path
$script:LctProbeRoot = Split-Path -Parent (Split-Path -Parent $script:LctProbeSelf)
$script:LctProbeCore = Join-Path $script:LctProbeRoot 'core'

# 依赖：本模块要调 DriverProfiles / Logging 的函数。
# 不要 -Force 重载（会重置模块状态，破坏 Engine 会话）；能解析到就复用。
$script:LctProbeDeps = New-Object System.Collections.ArrayList
$probeMap = @{ 'Logging' = 'New-LctResult'; 'DriverProfiles' = 'Invoke-LctDriverCtl' }
foreach ($dep in @('Logging', 'DriverProfiles')) {
    $probeName = $probeMap[$dep]
    if ($null -ne (Get-Command -Name $probeName -ErrorAction SilentlyContinue)) {
        $null = $script:LctProbeDeps.Add($dep + ':reuse')
        continue
    }
    $depPath = Join-Path $script:LctProbeCore ($dep + '.psm1')
    if (-not (Test-Path -LiteralPath $depPath)) { $null = $script:LctProbeDeps.Add($dep + ':missing'); continue }
    try {
        Import-Module $depPath -ErrorAction Stop
        $null = $script:LctProbeDeps.Add($dep + ':imported')
    } catch {
        $null = $script:LctProbeDeps.Add($dep + ':FAIL ' + $_.Exception.Message)
    }
}
function Get-LctProbeDeps { return @($script:LctProbeDeps) }

function Get-LctProbeProp {
    # 注意：OrderedDictionary / Hashtable 的键**不在** PSObject.Properties 里
    #   （对它取 PSObject.Properties.Name 拿到的是 Count/Keys/Values 这些字典属性）
    #   所以必须先按 IDictionary 处理，否则 profile（OrderedDictionary）的字段全取不到。
    param($Bag, [string]$Name, $Default = $null)
    if ($null -eq $Bag) { return $Default }
    try {
        if ($Bag -is [System.Collections.IDictionary]) {
            if ($Bag.Contains($Name)) { return $Bag[$Name] }
            return $Default
        }
        $p = $Bag.PSObject.Properties[$Name]
        if ($null -ne $p) { return $p.Value }
    } catch { }
    return $Default
}

function Get-LctProbeFieldType {
    # 把 profile 的字段类型归一化：返回 u32/u64/bytes 三类 + 位宽
    param([string]$Type = '', [int]$Len = 0)
    $t = ([string]$Type).Trim().ToLowerInvariant()
    $bits = 0
    switch -regex ($t) {
        '^(u32|uint32|dword)$' { return @{ kind = 'u32'; bits = 32; len = 4 } }
        '^(u64|uint64|qword|u64ptr)$' { return @{ kind = 'u64'; bits = 64; len = 8 } }
        '^(u16|uint16|word)$' { return @{ kind = 'u16'; bits = 16; len = 2 } }
        '^(u8|uint8|byte)$' { return @{ kind = 'u8'; bits = 8; len = 1 } }
        '^(bytes|hex|blob)$' { $l = $(if ($Len -gt 0) { $Len } else { 8 }); return @{ kind = 'bytes'; bits = ($l * 8); len = $l } }
    }
    if ($Len -gt 0) { return @{ kind = 'bytes'; bits = ($Len * 8); len = $Len } }
    return @{ kind = 'unknown'; bits = 0; len = 0 }
}

function Format-LctProbeValue {
    # 按字段类型把整数格式化成 payload 能接受的字面量
    param([string]$Kind, [string]$Value)
    if ($Kind -eq 'u64') { return $Value }
    if ($Kind -eq 'u32') { return $Value }
    if ($Kind -eq 'u16') { return $Value }
    if ($Kind -eq 'u8') { return $Value }
    return $Value
}

function New-LctCtlPayloadVariants {
    <#
    .SYNOPSIS ctl.variants：从 profile 的 in 字段布局自动生成变异 payload 列表（**不发 IOCTL**）。
    .DESCRIPTION
      产出四种层次的变异：baseline / boundary / address / cross-page。
      每条带 mutation（变异类型）、payload（简写字符串）、why（为什么这么变）、risk（low/medium/high）。
      默认只生成，调用方拿去做预览或交给 ctl.probe 逐条发。
    #>
    param(
        [Parameter(Mandatory)][string]$Profile,
        [Parameter(Mandatory)][string]$Action,
        [int]$MaxVariants = 40
    )
    $verb = 'driver.ctl.variants'
    $warnings = New-Object System.Collections.ArrayList
    $errors = New-Object System.Collections.ArrayList

    $show = $null
    try { $show = Get-LctDriverProfileShow -Id $Profile } catch { $show = $null }
    if ($null -eq $show) { return New-LctResult -Verb $verb -Errors @('读不到 profile: ' + $Profile) }

    # 兼容两种返回风格：
    #   Get-LctDriverProfileShow 返回**裸 data**（id/source/profile/schemaOk…）
    #   若将来改成 Result 包装，则有 .data
    $shell = $show
    if (($null -ne $show.PSObject.Properties['data']) -and ($null -ne $show.data)) { $shell = $show.data }
    if ($null -ne $shell.PSObject.Properties['ok'] -and $shell.ok -eq $false) {
        return New-LctResult -Verb $verb -Errors @((@($shell.errors) -join ';'))
    }
    # 真正的 profile 在 shell.profile；没有则 shell 本身就是
    $prof = $shell
    $innerProf = Get-LctProbeProp $shell 'profile' $null
    if ($null -ne $innerProf) { $prof = $innerProf }
    $actions = Get-LctProbeProp $prof 'actions' $null
    if ($null -eq $actions) {
        return New-LctResult -Verb $verb -Errors @('profile 里没有 actions（id 可能不对，或 profile 未审定）: ' + $Profile)
    }
    $act = $null
    if ($null -ne $actions) {
        $a = Get-LctProbeProp $actions $Action $null
        if ($null -ne $a) { $act = $a }
    }
    if ($null -eq $act) {
        return New-LctResult -Verb $verb -Errors @('profile 里没有 action: ' + $Action)
    }

    $inFields = @(Get-LctProbeProp $act 'in' @())
    $presets = Get-LctProbeProp $act 'presets' $null
    $presetBag = @{}
    if ($null -ne $presets) {
        try {
            # presets 也是 OrderedDictionary —— 必须按 IDictionary 遍历，否则键全丢
            if ($presets -is [System.Collections.IDictionary]) {
                foreach ($k in @($presets.Keys)) { $presetBag[[string]$k] = $presets[$k] }
            } else {
                foreach ($p in @($presets.PSObject.Properties)) { $presetBag[[string]$p.Name] = $p.Value }
            }
        } catch { }
    }

    # 基线值：优先 presets，其次按类型给安全默认
    $baseVals = @{}
    foreach ($kv in $presetBag.GetEnumerator()) { $baseVals[[string]$kv.Key] = [string]$kv.Value }
    $addrField = ''
    $sizeField = ''
    foreach ($f in $inFields) {
        $nm = [string](Get-LctProbeProp $f 'name' '')
        if ($nm -eq '') { continue }
        $ty = Get-LctProbeFieldType -Type ([string](Get-LctProbeProp $f 'type' '')) -Len ([int](Get-LctProbeProp $f 'len' 0))
        if ($ty.kind -eq 'bytes') { continue }
        if (-not $baseVals.ContainsKey($nm)) {
            if ($nm -match '(?i)addr|address|base') { $baseVals[$nm] = '@ntoskrnl'; $addrField = $nm }
            elseif ($nm -match '(?i)size|length|len|count|bytes') { $baseVals[$nm] = '4'; $sizeField = $nm }
            else { $baseVals[$nm] = '0' }
        } else {
            if ($nm -match '(?i)addr|address|base') { $addrField = $nm }
            if ($nm -match '(?i)size|length|len|count|bytes') { $sizeField = $nm }
        }
    }
    # 无语义字段名（如探测产物 field_8）时不硬拒 —— 改用「无语义通用变异」。
    # 语义名只影响变异精准度，不影响可行性；对每个数值字段挨个试边界值，覆盖面其实更广。
    $genericMode = $false
    if ($addrField -eq '' -and $sizeField -eq '') {
        $genericMode = $true
        $null = $warnings.Add('profile 字段没有语义名（如 field_8）—— 改用「无语义通用变异」：对每个数值字段挨个试 0 / 1 / 最大值。')
    }

    $variants = New-Object System.Collections.ArrayList
    $addVariant = {
        param([string]$Mutation, [hashtable]$Vals, [string]$Why, [string]$Risk)
        $parts = @()
        foreach ($k in @($Vals.Keys | Sort-Object)) { $parts += ([string]$k + '=' + [string]$Vals[$k]) }
        $payload = ($parts -join ',')
        $null = $variants.Add([pscustomobject][ordered]@{
                mutation = $Mutation
                payload = $payload
                why = $Why
                risk = $Risk
                values = [pscustomobject]$Vals
            })
    }

    # ---- L1 基线（合法输入） ----
    & $addVariant 'baseline' $baseVals '合法基线：证明功能存在、profile 参数可用' 'low'

    # ---- L2 边界（长度字段） ----
    if ($sizeField -ne '') {
        $expected = 4
        try { $expected = [int]$baseVals[$sizeField] } catch { $expected = 4 }
        foreach ($spec in @(
                @{ v = 0; m = 'size-zero'; w = '零长度：很多驱动不检查 0 长度就直接 memcpy'; r = 'medium' }
                @{ v = 1; m = 'size-one'; w = '最小长度：读 1 字节，检查是否只读了 1 字节'; r = 'medium' }
                @{ v = ($expected + 1); m = 'size-over'; w = '超出预期 1 字节：经典 off-by-one'; r = 'high' }
                @{ v = 4294967295; m = 'size-max'; w = '0xFFFFFFFF：整数溢出/无上限检查'; r = 'high' }
            )) {
            $vals = @{}
            foreach ($kv in $baseVals.GetEnumerator()) { $vals[[string]$kv.Key] = [string]$kv.Value }
            $vals[$sizeField] = [string]$spec.v
            & $addVariant $spec.m $vals $spec.w $spec.r
        }
    }

    # ---- L3 地址（地址字段） ----
    if ($addrField -ne '') {
        foreach ($spec in @(
                @{ v = '0x0'; m = 'addr-null'; w = '空指针：没做空检查就直接访问'; r = 'medium' }
                @{ v = '0x1'; m = 'addr-low'; w = '低地址（用户态/未映射）：测 ProbeForRead 是否存在'; r = 'medium' }
                @{ v = '0xFFFFFFFFFFFFFFFF'; m = 'addr-max'; w = '全 F：无效内核地址，测地址校验'; r = 'high' }
                @{ v = '0x7FFFFFFF0000'; m = 'addr-user'; w = '典型用户态地址：测是否限制调用者地址空间'; r = 'high' }
            )) {
            $vals = @{}
            foreach ($kv in $baseVals.GetEnumerator()) { $vals[[string]$kv.Key] = [string]$kv.Value }
            $vals[$addrField] = [string]$spec.v
            & $addVariant $spec.m $vals $spec.w $spec.r
        }
    }

    # ---- L4 跨页（地址 + 长度组合） ----
    if ($addrField -ne '' -and $sizeField -ne '') {
        $vals = @{}
        foreach ($kv in $baseVals.GetEnumerator()) { $vals[[string]$kv.Key] = [string]$kv.Value }
        $vals[$addrField] = '@ntoskrnl'
        $vals[$sizeField] = '4294967295'
        & $addVariant 'cross-page-maxsize' $vals '内核基址 + 0xFFFFFFFF 长度：必然跨页，测边界检查' 'high'

        $vals2 = @{}
        foreach ($kv in $baseVals.GetEnumerator()) { $vals2[[string]$kv.Key] = [string]$kv.Value }
        $vals2[$addrField] = '0xFFFFFFFFFFFFFFFF'
        $vals2[$sizeField] = '0'
        & $addVariant 'addr-max-size-zero' $vals2 '全 F 地址 + 0 长度：测最短路径是否仍然访问指针' 'high'
    }

    # ---- L0 通用变异（无语义字段时的降级路径）----
    if ($genericMode) {
        $numFields = New-Object System.Collections.ArrayList
        foreach ($f in $inFields) {
            $nm = [string](Get-LctProbeProp $f 'name' '')
            if ($nm -eq '') { continue }
            $ty = Get-LctProbeFieldType -Type ([string](Get-LctProbeProp $f 'type' '')) -Len ([int](Get-LctProbeProp $f 'len' 0))
            if ($ty.kind -eq 'bytes') { continue }   # padding 不变异
            $null = $numFields.Add([pscustomobject]@{ name = $nm; kind = $ty.kind })
        }
        if (@($numFields).Count -eq 0) {
            return New-LctResult -Verb $verb -Warnings @($warnings) -Errors @('profile 里没有任何数值字段（全是 bytes padding），无法生成变异') -Data ([pscustomobject][ordered]@{ profile = $Profile; action = $Action; variants = @() })
        }
        foreach ($nf in @($numFields)) {
            $maxVal = if ($nf.kind -eq 'u64') { '0xFFFFFFFFFFFFFFFF' } else { '0xFFFFFFFF' }
            foreach ($spec in @(
                    @{ v = '0'; m = 'zero'; w = '该字段置 0（测 NULL/空值路径）'; r = 'medium' }
                    @{ v = '1'; m = 'one'; w = '该字段置 1（最小非零值）'; r = 'medium' }
                    @{ v = $maxVal; m = 'max'; w = '该字段置最大值（测无边界检查/整数溢出）'; r = 'high' }
                )) {
                $vals = @{}
                foreach ($kv in $baseVals.GetEnumerator()) { $vals[[string]$kv.Key] = [string]$kv.Value }
                $vals[$nf.name] = [string]$spec.v
                & $addVariant ($nf.name + '-' + $spec.m) $vals ($spec.w + ' [字段=' + $nf.name + '/' + $nf.kind + ']') $spec.r
            }
        }
    }

    $list = @($variants)
    if (@($list).Count -gt $MaxVariants) {
        $list = @($list | Select-Object -First $MaxVariants)
        $null = $warnings.Add('变异数超过 MaxVariants=' + $MaxVariants + '，已截断')
    }
    $data = [pscustomobject][ordered]@{
        profile     = $Profile
        action      = $Action
        ioctl       = [string](Get-LctProbeProp $act 'ioctl' '')
        inFields    = @($inFields | ForEach-Object { [pscustomobject][ordered]@{ name = [string](Get-LctProbeProp $_ 'name' ''); type = [string](Get-LctProbeProp $_ 'type' '') } })
        basePayload = (& { $p = @(); foreach ($k in @($baseVals.Keys | Sort-Object)) { $p += ([string]$k + '=' + [string]$baseVals[$k]) }; $p -join ',' })
        count       = @($list).Count
        variants    = $list
        note        = '本命令只生成变异，不发 IOCTL。要真发用 ctl.probe（默认也只预览，-Apply 才发送）。畸形包可能蓝屏——先确保有快照。'
    }
    return New-LctResult -Verb $verb -Warnings @($warnings) -Errors @($errors) -Data $data
}

function Invoke-LctCtlProbe {
    <#
    .SYNOPSIS ctl.probe：对单个驱动按变异层次逐条发 IOCTL，如实记录每次结果（默认只预览）。
    .DESCRIPTION
      逐级升级：baseline → boundary → address → cross-page。
      每条的 verdict 由系统返回判定：
        ok-data        返回了数据（**任意读/写确认**）
        error-invalid  ERROR_INVALID_FUNCTION（不认这个码）
        error-param    ERROR_INVALID_PARAMETER（认了但参数不对）
        timeout        超时（可能死锁/无界循环）
        crash          宿主进程消失/无响应（BSOD 或致命崩溃）
    .NOTES
      真发需要 -Apply。发之前请确认：有快照、这是自有设备、知道畸形包会蓝屏。
    #>
    param(
        [Parameter(Mandatory)][string]$Profile,
        [Parameter(Mandatory)][string]$Action,
        [int]$MaxVariants = 40,
        [switch]$Apply,
        [string]$Levels = 'baseline,boundary,address,cross-page'
    )
    $verb = 'driver.ctl.probe'
    $warnings = New-Object System.Collections.ArrayList
    $errors = New-Object System.Collections.ArrayList
    $sw = [Diagnostics.Stopwatch]::StartNew()

    $var = New-LctCtlPayloadVariants -Profile $Profile -Action $Action -MaxVariants $MaxVariants
    if ($null -eq $var -or -not $var.ok) {
        $e = '生成变异失败'
        if ($null -ne $var) { $e = (@($var.errors) -join ';') }
        return New-LctResult -Verb $verb -Errors @($e)
    }
    $want = @(([string]$Levels) -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })

    $results = New-Object System.Collections.ArrayList
    $sent = 0
    $skipped = 0
    foreach ($v in @($var.data.variants)) {
        $mut = [string]$v.mutation
        $lvl = 'baseline'
        if ($mut -like 'size-*') { $lvl = 'boundary' }
        elseif ($mut -like 'addr-*') { $lvl = 'address' }
        elseif ($mut -like 'cross-page-*' -or $mut -like 'addr-max-size-zero') { $lvl = 'cross-page' }
        if ($want -notcontains $lvl) { $skipped++; continue }

        $one = [ordered]@{
            mutation = $mut; level = $lvl; payload = [string]$v.payload; why = [string]$v.why
            risk = [string]$v.risk; sent = $false; verdict = ''; detail = ''; bytesReturned = 0; win32Error = 0; ms = 0
        }
        if (-not $Apply) {
            $one.verdict = 'preview'
            $null = $results.Add([pscustomobject]$one)
            continue
        }

        $vsw = [Diagnostics.Stopwatch]::StartNew()
        $r = $null
        try {
            # 盲扫类动作要 -IUnderstand；这里如实透传，让 ctl.send 自己判断
            $r = Invoke-LctDriverCtl -Profile $Profile -Action $Action -Payload ([string]$v.payload) -Apply
        } catch {
            $one.verdict = 'crash'
            $one.detail = '调用异常（可能崩溃）：' + $_.Exception.Message
        }
        $vsw.Stop()
        $one.ms = [int]$vsw.ElapsedMilliseconds
        $sent++

        if ($null -ne $r) {
            $one.sent = $true
            $d = $r.data
            if ($null -ne $d) {
                try { $one.bytesReturned = [int](Get-LctProbeProp $d 'bytesReturned' 0) } catch { }
                try { $one.win32Error = [int](Get-LctProbeProp $d 'win32Error' 0) } catch { }
                $cls = [string](Get-LctProbeProp $d 'classification' '')
                if ($r.ok -and $one.bytesReturned -gt 0) { $one.verdict = 'ok-data'; $one.detail = '返回 ' + $one.bytesReturned + ' 字节（功能执行成功）' }
                elseif ($cls -ne '') { $one.verdict = $cls }
                elseif (-not $r.ok) { $one.verdict = 'error-invalid'; $one.detail = (@($r.errors) -join ';') }
                else { $one.verdict = 'no-data'; $one.detail = '调用成功但没返回数据' }
            } else {
                $one.verdict = $(if ($r.ok) { 'no-data' } else { 'error-invalid' })
                $one.detail = (@($r.errors) -join ';')
            }
        } elseif ($one.verdict -eq '') {
            $one.verdict = 'unknown'
            $one.detail = '没有拿到结果'
        }
        $null = $results.Add([pscustomobject]$one)
    }
    $sw.Stop()

    $data = [pscustomobject][ordered]@{
        profile   = $Profile
        action    = $Action
        applied   = [bool]$Apply
        levels    = @($want)
        total     = @($results).Count
        sent      = $sent
        skipped   = $skipped
        ms        = $sw.ElapsedMilliseconds
        results   = @($results)
        note      = $(if ($Apply) {
                '逐条如实记录系统返回。ok-data = 功能执行成功（任意读写确认）；crash = 崩溃/无响应（校验缺失的强证据）；error-param = 认了但参数不对；error-invalid = 不认这个码。'
            } else {
                '当前是预览（未发 IOCTL）。加 -Apply 才真发；畸形包可能蓝屏，先确认有快照。'
            })
    }
    return New-LctResult -Verb $verb -Warnings @($warnings) -Errors @($errors) -Data $data
}

Export-ModuleMember -Function New-LctCtlPayloadVariants, Invoke-LctCtlProbe, Get-LctProbeDeps