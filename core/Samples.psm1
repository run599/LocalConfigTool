# LocalConfigTool - core\Samples.psm1
#
# 样本库（预置规则）：让不会自己找驱动的人，也能拿到"能用的漏洞驱动"。
#
# 边界（这条线要一直守住）：
#   * 仓库里放**规则**（名字 / 对应 CVE / 来源 URL / SHA256 / 适用系统 / 能干什么 / 风险），
#     不放**可执行载荷**——厂商文件的再分发风险不该落在使用者身上。
#   * 载荷由 samples.get **按需获取**，并且**强制哈希校验**：不符直接丢弃，绝不落盘使用。
#   * 只允许写 var\samples\，id 严格校验（防路径穿越）。
#
# 对小白来说体验就是：打开界面 → 第 8 页「样本库」→ 点「获取并校验」→ 拿到文件 → 点「生成 profile」。
#
# 两个能力：
#   samples.list  列出目录（含"是否已获取/哈希是否对得上"）
#   samples.get   获取：预览不落盘；-Apply 才下载，且必须过哈希门

$script:LctSampleIdPattern = '^[a-z0-9][a-z0-9._-]{0,63}$'
$script:LctSampleMaxBytes = 64MB

function Get-LctSampleRoot {
    param()
    $d = Join-Path (Split-Path -Parent $PSScriptRoot) 'samples'
    if (-not (Test-Path -LiteralPath $d)) { $null = New-Item -ItemType Directory -Path $d -Force }
    return $d
}

function Get-LctSampleStoreDir {
    # 载荷只允许落在这里
    param()
    $d = Join-Path (Get-LctVarDir) 'samples'
    if (-not (Test-Path -LiteralPath $d)) { $null = New-Item -ItemType Directory -Path $d -Force }
    return $d
}

function Test-LctSampleId {
    # 严格 id：小写字母数字开头，只允许 . _ -，最长 64；任何路径分隔符/盘符/点点都拒
    param([AllowEmptyString()][string]$Id = '')
    $v = [string]$Id
    if ([string]::IsNullOrWhiteSpace($v)) { return $false }
    if ($v -match '[\\/:]') { return $false }
    if ($v -match '\.\.') { return $false }
    return ($v -match $script:LctSampleIdPattern)
}

function Test-LctSampleSha256 {
    param([AllowEmptyString()][string]$Sha256 = '')
    return ([string]$Sha256 -match '^[0-9a-fA-F]{64}$')
}

function Get-LctSampleCatalogFile {
    param([string]$Name = 'catalog.json')
    return (Join-Path (Get-LctSampleRoot) $Name)
}

function Read-LctSampleCatalogRaw {
    # 仓库目录 + 用户本地目录（var\samples\catalog.local.json）合并；后者可覆盖/新增条目
    param()
    $warnings = New-Object System.Collections.ArrayList
    $entries = New-Object System.Collections.ArrayList
    $seen = @{}
    foreach ($p in @((Get-LctSampleCatalogFile -Name 'catalog.json'), (Join-Path (Get-LctSampleStoreDir) 'catalog.local.json'))) {
        if (-not (Test-Path -LiteralPath $p)) { continue }
        $doc = $null
        try { $doc = (Get-Content -LiteralPath $p -Raw -Encoding UTF8 | ConvertFrom-Json) } catch {
            $null = $warnings.Add('目录文件解析失败（已跳过）：' + $p + ' :: ' + $_.Exception.Message)
            continue
        }
        $list = @()
        if ($null -ne $doc -and $null -ne $doc.PSObject.Properties['entries']) { $list = @($doc.entries) }
        foreach ($e in $list) {
            $id = ''
            if ($null -ne $e.PSObject.Properties['id']) { $id = [string]$e.id }
            if (-not (Test-LctSampleId -Id $id)) { $null = $warnings.Add('跳过非法条目 id：' + $id); continue }
            if ($seen.ContainsKey($id)) { continue }
            $seen[$id] = $true
            $null = $entries.Add($e)
        }
    }
    return [pscustomobject]@{ entries = @($entries); warnings = @($warnings) }
}

function Get-LctSampleEntryState {
    # 某一项在本机的状态：是否已获取、哈希是否对得上
    param($Entry)
    $id = [string]$Entry.id
    $path = Join-Path (Get-LctSampleStoreDir) ($id + '.sys')
    $o = [ordered]@{ fetched = $false; path = $path; sizeBytes = 0; actualSha256 = ''; hashMatch = $false; error = '' }
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return [pscustomobject]$o }
    $o.fetched = $true
    try { $o.sizeBytes = [int64](Get-Item -LiteralPath $path).Length } catch { }
    try { $o.actualSha256 = [string](Get-FileHash -LiteralPath $path -Algorithm SHA256 -ErrorAction Stop).Hash } catch { $o.error = $_.Exception.Message }
    $want = ''
    if ($null -ne $Entry.PSObject.Properties['sha256']) { $want = [string]$Entry.sha256 }
    if ($want -ne '' -and $o.actualSha256 -ne '') { $o.hashMatch = ($o.actualSha256 -ieq $want) }
    return [pscustomobject]$o
}

