# LocalConfigTool - 插件 SDK v2 纯逻辑层（core\PluginSdk.psm1）
# 冻结接口：docs\CONTRACT.md §12.1（导出恰好 7 个，第 7 个是 Get-LctPluginEngineApiVersion）
#           + §12.2（硬性语义）。签名与名字逐字一致，不得改名。
#
# 设计铁律（违反即返工）：
#   1) 本模块任何函数都【不得 throw】：一切可预期与不可预期的失败都转成 ok=false + errors，
#      让下游（core\Plugins.psm1 的 Get-LctPluginManifest / Invoke-LctPlugin）能做可读降级。
#      因此导出函数的主体全部包在 try/catch 里，catch 只追加可读错误，绝不重新抛出。
#   2) 本模块是【纯逻辑层】：不起进程、不写文件、不删文件、不联网；除「sha256 计算 + 存在性检查」
#      外不接触文件系统。也不依赖 Logging.psm1，可独立 Import-Module（装载顺序自由）。
#   3) 未知 capability / 未知 kind / 含 .. 的路径 / sha256 不符或文件不存在 ⇒ ok=false 且点名。
#   4) v1 兼容：缺 manifest/engineApi/capabilities ⇒ ok=true + degraded=true，并在 warnings 里
#      写明「按 v1 规则运行」。绝不允许因为缺 v2 字段就拒绝老插件。
#   5) engineApi 是形如 ">=1.0 <2.0" 的区间；引擎版本常量 1.0。
#      不满足 ⇒ engineApiOk=false（仍然 ok=true，由调用方决定是否拒绝）。
#   6) 种类注册表初始只有 ps1/exe；能力表见 §12.2 第 8 条（9 项；写类 4 项 needsConfirm=true）。
#   7) Windows PowerShell 5.1 可跑；不 Set-StrictMode；形参名不用 $Args；不用只读自动变量名；中文文案。
#   8) 取清单字段一律走 Get-LctSdkProp：它在返回**数组值**时用一元逗号（`,$v`）阻止 PowerShell 在 return
#      处把「单元素数组」解包成裸值。实测（PS 5.1）：清单里 "kinds":["ps1"] 若直接 `return $prop.Value`
#      会变成字符串 'ps1'，把完全合法的清单误判成「字段形状错误」。PluginSdkTest 对该回归有专门断言。
#
# 相对冻结语义的两处【有意收紧】（比 §12.2 更严，不与任何冻结签名冲突，均已在下方注明）：
#   a) integrity.sha256 的键若是绝对路径 ⇒ ok=false（完整性清单只能指向插件目录内的相对文件）；
#   b) integrity.sha256 的期望值不是 64 位十六进制 ⇒ ok=false（写错的哈希不可能"碰巧通过"）。
#
# 边界（docs\CONTRACT.md §12.4 与 docs\PLUGIN-SDK.md §10，写死、不得放宽）：本 SDK 不提供加载任意内核
# 载荷、不执行任意内核命令、不绕过签名强制（不改 testsigning / 不关 VBS·HVCI / 不碰 DSE / 不写
# nointegritychecks）、不做隐藏或伪装、不做针对安全产品（杀软·EDR·反作弊）的停止/屏蔽/绕过流程。
# 因此本模块的种类表里没有 driver、能力表里也没有任何 kernel.* / policy.wdac 项（§12.2 第 8 条只列 9 项）。

# 引擎 API 版本常量（§12.2 第 5 条）。用 Get-LctPluginEngineApiVersion 读取，不要在别处硬编码。
$script:LctPluginEngineApiVersion = '1.0'

# ---------------------------------------------------------------------------
# 内部辅助（不导出）
# ---------------------------------------------------------------------------