function Get-LctSampleCatalog {
    param()
    $verb = 'samples.list'
    $raw = Read-LctSampleCatalogRaw
    $items = New-Object System.Collections.ArrayList
    foreach ($e in @($raw.entries)) {
        $id = [string]$e.id
        $st = Get-LctSampleEntryState -Entry $e
        $want = ''
        if ($null -ne $e.PSObject.Properties['sha256']) { $want = [string]$e.sha256 }
        $usable = (Test-LctSampleSha256 -Sha256 $want)
        $name = ''
        if ($null -ne $e.PSObject.Properties['name']) { $name = [string]$e.name }
        $url = ''
        if ($null -ne $e.PSObject.Properties['url']) { $url = [string]$e.url }
        $risk = ''
        if ($null -ne $e.PSObject.Properties['risk']) { $risk = [string]$e.risk }
        $capability = @()
        if ($null -ne $e.PSObject.Properties['capability']) { $capability = @($e.capability) }
        $tags = @()
        if ($null -ne $e.PSObject.Properties['tags']) { $tags = @($e.tags) }
        $notes = ''
        if ($null -ne $e.PSObject.Properties['notes']) { $notes = [string]$e.notes }
        $null = $items.Add([pscustomobject][ordered]@{
                id          = $id
                name        = $name
                risk        = $risk
                tags        = $tags
                capability  = $capability
                url         = $url
                sha256      = $want
                usable      = $usable
                blockedBy   = $(if ($usable) { '' } else { '目录里没有可用的 sha256（占位条目）：填入哈希后才允许获取' })
                fetched     = $st.fetched
                hashMatch   = $st.hashMatch
                path        = $st.path
                sizeBytes   = $st.sizeBytes
                notes       = $notes
            })
    }
    return New-LctResult -Verb $verb -Warnings @($raw.warnings) -Data ([pscustomobject][ordered]@{
            root       = (Get-LctSampleRoot)
            storeDir   = (Get-LctSampleStoreDir)
            count      = @($items).Count
            fetched    = @($items | Where-Object { $_.fetched }).Count
            usable     = @($items | Where-Object { $_.usable }).Count
            items      = @($items)
            notes      = @(
                '仓库里只放规则（URL/哈希/风险），不放可执行载荷；载荷由 samples.get 按需获取并强制校验哈希。',
                '获取后文件在 var\samples\<id>.sys，配套 var\samples\<id>.json 记录来源与哈希（审计用）。',
                '哈希不符的文件会被直接丢弃（回收站），绝不落盘使用。'
            )
        })
}

function Remove-LctSampleFileSafe {
    # 只走回收站（项目铁律）
    param([string]$Path = '')
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    if (-not (Test-Path -LiteralPath $Path)) { return $true }
    try { Add-Type -AssemblyName Microsoft.VisualBasic -ErrorAction Stop } catch { }
    try {
        [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile($Path, 'OnlyErrorDialogs', 'SendToRecycleBin')
        return (-not (Test-Path -LiteralPath $Path))
    } catch { return $false }
}

function Invoke-LctSampleGet {
    <#
    .SYNOPSIS
        获取一个样本（或按 ad-hoc 参数获取）：预览默认不落盘，-Apply 才下载，且必须过 SHA256 门。
    .PARAMETER Id
        目录里的条目 id（严格校验，防路径穿越）。
    .PARAMETER Url
        ad-hoc 来源：http(s):// / file:// / 本地绝对路径。
    .PARAMETER Sha256
        ad-hoc 模式必填：期望哈希（64 位十六进制）。
    .PARAMETER Apply
        真正下载并校验。不加 = 只预览（不产生任何文件）。
    #>
    param(
        [AllowEmptyString()][string]$Id = '',
        [AllowEmptyString()][string]$Url = '',
        [AllowEmptyString()][string]$Sha256 = '',
        [AllowEmptyString()][string]$Name = '',
        [switch]$Apply
    )
    $verb = 'samples.get'
    $warnings = New-Object System.Collections.ArrayList
    $errors = New-Object System.Collections.ArrayList
    $changes = New-Object System.Collections.ArrayList

    # ---- 1) 解析条目 ----
    $entry = $null
    $sid = ''
    if (-not [string]::IsNullOrWhiteSpace($Id)) {
        if (-not (Test-LctSampleId -Id $Id)) {
            $null = $errors.Add('id 非法（只允许小写字母数字开头，含 . _ -，最长 64，且不得含路径分隔符或 ..）：' + $Id)
            return New-LctResult -Verb $verb -Errors @($errors) -Data ([pscustomobject]@{ id = $Id; applied = $false })
        }
        $cat = Read-LctSampleCatalogRaw
        $entry = @($cat.entries) | Where-Object { [string]$_.id -eq $Id } | Select-Object -First 1
        if ($null -eq $entry) {
            $null = $errors.Add('目录里没有这个 id：' + $Id + '（可先用 samples.list 看有哪些）')
            return New-LctResult -Verb $verb -Errors @($errors) -Data ([pscustomobject]@{ id = $Id; applied = $false })
        }
        $sid = $Id
        if ([string]::IsNullOrWhiteSpace($Url) -and $null -ne $entry.PSObject.Properties['url']) { $Url = [string]$entry.url }
        if ([string]::IsNullOrWhiteSpace($Sha256) -and $null -ne $entry.PSObject.Properties['sha256']) { $Sha256 = [string]$entry.sha256 }
        if ([string]::IsNullOrWhiteSpace($Name) -and $null -ne $entry.PSObject.Properties['name']) { $Name = [string]$entry.name }
    } else {
        # ad-hoc：必须给 url + sha256；id 由哈希前 12 位派生
        if (-not (Test-LctSampleSha256 -Sha256 $Sha256)) {
            $null = $errors.Add('ad-hoc 获取必须给 -Sha256（64 位十六进制）；没有哈希就没法校验，不允许下载')
            return New-LctResult -Verb $verb -Errors @($errors) -Data ([pscustomobject]@{ applied = $false })
        }
        if ([string]::IsNullOrWhiteSpace($Url)) {
            $null = $errors.Add('ad-hoc 获取必须给 -Url（http(s):// / file:// / 本地绝对路径）')
            return New-LctResult -Verb $verb -Errors @($errors) -Data ([pscustomobject]@{ applied = $false })
        }
        $sid = 'adhoc-' + ([string]$Sha256).Substring(0, 12).ToLowerInvariant()
        if (-not (Test-LctSampleId -Id $sid)) { $sid = 'adhoc-' + [guid]::NewGuid().ToString('N').Substring(0, 12) }
    }

    if (-not (Test-LctSampleSha256 -Sha256 $Sha256)) {
        $msg = '目录条目缺少可用的 sha256：没有哈希就无法校验，拒绝获取（请在 samples\catalog.json 里补上 64 位哈希）'
        if ($null -ne $entry -and $null -ne $entry.PSObject.Properties['notes'] -and [string]$entry.notes -ne '') { $msg += '；条目备注：' + [string]$entry.notes }
        $null = $errors.Add($msg)
        return New-LctResult -Verb $verb -Errors @($errors) -Data ([pscustomobject]@{ id = $sid; applied = $false; needHash = $true })
    }

    $sha256ForProfile = ([string]$Sha256).ToLowerInvariant()
    $storeDir = Get-LctSampleStoreDir
    $destPath = Join-Path $storeDir ($sid + '.sys')
    $provPath = Join-Path $storeDir ($sid + '.json')
    $tmpDir = Join-Path $storeDir '.tmp'
    if (-not (Test-Path -LiteralPath $tmpDir)) { $null = New-Item -ItemType Directory -Path $tmpDir -Force }
    $tmpPath = Join-Path $tmpDir ($sid + '.part')
    $plan = @(
        ('下载 ' + $Url + ' -> ' + $tmpPath),
        ('校验 SHA256 == ' + $Sha256 + '（不符则丢弃）'),
        ('通过后放到 ' + $destPath),
        ('写来源记录 ' + $provPath)
    )

    # ---- 2) 预览 ----
    if (-not $Apply) {
        $st = Get-LctSampleEntryState -Entry ([pscustomobject]@{ id = $sid; sha256 = $Sha256 })
        $null = $changes.Add((New-LctSampleChangeNote -Target $sid -Before $(if ($st.fetched) { '已存在（size=' + $st.sizeBytes + '，hashMatch=' + $st.hashMatch + '）' } else { '(未获取)' }) -After ('下载并校验后写入 ' + $destPath)))
        return New-LctResult -Verb $verb -Warnings @($warnings) -Changes @($changes) -Data ([pscustomobject][ordered]@{
                id = $sid; name = $Name; url = $Url; sha256 = $Sha256; applied = $false
                plan = @($plan); targetPath = $destPath; provenancePath = $provPath
                alreadyFetched = $st.fetched; existingHashMatch = $st.hashMatch
                note = '预览：没有下载任何东西、没有写任何文件'
            })
    }

    # ---- 3) 执行：下载 -> 校验 -> 落盘 -> 记录 ----
    $downloaded = $false
    try {
        if ($Url -match '^https?://') {
            try {
                Invoke-WebRequest -Uri $Url -OutFile $tmpPath -UseBasicParsing -TimeoutSec 180 -ErrorAction Stop
                $downloaded = $true
            } catch {
                $null = $errors.Add('下载失败：' + $_.Exception.Message)
            }
        } elseif ($Url -match '^file://') {
            $lp = ''
            try { $lp = ([uri]$Url).LocalPath } catch { $lp = '' }
            if ($lp -eq '' -or -not (Test-Path -LiteralPath $lp -PathType Leaf)) { $null = $errors.Add('file:// 指向的本地文件不存在：' + $Url) }
            else { Copy-Item -LiteralPath $lp -Destination $tmpPath -Force -ErrorAction Stop; $downloaded = $true }
        } else {
            if (-not (Test-Path -LiteralPath $Url -PathType Leaf)) { $null = $errors.Add('本地来源不存在：' + $Url) }
            else { Copy-Item -LiteralPath $Url -Destination $tmpPath -Force -ErrorAction Stop; $downloaded = $true }
        }
    } catch { $null = $errors.Add('获取异常：' + $_.Exception.Message) }

    if (-not $downloaded) {
        $null = Remove-LctSampleFileSafe -Path $tmpPath
        return New-LctResult -Verb $verb -Errors @($errors) -Warnings @($warnings) -Data ([pscustomobject][ordered]@{ id = $sid; applied = $false; targetPath = $destPath })
    }

    $actual = ''
    try { $actual = [string](Get-FileHash -LiteralPath $tmpPath -Algorithm SHA256 -ErrorAction Stop).Hash } catch { $null = $errors.Add('计算哈希失败：' + $_.Exception.Message) }
    $size = 0
    try { $size = [int64](Get-Item -LiteralPath $tmpPath).Length } catch { }

    if ($size -le 0 -or $size -gt $script:LctSampleMaxBytes) {
        $null = Remove-LctSampleFileSafe -Path $tmpPath
        $null = $errors.Add('下载内容大小异常（' + $size + ' 字节），已丢弃')
        return New-LctResult -Verb $verb -Errors @($errors) -Warnings @($warnings) -Data ([pscustomobject][ordered]@{ id = $sid; applied = $false; bytes = $size })
    }
    if ($actual -eq '' -or ($actual -ine $Sha256)) {
        $null = Remove-LctSampleFileSafe -Path $tmpPath
        $null = $errors.Add('SHA256 不符，已丢弃（期望 ' + $Sha256 + '，实际 ' + $actual + '）。这不是你的操作问题：来源可能换了文件，或目录里的哈希是错的。')
        try { Write-LctLog -Verb $verb -Level 'warn' -Message ('样本哈希不符已丢弃 ' + $sid) -Data @{ expected = $Sha256; actual = $actual; url = $Url } | Out-Null } catch { }
        return New-LctResult -Verb $verb -Errors @($errors) -Warnings @($warnings) -Data ([pscustomobject][ordered]@{ id = $sid; applied = $false; expectedSha256 = $Sha256; actualSha256 = $actual })
    }

    # 通过校验：替换目标文件（旧文件先走回收站）
    $hadOld = Test-Path -LiteralPath $destPath -PathType Leaf
    if ($hadOld) { $null = Remove-LctSampleFileSafe -Path $destPath }
    try {
        Move-Item -LiteralPath $tmpPath -Destination $destPath -Force -ErrorAction Stop
    } catch {
        $null = Remove-LctSampleFileSafe -Path $tmpPath
        $null = $errors.Add('写入目标失败：' + $_.Exception.Message)
        return New-LctResult -Verb $verb -Errors @($errors) -Warnings @($warnings) -Data ([pscustomobject][ordered]@{ id = $sid; applied = $false })
    }

    $prov = [ordered]@{
        id = $sid; name = $Name; sha256 = $Sha256.ToLowerInvariant(); source = $Url
        sizeBytes = $size; fetchedAt = (Get-Date).ToString('s'); file = $destPath
        note = '本文件只是来源记录（审计用）；载荷本体是同目录的 <id>.sys。'
    }
    try { [IO.File]::WriteAllText($provPath, ($prov | ConvertTo-Json -Depth 6), (New-Object System.Text.UTF8Encoding($false))) } catch { $null = $warnings.Add('来源记录写入失败：' + $_.Exception.Message) }

    # 若目录条目自带**已验证 profile**（纯数据），自动落盘：拿到样本就有可用的 action，不用自己写结构体
    $profileInfo = $null
    try {
        $profRaw = $null
        if ($null -ne $entry -and $null -ne $entry.PSObject.Properties['profile']) { $profRaw = $entry.profile }
        if ($null -ne $profRaw) {
            $profJson = ($profRaw | ConvertTo-Json -Depth 12)
            # 指纹以实际文件为准（目录里的哈希只是声明）
            $profJson = [regex]::Replace($profJson, '"sha256"\s*:\s*"[0-9a-fA-F]*"', ('"sha256": "' + $sha256ForProfile + '"'), 1)
            $profDir = Join-Path (Get-LctVarDir) 'driver-profiles'
            $profPath = Join-Path $profDir ($sid + '.json')
            if (Test-Path -LiteralPath $profPath) {
                $profileInfo = [pscustomobject][ordered]@{ saved = $false; skipped = $true; id = $sid; path = $profPath; note = '该 profile 已存在：保留现有（不覆盖人工审定过的版本）' }
            } else {
                # Save 内部会先过 schema 校验再落盘；不必先单独 validate（那个函数只接受 -Id/-Path 去磁盘找 profile）
                $saveRes = Save-LctDriverProfile -Id $sid -Json $profJson -Apply
                $profileInfo = [pscustomobject][ordered]@{
                    saved = ($null -ne $saveRes -and $saveRes.ok); skipped = $false; id = $sid; path = $profPath
                    errors = @($saveRes.errors)
                    note = $(if ($null -ne $saveRes -and $saveRes.ok) { '已落盘，可直接 driver.ctl.send -Profile ' + $sid } else { '落盘失败（schema 不合法或写入错误）' })
                }
            }
        }
    } catch { $null = $warnings.Add('自动落盘 profile 失败（不影响已获取的文件）：' + $_.Exception.Message) }

    # 自动起草 profile（只读分析，产物不落盘、不可执行）
    $draftSummary = $null
    try {
        $draftRes = New-LctDriverProfileDraft -Path $destPath
        if ($null -ne $draftRes -and $draftRes.ok) {
            $dd = $draftRes.data
            $draftSummary = [pscustomobject][ordered]@{
                confidence = $dd.confidence; needsReview = $dd.needsReview
                ioctlCandidateCount = $dd.ioctlCandidateCount; devNameXrefCount = $dd.devNameXrefCount
                draftId = $(if ($null -ne $dd.draft) { [string]$dd.draft.id } else { '' })
                note = '草案只读产物，actions 为空、不可直接执行；要发送 IOCTL 必须人工审定后 driver.profile.save'
            }
        }
    } catch { $null = $warnings.Add('自动起草失败（不影响已获取的文件）：' + $_.Exception.Message) }

    $null = $changes.Add((New-LctSampleChangeNote -Target $sid -Before $(if ($hadOld) { '已存在同名文件（已换成校验通过的新文件）' } else { '(未获取)' }) -After ('已写入 ' + $destPath + '（size=' + $size + '，SHA256 校验通过）')))
    try { Write-LctLog -Verb $verb -Level 'change' -Message ('样本获取成功 ' + $sid) -Data @{ sha256 = $Sha256; size = $size; source = $Url; file = $destPath } | Out-Null } catch { }

    return New-LctResult -Verb $verb -Applied -Changes @($changes) -Warnings @($warnings) -Errors @($errors) -Data ([pscustomobject][ordered]@{
            id = $sid; name = $Name; url = $Url; sha256 = $Sha256; actualSha256 = $actual
            sizeBytes = $size; applied = $true; targetPath = $destPath; provenancePath = $provPath
            hashVerified = $true; draft = $draftSummary; profile = $profileInfo
            nextStep = ('把 ' + $destPath + ' 交给 driver.load（需要管理员）；或用 driver.profile.draft / driver.profile.save 继续适配')
        })
}

function New-LctSampleChangeNote {
    param([string]$Target = '', [string]$Before = '', [string]$After = '')
    return [pscustomobject][ordered]@{ kind = 'note'; target = $Target; name = 'sample'; before = $Before; after = $After; note = 'samples.get' }
}

Export-ModuleMember -Function Get-LctSampleCatalog, Invoke-LctSampleGet, Test-LctSampleId, Test-LctSampleSha256, Get-LctSampleStoreDir