function Get-LctSdkProp {
    # 从 Hashtable / PSCustomObject 上安全取属性（不存在、类型不符或对象为空都返回 $null）
    # 注意：数组等可枚举值必须用一元逗号返回，否则 PowerShell 会在 return 处把单元素数组解包成裸值。
    param($Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    $value = $null
    if ($Object -is [System.Collections.IDictionary]) {
        if (-not $Object.Contains($Name)) { return $null }
        $value = $Object[$Name]
    } elseif ($Object -is [System.Management.Automation.PSCustomObject]) {
        $prop = $Object.PSObject.Properties[$Name]
        if ($null -eq $prop) { return $null }
        $value = $prop.Value
    } else {
        return $null
    }
    if ($null -eq $value) { return $null }
    $isString = $value -is [string]
    if ((-not $isString) -and ($value -is [System.Collections.IEnumerable])) { return ,$value }
    return $value
}

function Get-LctSdkStringList {
    # 把清单里的数组字段归一化为字符串数组。
    # 返回 @{ ok; items; error }；ok=false 表示形状不对（写成了字符串/对象/非字符串元素）。
    param($Value, [string]$Name)
    if ($null -eq $Value) { return @{ ok = $true; items = @(); error = '' } }
    if ($Value -is [string]) {
        return @{ ok = $false; items = @(); error = "$Name 必须是字符串数组，不能是单个字符串" }
    }
    if ($Value -is [System.Collections.IDictionary]) {
        return @{ ok = $false; items = @(); error = "$Name 必须是字符串数组，不能是对象" }
    }
    if ($Value -is [System.Management.Automation.PSCustomObject]) {
        return @{ ok = $false; items = @(); error = "$Name 必须是字符串数组，不能是对象" }
    }
    if ($Value -is [System.Collections.IEnumerable]) {
        $items = New-Object System.Collections.ArrayList
        foreach ($v in @($Value)) {
            if ($null -eq $v) { continue }
            if (-not ($v -is [string])) {
                return @{ ok = $false; items = @(); error = "$Name 的元素必须都是字符串" }
            }
            $null = $items.Add([string]$v)
        }
        return @{ ok = $true; items = @($items); error = '' }
    }
    return @{ ok = $false; items = @(); error = "$Name 必须是字符串数组" }
}

function New-LctPluginV2Outcome {
    # §12.1 冻结返回形状：ok / errors / warnings / manifestVersion / engineApiOk / capabilities / kinds / degraded
    param($Errors, $Warnings, $ManifestVersion, $EngineApiOk, $Capabilities, $Kinds, $Degraded)
    return [pscustomobject][ordered]@{
        ok              = (@($Errors).Count -eq 0)
        errors          = @($Errors)
        warnings        = @($Warnings)
        manifestVersion = [int]$ManifestVersion
        engineApiOk     = [bool]$EngineApiOk
        capabilities    = @($Capabilities)
        kinds           = @($Kinds)
        degraded        = [bool]$Degraded
    }
}

function Get-LctSdkVersionObject {
    # 把 "1.0"/"1.0.0" 之类的文本转成 [version]；失败返回 $null（不 throw）
    param([string]$Text)
    $v = New-Object System.Version(0,0)
    if ([version]::TryParse(([string]$Text).Trim(), [ref]$v)) { return $v }
    return $null
}

# ---------------------------------------------------------------------------
# 导出函数（§12.1）
# ---------------------------------------------------------------------------

function Get-LctPluginKindRegistry {
    <#
      .SYNOPSIS
        入口种类注册表（§12.1 / §12.2 第 7 条）：kind -> @{ name; isolation; needsApply; entryRequired[]; summary }。
      .DESCRIPTION
        P0 初始内容只有 ps1 与 exe（两个都是子进程隔离，均为 v1 现有行为）。
        **加新种类 = 在下面加一条表项**，解析器（core\Plugins.psm1）与执行器不得再写 kind 硬编码分支。
        driver / psm1 等未列入：driver 受 §12.4 边界限制（本 SDK 不做内核载荷与签名绕过类能力），
        psm1（常驻）属于后续阶段，未在本任务范围内实现，因此不在此表里"占位"。
    #>
    $registry = @{}
    $registry['ps1'] = [pscustomobject][ordered]@{
        name          = 'ps1'
        isolation     = '子进程'
        needsApply    = $true
        entryRequired = @('path')
        summary       = '一次性 PowerShell 脚本入口（保持 v1 现状，永久支持）'
    }
    $registry['exe'] = [pscustomobject][ordered]@{
        name          = 'exe'
        isolation     = '子进程'
        needsApply    = $true
        entryRequired = @('path')
        summary       = '原生可执行入口（保持 v1 现状，永久支持）'
    }
    return $registry
}

function Get-LctPluginCapabilityTable {
    <#
      .SYNOPSIS
        能力表（§12.1 / §12.2 第 8 条）：capability -> @{ name; risk; needsConfirm; summary }。
      .DESCRIPTION
        命名空间化常量，由引擎侧硬编码维护，插件只能"申请"不能自定义。
        P0 初始内容严格等于 §12.2 第 8 条列出的 9 项：
          read.process / write.process / read.registry / write.registry / read.fs / write.fs /
          account.change / service.control / network.out
        其中 write.process / write.registry / account.change / service.control 必须 needsConfirm=true。
        刻意不包含 kernel.* 与 policy.wdac —— 见本文件头部「边界」。
    #>
    $table = @{}
    $table['read.process'] = [pscustomobject][ordered]@{
        name         = 'read.process'
        risk         = 'low'
        needsConfirm = $false
        summary      = '只读进程信息（枚举/详情），无副作用'
    }
    $table['write.process'] = [pscustomobject][ordered]@{
        name         = 'write.process'
        risk         = 'high'
        needsConfirm = $true
        summary      = '影响进程（终止/阻断等），必须逐条确认'
    }
    $table['read.registry'] = [pscustomobject][ordered]@{
        name         = 'read.registry'
        risk         = 'low'
        needsConfirm = $false
        summary      = '只读注册表，无副作用'
    }
    $table['write.registry'] = [pscustomobject][ordered]@{
        name         = 'write.registry'
        risk         = 'high'
        needsConfirm = $true
        summary      = '写注册表（含 HKLM 高风险面），必须逐条确认且先备份'
    }
    $table['read.fs'] = [pscustomobject][ordered]@{
        name         = 'read.fs'
        risk         = 'low'
        needsConfirm = $false
        summary      = '只读文件（哈希/列举/存在性），无副作用'
    }
    $table['write.fs'] = [pscustomobject][ordered]@{
        name         = 'write.fs'
        risk         = 'medium'
        needsConfirm = $false
        summary      = '写文件（含临时文件即可），删除只允许走回收站'
    }
    $table['account.change'] = [pscustomobject][ordered]@{
        name         = 'account.change'
        risk         = 'high'
        needsConfirm = $true
        summary      = '更改账户/UAC/自动登录，必须逐条确认且先备份'
    }
    $table['service.control'] = [pscustomobject][ordered]@{
        name         = 'service.control'
        risk         = 'high'
        needsConfirm = $true
        summary      = '服务控制（启停/配置），必须逐条确认'
    }
    $table['network.out'] = [pscustomobject][ordered]@{
        name         = 'network.out'
        risk         = 'medium'
        needsConfirm = $false
        summary      = '对外网络访问，需写审计日志'
    }
    return $table
}

function Get-LctPluginEngineApiVersion {
    <#
      .SYNOPSIS
        当前引擎实现的插件 API 版本常量（§12.2 第 5 条「写在模块里、可查」）。
      .DESCRIPTION
        返回形如 '1.0' 的字符串。清单里的 engineApi 是相对这个常量比较的区间。
    #>
    return [string]$script:LctPluginEngineApiVersion
}

function Test-LctPluginEngineApi {
    <#
      .SYNOPSIS
        校验清单声明的 engineApi 区间是否被当前引擎满足（§12.1 / §12.2 第 5 条）。
      .DESCRIPTION
        区间由空白分隔的若干比较式组成（AND 语义），支持 >= <= == = > <（也接受裸版本号 = 精确相等），
        版本号形如 major.minor[.patch]。返回 @{ ok; errors=@(); reason }。
        * 区间无法解析 / 版本号非法 ⇒ ok=false，错误进 errors；
        * 区间可解析但引擎不满足 ⇒ ok=false，**errors 为空**，解释写在 reason（调用方据此置 engineApiOk=false）。
        本函数不 throw。
    #>
    param([string]$Requirement, [string]$EngineApi)

    $errors = New-Object System.Collections.ArrayList
    try {
        $reqText = ''
        $engText = ''
        if ($null -ne $Requirement) { $reqText = ([string]$Requirement).Trim() }
        if ($null -ne $EngineApi) { $engText = ([string]$EngineApi).Trim() }

        if ([string]::IsNullOrWhiteSpace($engText)) {
            $null = $errors.Add('引擎 API 版本为空，无法比较')
            return @{ ok = $false; errors = @($errors); reason = '引擎 API 版本为空' }
        }
        $engVersion = Get-LctSdkVersionObject -Text $engText
        if ($null -eq $engVersion) {
            $null = $errors.Add("引擎 API 版本不是合法的 major.minor[.patch] 形式: $engText")
            return @{ ok = $false; errors = @($errors); reason = '引擎 API 版本无法解析' }
        }
        if ([string]::IsNullOrWhiteSpace($reqText)) {
            $null = $errors.Add('engineApi 要求为空；缺 engineApi 的清单应按 v1 规则处理，不应调用本函数')
            return @{ ok = $false; errors = @($errors); reason = 'engineApi 要求为空' }
        }

        $tokens = @($reqText -split '\s+' | Where-Object { $_ -ne '' })
        $failed = New-Object System.Collections.ArrayList
        foreach ($token in @($tokens)) {
            $op = ''
            $verText = ''
            foreach ($cand in @('>=', '<=', '==', '>', '<', '=')) {
                if ($token.StartsWith($cand)) { $op = $cand; $verText = $token.Substring($cand.Length); break }
            }
            if ([string]::IsNullOrEmpty($op)) { $op = '='; $verText = $token }
            $reqVersion = Get-LctSdkVersionObject -Text $verText
            if ($null -eq $reqVersion) {
                $null = $errors.Add("engineApi 区间里的版本号无法解析: $token")
                continue
            }
            $cmp = $engVersion.CompareTo($reqVersion)
            $pass = $true
            switch ($op) {
                '>='    { $pass = ($cmp -ge 0) }
                '<='    { $pass = ($cmp -le 0) }
                '=='    { $pass = ($cmp -eq 0) }
                '='     { $pass = ($cmp -eq 0) }
                '>'     { $pass = ($cmp -gt 0) }
                '<'     { $pass = ($cmp -lt 0) }
                default { $pass = $false }
            }
            if (-not $pass) { $null = $failed.Add($token) }
        }

        if ($errors.Count -gt 0) {
            return @{ ok = $false; errors = @($errors); reason = "engineApi 区间无法解析: $reqText" }
        }
        if ($failed.Count -gt 0) {
            $reason = "引擎 $engText 不满足要求 '$reqText'（未成立: $(@($failed) -join ', ')）"
            return @{ ok = $false; errors = @(); reason = $reason }
        }
        return @{ ok = $true; errors = @(); reason = "引擎 $engText 满足要求 '$reqText'" }
    } catch {
        $null = $errors.Add("engineApi 校验内部错误（已转为可读错误）: $($_.Exception.Message)")
        return @{ ok = $false; errors = @($errors); reason = 'engineApi 校验内部错误' }
    }
}

function Get-LctPluginChecksum {
    <#
      .SYNOPSIS
        计算单个文件的 SHA-256 与大小（§12.1）。
      .DESCRIPTION
        返回 @{ ok; sha256; size; error }；sha256 是小写 64 位十六进制。
        文件不存在（或路径是目录/为空/非法）⇒ ok=false 且 error 说明原因。本函数不 throw。
        只读打开并共享读写，不改动目标文件。
    #>
    param([string]$Path)

    $result = @{ ok = $false; sha256 = ''; size = 0; error = '' }
    try {
        $target = ''
        if ($null -ne $Path) { $target = [string]$Path }
        if ([string]::IsNullOrWhiteSpace($target)) {
            $result.error = '未提供文件路径'
            return $result
        }
        # 用 .NET 的 Exists 而不是 Test-Path：非法路径/通配符路径不会产生非终止错误记录（不污染调用方的
        # 错误流），而且按字面处理、不做通配符展开。
        $fileExists = $false
        try { $fileExists = [System.IO.File]::Exists($target) } catch { $fileExists = $false }
        if (-not $fileExists) {
            $dirExists = $false
            try { $dirExists = [System.IO.Directory]::Exists($target) } catch { $dirExists = $false }
            if ($dirExists) {
                $result.error = "路径是目录而不是文件: $target"
            } else {
                $result.error = "文件不存在或路径非法: $target"
            }
            return $result
        }

        $size = 0
        try { $size = [long](Get-Item -LiteralPath $target -ErrorAction Stop).Length } catch { $size = 0 }

        $sha = $null
        $stream = $null
        try {
            $sha = [System.Security.Cryptography.SHA256]::Create()
            $stream = [System.IO.File]::Open($target, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
            $bytes = $sha.ComputeHash($stream)
            $result.sha256 = (($bytes | ForEach-Object { $_.ToString('x2') }) -join '')
            $result.size = $size
            $result.ok = $true
        } finally {
            if ($null -ne $stream) { try { $stream.Dispose() } catch { } }
            if ($null -ne $sha) { try { $sha.Dispose() } catch { } }
        }
        return $result
    } catch {
        $result.ok = $false
        $result.sha256 = ''
        $result.size = 0
        $result.error = "计算文件校验和失败: $($_.Exception.Message)"
        return $result
    }
}

function Test-LctPluginIntegrity {
    <#
      .SYNOPSIS
        按清单的 integrity.sha256 校验插件目录内的文件（§12.1 / §12.2 第 3、6 条）。
      .DESCRIPTION
        返回 @{ ok; errors=@(); checked=@() }，checked 每项为 @{ path; expected; actual; matched }。
        * integrity 为空 ⇒ ok=true（清单没有声明完整性，不做要求）；
        * sha256 的键含 `..` ⇒ ok=false（点名，禁止越出插件目录）；
        * 键是绝对路径 ⇒ ok=false（有意收紧：完整性清单只能指向插件目录内的相对文件）；
        * 期望值不是 64 位十六进制 ⇒ ok=false（有意收紧：写错的哈希不可能"碰巧"通过）；
        * 声明的文件不存在 / 读取失败 ⇒ ok=false；哈希与实际不符 ⇒ ok=false。
        本函数不 throw。
    #>
    param([string]$Dir, $Integrity)

    $errors = New-Object System.Collections.ArrayList
    $checked = New-Object System.Collections.ArrayList
    try {
        if ($null -eq $Integrity) {
            return @{ ok = $true; errors = @(); checked = @() }
        }
        $isContainer = ($Integrity -is [System.Collections.IDictionary]) -or ($Integrity -is [System.Management.Automation.PSCustomObject])
        if (-not $isContainer) {
            $null = $errors.Add("integrity 必须是对象（含可选的 sha256 映射），收到 $($Integrity.GetType().Name)")
            return @{ ok = $false; errors = @($errors); checked = @() }
        }

        $sha256Map = Get-LctSdkProp $Integrity 'sha256'
        if ($null -eq $sha256Map) {
            return @{ ok = $true; errors = @(); checked = @() }
        }

        $entries = New-Object System.Collections.ArrayList
        if ($sha256Map -is [System.Collections.IDictionary]) {
            foreach ($k in @($sha256Map.Keys)) {
                $null = $entries.Add([pscustomobject]@{ key = [string]$k; value = $sha256Map[$k] })
            }
        } elseif ($sha256Map -is [System.Management.Automation.PSCustomObject]) {
            foreach ($p in @($sha256Map.PSObject.Properties)) {
                $null = $entries.Add([pscustomobject]@{ key = [string]$p.Name; value = $p.Value })
            }
        } else {
            $null = $errors.Add('integrity.sha256 必须是 { 相对路径: 哈希 } 对象，不能是字符串/数组/数字')
            return @{ ok = $false; errors = @($errors); checked = @() }
        }
        if ($entries.Count -eq 0) {
            return @{ ok = $true; errors = @(); checked = @() }
        }

        $dirText = ''
        if ($null -ne $Dir) { $dirText = [string]$Dir }
        $dirOk = $false
        if (-not [string]::IsNullOrWhiteSpace($dirText)) {
            # 同样用 .NET Exists：非法路径不产生非终止错误记录
            try { $dirOk = [System.IO.Directory]::Exists($dirText) } catch { $dirOk = $false }
        }
        if (-not $dirOk) {
            $null = $errors.Add("插件目录不存在或不可访问，无法校验完整性: $dirText")
            return @{ ok = $false; errors = @($errors); checked = @() }
        }

        foreach ($entry in @($entries)) {
            try {
                $rel = ([string]$entry.key).Trim()
                $expected = ''
                if ($null -ne $entry.value) { $expected = ([string]$entry.value).Trim() }

                if ([string]::IsNullOrEmpty($rel)) {
                    $null = $errors.Add('integrity.sha256 里有空的路径键')
                    continue
                }
                if ($rel -match '\.\.') {
                    $null = $errors.Add("integrity.sha256 的路径不得包含 ..（禁止越出插件目录）: $rel")
                    $null = $checked.Add([pscustomobject]@{ path = $rel; expected = $expected.ToLowerInvariant(); actual = ''; matched = $false })
                    continue
                }
                if ([IO.Path]::IsPathRooted($rel)) {
                    $null = $errors.Add("integrity.sha256 的键必须是插件目录内的相对路径: $rel")
                    $null = $checked.Add([pscustomobject]@{ path = $rel; expected = $expected.ToLowerInvariant(); actual = ''; matched = $false })
                    continue
                }
                if ($expected -notmatch '^[0-9a-fA-F]{64}$') {
                    $null = $errors.Add("integrity.sha256.$rel 的期望值不是合法的 SHA-256（需 64 位十六进制）: $expected")
                    $null = $checked.Add([pscustomobject]@{ path = $rel; expected = $expected.ToLowerInvariant(); actual = ''; matched = $false })
                    continue
                }

                $full = Join-Path $dirText $rel
                $check = Get-LctPluginChecksum -Path $full
                if (-not $check.ok) {
                    $null = $errors.Add("integrity 声明的文件不可校验: $rel（$($check.error)）")
                    $null = $checked.Add([pscustomobject]@{ path = $rel; expected = $expected.ToLowerInvariant(); actual = ''; matched = $false })
                    continue
                }
                $actual = ([string]$check.sha256).ToLowerInvariant()
                $matched = ($actual -eq $expected.ToLowerInvariant())
                if (-not $matched) {
                    $null = $errors.Add("sha256 不符: $rel（期望 $($expected.ToLowerInvariant())，实际 $actual）")
                }
                $null = $checked.Add([pscustomobject]@{ path = $rel; expected = $expected.ToLowerInvariant(); actual = $actual; matched = $matched })
            } catch {
                $null = $errors.Add("校验完整性条目 '$($entry.key)' 时出错: $($_.Exception.Message)")
            }
        }
    } catch {
        $null = $errors.Add("完整性校验内部错误（已转为可读错误）: $($_.Exception.Message)")
    }
    return @{ ok = ($errors.Count -eq 0); errors = @($errors); checked = @($checked) }
}

function Test-LctPluginManifestV2 {
    <#
      .SYNOPSIS
        插件清单 v2 校验（§12.1 / §12.2 全部硬性语义）。core\Plugins.psm1 解析 v1 清单之后条件调用本函数。
      .DESCRIPTION
        返回 [pscustomobject]@{ ok; errors; warnings; manifestVersion; engineApiOk; capabilities; kinds; degraded }。
        * v1 兼容（§12.2 第 4 条）：缺 manifest/engineApi/capabilities ⇒ ok=true + degraded=true，
          warnings 里写明「按 v1 规则运行」，绝不拒绝老插件；
        * 未知 capability / 未知 kind（含 kinds[] 与 entry.kind）⇒ ok=false 并点名；
        * entry.path / integrity.sha256 的键 / lifecycle 命令里含 `..` 的路径 ⇒ ok=false；
        * integrity.sha256 不符或文件不存在 ⇒ ok=false；
        * engineApi 不满足 ⇒ engineApiOk=false（ok 仍为 true，由调用方决定是否拒绝）。
        本函数不 throw。此处只做「清单说了什么」的校验，不启动任何进程、不执行任何载荷。
    #>
    param($Obj, [string]$Dir, [string]$Id)

    $errors = New-Object System.Collections.ArrayList
    $warnings = New-Object System.Collections.ArrayList
    $capabilities = New-Object System.Collections.ArrayList
    $kinds = New-Object System.Collections.ArrayList
    $manifestVersion = 1
    $engineApiOk = $true
    $degraded = $true

    try {
        # ---- 0. 形状：必须是对象（v1 解析器已保证，这里对"直接调用/异常输入"兜底）----
        if ($null -eq $Obj) {
            $null = $errors.Add('插件清单为空（未提供清单对象）')
            return (New-LctPluginV2Outcome -Errors $errors -Warnings $warnings -ManifestVersion $manifestVersion -EngineApiOk $engineApiOk -Capabilities $capabilities -Kinds $kinds -Degraded $degraded)
        }
        $isContainer = ($Obj -is [System.Collections.IDictionary]) -or ($Obj -is [System.Management.Automation.PSCustomObject])
        if (-not $isContainer) {
            $null = $errors.Add("插件清单必须是对象，收到 $($Obj.GetType().Name)")
            return (New-LctPluginV2Outcome -Errors $errors -Warnings $warnings -ManifestVersion $manifestVersion -EngineApiOk $engineApiOk -Capabilities $capabilities -Kinds $kinds -Degraded $degraded)
        }

        # ---- 1. id（与 v1 规则一致：必填 + 只允许字母数字与 . - _）----
        $idText = ''
        $idRaw = Get-LctSdkProp $Obj 'id'
        if ($null -ne $idRaw) { $idText = ([string]$idRaw).Trim() }
        if ([string]::IsNullOrEmpty($idText)) {
            $null = $errors.Add('插件清单缺少 id')
        } elseif ($idText -notmatch '^[A-Za-z0-9][A-Za-z0-9\.\-_]*$') {
            $null = $errors.Add("插件 id 非法（只允许字母数字与 . - _）: $idText")
        }
        $idExpected = ''
        if ($null -ne $Id) { $idExpected = ([string]$Id).Trim() }
        if ((-not [string]::IsNullOrEmpty($idExpected)) -and (-not [string]::IsNullOrEmpty($idText)) -and ($idText -ne $idExpected)) {
            $null = $errors.Add("插件 id 与所在目录名不一致: 目录=$idExpected 清单=$idText")
        }

        # ---- 2. manifest 版本（缺省=1 ⇒ v1 路径）----
        $manifestRaw = Get-LctSdkProp $Obj 'manifest'
        if ($null -eq $manifestRaw) {
            $manifestVersion = 1
            $degraded = $true
            $null = $warnings.Add('清单未声明 manifest 字段，按 v1 规则运行')
        } else {
            $parsed = 0
            $manifestOk = $false
            $manifestText = ''
            if ($manifestRaw -is [string] -or $manifestRaw -is [int] -or $manifestRaw -is [long] -or $manifestRaw -is [double] -or $manifestRaw -is [decimal]) {
                $manifestText = ([string]$manifestRaw).Trim()
                $manifestOk = [int]::TryParse($manifestText, [ref]$parsed)
            }
            if ((-not $manifestOk) -or ($parsed -lt 1) -or ($parsed -gt 2)) {
                $null = $errors.Add("清单 manifest 版本不受支持: $manifestRaw（当前引擎只支持 1 与 2）")
                $degraded = $true
            } else {
                $manifestVersion = $parsed
                if ($parsed -lt 2) {
                    $degraded = $true
                    $null = $warnings.Add("清单声明 manifest=$parsed，按 v1 规则运行")
                } else {
                    $degraded = $false
                }
            }
        }

        # ---- 3. engineApi（不满足 ⇒ engineApiOk=false；缺 ⇒ v1 降级且 engineApiOk 保持 true）----
        $engineApiRaw = Get-LctSdkProp $Obj 'engineApi'
        $engineApiText = ''
        if ($null -ne $engineApiRaw) { $engineApiText = ([string]$engineApiRaw).Trim() }
        if ([string]::IsNullOrWhiteSpace($engineApiText)) {
            $engineApiOk = $true
            $degraded = $true
            $null = $warnings.Add('清单未声明 engineApi，按 v1 规则运行（不校验引擎 API 门槛）')
        } else {
            $apiResult = @{ ok = $false; errors = @(); reason = '' }
            try {
                $apiResult = Test-LctPluginEngineApi -Requirement $engineApiText -EngineApi ([string]$script:LctPluginEngineApiVersion)
            } catch {
                $apiResult = @{ ok = $false; errors = @($_.Exception.Message); reason = 'engineApi 校验内部错误' }
            }
            $engineApiOk = [bool]$apiResult.ok
            if (-not $engineApiOk) {
                $null = $warnings.Add("engineApi 要求 '$engineApiText' 不满足当前引擎 $($script:LctPluginEngineApiVersion)：$($apiResult.reason)")
            }
        }

        # ---- 4. capabilities（未知能力 ⇒ ok=false 并点名）----
        $capRaw = Get-LctSdkProp $Obj 'capabilities'
        if ($null -eq $capRaw) {
            $degraded = $true
            $null = $warnings.Add('清单未声明 capabilities，按 v1 规则运行（引擎无法按能力做默认拒绝）')
        } else {
            $capInfo = Get-LctSdkStringList -Value $capRaw -Name 'capabilities'
            if (-not $capInfo.ok) {
                $null = $errors.Add($capInfo.error)
            } else {
                $capTable = Get-LctPluginCapabilityTable
                $knownNames = @($capTable.Keys | Sort-Object)
                foreach ($c in @($capInfo.items)) {
                    $cName = ([string]$c).Trim()
                    if ([string]::IsNullOrEmpty($cName)) {
                        $null = $errors.Add('capabilities 里有空的能力名')
                        continue
                    }
                    if (-not $capTable.ContainsKey($cName)) {
                        $null = $errors.Add("未知能力: $cName（不在引擎能力表内；已知能力: $($knownNames -join ', ')）")
                    } else {
                        $null = $capabilities.Add($cName)
                    }
                }
            }
        }

        # ---- 5. kinds[] 与 entry.kind（未知种类 ⇒ ok=false 并点名）----
        $kindTable = Get-LctPluginKindRegistry
        $knownKinds = @($kindTable.Keys | Sort-Object)
        $kindsRaw = Get-LctSdkProp $Obj 'kinds'
        if ($null -ne $kindsRaw) {
            $kindInfo = Get-LctSdkStringList -Value $kindsRaw -Name 'kinds'
            if (-not $kindInfo.ok) {
                $null = $errors.Add($kindInfo.error)
            } else {
                foreach ($k in @($kindInfo.items)) {
                    $kName = ([string]$k).Trim()
                    if ([string]::IsNullOrEmpty($kName)) {
                        $null = $errors.Add('kinds 里有空的入口种类名')
                        continue
                    }
                    if (-not $kindTable.ContainsKey($kName)) {
                        $null = $errors.Add("未知入口种类(kinds): $kName（不在种类注册表内；已知种类: $($knownKinds -join ', ')）")
                    } else {
                        $null = $kinds.Add($kName)
                    }
                }
            }
        }

        $entry = Get-LctSdkProp $Obj 'entry'
        if ($null -eq $entry) {
            $null = $errors.Add('清单缺少 entry（v1/v2 都要求 entry.kind 与 entry.path）')
        } else {
            $entryKind = ''
            $kindRaw = Get-LctSdkProp $entry 'kind'
            if ($null -ne $kindRaw) { $entryKind = ([string]$kindRaw).Trim() }
            if ([string]::IsNullOrEmpty($entryKind)) {
                $null = $errors.Add('清单缺少 entry.kind')
            } elseif (-not $kindTable.ContainsKey($entryKind)) {
                $null = $errors.Add("未知入口种类(entry.kind): $entryKind（不在种类注册表内；已知种类: $($knownKinds -join ', ')）")
            } else {
                if ($kinds.Count -eq 0) {
                    $null = $kinds.Add($entryKind)
                } elseif ($kinds -notcontains $entryKind) {
                    $null = $warnings.Add("entry.kind '$entryKind' 未列在 kinds 里，已按清单自动补入种类列表")
                    $null = $kinds.Add($entryKind)
                }
            }

            $rel = ''
            $pathRaw = Get-LctSdkProp $entry 'path'
            if ($null -ne $pathRaw) { $rel = ([string]$pathRaw).Trim() }
            if ([string]::IsNullOrEmpty($rel)) {
                $null = $errors.Add('清单缺少 entry.path')
            } elseif ($rel -match '\.\.') {
                $null = $errors.Add("entry.path 不得包含 ..（禁止越出插件目录）: $rel")
            }
        }

        # ---- 6. lifecycle：每个动作必须是字符串命令，且命令里出现的路径不得含 .. ----
        $lifecycle = Get-LctSdkProp $Obj 'lifecycle'
        if ($null -ne $lifecycle) {
            $pairs = New-Object System.Collections.ArrayList
            if ($lifecycle -is [System.Collections.IDictionary]) {
                foreach ($k in @($lifecycle.Keys)) { $null = $pairs.Add([pscustomobject]@{ action = [string]$k; value = $lifecycle[$k] }) }
            } elseif ($lifecycle -is [System.Management.Automation.PSCustomObject]) {
                foreach ($p in @($lifecycle.PSObject.Properties)) { $null = $pairs.Add([pscustomobject]@{ action = [string]$p.Name; value = $p.Value }) }
            } else {
                $null = $errors.Add('lifecycle 必须是对象（动作名 -> 命令字符串）')
            }
            foreach ($pair in @($pairs)) {
                try {
                    $actionName = ([string]$pair.action).Trim()
                    if ($null -eq $pair.value) {
                        $null = $errors.Add("lifecycle.$actionName 的命令为空")
                        continue
                    }
                    if (-not ($pair.value -is [string])) {
                        $null = $errors.Add("lifecycle.$actionName 必须是字符串命令，收到 $($pair.value.GetType().Name)")
                        continue
                    }
                    $tokens = @(([string]$pair.value) -split '\s+' | Where-Object { $_ -ne '' })
                    foreach ($t in @($tokens)) {
                        $bare = $t.Trim([char[]]@('"', "'"))
                        if ($bare.Contains('..')) {
                            $null = $errors.Add("lifecycle.$actionName 的命令里出现含 .. 的路径: $bare（禁止越出插件目录）")
                            break
                        }
                    }
                } catch {
                    $null = $errors.Add("校验 lifecycle.$($pair.action) 时出错: $($_.Exception.Message)")
                }
            }
        }

        # ---- 7. integrity：整段委托给 Test-LctPluginIntegrity，错误原样并入 ----
        $integrity = Get-LctSdkProp $Obj 'integrity'
        if ($null -ne $integrity) {
            if (-not (($integrity -is [System.Collections.IDictionary]) -or ($integrity -is [System.Management.Automation.PSCustomObject]))) {
                $null = $errors.Add('integrity 必须是对象（含可选的 sha256 映射）')
            } else {
                $intResult = @{ ok = $false; errors = @(); checked = @() }
                try {
                    $intResult = Test-LctPluginIntegrity -Dir $Dir -Integrity $integrity
                } catch {
                    $intResult = @{ ok = $false; errors = @("完整性校验内部错误: $($_.Exception.Message)"); checked = @() }
                }
                foreach ($e in @($intResult.errors)) { $null = $errors.Add([string]$e) }
            }
        }
    } catch {
        $null = $errors.Add("清单校验内部错误（已转为可读错误）: $($_.Exception.Message)")
        $degraded = $true
    }

    return (New-LctPluginV2Outcome -Errors $errors -Warnings $warnings -ManifestVersion $manifestVersion -EngineApiOk $engineApiOk -Capabilities $capabilities -Kinds $kinds -Degraded $degraded)
}

Export-ModuleMember -Function Get-LctPluginKindRegistry, Get-LctPluginCapabilityTable, Get-LctPluginEngineApiVersion, Test-LctPluginManifestV2, Test-LctPluginIntegrity, Test-LctPluginEngineApi, Get-LctPluginChecksum