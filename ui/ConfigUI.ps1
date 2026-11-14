# =============================================================================
# LocalConfigTool - 前端 WinForms 配置界面
# 作者：task-3 (ui-winforms)
# 职责（严格限定）：只做「渲染 / 收集输入 / 展示结果」。
#   所有数据一律通过引擎 CLI 取：
#     powershell -NoProfile -ExecutionPolicy Bypass -File core\Engine.ps1 `
#        -Verb <verb> -Args <json|@文件路径> [-Apply] -Out json
#   本脚本不实现任何后端逻辑：不写注册表、不改账户、不跑插件命令、不删文件。
#
# 用法：
#   powershell -NoProfile -ExecutionPolicy Bypass -File ui\ConfigUI.ps1
#   powershell -NoProfile -ExecutionPolicy Bypass -File ui\ConfigUI.ps1 -SelfCheck   # 验收用
# 测试用环境变量：LCT_ENGINE_PATH 可覆盖引擎脚本路径（正常双击不需要）。
# 安全约定：写类操作一律「先预览（无 -Apply）→ 用户再点应用 → MessageBox 二次确认 → 带 -Apply」。
#
# 【验收 / 自动化注意（2026-10-26 实测，别丢）】
#   · **未 show 的 WinForms 窗体上 Control.CanSelect=False ⇒ 按钮 PerformClick() 不会触发任何事件。**
#     要按「真实点击路径」驱动界面，必须先把窗体 show 出来；本项目证据脚本的做法是把窗体 show 在
#     屏幕外：$form.StartPosition='Manual'; $form.Location=New-Object Drawing.Point(-4000,-4000);
#     $form.ShowInTaskbar=$false; $form.Show()。页面级控件点之前还要先 Switch-LctPage -Key <页>
#     （非当前页的控件 Visible=False，同样点不动）。新页面的按钮句柄已存成 $script:*Btn 变量。
#   · **编辑本文件后必须立刻跑 tests\Fix-Encoding.ps1**：本机编辑工具每次重写文件都会丢 UTF-8 BOM；
#     BOM 一丢，PS 5.1 按 GBK 解析中文 ⇒ 吞引号 ⇒ 整份文件解析失败（看起来像语法错，其实是编码错）。
#   · 进程终止的身份复核口径：只传 id + path，**不传 name**（同名多进程会让引擎判定目标不唯一而拒绝）；
#     path 取不到时降级为仅 PID，并在预览结果里如实标注。
# =============================================================================

param(
    [switch]$SelfCheck,
    [string]$EnginePath = ''
)

$ErrorActionPreference = 'Continue'

# 必须先加载 .NET 程序集：下面的配色表就要用 [System.Drawing.Color]
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

# ---------------------------------------------------------------------------
# 全局状态（事件处理器只引用 $script: 变量，避免 PS 闭包取不到局部变量）
# ---------------------------------------------------------------------------
$script:UiVersion    = '1.0.0'
$script:ToolRoot     = ''
$script:EngineScript = ''
$script:EngineMode = 'ArgsFile'   # 参数一律走临时文件 + 引擎 -ArgsFile
$script:EngineOk     = $false
$script:PsExe        = ''
$script:TempFiles    = New-Object System.Collections.ArrayList
$script:Pending      = @{}             # pageKey -> ArrayList of @{Id;Verb;Args;Summary}
$script:PendingLabels= @{}
$script:Pages        = @{}
$script:NavButtons   = @{}
$script:LastResult   = $null
$script:LastVerbsResult = $null
$script:LogPath      = ''
$script:VerbTable    = @()
$script:PluginParamCtrls = New-Object System.Collections.ArrayList
$script:RecycleOk    = $false

# 深色主题配色
$script:C = @{
    Bg     = [System.Drawing.Color]::FromArgb(24, 26, 30)
    Panel  = [System.Drawing.Color]::FromArgb(33, 36, 42)
    Panel2 = [System.Drawing.Color]::FromArgb(44, 48, 55)
    Text   = [System.Drawing.Color]::FromArgb(232, 235, 240)
    Dim    = [System.Drawing.Color]::FromArgb(150, 158, 168)
    Accent = [System.Drawing.Color]::FromArgb(86, 182, 255)
    Warn   = [System.Drawing.Color]::FromArgb(255, 196, 84)
    Ok     = [System.Drawing.Color]::FromArgb(122, 214, 140)
    Err    = [System.Drawing.Color]::FromArgb(255, 122, 122)
    Border = [System.Drawing.Color]::FromArgb(70, 76, 86)
    Black  = [System.Drawing.Color]::FromArgb(12, 13, 15)
}
$script:PREVIEW_BANNER = '仅预览，未落盘'

# 写类 verb（仅用于界面标注「仅预览」；优先用 engine.verbs 返回的 mutating 字段）
$script:FallbackMutating = @(
    'registry.set', 'registry.delete', 'account.admin', 'account.uac', 'account.autologon',
    'presets.apply', 'plugins.run', 'backup.restore',
    'driver.load', 'driver.start', 'driver.stop', 'driver.unload', 'driver.testsigning',
    'driver.ctl.send', 'driver.profile.save'
)

# ===========================================================================
# 一、基础界面小工具
# ===========================================================================

function Test-LctTlp { param($Control) return ($Control -is [System.Windows.Forms.TableLayoutPanel]) }

function Add-LctChild {
    # 统一挂载：父容器是 TableLayoutPanel 且给了 (Col,Row) 时用单元格重载，否则普通添加
    param($Parent, $Child, [int]$Col = -1, [int]$Row = -1)
    if ($null -eq $Parent) { return }
    if ($Col -ge 0 -and $Row -ge 0 -and (Test-LctTlp $Parent)) { $null = $Parent.Controls.Add($Child, $Col, $Row) }
    else { $null = $Parent.Controls.Add($Child) }
}

function New-LctFont {
    param([float]$Size = 9, [switch]$Bold, [string]$Name = 'Microsoft YaHei UI')
    if ($Bold) { return (New-Object System.Drawing.Font($Name, $Size, [System.Drawing.FontStyle]::Bold)) }
    return (New-Object System.Drawing.Font($Name, $Size, [System.Drawing.FontStyle]::Regular))
}

function New-LctLabel {
    param(
        [string]$Text = '', [int]$X = 0, [int]$Y = 0, [int]$W = 200, [int]$H = 20,
        $Parent = $null, [switch]$Bold, [float]$Size = 9, $Color = $null, [switch]$Dim,
        [int]$Col = -1, [int]$Row = -1
    )
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $Text
    $l.AutoSize = $false
    $l.Location = New-Object System.Drawing.Point($X, $Y)
    $l.Size = New-Object System.Drawing.Size($W, $H)
    $l.BackColor = [System.Drawing.Color]::Transparent
    $l.ForeColor = $script:C.Text
    if ($Dim) { $l.ForeColor = $script:C.Dim }
    if ($null -ne $Color) { $l.ForeColor = $Color }
    $l.Font = New-LctFont -Size $Size -Bold:$Bold
    Add-LctChild -Parent $Parent -Child $l -Col $Col -Row $Row
    return $l
}

function New-LctText {
    param(
        [string]$Text = '', [int]$X = 0, [int]$Y = 0, [int]$W = 200, [int]$H = 24,
        $Parent = $null, [switch]$Multiline, [switch]$ReadOnly, [switch]$Mono,
        [switch]$Password, [switch]$Dark, [int]$Col = -1, [int]$Row = -1
    )
    $t = New-Object System.Windows.Forms.TextBox
    $t.Text = $Text
    $t.Location = New-Object System.Drawing.Point($X, $Y)
    $t.Size = New-Object System.Drawing.Size($W, $H)
    $t.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
    if ($Dark) { $t.BackColor = $script:C.Black } else { $t.BackColor = $script:C.Panel2 }
    $t.ForeColor = $script:C.Text
    if ($Mono) { $t.Font = New-LctFont -Size 9 -Name 'Consolas' } else { $t.Font = New-LctFont -Size 9 }
    if ($Multiline) {
        $t.Multiline = $true
        $t.ScrollBars = [System.Windows.Forms.ScrollBars]::Vertical
        $t.WordWrap = $true
        $t.AcceptsReturn = $true
    }
    if ($ReadOnly) { $t.ReadOnly = $true }
    if ($Password) { $t.UseSystemPasswordChar = $true }
    Add-LctChild -Parent $Parent -Child $t -Col $Col -Row $Row
    return $t
}

function New-LctButton {
    param(
        [string]$Text = '', [int]$X = 0, [int]$Y = 0, [int]$W = 110, [int]$H = 30,
        $Parent = $null, [switch]$Accent, [switch]$Warn, [switch]$Font9,
        [int]$Col = -1, [int]$Row = -1
    )
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $Text
    $b.Location = New-Object System.Drawing.Point($X, $Y)
    $b.Size = New-Object System.Drawing.Size($W, $H)
    $b.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $b.UseVisualStyleBackColor = $false
    $b.BackColor = $script:C.Panel2
    $b.ForeColor = $script:C.Text
    $b.FlatAppearance.BorderColor = $script:C.Border
    $b.FlatAppearance.BorderSize = 1
    $b.FlatAppearance.MouseOverBackColor = $script:C.Border
    if ($Accent) { $b.BackColor = $script:C.Accent; $b.ForeColor = $script:C.Black }
    if ($Warn) { $b.BackColor = $script:C.Warn; $b.ForeColor = $script:C.Black }
    $b.Font = New-LctFont -Size 9
    Add-LctChild -Parent $Parent -Child $b -Col $Col -Row $Row
    return $b
}

function New-LctTable {
    param(
        $Parent = $null, [string[]]$ColSpec = @('100p'), [string[]]$RowSpec = @('100p'),
        [int]$Col = -1, [int]$Row = -1, [string]$Margin = '0'
    )
    $t = New-Object System.Windows.Forms.TableLayoutPanel
    $t.BackColor = [System.Drawing.Color]::Transparent
    $t.ColumnCount = $ColSpec.Count
    $t.RowCount = $RowSpec.Count
    foreach ($c in $ColSpec) {
        if ($c -match '^(\d+)p$') {
            $null = $t.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, [int]$Matches[1])))
        } else {
            $v = 0
            if ($c -match '^(\d+)a$') { $v = [int]$Matches[1] }
            $null = $t.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Absolute, $v)))
        }
    }
    foreach ($r in $RowSpec) {
        if ($r -match '^(\d+)p$') {
            $null = $t.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, [int]$Matches[1])))
        } else {
            $v = 0
            if ($r -match '^(\d+)a$') { $v = [int]$Matches[1] }
            $null = $t.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, $v)))
        }
    }
    $t.Dock = [System.Windows.Forms.DockStyle]::Fill
    if ($Margin -ne '0') {
        $mp = $Margin -split ','
        if ($mp.Count -eq 1) { $t.Margin = New-Object System.Windows.Forms.Padding([int]$mp[0]) }
        elseif ($mp.Count -eq 4) { $t.Margin = New-Object System.Windows.Forms.Padding([int]$mp[0], [int]$mp[1], [int]$mp[2], [int]$mp[3]) }
    }
    Add-LctChild -Parent $Parent -Child $t -Col $Col -Row $Row
    return $t
}

function New-LctCard {
    # 深色卡片（GroupBox），标题用强调色
    param([string]$Title, $Parent = $null, [int]$Col = -1, [int]$Row = -1, [int]$MarginPx = 6)
    $g = New-Object System.Windows.Forms.GroupBox
    $g.Text = '  ' + $Title + '  '
    $g.ForeColor = $script:C.Accent
    $g.BackColor = $script:C.Panel
    $g.Font = New-LctFont -Size 9 -Bold
    $g.Dock = [System.Windows.Forms.DockStyle]::Fill
    $g.Margin = New-Object System.Windows.Forms.Padding($MarginPx)
    Add-LctChild -Parent $Parent -Child $g -Col $Col -Row $Row
    return $g
}

function New-LctFormRow {
    # 卡片内「标签 + 输入框」一行；返回输入框（Dock=Fill）
    param($Parent, [int]$Row, [string]$Label, [int]$LabelW = 70, [int]$H = 28, [switch]$Password, [switch]$Mono)
    $t = New-LctTable -Parent $Parent -ColSpec @("$($LabelW)a", '100p') -RowSpec @("$($H)a") -Col 0 -Row $Row
    $null = New-LctLabel -Text $Label -X 2 -Y 4 -W ($LabelW - 6) -H ($H - 6) -Parent $t
    $tx = New-LctText -X 0 -Y 0 -W 100 -H ($H - 6) -Parent $t -Password:$Password -Mono:$Mono
    $tx.Dock = [System.Windows.Forms.DockStyle]::Fill
    $tx.Margin = New-Object System.Windows.Forms.Padding(0, 3, 2, 3)
    return $tx
}

function New-LctFormCombo {
    param($Parent, [int]$Row, [string]$Label, [string[]]$Items = @(), [int]$LabelW = 70, [int]$H = 28)
    $t = New-LctTable -Parent $Parent -ColSpec @("$($LabelW)a", '100p') -RowSpec @("$($H)a") -Col 0 -Row $Row
    $null = New-LctLabel -Text $Label -X 2 -Y 4 -W ($LabelW - 6) -H ($H - 6) -Parent $t
    $cb = New-Object System.Windows.Forms.ComboBox
    $cb.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
    $cb.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $cb.BackColor = $script:C.Panel2
    $cb.ForeColor = $script:C.Text
    $cb.Font = New-LctFont -Size 9
    foreach ($i in $Items) { $null = $cb.Items.Add($i) }
    if ($cb.Items.Count -gt 0) { $cb.SelectedIndex = 0 }
    $cb.Dock = [System.Windows.Forms.DockStyle]::Fill
    $cb.Margin = New-Object System.Windows.Forms.Padding(0, 3, 2, 3)
    $null = $t.Controls.Add($cb, 1, 0)
    return $cb
}

function New-LctGrid {
    # Cols/Buttons 规格：'name|表头|宽度'（宽度=数字 或 fill）
    param($Parent = $null, [string[]]$Cols = @(), [string[]]$Buttons = @(), [string]$Name = '')
    $g = New-Object System.Windows.Forms.DataGridView
    $g.Name = $Name
    $g.Dock = [System.Windows.Forms.DockStyle]::Fill
    $g.Margin = New-Object System.Windows.Forms.Padding(8)
    $g.BackgroundColor = $script:C.Bg
    $g.GridColor = $script:C.Border
    $g.BorderStyle = [System.Windows.Forms.BorderStyle]::None
    $g.EnableHeadersVisualStyles = $false
    $g.ColumnHeadersDefaultCellStyle.BackColor = $script:C.Panel2
    $g.ColumnHeadersDefaultCellStyle.ForeColor = $script:C.Text
    $g.ColumnHeadersDefaultCellStyle.SelectionBackColor = $script:C.Panel2
    $g.ColumnHeadersBorderStyle = [System.Windows.Forms.DataGridViewHeaderBorderStyle]::Single
    $g.DefaultCellStyle.BackColor = $script:C.Panel
    $g.DefaultCellStyle.ForeColor = $script:C.Text
    $g.DefaultCellStyle.SelectionBackColor = $script:C.Accent
    $g.DefaultCellStyle.SelectionForeColor = $script:C.Black
    $g.AlternatingRowsDefaultCellStyle.BackColor = $script:C.Panel2
    $g.RowHeadersVisible = $false
    $g.AllowUserToAddRows = $false
    $g.AllowUserToDeleteRows = $false
    $g.AllowUserToResizeRows = $false
    $g.ReadOnly = $true
    $g.MultiSelect = $false
    $g.SelectionMode = [System.Windows.Forms.DataGridViewSelectionMode]::FullRowSelect
    $g.AutoSizeColumnsMode = [System.Windows.Forms.DataGridViewAutoSizeColumnsMode]::None
    $g.RowTemplate.Height = 24
    $g.ColumnHeadersHeight = 28
    $g.ColumnHeadersHeightSizeMode = [System.Windows.Forms.DataGridViewColumnHeadersHeightSizeMode]::DisableResizing

    $hc = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $hc.Name = 'rowkey'; $hc.HeaderText = ''; $hc.Width = 1; $hc.Visible = $false
    $null = $g.Columns.Add($hc)

    foreach ($b in $Buttons) {
        $p = $b -split '\|'
        $bc = New-Object System.Windows.Forms.DataGridViewButtonColumn
        $bc.Name = $p[0]; $bc.HeaderText = $p[1]; $bc.Width = [int]$p[2]
        $bc.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
        $bc.DefaultCellStyle.BackColor = $script:C.Panel2
        $bc.DefaultCellStyle.ForeColor = $script:C.Accent
        $bc.DefaultCellStyle.SelectionBackColor = $script:C.Border
        $bc.DefaultCellStyle.SelectionForeColor = $script:C.Text
        $bc.Resizable = [System.Windows.Forms.DataGridViewTriState]::False
        $null = $g.Columns.Add($bc)
    }
    foreach ($c in $Cols) {
        $p = $c -split '\|'
        $tc = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
        $tc.Name = $p[0]; $tc.HeaderText = $p[1]
        if ($p.Count -gt 2 -and $p[2] -eq 'fill') {
            $tc.AutoSizeMode = [System.Windows.Forms.DataGridViewAutoSizeColumnMode]::Fill
        } elseif ($p.Count -gt 2) {
            $tc.Width = [int]$p[2]
        }
        $null = $g.Columns.Add($tc)
    }
    Add-LctChild -Parent $Parent -Child $g
    return $g
}

function Clear-LctGrid {
    param($Grid)
    if ($null -ne $Grid) { $Grid.Rows.Clear() }
}

function Add-LctGridRow {
    param($Grid, [string]$Key, [string[]]$ButtonTexts = @(), $Values = @())
    $cells = New-Object System.Collections.ArrayList
    $null = $cells.Add([string]$Key)
    foreach ($b in $ButtonTexts) { $null = $cells.Add([string]$b) }
    foreach ($v in $Values) { $null = $cells.Add([string]$v) }
    $null = $Grid.Rows.Add($cells.ToArray())
}

# ===========================================================================
# 二、通用只读数据小工具
# ===========================================================================

function Get-LctArray {
    param($Value)
    if ($null -eq $Value) { return @() }
    if ($Value -is [System.Array]) { return @($Value | Where-Object { $null -ne $_ }) }
    if (($Value -is [System.Collections.IEnumerable]) -and -not ($Value -is [string]) -and -not ($Value -is [System.Collections.IDictionary])) {
        $a = @()
        foreach ($x in $Value) { if ($null -ne $x) { $a += $x } }
        return $a
    }
    return @($Value)
}

function Get-LctProp {
    param($Object, [string]$Name, $Default = $null)
    if ($null -eq $Object) { return $Default }
    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) { return $Object[$Name] }
        return $Default
    }
    if ($Object -is [System.Management.Automation.PSCustomObject]) {
        $p = $Object.PSObject.Properties[$Name]
        if ($null -eq $p) { return $Default }
        return $p.Value
    }
    return $Default
}

function Test-LctMutatingVerb {
    param([string]$Verb)
    foreach ($v in @($script:VerbTable)) {
        if ((Get-LctProp $v 'verb' '') -eq $Verb) { return [bool](Get-LctProp $v 'mutating' $false) }
    }
    return ($script:FallbackMutating -contains $Verb)
}

function ConvertTo-LctParamList {
    # 归一化插件 params：支持 [{name,type,required,secret,default,...}] 与 {name={type=...}} 两种形状
    param($Raw)
    $out = New-Object System.Collections.ArrayList
    if ($null -eq $Raw) { return $out }

    $mk = { param($Name) return [pscustomobject]@{ name = [string]$Name; type = 'string'; required = $false; secret = $false; default = $null; description = ''; choices = @() } }
    $fill = {
        param($p, $src)
        $x = Get-LctProp $src 'type' $null;        if ($null -ne $x) { $p.type = [string]$x }
        $x = Get-LctProp $src 'required' $null;    if ($null -ne $x) { $p.required = [bool]$x }
        $x = Get-LctProp $src 'secret' $null;      if ($null -ne $x) { $p.secret = [bool]$x }
        $x = Get-LctProp $src 'default' $null;     if ($null -ne $x) { $p.default = $x }
        $x = Get-LctProp $src 'description' $null; if ($null -ne $x) { $p.description = [string]$x }
        $x = Get-LctProp $src 'choices' $null;     if ($null -ne $x) { $p.choices = @(Get-LctArray $x) }
    }

    $isList = (($Raw -is [System.Array]) -or ($Raw -is [System.Collections.IList]))
    if ($isList) {
        foreach ($item in @($Raw)) {
            if ($null -eq $item) { continue }
            if ($item -is [string]) { $null = $out.Add((& $mk $item)); continue }
            $p = & $mk (Get-LctProp $item 'name' '')
            if (-not $p.name) { continue }
            & $fill $p $item
            $null = $out.Add($p)
        }
        return $out
    }

    $pl = New-Object System.Collections.ArrayList
    if ($Raw -is [System.Collections.IDictionary]) {
        foreach ($k in $Raw.Keys) { $null = $pl.Add([pscustomobject]@{ n = [string]$k; v = $Raw[$k] }) }
    } elseif ($Raw -is [System.Management.Automation.PSCustomObject]) {
        foreach ($pp in $Raw.PSObject.Properties) { $null = $pl.Add([pscustomobject]@{ n = [string]$pp.Name; v = $pp.Value }) }
    } else {
        return $out
    }
    foreach ($e in $pl) {
        $p = & $mk $e.n
        if ($e.v -is [string]) { $p.type = [string]$e.v } else { & $fill $p $e.v }
        $null = $out.Add($p)
    }
    return $out
}

# ===========================================================================
# 三、引擎调用（前端唯一的数据出入口）
# ===========================================================================

function Find-LctEngineScript {
    param([string]$Override = '')
    if ($Override) { return $Override }
    if ($env:LCT_ENGINE_PATH) { return $env:LCT_ENGINE_PATH }
    if (-not $PSScriptRoot) { return '' }
    $root = Split-Path -Parent $PSScriptRoot
    if (-not $root) { return '' }
    return (Join-Path $root 'core\Engine.ps1')
}

function New-LctArgFile {
    param($ArgsObject)
    $json = ConvertTo-Json -InputObject $ArgsObject -Depth 10 -Compress
    $path = [System.IO.Path]::GetTempFileName()
    # 带 BOM 的 UTF-8：PS 5.1 读文件时能可靠识别中文
    [System.IO.File]::WriteAllText($path, $json, (New-Object System.Text.UTF8Encoding($true)))
    $null = $script:TempFiles.Add($path)
    return $path
}

function Initialize-LctRecycle {
    # 只 Import core\Logging.psm1 的 Move-LctToRecycleBin 这一个函数
    if ($script:RecycleOk) { return $true }
    if (-not $script:EngineScript) { return $false }
    $mod = Join-Path (Split-Path -Parent $script:EngineScript) 'Logging.psm1'
    if (-not (Test-Path -LiteralPath $mod)) { return $false }
    try {
        Import-Module -Name $mod -Function Move-LctToRecycleBin -Force -ErrorAction Stop
        $script:RecycleOk = $true
        return $true
    } catch { return $false }
}

function Remove-LctTempFile {
    # 铁律：绝不永久删除，只送回收站
    param([string]$Path)
    if (-not $Path) { return }
    if (-not (Test-Path -LiteralPath $Path)) { return }
    try {
        if (Initialize-LctRecycle) { $null = Move-LctToRecycleBin -Path $Path; return }
    } catch { }
    try {
        Add-Type -AssemblyName Microsoft.VisualBasic -ErrorAction Stop
        [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile($Path, 'OnlyErrorDialogs', 'SendToRecycleBin')
    } catch {
        Add-LctLogLine "  （临时文件无法删除，已原样保留：$Path）" $script:C.Dim
    }
}

function Remove-LctAllTempFiles {
    foreach ($f in @($script:TempFiles)) { Remove-LctTempFile -Path $f }
    $script:TempFiles.Clear()
}

function New-LctCallScript {
    # 生成交给 -EncodedCommand 的 wrapper：命令行里只有 ASCII(base64)。
    # 参数 JSON 一律走临时文件 + 引擎的 -ArgsFile（绝不内联，避免跨进程命令行转义把 JSON 破坏成
    # `Invalid JSON primitive: HKCU.` 这类问题）；stdout 强制 UTF-8。
    param([string]$Verb, [string]$ArgsFile, [switch]$Apply)
    $engineEsc = $script:EngineScript.Replace("'", "''")
    $verbEsc = $Verb.Replace("'", "''")
    $line = "& '$engineEsc' -Verb '$verbEsc'"
    if ($ArgsFile) { $line += " -ArgsFile '$($ArgsFile.Replace("'", "''"))'" }
    if ($Apply) { $line += ' -Apply' }
    $line += ' -Out json'
    $nl = "`r`n"
    $sb = New-Object System.Text.StringBuilder
    $null = $sb.Append('$ErrorActionPreference = ''Continue''' + $nl)
    $null = $sb.Append('[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)' + $nl)
    $null = $sb.Append('try {' + $nl)
    $null = $sb.Append('  ' + $line + $nl)
    $null = $sb.Append('} catch {' + $nl)
    $null = $sb.Append('  [Console]::Error.WriteLine(''UI_WRAPPER_ERROR: '' + $_.Exception.Message)' + $nl)
    $null = $sb.Append('  exit 3' + $nl)
    $null = $sb.Append('}' + $nl)
    $null = $sb.Append('exit 0' + $nl)
    return $sb.ToString()
}

function Invoke-LctProcess {
    param([string]$Encoded, [int]$TimeoutSec = 180)
    $res = [pscustomobject]@{ ExitCode = $null; Stdout = ''; Stderr = ''; TimedOut = $false; StartFailed = '' }
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $script:PsExe
        $psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -EncodedCommand $Encoded"
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
        $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8
        if ($script:ToolRoot -and (Test-Path -LiteralPath $script:ToolRoot)) { $psi.WorkingDirectory = $script:ToolRoot }
        $p = New-Object System.Diagnostics.Process
        $p.StartInfo = $psi
        $null = $p.Start()
        $outTask = $p.StandardOutput.ReadToEndAsync()
        $errTask = $p.StandardError.ReadToEndAsync()
        if (-not $p.WaitForExit($TimeoutSec * 1000)) {
            try { $p.Kill() } catch { }
            $res.TimedOut = $true
            $res.Stderr = "引擎调用超时（$TimeoutSec 秒），已强制结束。"
            return $res
        }
        try { $res.Stdout = $outTask.GetAwaiter().GetResult() } catch { }
        try { $res.Stderr = $errTask.GetAwaiter().GetResult() } catch { }
        $res.ExitCode = $p.ExitCode
        $p.Dispose()
    } catch {
        $res.StartFailed = $_.Exception.Message
    }
    return $res
}

function ConvertFrom-LctConsoleJson {
    param([string]$Text)
    if (-not $Text) { return $null }
    $t = $Text.Trim()
    try { return ($t | ConvertFrom-Json) } catch { }
    $i = $t.IndexOf('{')
    $j = $t.LastIndexOf('}')
    if ($i -ge 0 -and $j -gt $i) {
        try { return ($t.Substring($i, $j - $i + 1) | ConvertFrom-Json) } catch { }
    }
    return $null
}

function New-LctFailResult {
    param([string]$Verb, [string[]]$Errors)
    return [pscustomobject][ordered]@{
        ok = $false; verb = $Verb; applied = $false; changes = @(); warnings = @(); errors = @($Errors)
        backupId = ''; log = ''; data = $null; exitCode = $null; stderr = ''
    }
}

function Invoke-LctEngine {
    <#
      统一封装：拼命令 → 传参（临时文件）→ 解析 JSON → 异常兜底。
      返回统一的 Result 形状（契约 §3）；出错时 errors 里是可读中文，绝不会卡死。
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Verb,
        $Args = $null,
        [switch]$Apply,
        [int]$TimeoutSec = 180
    )

    if (-not $script:EngineScript -or -not (Test-Path -LiteralPath $script:EngineScript)) {
        $r = New-LctFailResult -Verb $Verb -Errors @("未找到引擎脚本：$script:EngineScript（引擎由 Lead 提供；等它就绪后重试）")
        Show-LctResult -Result $r
        return $r
    }

    $argValue = ''
    try {
        if ($null -ne $Args) { $argValue = New-LctArgFile -ArgsObject $Args }
        else { $argValue = New-LctArgFile -ArgsObject ([pscustomobject]@{}) }   # 无参 verb 也给个 {}
    } catch {
        $r = New-LctFailResult -Verb $Verb -Errors @("参数序列化/写临时文件失败：$($_.Exception.Message)")
        Show-LctResult -Result $r
        return $r
    }

    $scriptText = New-LctCallScript -Verb $Verb -ArgsFile $argValue -Apply:$Apply
    $b64 = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($scriptText))
    $run = Invoke-LctProcess -Encoded $b64 -TimeoutSec $TimeoutSec
    $final = ConvertFrom-LctConsoleJson $run.Stdout

    if ($null -ne $final) {
        $r = [pscustomobject][ordered]@{
            ok       = [bool](Get-LctProp $final 'ok' $false)
            verb     = [string](Get-LctProp $final 'verb' $Verb)
            applied  = [bool](Get-LctProp $final 'applied' $false)
            changes  = @(Get-LctArray (Get-LctProp $final 'changes' @()))
            warnings = @(Get-LctArray (Get-LctProp $final 'warnings' @()))
            errors   = @(Get-LctArray (Get-LctProp $final 'errors' @()))
            backupId = [string](Get-LctProp $final 'backupId' '')
            log      = [string](Get-LctProp $final 'log' '')
            data     = Get-LctProp $final 'data' $null
            exitCode = $run.ExitCode
            stderr   = [string]$run.Stderr
        }
        if ($r.log) { $script:LogPath = $r.log }
        $script:EngineOk = $true
        Show-LctResult -Result $r
        return $r
    }

    # 没有可用 JSON —— 给出可读错误，不卡死
    $errs = New-Object System.Collections.ArrayList
    if ($run.TimedOut) {
        $null = $errs.Add($run.Stderr)
    } elseif ($run.StartFailed) {
        $null = $errs.Add("无法启动 powershell.exe：$($run.StartFailed)")
    } else {
        $code = ''
        if ($null -ne $run.ExitCode) { $code = "（退出码 $($run.ExitCode)）" }
        $null = $errs.Add("引擎没有返回 JSON$code —— 可能引擎脚本报错，或输出里混入了其它信息。")
        if ($run.Stderr) { $null = $errs.Add('stderr: ' + $run.Stderr.Trim()) }
        if ($run.Stdout) {
            $tail = @($run.Stdout.Trim() -split "`r?`n" | Select-Object -Last 6)
            $null = $errs.Add('stdout 片段: ' + ($tail -join ' / '))
        }
    }
    $rf = New-LctFailResult -Verb $Verb -Errors @($errs)
    $rf.exitCode = $run.ExitCode
    $rf.stderr = [string]$run.Stderr
    Show-LctResult -Result $rf
    return $rf
}

# ===========================================================================
# 四、结果渲染 / 日志面板
# ===========================================================================

function Add-LctLogLine {
    param([string]$Text, $Color = $null)
    if ($null -eq $script:LogBox) { return }
    $box = $script:LogBox
    if ($null -eq $Color) { $Color = $script:C.Text }
    if ($box.TextLength -gt 200000) { $box.Clear() }
    $box.SelectionStart = $box.TextLength
    $box.SelectionLength = 0
    $box.SelectionColor = $Color
    $box.AppendText($Text + "`r`n")
    $box.SelectionColor = $script:C.Text
}

function Show-LctResult {
    param($Result)
    if ($null -eq $Result) { return }
    $script:LastResult = $Result
    $ts = (Get-Date).ToString('HH:mm:ss')
    $mut = Test-LctMutatingVerb $Result.verb
    $head = "[$ts] 引擎调用：$($Result.verb)"
    if ($Result.applied) { $head += '   ✔ 已落盘 / 已执行' }
    Add-LctLogLine $head $script:C.Accent

    if ($mut -and (-not $Result.applied) -and $Result.ok) {
        Add-LctLogLine "        ⚠⚠ $($script:PREVIEW_BANNER) —— 本次调用没有对系统做任何修改 ⚠⚠" $script:C.Warn
    }
    foreach ($c in @(Get-LctArray $Result.changes)) {
        $line = "        · [$([string](Get-LctProp $c 'kind' ''))] $([string](Get-LctProp $c 'target' ''))"
        $nm = [string](Get-LctProp $c 'name' '')
        if ($nm) { $line += " \ $nm" }
        $bf = [string](Get-LctProp $c 'before' '')
        $af = [string](Get-LctProp $c 'after' '')
        if ($bf -or $af) { $line += " :  $bf  →  $af" }
        $nt = [string](Get-LctProp $c 'note' '')
        if ($nt) { $line += "  （$nt）" }
        Add-LctLogLine $line $script:C.Text
    }
    foreach ($w in @(Get-LctArray $Result.warnings)) { Add-LctLogLine "        ⚠ $w" $script:C.Warn }
    foreach ($e in @(Get-LctArray $Result.errors)) { Add-LctLogLine "        ✖ $e" $script:C.Err }
    if ($Result.backupId) { Add-LctLogLine "        ⛨ 备份 id：$($Result.backupId)" $script:C.Dim }
    if ($Result.ok -and -not $Result.applied -and -not $mut) { Add-LctLogLine '        ✔ 读取成功' $script:C.Ok }
}

# ===========================================================================
# 五、预览 / 待应用 / 二次确认（写操作的统一闸门）
# ===========================================================================

function Add-LctPending {
    # 注意（真实 bug，2026-10-26 实测）：这里**不能**把形参写成 `$Args`。本函数是「简单函数」
    # （只有类型约束、没有 [Parameter()] 特性），形参 `$Args` 会被自动变量 `$args` 顶掉 ——
    # 传进来的参数包会静默变成空数组（实测 Count=0、JSON 为 `[]`），于是「应用」时引擎只收到
    # `{}`，所有页面的 apply 都会失败/空跑。契约 §10.8 的修法：参数包用 [Alias('Args')]。
    param([string]$Page, [string]$Id, [string]$Verb, [Alias('Args')][object]$ArgBag, [string]$Summary, [int]$TimeoutSec = 180)
    if (-not $script:Pending.ContainsKey($Page)) { $script:Pending[$Page] = New-Object System.Collections.ArrayList }
    $list = $script:Pending[$Page]
    for ($i = $list.Count - 1; $i -ge 0; $i--) { if ($list[$i].Id -eq $Id) { $list.RemoveAt($i) } }
    $null = $list.Add([pscustomobject]@{ Id = $Id; Verb = $Verb; Args = $ArgBag; Summary = $Summary; TimeoutSec = $TimeoutSec })
    Update-LctPendingLabels
}

function Get-LctPending {
    param([string]$Page, [string]$Id = '')
    if (-not $script:Pending.ContainsKey($Page)) { return @() }
    $list = $script:Pending[$Page]
    if (-not $Id) { return @($list) }
    return @($list | Where-Object { $_.Id -eq $Id })
}

function Remove-LctPending {
    param([string]$Page, [string]$Id)
    if (-not $script:Pending.ContainsKey($Page)) { return }
    $list = $script:Pending[$Page]
    for ($i = $list.Count - 1; $i -ge 0; $i--) { if ($list[$i].Id -eq $Id) { $list.RemoveAt($i) } }
    Update-LctPendingLabels
}

function Invoke-LctPreview {
    # 预览（不带 -Apply）：ok 才登记为「待应用」
    param(
        [Parameter(Mandatory = $true)][string]$Page,
        [Parameter(Mandatory = $true)][string]$Id,
        [Parameter(Mandatory = $true)][string]$Verb,
        $Args = $null,
        [string]$Summary = '',
        [int]$TimeoutSec = 180
    )
    $r = Invoke-LctEngine -Verb $Verb -Args $Args -TimeoutSec $TimeoutSec
    if ($r.ok) {
        Add-LctPending -Page $Page -Id $Id -Verb $Verb -Args $Args -Summary $Summary -TimeoutSec $TimeoutSec
        Add-LctLogLine "        ✔ 预览通过，已登记为待应用（还差一次「应用」+ 确认）" $script:C.Ok
    } else {
        Add-LctLogLine '        ✖ 预览失败，未登记待应用' $script:C.Err
    }
    return $r
}

function Invoke-LctApplyPending {
    # 应用待执行项：必须先有预览 → MessageBox 二次确认 → 才带 -Apply
    param([Parameter(Mandatory = $true)][string]$Page, [string]$Id = '')
    $ops = @(Get-LctPending -Page $Page -Id $Id)
    if ($ops.Count -eq 0) {
        $null = [System.Windows.Forms.MessageBox]::Show(
            "还没有通过预览的操作。`r`n请先点「预览」，确认界面显示「$($script:PREVIEW_BANNER)」且 before/after 无误，再点应用。",
            '需要先预览', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
        return
    }
    $lines = @()
    foreach ($op in $ops) {
        $j = '(无参数)'
        try { $j = ConvertTo-Json -InputObject $op.Args -Depth 6 -Compress } catch { }
        $lines += ("· " + [string]$op.Summary + "`r`n    引擎调用：" + [string]$op.Verb + " -Apply" + "`r`n    参数：" + $j)
    }
    $msg = "即将在本机【真实执行】以下 $($ops.Count) 项操作：`r`n`r`n" + ($lines -join "`r`n`r`n")
    $msg += "`r`n`r`n引擎在真实写入前会先创建备份，之后可用「备份与回滚」还原。`r`n确定继续吗？"
    $dr = [System.Windows.Forms.MessageBox]::Show($msg, '二次确认：要真实落盘吗？',
        [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Warning,
        [System.Windows.Forms.MessageBoxDefaultButton]::Button2)
    if ($dr -ne [System.Windows.Forms.DialogResult]::Yes) {
        Add-LctLogLine '  ℹ 用户取消了应用（未落盘）' $script:C.Dim
        return
    }
    foreach ($op in $ops) {
        $to = 180
        if ($null -ne $op.TimeoutSec) { $to = [int]$op.TimeoutSec }
        # 防御（同类 bug 的回归护栏）：verb 声明了必填参数、而参数包却是空的 ⇒ 立刻中止，
        # 不让引擎收到空 {} 静默空跑（历史上 Add-LctPending 的 $Args 形参被自动变量顶掉过）。
        $reqNames = @()
        foreach ($v in @($script:VerbTable)) {
            if ((Get-LctProp $v 'verb' '') -eq $op.Verb) {
                foreach ($a in @(Get-LctArray (Get-LctProp $v 'args' @()))) {
                    if ([bool](Get-LctProp $a 'required' $false)) { $reqNames += [string](Get-LctProp $a 'name' '') }
                }
            }
        }
        if (@($reqNames).Count -gt 0 -and $null -ne $op.Args -and @($op.Args).Count -eq 0) {
            Add-LctLogLine "        ✖ 该待应用项的参数包是空的，而 $($op.Verb) 需要必填参数（$((@($reqNames)) -join ', ')）—— 已中止，请重新点一次「预览」。" $script:C.Err
            break
        }
        $r = Invoke-LctEngine -Verb $op.Verb -Args $op.Args -Apply -TimeoutSec $to
        if ($r.ok) {
            Remove-LctPending -Page $Page -Id $op.Id
            Add-LctLogLine "        ✔ 已应用：$($op.Summary)" $script:C.Ok
        } else {
            Add-LctLogLine "        ✖ 应用失败，已保留在待应用列表：$($op.Summary)" $script:C.Err
            break
        }
    }
    Update-LctPendingLabels
}

function New-LctPendingStrip {
    param($Parent, [int]$Col, [int]$Row, [string]$PageKey)
    $t = New-LctTable -Parent $Parent -ColSpec @('100p', '200a') -RowSpec @('34a') -Col $Col -Row $Row -Margin '0'
    $l = New-LctLabel -Text '待应用：无（先在左边点「预览」）' -X 0 -Y 0 -W 100 -H 34 -Parent $t -Color $script:C.Dim
    $l.Dock = [System.Windows.Forms.DockStyle]::Fill
    $b = New-LctButton -Text '应用本页待执行更改' -X 0 -Y 0 -W 100 -H 30 -Parent $t
    $b.Dock = [System.Windows.Forms.DockStyle]::Fill
    $b.Margin = New-Object System.Windows.Forms.Padding(2, 2, 2, 2)
    $b.Tag = $PageKey
    $b.Add_Click({ param($s, $e) Invoke-LctApplyPending -Page ([string]$s.Tag) })
    $script:PendingLabels[$PageKey] = $l
    Update-LctPendingLabels
    return $t
}

function Update-LctPendingLabels {
    foreach ($k in @($script:PendingLabels.Keys)) {
        $l = $script:PendingLabels[$k]
        $n = 0
        if ($script:Pending.ContainsKey($k)) { $n = $script:Pending[$k].Count }
        if ($n -gt 0) {
            $l.Text = "待应用：$n 项（已预览，$($script:PREVIEW_BANNER)）  ←  点右侧按钮才落盘"
            $l.ForeColor = $script:C.Warn
        } else {
            $l.Text = '待应用：无（先在左边点「预览」）'
            $l.ForeColor = $script:C.Dim
        }
    }
    Update-LctStatus
}

function Update-LctStatus {
    if ($null -eq $script:StatusLeft) { return }
    $total = 0
    foreach ($k in @($script:Pending.Keys)) { $total += $script:Pending[$k].Count }
    $eng = '未找到引擎脚本'
    if ($script:EngineScript -and (Test-Path -LiteralPath $script:EngineScript)) {
        if ($script:EngineOk) { $eng = '引擎可达'; } else { $eng = '引擎未验证' }
    }
    $script:StatusLeft.Text = "  当前用户：$env:USERDOMAIN\$env:USERNAME   |   $eng   |   待应用：$total 项   |   写操作一律「先预览、再确认」"
}

# ===========================================================================
# 六、页面骨架与导航
# ===========================================================================

function New-LctPage {
    param([string]$Key, [string]$Title, [string]$Subtitle, $Parent)
    $p = New-Object System.Windows.Forms.Panel
    $p.Dock = [System.Windows.Forms.DockStyle]::Fill
    $p.BackColor = $script:C.Bg
    $p.Visible = $false
    $null = $Parent.Controls.Add($p)

    $root = New-LctTable -Parent $p -ColSpec @('100p') -RowSpec @('68a', '100p')
    $head = New-Object System.Windows.Forms.Panel
    $head.Dock = [System.Windows.Forms.DockStyle]::Fill
    $head.BackColor = $script:C.Bg
    $null = $root.Controls.Add($head, 0, 0)
    $null = New-LctLabel -Text $Title -X 14 -Y 8 -W 700 -H 28 -Parent $head -Bold -Size 13
    $null = New-LctLabel -Text $Subtitle -X 16 -Y 38 -W 1100 -H 20 -Parent $head -Dim -Size 9

    $body = New-Object System.Windows.Forms.Panel
    $body.Dock = [System.Windows.Forms.DockStyle]::Fill
    $body.BackColor = $script:C.Bg
    $null = $root.Controls.Add($body, 0, 1)

    $script:Pages[$Key] = $p
    return $body
}

function Switch-LctPage {
    param([string]$Key)
    foreach ($k in @($script:Pages.Keys)) { $script:Pages[$k].Visible = ($k -eq $Key) }
    foreach ($k in @($script:NavButtons.Keys)) {
        $b = $script:NavButtons[$k]
        if ($k -eq $Key) { $b.BackColor = $script:C.Accent; $b.ForeColor = $script:C.Black }
        else { $b.BackColor = $script:C.Panel; $b.ForeColor = $script:C.Text }
    }
    if ($script:Pages.ContainsKey($Key)) { $script:Pages[$Key].BringToFront() }
    if ($Key -eq 'overview') { Update-LctOverview }
    elseif ($Key -eq 'account') { Update-LctAccount }
    elseif ($Key -eq 'registry') { Update-LctPresets }
    elseif ($Key -eq 'plugins') { Update-LctPlugins }
    elseif ($Key -eq 'processes') { Update-LctProcesses }
    elseif ($Key -eq 'wdac') { Update-LctWdac }
    elseif ($Key -eq 'drivers') { Update-LctDrivers }
    elseif ($Key -eq 'driverprofiles') { Update-LctDriverProfiles }
    elseif ($Key -eq 'backup') { Update-LctBackups }
    Update-LctStatus
}

# ===========================================================================
# 七、页面一：概览
# ===========================================================================

function Update-LctOverviewLog {
    $p = $script:LogPath
    $lines = @()
    if ($p -and (Test-Path -LiteralPath $p)) {
        try { $lines = @(Get-Content -LiteralPath $p -Tail 10 -Encoding UTF8) }
        catch { $lines = @("读取日志失败：$($_.Exception.Message)") }
    } else {
        $lines = @('（暂无日志：还没有引擎调用，或引擎未返回 log 路径）')
    }
    if ($null -ne $script:OvLogBox) { $script:OvLogBox.Text = ($lines -join "`r`n") }
}

function Update-LctOverview {
    if ($null -eq $script:OvInfoBox) { return }
    $script:OvInfoBox.Text = '正在向引擎查询…'

    $rv = Invoke-LctEngine -Verb 'engine.verbs'
    $script:LastVerbsResult = $rv
    $vd = Get-LctProp $rv 'data' $null
    # engine.verbs 的 data 可能是 verb 数组，也可能包成 { verbs=[...]; availability; loadErrors; toolRoot; varDir; elevated }
    $script:VerbTable = @()
    $maybeVerbs = Get-LctProp $vd 'verbs' $null
    if ($null -ne $maybeVerbs) { $script:VerbTable = @(Get-LctArray $maybeVerbs) }
    elseif ($null -ne $vd) { $script:VerbTable = @(Get-LctArray $vd) }
    if (-not $rv.ok) { $script:VerbTable = @() }

    $availability = Get-LctProp $vd 'availability' (Get-LctProp $rv 'availability' $null)
    $loadErrors = @(Get-LctArray (Get-LctProp $vd 'loadErrors' (Get-LctProp $rv 'loadErrors' $null)))
    $engToolRoot = [string](Get-LctProp $vd 'toolRoot' (Get-LctProp $rv 'toolRoot' ''))
    $engVarDir = [string](Get-LctProp $vd 'varDir' (Get-LctProp $rv 'varDir' ''))
    $engElevated = Get-LctProp $vd 'elevated' (Get-LctProp $rv 'elevated' $null)

    Clear-LctGrid $script:OvVerbGrid
    foreach ($v in @($script:VerbTable)) {
        $argNames = @()
        foreach ($a in @(Get-LctArray (Get-LctProp $v 'args' @()))) {
            $an = [string](Get-LctProp $a 'name' '')
            if ($an) {
                if ([bool](Get-LctProp $a 'required' $false)) { $an += '*' }
                $argNames += $an
            }
        }
        $mut = '否'
        if ([bool](Get-LctProp $v 'mutating' $false)) { $mut = '是（默认只预览）' }
        Add-LctGridRow -Grid $script:OvVerbGrid -Key ([string](Get-LctProp $v 'verb' '')) -Values @(
            [string](Get-LctProp $v 'verb' ''), [string](Get-LctProp $v 'summary' ''), $mut, ($argNames -join ', ')
        )
    }

    # 模块装载失败原文（Lead 建议在概览页直接显示）同时打到日志面板
    if ($loadErrors.Count -gt 0) {
        Add-LctLogLine "  ⚠ 引擎模块装载问题（$($loadErrors.Count) 条）：" $script:C.Warn
        foreach ($le in $loadErrors) { Add-LctLogLine "     · $le" $script:C.Warn }
    }

    $ra = Invoke-LctEngine -Verb 'account.status'
    $ad = Get-LctProp $ra 'data' $null
    $user = Get-LctProp $ad 'user' $null
    $elev = '未知'
    if ($null -ne $engElevated) {
        if ([bool]$engElevated) { $elev = '已提权（引擎进程是管理员令牌）' } else { $elev = '未提权（引擎进程为普通权限）' }
    } elseif ($null -ne $user) {
        if ([bool](Get-LctProp $user 'isAdminToken' $false)) { $elev = '已提权（当前会话是管理员令牌）' }
        else { $elev = '未提权（普通权限）' }
    }
    $lines = New-Object System.Collections.ArrayList
    $null = $lines.Add("工具版本     ：前端 v$($script:UiVersion)  /  引擎 core\Engine.ps1")
    $null = $lines.Add("引擎脚本     ：$($script:EngineScript)")
    if ($script:EngineScript -and (Test-Path -LiteralPath $script:EngineScript)) {
        try {
            $fi = Get-Item -LiteralPath $script:EngineScript
            $null = $lines.Add("引擎构建时间 ：$($fi.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss'))")
        } catch { }
    }
    $null = $lines.Add("可用能力     ：$(@($script:VerbTable).Count) 个 verb（右侧清单来自 engine.verbs）")
    if ($null -ne $availability) { $null = $lines.Add("模块可用性   ：$([string]$availability)") }
    $tr = $script:ToolRoot
    if ($engToolRoot) { $tr = $engToolRoot }
    $null = $lines.Add("工具根目录   ：$tr")
    if ($engVarDir) { $null = $lines.Add("var 目录     ：$engVarDir") }
    $null = $lines.Add("当前用户     ：$([string](Get-LctProp $user 'domain' $env:USERDOMAIN))\$([string](Get-LctProp $user 'name' $env:USERNAME))")
    $null = $lines.Add("是否提权     ：$elev")
    if ($null -ne $user) {
        $inG = '否'
        if ([bool](Get-LctProp $user 'inAdminGroup' $false)) { $inG = '是' }
        $null = $lines.Add("在管理员组   ：$inG")
    }
    $leText = '无'
    if ($loadErrors.Count -gt 0) { $leText = "$($loadErrors.Count) 条（见右下日志面板）" }
    $null = $lines.Add("模块装载问题 ：$leText")
    $null = $lines.Add("参数传递     ：临时文件 + 引擎 -ArgsFile（命令行仅有 base64 wrapper，无明文 JSON）")
    $lg = $script:LogPath
    if (-not $lg) { $lg = '(等待引擎返回 log 路径)' }
    $null = $lines.Add("日志文件     ：$lg")
    $null = $lines.Add("数据来源     ：全部经引擎 CLI 获取，前端不读注册表、不改账户")
    $script:OvInfoBox.Text = ($lines -join "`r`n")
    Update-LctOverviewLog
}

function New-LctPageOverview {
    param($Body)
    $t = New-LctTable -Parent $Body -ColSpec @('440a', '100p') -RowSpec @('100p')
    $left = New-LctTable -Parent $t -ColSpec @('100p') -RowSpec @('200a', '100p') -Col 0 -Row 0

    $c1 = New-LctCard -Title '环境信息（engine.verbs / account.status）' -Parent $left -Col 0 -Row 0
    $script:OvInfoBox = New-LctText -X 0 -Y 0 -W 100 -H 100 -Parent $c1 -Multiline -ReadOnly -Dark
    $script:OvInfoBox.Dock = [System.Windows.Forms.DockStyle]::Fill
    $script:OvInfoBox.Margin = New-Object System.Windows.Forms.Padding(10, 22, 10, 10)

    $c2 = New-LctCard -Title '最近日志尾部（var\logs\engine-*.log）' -Parent $left -Col 0 -Row 1
    $script:OvLogBox = New-LctText -X 0 -Y 0 -W 100 -H 100 -Parent $c2 -Multiline -ReadOnly -Mono -Dark
    $script:OvLogBox.Dock = [System.Windows.Forms.DockStyle]::Fill
    $script:OvLogBox.Margin = New-Object System.Windows.Forms.Padding(10, 22, 10, 10)

    $c3 = New-LctCard -Title '引擎能力清单（engine.verbs，带 * 为必填参数）' -Parent $t -Col 1 -Row 0
    $inner = New-LctTable -Parent $c3 -ColSpec @('100p', '170a') -RowSpec @('36a', '100p')
    $inner.Margin = New-Object System.Windows.Forms.Padding(10, 22, 10, 10)
    $bf = New-LctButton -Text '刷新（重新调 engine.verbs）' -X 0 -Y 0 -W 100 -H 30 -Parent $inner -Accent
    $bf.Dock = [System.Windows.Forms.DockStyle]::Fill
    $bf.Margin = New-Object System.Windows.Forms.Padding(0, 2, 8, 2)
    $bf2 = New-LctButton -Text '刷新日志尾部' -X 0 -Y 0 -W 100 -H 30 -Parent $inner
    $bf2.Dock = [System.Windows.Forms.DockStyle]::Fill
    $bf2.Margin = New-Object System.Windows.Forms.Padding(0, 2, 2, 2)
    $bf.Add_Click({ param($s, $e) Update-LctOverview })
    $bf2.Add_Click({ param($s, $e) Update-LctOverviewLog })
    $script:OvVerbGrid = New-LctGrid -Parent $inner -Name 'verbs' -Cols @(
        'verb|verb|170', 'summary|说明|fill', 'mutating|写操作|110', 'args|参数|250'
    )
    $inner.SetColumnSpan($script:OvVerbGrid, 2)
    return $t
}

# ===========================================================================
# 八、页面二：账户与登录
# ===========================================================================

function Update-LctAccount {
    if ($null -eq $script:AccUserBox) { return }
    $r = Invoke-LctEngine -Verb 'account.status'
    $d = Get-LctProp $r 'data' $null
    if (-not $r.ok -or $null -eq $d) {
        $script:AccUserBox.Text = 'account.status 调用失败，详见底部日志。'
        return
    }
    $user = Get-LctProp $d 'user' $null
    $lines = New-Object System.Collections.ArrayList
    $null = $lines.Add("用户名     ：$([string](Get-LctProp $user 'name' ''))")
    $null = $lines.Add("域         ：$([string](Get-LctProp $user 'domain' ''))")
    $tok = '否'
    if ([bool](Get-LctProp $user 'isAdminToken' $false)) { $tok = '是' }
    $null = $lines.Add("管理员令牌 ：$tok")
    $inG = '否'
    if ([bool](Get-LctProp $user 'inAdminGroup' $false)) { $inG = '是' }
    $null = $lines.Add("在管理员组 ：$inG")
    $script:AccUserBox.Text = ($lines -join "`r`n")

    Clear-LctGrid $script:AccUsersGrid
    foreach ($u in @(Get-LctArray (Get-LctProp $d 'users' @()))) {
        $en = '否'; if ([bool](Get-LctProp $u 'enabled' $false)) { $en = '是' }
        $ia = '否'; if ([bool](Get-LctProp $u 'isAdmin' $false)) { $ia = '是' }
        Add-LctGridRow -Grid $script:AccUsersGrid -Key ([string](Get-LctProp $u 'name' '')) -Values @(
            [string](Get-LctProp $u 'name' ''), $en, $ia, [string](Get-LctProp $u 'description' '')
        )
    }

    $grp = Get-LctProp $d 'groups' $null
    $gl = @()
    foreach ($g in @(Get-LctArray (Get-LctProp $grp 'Administrators' @()))) { $gl += "· $g" }
    if ($gl.Count -eq 0) { $gl = @('（engine 未返回管理员组成员）') }
    $script:AccGroupsBox.Text = ("管理员组成员：`r`n" + ($gl -join "`r`n"))

    $uac = Get-LctProp $d 'uac' $null
    $ul = New-Object System.Collections.ArrayList
    $null = $ul.Add("enableLUA                 = $([string](Get-LctProp $uac 'enableLUA' ''))")
    $null = $ul.Add("consentPromptBehaviorAdmin = $([string](Get-LctProp $uac 'consentPromptBehaviorAdmin' ''))")
    $null = $ul.Add("promptOnSecureDesktop     = $([string](Get-LctProp $uac 'promptOnSecureDesktop' ''))")
    $null = $ul.Add("enableInstallerDetection  = $([string](Get-LctProp $uac 'enableInstallerDetection' ''))")
    $null = $ul.Add("path = $([string](Get-LctProp $uac 'path' ''))")
    $script:AccUacBox.Text = ($ul -join "`r`n")

    $al = Get-LctProp $d 'autologon' $null
    $ll = New-Object System.Collections.ArrayList
    $en = '否'; if ([bool](Get-LctProp $al 'enabled' $false)) { $en = '是' }
    $hp = '否'; if ([bool](Get-LctProp $al 'hasPassword' $false)) { $hp = '是' }
    $null = $ll.Add("已启用         ：$en")
    $null = $ll.Add("自动登录用户   ：$([string](Get-LctProp $al 'user' ''))")
    $null = $ll.Add("已存口令       ：$hp（引擎永不返回口令内容）")
    $null = $ll.Add("path = $([string](Get-LctProp $al 'path' ''))")
    $script:AccAutoBox.Text = ($ll -join "`r`n")

    $au = [string](Get-LctProp $al 'user' '')
    if ($au -and -not $script:AutoUserBox.Text) { $script:AutoUserBox.Text = $au }

    $stmt = '内置 Administrator：未在 account.status 的 users 里找到'
    foreach ($u in @(Get-LctArray (Get-LctProp $d 'users' @()))) {
        if ([string](Get-LctProp $u 'name' '') -ieq 'Administrator') {
            $en2 = '已禁用'
            if ([bool](Get-LctProp $u 'enabled' $false)) { $en2 = '已启用' }
            $stmt = "内置 Administrator：$en2   （isAdmin=$([string](Get-LctProp $u 'isAdmin' $false))）"
        }
    }
    $script:AccAdminState.Text = $stmt

    $lua = [string](Get-LctProp $uac 'enableLUA' '')
    $ust = '未知'
    if ($lua -eq '1') { $ust = "enableLUA=1 → UAC 已开启" }
    elseif ($lua -eq '0') { $ust = "enableLUA=0 → UAC 已关闭" }
    elseif ($lua) { $ust = "enableLUA=$lua" }
    $script:AccUacState.Text = "UAC 当前状态：$ust"
}

function New-LctPageAccount {
    param($Body)
    $t = New-LctTable -Parent $Body -ColSpec @('450a', '100p') -RowSpec @('100p')
    $left = New-LctTable -Parent $t -ColSpec @('100p') -RowSpec @('126a', '170a', '100p') -Col 0 -Row 0

    $c1 = New-LctCard -Title '当前用户（account.status → user）' -Parent $left -Col 0 -Row 0
    $script:AccUserBox = New-LctText -X 0 -Y 0 -W 100 -H 100 -Parent $c1 -Multiline -ReadOnly -Dark
    $script:AccUserBox.Dock = [System.Windows.Forms.DockStyle]::Fill
    $script:AccUserBox.Margin = New-Object System.Windows.Forms.Padding(10, 22, 10, 10)

    $c2 = New-LctCard -Title '管理员组成员（account.status → groups.Administrators）' -Parent $left -Col 0 -Row 1
    $script:AccGroupsBox = New-LctText -X 0 -Y 0 -W 100 -H 100 -Parent $c2 -Multiline -ReadOnly -Dark
    $script:AccGroupsBox.Dock = [System.Windows.Forms.DockStyle]::Fill
    $script:AccGroupsBox.Margin = New-Object System.Windows.Forms.Padding(10, 22, 10, 10)

    $c3 = New-LctCard -Title '本机用户列表（account.status → users）' -Parent $left -Col 0 -Row 2
    $inner3 = New-LctTable -Parent $c3 -ColSpec @('100p', '170a') -RowSpec @('34a', '100p')
    $inner3.Margin = New-Object System.Windows.Forms.Padding(10, 22, 10, 8)
    $b3 = New-LctButton -Text '刷新账户状态' -X 0 -Y 0 -W 100 -H 30 -Parent $inner3 -Accent
    $b3.Dock = [System.Windows.Forms.DockStyle]::Fill
    $b3.Margin = New-Object System.Windows.Forms.Padding(0, 2, 8, 2)
    $b3.Add_Click({ param($s, $e) Update-LctAccount })
    $script:AccUsersGrid = New-LctGrid -Parent $inner3 -Name 'users' -Cols @(
        'name|用户|170', 'enabled|已启用|80', 'isAdmin|管理员|80', 'description|说明|fill'
    )
    $inner3.SetColumnSpan($script:AccUsersGrid, 2)

    $right = New-LctTable -Parent $t -ColSpec @('100p') -RowSpec @('146a', '146a', '100p', '44a') -Col 1 -Row 0

    # 操作一：Administrator
    $ca = New-LctCard -Title '操作一：内置 Administrator 启用 / 禁用（account.admin）' -Parent $right -Col 0 -Row 0
    $script:AccAdminState = New-LctLabel -Text '内置 Administrator：—' -X 14 -Y 24 -W 560 -H 22 -Parent $ca -Color $script:C.Accent
    $ba1 = New-LctButton -Text '预览：启用 Administrator' -X 14 -Y 52 -W 180 -H 30 -Parent $ca
    $ba2 = New-LctButton -Text '预览：禁用 Administrator' -X 204 -Y 52 -W 180 -H 30 -Parent $ca
    $null = New-LctLabel -Text '说明：启用内置 Administrator 会提高本机被提权的风险；先看预览的 before/after，确认后再应用。' -X 14 -Y 90 -W 620 -H 44 -Parent $ca -Dim -Size 8
    $ba1.Add_Click({
        param($s, $e)
        $null = Invoke-LctPreview -Page 'account' -Id 'account.admin:on' -Verb 'account.admin' `
            -Args @{ enable = $true } -Summary '启用内置 Administrator'
    })
    $ba2.Add_Click({
        param($s, $e)
        $null = Invoke-LctPreview -Page 'account' -Id 'account.admin:off' -Verb 'account.admin' `
            -Args @{ enable = $false } -Summary '禁用内置 Administrator'
    })
    $script:AccAdminPreviewOn = $ba1
    $script:AccAdminPreviewOff = $ba2

    # 操作二：UAC
    $cu = New-LctCard -Title '操作二：UAC 开关（account.uac）' -Parent $right -Col 0 -Row 1
    $script:AccUacState = New-LctLabel -Text 'UAC 当前状态：—' -X 14 -Y 24 -W 560 -H 22 -Parent $cu -Color $script:C.Accent
    $bu1 = New-LctButton -Text '预览：开启 UAC' -X 14 -Y 52 -W 160 -H 30 -Parent $cu
    $bu2 = New-LctButton -Text '预览：关闭 UAC' -X 184 -Y 52 -W 160 -H 30 -Parent $cu
    $script:AccUacBox = New-LctText -X 360 -Y 50 -W 100 -H 90 -Parent $cu -Multiline -ReadOnly -Dark -Mono
    $script:AccUacBox.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
    $bu1.Add_Click({
        param($s, $e)
        $null = Invoke-LctPreview -Page 'account' -Id 'account.uac:on' -Verb 'account.uac' `
            -Args @{ enable = $true } -Summary '开启 UAC'
    })
    $bu2.Add_Click({
        param($s, $e)
        $null = Invoke-LctPreview -Page 'account' -Id 'account.uac:off' -Verb 'account.uac' `
            -Args @{ enable = $false } -Summary '关闭 UAC'
    })
    $script:AccUacPreviewOn = $bu1
    $script:AccUacPreviewOff = $bu2

    # 操作三：自动登录
    $cl = New-LctCard -Title '操作三：自动登录开关（account.autologon，口令只走文件选择）' -Parent $right -Col 0 -Row 2
    $script:AccAutoBox = New-LctText -X 330 -Y 24 -W 100 -H 150 -Parent $cl -Multiline -ReadOnly -Dark -Mono
    $script:AccAutoBox.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right -bor [System.Windows.Forms.AnchorStyles]::Bottom
    $inner = New-LctTable -Parent $cl -ColSpec @('100p') -RowSpec @('30a', '30a', '36a', '100p')
    $inner.Margin = New-Object System.Windows.Forms.Padding(12, 24, 6, 8)
    $script:AutoUserBox = New-LctFormRow -Parent $inner -Row 0 -Label '登录用户' -LabelW 80 -H 28
    $fr = New-LctTable -Parent $inner -ColSpec @('100p', '80a') -RowSpec @('28a') -Col 0 -Row 1
    $fr.Margin = New-Object System.Windows.Forms.Padding(0)
    $pl = New-LctTable -Parent $fr -ColSpec @('80a', '100p') -RowSpec @('28a') -Col 0 -Row 0
    $pl.Margin = New-Object System.Windows.Forms.Padding(0)
    $null = New-LctLabel -Text '口令文件' -X 2 -Y 4 -W 74 -H 22 -Parent $pl
    $script:AutoPwdFileBox = New-LctText -X 0 -Y 0 -W 100 -H 22 -Parent $pl -ReadOnly
    $script:AutoPwdFileBox.Dock = [System.Windows.Forms.DockStyle]::Fill
    $script:AutoPwdFileBox.Margin = New-Object System.Windows.Forms.Padding(0, 3, 2, 3)
    $bb = New-LctButton -Text '浏览…' -X 0 -Y 0 -W 74 -H 24 -Parent $fr
    $bb.Dock = [System.Windows.Forms.DockStyle]::Fill
    $bb.Margin = New-Object System.Windows.Forms.Padding(2, 3, 2, 3)
    $bb.Add_Click({
        param($s, $e)
        $dlg = New-Object System.Windows.Forms.OpenFileDialog
        $dlg.Title = '选择存放自动登录口令的文件（口令只由引擎从该文件读取，界面不接受明文输入）'
        $dlg.Filter = '所有文件 (*.*)|*.*'
        $dlg.CheckFileExists = $true
        if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { $script:AutoPwdFileBox.Text = $dlg.FileName }
    })
    $br = New-LctTable -Parent $inner -ColSpec @('100p', '120a') -RowSpec @('34a') -Col 0 -Row 2
    $br.Margin = New-Object System.Windows.Forms.Padding(0)
    $b1 = New-LctButton -Text '预览：启用自动登录' -X 0 -Y 0 -W 100 -H 30 -Parent $br
    $b1.Dock = [System.Windows.Forms.DockStyle]::Fill
    $b1.Margin = New-Object System.Windows.Forms.Padding(0, 2, 6, 2)
    $b2 = New-LctButton -Text '预览：关闭' -X 0 -Y 0 -W 100 -H 30 -Parent $br
    $b2.Dock = [System.Windows.Forms.DockStyle]::Fill
    $b2.Margin = New-Object System.Windows.Forms.Padding(0, 2, 2, 2)
    $null = New-LctLabel -Text '安全提示：AutoAdminLogon 会把口令明文存进注册表（风险高）；引擎会同时给出更安全的 Sysinternals Autologon（LSA secret）建议。' -X 12 -Y 116 -W 300 -H 60 -Parent $inner -Dim -Size 8
    $b1.Add_Click({
        param($s, $e)
        $u = $script:AutoUserBox.Text.Trim()
        $f = $script:AutoPwdFileBox.Text.Trim()
        if (-not $u) {
            $null = [System.Windows.Forms.MessageBox]::Show('请先填写「登录用户」。', '参数不足', 'OK', 'Warning')
            return
        }
        if (-not $f) {
            $null = [System.Windows.Forms.MessageBox]::Show('请先用「浏览…」选择口令文件（界面不接受明文口令输入）。', '参数不足', 'OK', 'Warning')
            return
        }
        $null = Invoke-LctPreview -Page 'account' -Id 'account.autologon:on' -Verb 'account.autologon' `
            -Args @{ enable = $true; user = $u; passwordFile = $f } -Summary "启用自动登录（用户 $u，口令文件 $f）"
    })
    $b2.Add_Click({
        param($s, $e)
        $null = Invoke-LctPreview -Page 'account' -Id 'account.autologon:off' -Verb 'account.autologon' `
            -Args @{ enable = $false } -Summary '关闭自动登录'
    })
    $script:AutoPreviewOn = $b1
    $script:AutoPreviewOff = $b2

    $null = New-LctPendingStrip -Parent $right -Col 0 -Row 3 -PageKey 'account'
    return $t
}

# ===========================================================================
# 九、页面三：注册表 + 预设包
# ===========================================================================

function Update-LctPresets {
    if ($null -eq $script:PresetGrid) { return }
    $r = Invoke-LctEngine -Verb 'presets.list'
    Clear-LctGrid $script:PresetGrid
    if (-not $r.ok) { return }
    foreach ($p in @(Get-LctArray $r.data)) {
        $presetId = [string](Get-LctProp $p 'id' '')
        $pname = [string](Get-LctProp $p 'name' '')
        $risk = [string](Get-LctProp $p 'risk' '')
        foreach ($it in @(Get-LctArray (Get-LctProp $p 'items' @()))) {
            $iid = [string](Get-LctProp $it 'id' '')
            Add-LctGridRow -Grid $script:PresetGrid -Key "$presetId||$iid" -ButtonTexts @('预览', '应用') -Values @(
                $pname, $risk, [string](Get-LctProp $it 'title' ''), [string](Get-LctProp $it 'summary' ''),
                [string](Get-LctProp $it 'verb' '')
            )
        }
    }
    if ($script:PresetGrid.Rows.Count -eq 0) {
        Add-LctGridRow -Grid $script:PresetGrid -Key '' -ButtonTexts @('', '') -Values @('（无预设包）', '', '', '', '')
    }
}

function Update-LctPresetDetail {
    $key = ''
    if ($script:PresetGrid.SelectedRows.Count -gt 0) { $key = [string]$script:PresetGrid.SelectedRows[0].Cells['rowkey'].Value }
    if (-not $key) {
        $script:PresetDetailBox.Text = '（在上面的列表里选中一行，再点「查看选中行预设包详情」）'
        return
    }
    $presetId = ($key -split '\|\|')[0]
    $r = Invoke-LctEngine -Verb 'presets.show' -Args @{ preset = $presetId }
    if ($r.ok) {
        try { $script:PresetDetailBox.Text = ConvertTo-Json -InputObject $r.data -Depth 8 }
        catch { $script:PresetDetailBox.Text = [string]$r.data }
    } else {
        $script:PresetDetailBox.Text = 'presets.show 失败，详见底部日志。'
    }
}

function Get-LctPresetPendingId { param([string]$Key) return ('preset:' + ($Key -replace '\|\|', ':')) }

function Invoke-LctPresetRowPreview {
    param([string]$Key)
    if (-not $Key) { return }
    $p = $Key -split '\|\|'
    $null = Invoke-LctPreview -Page 'registry' -Id (Get-LctPresetPendingId $Key) -Verb 'presets.apply' `
        -Args @{ preset = $p[0]; item = $p[1] } -Summary "预设包 $($p[0]) / 项目 $($p[1])"
}

function New-LctPageRegistry {
    param($Body)
    $t = New-LctTable -Parent $Body -ColSpec @('100p') -RowSpec @('242a', '100p')

    # --- 注册表读写 ---
    $c1 = New-LctCard -Title '注册表读取与写入（registry.get / registry.set / registry.delete，写入需选类型）' -Parent $t -Col 0 -Row 0
    $inner = New-LctTable -Parent $c1 -ColSpec @('480a', '100p') -RowSpec @('100p')
    $inner.Margin = New-Object System.Windows.Forms.Padding(12, 24, 8, 10)

    $form = New-LctTable -Parent $inner -ColSpec @('100p') -RowSpec @('30a', '30a', '30a', '30a', '38a', '42a') -Col 0 -Row 0
    $script:RegPathBox = New-LctFormRow -Parent $form -Row 0 -Label '路径' -LabelW 62 -H 28
    $script:RegPathBox.Text = 'HKCU:\Software\LocalConfigToolDemo'
    $script:RegNameBox = New-LctFormRow -Parent $form -Row 1 -Label '值名' -LabelW 62 -H 28
    $script:RegNameBox.Text = 'Demo'
    $script:RegTypeBox = New-LctFormCombo -Parent $form -Row 2 -Label '类型' -LabelW 62 -H 28 -Items @(
        'String', 'ExpandString', 'DWord', 'QWord', 'MultiString', 'Binary'
    )
    $script:RegValueBox = New-LctFormRow -Parent $form -Row 3 -Label '值' -LabelW 62 -H 28
    $br1 = New-LctTable -Parent $form -ColSpec @('100p', '180a', '100p') -RowSpec @('36a') -Col 0 -Row 4
    $br1.Margin = New-Object System.Windows.Forms.Padding(0)
    $bRead = New-LctButton -Text '读取（registry.get）' -X 0 -Y 0 -W 100 -H 30 -Parent $br1
    $bRead.Dock = [System.Windows.Forms.DockStyle]::Fill
    $bRead.Margin = New-Object System.Windows.Forms.Padding(0, 2, 6, 2)
    $bPrev = New-LctButton -Text '预览：按上面内容写入' -X 0 -Y 0 -W 100 -H 30 -Parent $br1
    $bPrev.Dock = [System.Windows.Forms.DockStyle]::Fill
    $bPrev.Margin = New-Object System.Windows.Forms.Padding(0, 2, 6, 2)
    $bDel = New-LctButton -Text '预览：删除该值' -X 0 -Y 0 -W 100 -H 30 -Parent $br1
    $bDel.Dock = [System.Windows.Forms.DockStyle]::Fill
    $bDel.Margin = New-Object System.Windows.Forms.Padding(0, 2, 2, 2)
    $script:RegPreviewBtn = $bPrev
    $script:RegDeletePreviewBtn = $bDel

    $bRead.Add_Click({
        param($s, $e)
        $p = $script:RegPathBox.Text.Trim()
        $n = $script:RegNameBox.Text.Trim()
        if (-not $p) {
            $null = [System.Windows.Forms.MessageBox]::Show('请填写注册表路径（如 HKCU:\Software\X）。', '参数不足', 'OK', 'Warning')
            return
        }
        $a = @{ path = $p }
        if ($n) { $a['name'] = $n }
        $r = Invoke-LctEngine -Verb 'registry.get' -Args $a
        if ($r.ok -and $null -ne $r.data) {
            $d = $r.data
            $script:RegReadBox.Text = "path  = $([string](Get-LctProp $d 'path' ''))`r`nname  = $([string](Get-LctProp $d 'name' ''))`r`ntype  = $([string](Get-LctProp $d 'type' ''))`r`nvalue = $([string](Get-LctProp $d 'value' ''))"
        } else {
            $script:RegReadBox.Text = '（读取失败，或该键/值不存在；详见底部日志）'
        }
    })
    $bPrev.Add_Click({
        param($s, $e)
        $p = $script:RegPathBox.Text.Trim()
        $n = $script:RegNameBox.Text.Trim()
        if (-not $p -or -not $n) {
            $null = [System.Windows.Forms.MessageBox]::Show('写入需要「路径」和「值名」都不为空。', '参数不足', 'OK', 'Warning')
            return
        }
        $tp = [string]$script:RegTypeBox.Text
        $v = [string]$script:RegValueBox.Text
        $null = Invoke-LctPreview -Page 'registry' -Id 'registry.set' -Verb 'registry.set' `
            -Args @{ path = $p; name = $n; value = $v; type = $tp } -Summary "写注册表 $p \ $n （$tp = $v）"
    })
    $bDel.Add_Click({
        param($s, $e)
        $p = $script:RegPathBox.Text.Trim()
        $n = $script:RegNameBox.Text.Trim()
        if (-not $p -or -not $n) {
            $null = [System.Windows.Forms.MessageBox]::Show('删除需要「路径」和「值名」都不为空。', '参数不足', 'OK', 'Warning')
            return
        }
        $null = Invoke-LctPreview -Page 'registry' -Id 'registry.delete' -Verb 'registry.delete' `
            -Args @{ path = $p; name = $n } -Summary "删除注册表值 $p \ $n"
    })

    $null = New-LctPendingStrip -Parent $form -Col 0 -Row 5 -PageKey 'registry'

    $c2 = New-LctCard -Title '读取结果（registry.get）' -Parent $inner -Col 1 -Row 0
    $script:RegReadBox = New-LctText -X 0 -Y 0 -W 100 -H 100 -Parent $c2 -Multiline -ReadOnly -Mono -Dark
    $script:RegReadBox.Dock = [System.Windows.Forms.DockStyle]::Fill
    $script:RegReadBox.Margin = New-Object System.Windows.Forms.Padding(10, 22, 10, 10)

    # --- 预设包 ---
    $c3 = New-LctCard -Title '预设包（presets.list / presets.show）：每项一行「预览」「应用」' -Parent $t -Col 0 -Row 1
    $inner3 = New-LctTable -Parent $c3 -ColSpec @('100p', '380a') -RowSpec @('100p')
    $inner3.Margin = New-Object System.Windows.Forms.Padding(12, 24, 8, 10)

    $lg = New-LctTable -Parent $inner3 -ColSpec @('100p') -RowSpec @('36a', '100p') -Col 0 -Row 0
    $bt = New-LctTable -Parent $lg -ColSpec @('200a', '230a', '100p') -RowSpec @('34a') -Col 0 -Row 0
    $bt.Margin = New-Object System.Windows.Forms.Padding(0)
    $bLd = New-LctButton -Text '加载 / 刷新预设包列表' -X 0 -Y 0 -W 100 -H 30 -Parent $bt -Accent
    $bLd.Dock = [System.Windows.Forms.DockStyle]::Fill
    $bLd.Margin = New-Object System.Windows.Forms.Padding(0, 2, 6, 2)
    $bSh = New-LctButton -Text '查看选中行预设包详情' -X 0 -Y 0 -W 100 -H 30 -Parent $bt
    $bSh.Dock = [System.Windows.Forms.DockStyle]::Fill
    $bSh.Margin = New-Object System.Windows.Forms.Padding(0, 2, 6, 2)
    $bLd.Add_Click({ param($s, $e) Update-LctPresets })
    $bSh.Add_Click({ param($s, $e) Update-LctPresetDetail })
    $script:PresetGrid = New-LctGrid -Parent $lg -Name 'presets' -Buttons @(
        'btnPreview|预览|64', 'btnApply|应用|64'
    ) -Cols @('preset|预设包|150', 'risk|风险|70', 'title|项目|220', 'summary|说明|fill', 'verb|verb|130')
    $script:PresetGrid.Add_CellContentClick({
        param($s, $e)
        if ($e.RowIndex -lt 0) { return }
        $cn = [string]$s.Columns[$e.ColumnIndex].Name
        $key = [string]$s.Rows[$e.RowIndex].Cells['rowkey'].Value
        if ($cn -eq 'btnPreview') {
            Invoke-LctPresetRowPreview -Key $key
        } elseif ($cn -eq 'btnApply') {
            if (@(Get-LctPending -Page 'registry' -Id (Get-LctPresetPendingId $key)).Count -eq 0) {
                Invoke-LctPresetRowPreview -Key $key
                $null = [System.Windows.Forms.MessageBox]::Show(
                    "已生成预览（$($script:PREVIEW_BANNER)）。`r`n请确认日志面板里的 before/after 无误后，再点一次「应用」即可二次确认并落盘。",
                    '先预览，再应用', 'OK', 'Information')
                return
            }
            Invoke-LctApplyPending -Page 'registry' -Id (Get-LctPresetPendingId $key)
        }
    })

    $rg = New-LctTable -Parent $inner3 -ColSpec @('100p') -RowSpec @('30a', '100p') -Col 1 -Row 0
    $null = New-LctLabel -Text '预设包详情（presets.show，JSON 原文）' -X 4 -Y 2 -W 340 -H 24 -Parent $rg -Dim
    $script:PresetDetailBox = New-LctText -X 4 -Y 28 -W 100 -H 100 -Parent $rg -Multiline -ReadOnly -Mono -Dark
    $script:PresetDetailBox.Dock = [System.Windows.Forms.DockStyle]::Fill
    $script:PresetDetailBox.Margin = New-Object System.Windows.Forms.Padding(4, 28, 4, 6)
    return $t
}

# ===========================================================================
# 十、页面四：提权工具（插件）
# ===========================================================================

function Update-LctPlugins {
    if ($null -eq $script:PluginGrid) { return }
    $r = Invoke-LctEngine -Verb 'plugins.list'
    Clear-LctGrid $script:PluginGrid
    if (-not $r.ok) { return }
    foreach ($p in @(Get-LctArray $r.data)) {
        Add-LctGridRow -Grid $script:PluginGrid -Key ([string](Get-LctProp $p 'id' '')) -Values @(
            [string](Get-LctProp $p 'id' ''),
            [string](Get-LctProp $p 'name' ''),
            [string](Get-LctProp $p 'version' ''),
            [string](Get-LctProp $p 'risk' ''),
            [string](Get-LctProp $p 'description' ''))
    }
    if ($script:PluginGrid.Rows.Count -gt 0) {
        $script:PluginGrid.Rows[0].Selected = $true
        Update-LctPluginDetail
    }
}

function Update-LctPluginDetail {
    if ($null -eq $script:PluginDetailBox) { return }
    $id = Get-LctSelectedPluginId
    if (-not $id) {
        $script:PluginDetailBox.Text = '（请先在左侧选择一个插件）'
        return
    }
    $r = Invoke-LctEngine -Verb 'plugins.show' -Args @{ plugin = $id }
    if (-not $r.ok) {
        $script:PluginDetailBox.Text = 'plugins.show 失败，详见底部日志。'
        return
    }
    $d = $r.data
    try { $script:PluginDetailBox.Text = ConvertTo-Json -InputObject $d -Depth 8 }
    catch { $script:PluginDetailBox.Text = [string]$d }

    # 按 params 动态生成参数控件
    $script:PluginParamPanel.Controls.Clear()
    $script:PluginParamCtrls.Clear()
    $params = ConvertTo-LctParamList (Get-LctProp $d 'params' $null)
    foreach ($p in @($params)) {
        $row = New-Object System.Windows.Forms.Panel
        $row.Width = [Math]::Max(300, $script:PluginParamPanel.ClientSize.Width - 30)
        $row.Height = 46
        $row.BackColor = [System.Drawing.Color]::Transparent
        $lblText = [string]$p.name
        if ([bool]$p.required) { $lblText += ' *' }
        $null = New-LctLabel -Text $lblText -X 0 -Y 2 -W 200 -H 18 -Parent $row -Bold
        $desc = [string]$p.description
        if ($desc) { $null = New-LctLabel -Text $desc -X 0 -Y 22 -W 400 -H 18 -Parent $row -Dim -Size 8 }
        $ctrl = $null
        if (@($p.choices).Count -gt 0) {
            $ctrl = New-Object System.Windows.Forms.ComboBox
            $ctrl.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
            $ctrl.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
            $ctrl.BackColor = $script:C.Panel2
            $ctrl.ForeColor = $script:C.Text
            foreach ($ch in @($p.choices)) {
                $v = [string]$ch
                if (($ch -is [System.Management.Automation.PSCustomObject]) -or ($ch -is [System.Collections.IDictionary])) {
                    $v = [string](Get-LctProp $ch 'name' (Get-LctProp $ch 'value' ''))
                }
                $null = $ctrl.Items.Add($v)
            }
            if ($ctrl.Items.Count -gt 0) { $ctrl.SelectedIndex = 0 }
            $ctrl.Location = New-Object System.Drawing.Point(210, 2)
            $ctrl.Width = 240
        } elseif ([string]$p.type -match '(?i)^bool') {
            $ctrl = New-Object System.Windows.Forms.CheckBox
            $ctrl.Text = ''
            $ctrl.BackColor = [System.Drawing.Color]::Transparent
            $ctrl.ForeColor = $script:C.Text
            if ([bool]$p.default) { $ctrl.Checked = $true }
            $ctrl.Location = New-Object System.Drawing.Point(212, 2)
            $ctrl.Width = 240
        } else {
            $ctrl = New-Object System.Windows.Forms.TextBox
            $ctrl.BackColor = $script:C.Panel2
            $ctrl.ForeColor = $script:C.Text
            $ctrl.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
            $ctrl.Font = New-LctFont -Size 9
            $ctrl.Location = New-Object System.Drawing.Point(210, 2)
            $ctrl.Width = 240
            if ($null -ne $p.default) { $ctrl.Text = [string]$p.default }
            $isSecret = [bool]$p.secret
            if ([string]$p.type -match '(?i)secret|password|passwd') { $isSecret = $true }
            if ($isSecret) { $ctrl.UseSystemPasswordChar = $true }
        }
        if ($null -ne $ctrl) { $null = $row.Controls.Add($ctrl) }
        $null = $script:PluginParamPanel.Controls.Add($row)
        $null = $script:PluginParamCtrls.Add([pscustomobject]@{ name = [string]$p.name; type = [string]$p.type; secret = [bool]$p.secret; ctrl = $ctrl })
    }
    if ($script:PluginParamCtrls.Count -eq 0) {
        $null = New-LctLabel -Text '该插件没有声明参数（params 为空）。' -X 4 -Y 6 -W 320 -H 22 -Parent $script:PluginParamPanel -Dim
    }
}

function Get-LctPluginParamValues {
    $h = @{}
    foreach ($pc in @($script:PluginParamCtrls)) {
        $c = $pc.ctrl
        if ($c -is [System.Windows.Forms.CheckBox]) { $h[[string]$pc.name] = [bool]$c.Checked }
        elseif ($c -is [System.Windows.Forms.ComboBox]) { $h[[string]$pc.name] = [string]$c.Text }
        else { $h[[string]$pc.name] = [string]$c.Text }
    }
    return $h
}

function Get-LctSelectedPluginId {
    if ($script:PluginGrid.SelectedRows.Count -gt 0) { return [string]$script:PluginGrid.SelectedRows[0].Cells['rowkey'].Value }
    return ''
}

function New-LctPagePlugins {
    param($Body)
    $t = New-LctTable -Parent $Body -ColSpec @('420a', '100p') -RowSpec @('100p')

    $c1 = New-LctCard -Title '插件列表（plugins.list）' -Parent $t -Col 0 -Row 0
    $l1 = New-LctTable -Parent $c1 -ColSpec @('100p', '180a') -RowSpec @('36a', '100p')
    $l1.Margin = New-Object System.Windows.Forms.Padding(10, 24, 8, 10)
    $b1 = New-LctButton -Text '重新加载插件列表' -X 0 -Y 0 -W 100 -H 30 -Parent $l1 -Accent
    $b1.Dock = [System.Windows.Forms.DockStyle]::Fill
    $b1.Margin = New-Object System.Windows.Forms.Padding(0, 2, 8, 2)
    $b1.Add_Click({ param($s, $e) Update-LctPlugins })
    $script:PluginGrid = New-LctGrid -Parent $l1 -Name 'plugins' -Cols @(
        'id|插件 id|130', 'name|名称|fill', 'version|版本|60', 'risk|风险|60', 'description|说明|150'
    )
    $l1.SetColumnSpan($script:PluginGrid, 2)
    $script:PluginGrid.Add_SelectionChanged({
        param($s, $e)
        if ($script:SuppressSelection) { return }
        $script:SuppressSelection = $true
        try { Update-LctPluginDetail } finally { $script:SuppressSelection = $false }
    })

    $right = New-LctTable -Parent $t -ColSpec @('100p') -RowSpec @('236a', '100p', '44a') -Col 1 -Row 0

    $c2 = New-LctCard -Title '插件详情（plugins.show：插件目录 plugin.json 原文）' -Parent $right -Col 0 -Row 0
    $script:PluginDetailBox = New-LctText -X 0 -Y 0 -W 100 -H 100 -Parent $c2 -Multiline -ReadOnly -Mono -Dark
    $script:PluginDetailBox.Dock = [System.Windows.Forms.DockStyle]::Fill
    $script:PluginDetailBox.Margin = New-Object System.Windows.Forms.Padding(10, 22, 10, 10)

    $c3 = New-LctCard -Title '参数（按 params 动态生成，secret 为密码框）→ 预览命令 → 执行前二次确认' -Parent $right -Col 0 -Row 1
    $l3 = New-LctTable -Parent $c3 -ColSpec @('100p') -RowSpec @('100p', '40a', '110a')
    $l3.Margin = New-Object System.Windows.Forms.Padding(10, 22, 10, 10)

    $script:PluginParamPanel = New-Object System.Windows.Forms.FlowLayoutPanel
    $script:PluginParamPanel.Dock = [System.Windows.Forms.DockStyle]::Fill
    $script:PluginParamPanel.FlowDirection = [System.Windows.Forms.FlowDirection]::TopDown
    $script:PluginParamPanel.WrapContents = $false
    $script:PluginParamPanel.AutoScroll = $true
    $script:PluginParamPanel.BackColor = $script:C.Panel
    $script:PluginParamPanel.Margin = New-Object System.Windows.Forms.Padding(0)
    $script:PluginParamPanel.Add_Resize({
        param($s, $e)
        foreach ($c in $s.Controls) {
            try { $c.Width = [Math]::Max(300, $s.ClientSize.Width - 30) } catch { }
        }
    })
    $null = $l3.Controls.Add($script:PluginParamPanel, 0, 0)

    $br = New-LctTable -Parent $l3 -ColSpec @('160a', '190a', '66a', '100p') -RowSpec @('36a') -Col 0 -Row 1
    $br.Margin = New-Object System.Windows.Forms.Padding(0)
    $bp = New-LctButton -Text '预览命令（不执行）' -X 0 -Y 0 -W 100 -H 30 -Parent $br -Accent
    $bp.Dock = [System.Windows.Forms.DockStyle]::Fill
    $bp.Margin = New-Object System.Windows.Forms.Padding(0, 2, 8, 2)
    $be = New-LctButton -Text '执行（需二次确认）' -X 0 -Y 0 -W 100 -H 30 -Parent $br -Warn
    $be.Dock = [System.Windows.Forms.DockStyle]::Fill
    $be.Margin = New-Object System.Windows.Forms.Padding(0, 2, 8, 2)
    $null = New-LctLabel -Text '超时(秒)' -X 2 -Y 8 -W 62 -H 20 -Parent $br
    $script:PluginTimeout = New-Object System.Windows.Forms.NumericUpDown
    $script:PluginTimeout.Minimum = 5
    $script:PluginTimeout.Maximum = 600
    $script:PluginTimeout.Value = 120
    $script:PluginTimeout.BackColor = $script:C.Panel2
    $script:PluginTimeout.ForeColor = $script:C.Text
    $script:PluginTimeout.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
    $script:PluginTimeout.Dock = [System.Windows.Forms.DockStyle]::Fill
    $script:PluginTimeout.Margin = New-Object System.Windows.Forms.Padding(0, 4, 8, 4)
    $null = $br.Controls.Add($script:PluginTimeout, 3, 0)
    $script:PluginPreviewBtn = $bp
    $script:PluginExecBtn = $be

    $script:PluginCommandBox = New-LctText -X 0 -Y 0 -W 100 -H 100 -Parent $l3 -Multiline -ReadOnly -Mono -Dark
    $script:PluginCommandBox.Dock = [System.Windows.Forms.DockStyle]::Fill
    $script:PluginCommandBox.Margin = New-Object System.Windows.Forms.Padding(0, 4, 0, 0)

    $bp.Add_Click({
        param($s, $e)
        $id = Get-LctSelectedPluginId
        if (-not $id) {
            $null = [System.Windows.Forms.MessageBox]::Show('请先在左侧插件列表里选中一个插件。', '未选中插件', 'OK', 'Warning')
            return
        }
        $vals = Get-LctPluginParamValues
        $to = [int]$script:PluginTimeout.Value
        $r = Invoke-LctPreview -Page 'plugins' -Id "plugin:$id" -Verb 'plugins.run' `
            -Args @{ plugin = $id; params = $vals; timeout = $to } `
            -Summary "执行插件 $id（超时 ${to}s）" -TimeoutSec ($to + 60)
        if ($r.ok -and $null -ne $r.data) {
            $cmd = [string](Get-LctProp $r.data 'command' '')
            $rp = Get-LctProp $r.data 'resolvedParams' $null
            $txt = "预览命令（未执行）：`r`n$cmd`r`n`r`n解析后的参数（resolvedParams）：`r`n"
            try { $txt += (ConvertTo-Json -InputObject $rp -Depth 6) } catch { $txt += [string]$rp }
            $txt += "`r`n`r`n状态：$($script:PREVIEW_BANNER)（点「执行」并二次确认后才会真正运行）"
            $script:PluginCommandBox.Text = $txt
        } else {
            $script:PluginCommandBox.Text = '预览失败，详见底部日志。'
        }
    })
    $be.Add_Click({
        param($s, $e)
        $id = Get-LctSelectedPluginId
        if (-not $id) {
            $null = [System.Windows.Forms.MessageBox]::Show('请先在左侧插件列表里选中一个插件。', '未选中插件', 'OK', 'Warning')
            return
        }
        if (@(Get-LctPending -Page 'plugins' -Id "plugin:$id").Count -eq 0) {
            $null = [System.Windows.Forms.MessageBox]::Show(
                "必须先预览。`r`n请先点「预览命令」，确认命令与参数无误后，再点「执行」并二次确认。",
                '需要先预览', 'OK', 'Warning')
            return
        }
        Invoke-LctApplyPending -Page 'plugins' -Id "plugin:$id"
    })

    $null = New-LctPendingStrip -Parent $right -Col 0 -Row 2 -PageKey 'plugins'
    return $t
}

# ===========================================================================
# 十一、页面五：备份与回滚
# ===========================================================================

function Update-LctBackups {
    if ($null -eq $script:BackupGrid) { return }
    $r = Invoke-LctEngine -Verb 'backup.list'
    Clear-LctGrid $script:BackupGrid
    if (-not $r.ok) { return }
    foreach ($b in @(Get-LctArray $r.data)) {
        $ha = '否'; if ([bool](Get-LctProp $b 'hasAccountState' $false)) { $ha = '是' }
        Add-LctGridRow -Grid $script:BackupGrid -Key ([string](Get-LctProp $b 'id' '')) -Values @(
            [string](Get-LctProp $b 'id' ''), [string](Get-LctProp $b 'created' ''),
            [string](Get-LctProp $b 'verb' ''), [string](Get-LctProp $b 'user' ''),
            $ha, [string](Get-LctProp $b 'fileCount' ''))
    }
    if ($script:BackupGrid.Rows.Count -gt 0) { $script:BackupGrid.Rows[0].Selected = $true }
    Update-LctBackupDetail
}

function Update-LctBackupDetail {
    if ($null -eq $script:BackupDetailBox) { return }
    $id = ''
    if ($script:BackupGrid.SelectedRows.Count -gt 0) { $id = [string]$script:BackupGrid.SelectedRows[0].Cells['rowkey'].Value }
    if (-not $id) { $script:BackupDetailBox.Text = '（当前没有备份）'; return }
    $r = Invoke-LctEngine -Verb 'backup.show' -Args @{ id = $id }
    if ($r.ok) {
        try { $script:BackupDetailBox.Text = ConvertTo-Json -InputObject $r.data -Depth 8 }
        catch { $script:BackupDetailBox.Text = [string]$r.data }
    } else {
        $script:BackupDetailBox.Text = 'backup.show 失败，详见底部日志。'
    }
}

function Get-LctSelectedBackupId {
    if ($script:BackupGrid.SelectedRows.Count -gt 0) { return [string]$script:BackupGrid.SelectedRows[0].Cells['rowkey'].Value }
    return ''
}

function New-LctPageBackup {
    param($Body)
    $t = New-LctTable -Parent $Body -ColSpec @('580a', '100p') -RowSpec @('100p')

    $c1 = New-LctCard -Title '备份列表（backup.list）' -Parent $t -Col 0 -Row 0
    $l1 = New-LctTable -Parent $c1 -ColSpec @('100p', '170a') -RowSpec @('36a', '100p')
    $l1.Margin = New-Object System.Windows.Forms.Padding(10, 24, 8, 10)
    $b1 = New-LctButton -Text '刷新备份列表' -X 0 -Y 0 -W 100 -H 30 -Parent $l1 -Accent
    $b1.Dock = [System.Windows.Forms.DockStyle]::Fill
    $b1.Margin = New-Object System.Windows.Forms.Padding(0, 2, 8, 2)
    $b1.Add_Click({ param($s, $e) Update-LctBackups })
    $script:BackupGrid = New-LctGrid -Parent $l1 -Name 'backups' -Cols @(
        'id|备份 id|300', 'created|创建时间|140', 'verb|来源 verb|150', 'user|用户|130',
        'hasAccountState|含账户快照|90', 'fileCount|文件数|60'
    )
    $l1.SetColumnSpan($script:BackupGrid, 2)
    $script:BackupGrid.Add_SelectionChanged({ param($s, $e) Update-LctBackupDetail })

    $right = New-LctTable -Parent $t -ColSpec @('100p') -RowSpec @('100p', '44a', '44a', '44a') -Col 1 -Row 0
    $c2 = New-LctCard -Title '备份详情（backup.show）' -Parent $right -Col 0 -Row 0
    $script:BackupDetailBox = New-LctText -X 0 -Y 0 -W 100 -H 100 -Parent $c2 -Multiline -ReadOnly -Mono -Dark
    $script:BackupDetailBox.Dock = [System.Windows.Forms.DockStyle]::Fill
    $script:BackupDetailBox.Margin = New-Object System.Windows.Forms.Padding(10, 22, 10, 10)

    $br = New-LctTable -Parent $right -ColSpec @('100p') -RowSpec @('36a') -Col 0 -Row 1
    $br.Margin = New-Object System.Windows.Forms.Padding(2)
    $bp = New-LctButton -Text '预览还原（backup.restore，不落盘）' -X 0 -Y 0 -W 100 -H 30 -Parent $br -Accent
    $bp.Dock = [System.Windows.Forms.DockStyle]::Fill
    $bp.Margin = New-Object System.Windows.Forms.Padding(2)
    $script:BackupPreviewBtn = $bp
    $bp.Add_Click({
        param($s, $e)
        $id = Get-LctSelectedBackupId
        if (-not $id) {
            $null = [System.Windows.Forms.MessageBox]::Show('请先在左侧选中一个备份。', '未选中备份', 'OK', 'Warning')
            return
        }
        $null = Invoke-LctPreview -Page 'backup' -Id "restore:$id" -Verb 'backup.restore' `
            -Args @{ id = $id } -Summary "还原备份 $id"
    })

    $br2 = New-LctTable -Parent $right -ColSpec @('100p') -RowSpec @('36a') -Col 0 -Row 2
    $br2.Margin = New-Object System.Windows.Forms.Padding(2)
    $be = New-LctButton -Text '执行还原（需二次确认）' -X 0 -Y 0 -W 100 -H 30 -Parent $br2 -Warn
    $be.Dock = [System.Windows.Forms.DockStyle]::Fill
    $be.Margin = New-Object System.Windows.Forms.Padding(2)
    $script:BackupExecBtn = $be
    $be.Add_Click({
        param($s, $e)
        $id = Get-LctSelectedBackupId
        if (-not $id) {
            $null = [System.Windows.Forms.MessageBox]::Show('请先在左侧选中一个备份。', '未选中备份', 'OK', 'Warning')
            return
        }
        if (@(Get-LctPending -Page 'backup' -Id "restore:$id").Count -eq 0) {
            $null = [System.Windows.Forms.MessageBox]::Show('必须先点「预览还原」，确认 before/after 无误。', '需要先预览', 'OK', 'Warning')
            return
        }
        Invoke-LctApplyPending -Page 'backup' -Id "restore:$id"
    })

    $null = New-LctPendingStrip -Parent $right -Col 0 -Row 3 -PageKey 'backup'
    return $t
}

# ===========================================================================
# 十二、页面六：关于 / 说明
# ===========================================================================

function New-LctPageAbout {
    param($Body)
    $c = New-LctCard -Title '关于 LocalConfigTool'
    $null = $Body.Controls.Add($c)
    $txt = New-Object System.Windows.Forms.RichTextBox
    $txt.Dock = [System.Windows.Forms.DockStyle]::Fill
    $txt.Margin = New-Object System.Windows.Forms.Padding(12, 24, 12, 12)
    $txt.BackColor = $script:C.Panel
    $txt.ForeColor = $script:C.Text
    $txt.BorderStyle = [System.Windows.Forms.BorderStyle]::None
    $txt.ReadOnly = $true
    $txt.Font = New-LctFont -Size 10
    $txt.DetectUrls = $false
    $null = $c.Controls.Add($txt)
    $txt.Text = @'
LocalConfigTool —— 本地安全配置与提权工具

一、这个工具是做什么的
  把「本地安全配置」与「提权工具（插件）」收在一处，用同一个引擎执行、同一套界面操作：
    · 账户与登录：内置 Administrator 启用/禁用、UAC 开关、自动登录开关
    · 注册表：任意路径 / 值名的读取与写入（含预设包）
    · 提权工具（插件）：把 plugins\<id>\plugin.json 声明的工具做成表单，预览命令后再执行
    · 进程监控：进程快照 / 详情（能否 PROCESS_TERMINATE 的实测结论）/ 终止（先预览再二次确认）、
      会话内看门狗（不落地持久化）、IFEO 加载阻断（写注册表前先备份，可秒级回滚）
    · WDAC 黑名单：维护自管黑名单规则 → 生成策略（审计优先，产物落 var\wdac\staging）→
      安全校验（无 allow 机制 / 命中系统目录 / 缺救命绳 一律拦下）→ 手输确认文本后部署（★需重启生效★）
    · 驱动加载：指定 .sys 注册并启动（签名只做信息展示，能否加载交给系统判定并照抄错误原文）、
      停止 / 卸载（只删服务项，不删 .sys 文件，并生成 revert.cmd）、加载后复核、test-signing 开关
    · 驱动 Profile：第三方 / 漏洞驱动走「每驱一份 profile」（纯数据：定位法 + IOCTL + 结构布局 + 指纹 + 风险等级），
      可校验（target.sha256 与文件不符 ⇒ 拒绝）、可静态起草（草案不能直接执行）、可按 profile 发内核原语（默认只预览）
    · 备份与回滚：任何真实写入前都会先备份，随时可还原

二、安全说明（请务必读一遍）
  1. 默认预览：所有写类操作，界面第一次点只会「预览」——日志面板会明确标注
     「仅预览，未落盘」，不会对系统做任何修改。要真实生效，必须再点「应用」，
     并在弹出的确认框里选「是」。执行插件、还原备份同样要二次确认。
  2. 先备份后写：引擎在真实写入前先创建备份（注册表导出 .reg；账户类写入带账户快照），
     备份 id 会写进日志，可在「备份与回滚」页预览并还原。
  3. 删除走回收站：本工具绝不永久删除文件/目录，一律送 Windows 回收站；
     注册表键的删除也走受控的键树删除，不使用 Remove-Item。
  4. 不碰口令：自动登录的口令只由引擎从你选择的文件里读取，界面不接受明文输入，
     也不会把口令写进命令行参数、日志或备份元数据（只记「有没有口令」）。
  5. 前后端分离：本界面（前端）不实现任何后端逻辑——不写注册表、不改账户、
     不执行插件命令、不删文件；界面上的每个动作都是调用引擎 CLI 完成的。
   6. 驱动原语（driver.ctl.send）与驱动 profile：「① 预览：发送」只打印将发送的 IOCTL 与输入缓冲区
      的十六进制，预览阶段引擎不打开设备、不发任何 IOCTL；要真发必须再点「② 应用：发送」并在
      确认框里选「是」。risk.level=bsod 的动作默认禁用发送按钮，必须勾选「我知道可能蓝屏」并重新
      预览后才允许；写类原语拿不到写前原值时会拒绝（无原值不写）。profile 必须先过校验
      （target.sha256 与 .sys 不符一律拒绝：布局错版本必蓝屏）；静态草案（needsReview=true）永远
      不可直接执行，必须人工审定后另存到 var\driver-profiles。

三、插件风险提示
  · 插件是你自己放进 plugins\ 目录的提权工具，执行后拥有当前进程的全部权限
    （若本工具以管理员身份运行，插件也就是管理员权限）。只放你信任的插件。
  · 执行前请务必先看「预览命令」里显示的实际命令行与解析后的参数，确认无误再执行。
  · 插件可能修改系统状态，且不一定能被「备份与回滚」完全覆盖（备份只覆盖注册表与账户快照）。
  · 一次调用只执行一个插件；本工具不会自动接着执行第二个插件。

四、进程监控与 WDAC 的高风险后果（务必先读）
  · 终止进程：终止关键进程（csrss / lsass / services / winlogon / svchost / dwm 等）可能导致
    蓝屏、掉网、登录会话中断、杀软或安全组件失效。这类目标（契约 §11.2 名单）界面会额外提示，
    并只能用 override 才允许预览；受保护进程（PPL）在用户态永远杀不掉，引擎会如实返回失败原因。
  · 看门狗：只在本次工具运行期间有效（活在引擎调用进程里），关闭/退出即停，
    不装服务、不注册自启、不隐藏。目标必须显式指定，禁止通配与「杀全部」。
  · IFEO 阻断：让目标程序根本无法启动（含 Wow6432Node 视图）。写入前引擎先备份原值，
    可在「备份与回滚」页还原，也可用页面上的「预览：回滚 → 应用回滚」秒级恢复。
  · WDAC 部署：策略文件放进 System32\CodeIntegrity 后【需重启生效】。强制模式（enforce）
    会真的拦程序，必须手输确认文本（audit=I-UNDERSTAND-AUDIT，enforce=I-UNDERSTAND-ENFORCE）；
    审计部署 → 重启 → 「重启后校验」判定「可安全转强制」后才建议转强制。恢复方式见页面上的
    revert.cmd 位置与 F8 / WinRE 离线恢复步骤。

五、界面约定
  · 左侧导航切换 10 个页；右下「引擎结果 / 日志」面板显示每次引擎调用的
    changes / warnings / errors 与备份 id。
  · 「待应用：N 项」表示已经有 N 项通过了预览、但还没有落盘。
  · 前端版本 1.0.0；引擎 core\Engine.ps1（由 Lead 维护，前端不修改引擎）。
'@
    return $c
}

# ===========================================================================
# 十二·五、新增能力的两页：页面七「进程监控」(processes) / 页面八「WDAC 黑名单」(wdac)
#   作者：task-6 (ui-expansion)。铁则不变：**本段不含任何后端逻辑** ——
#   所有动作都经 Invoke-LctEngine（参数走临时文件 -ArgsFile + -EncodedCommand）调引擎 verb；
#   写操作一律「预览（橙色标注「仅预览，未落盘」）→ 登记待应用 → 点应用 + MessageBox
#   二次确认 → 才带 -Apply」。
#   对应的后端模块 core\Processes.psm1 / core\Wdac.psm1 由 backend-processes / backend-wdac
#   实现（docs\CONTRACT.md §11.2 / §11.3）；前端只渲染它们的 Result（契约 §3）。
#   验收脚本要按真实点击驱动时：按钮句柄存成了 $script:*Btn（ProcKill* / ProcWatch* / Block* /
#   WdacBuildAudit / WdacValidate / WdacVerify / WdacDeploy* / WdacRule*），但**必须先把窗体 show 出来**
#   且先 Switch-LctPage 到该页，否则 CanSelect=False、PerformClick 不触发（见文件头注释）。
# ===========================================================================

# 契约 §11.2 的关键进程 / 安全软件名单：界面用来「额外提示 + 使用 override」；
# 真正的拦截判定在引擎侧，这里只负责让用户看清风险。
$script:CriticalProcNames = @(
    'MsMpEng', 'NisSrv', 'MsSense', 'csrss', 'lsass', 'services', 'smss', 'wininit',
    'winlogon', 'dwm', 'svchost', 'System', 'Registry', 'SgrmBroker', 'audiodg'
)
$script:CriticalProcPattern = '(?i)^(avira|avp|mcafee|norton|symantec|kaspersky|eset|bitdefender|sophos|trendmicro|360|huorong|kingsoft)'
$script:WdacConfirmAudit   = 'I-UNDERSTAND-AUDIT'
$script:WdacConfirmEnforce = 'I-UNDERSTAND-ENFORCE'
$script:WdacRecoveryText = @'
部署/回滚须知（恢复靠这三步，先读再重启）：
  1) 首选：运行引擎生成的回滚脚本  <工具根>\var\backups\wdac-<备份戳>\revert.cmd
     （脚本会删除/还原 System32\CodeIntegrity\SiPolicy.p7b，恢复说明与备份放在同一目录）
  2) 开机自救：开机连按 F8 →「启动设置」；或在 WinRE 里离线处理（强制断电两次 → 修复 → 命令行）：
        del C:\Windows\System32\CodeIntegrity\SiPolicy.p7b
        copy <备份目录>\SiPolicy.p7b C:\Windows\System32\CodeIntegrity\SiPolicy.p7b
  3) 每次部署/回滚都写引擎日志（var\logs\engine-*.log），出问题按日志里的备份戳回滚。
★★ 策略放进 System32\CodeIntegrity 后「需重启生效」；本界面不会替你重启，也绝不自动重启 ★★
'@

$script:SuppressProcSel = $false
$script:SuppressWdacSel = $false

function Get-LctField {
    <#
      同义字段名兜底：core\Processes.psm1 / core\Wdac.psm1 与前端是并行开发的，
      契约冻结了语义但未逐一冻结每个键名。按候选名依次取第一个非空值，
      避免后端改一个键名就让界面整块空白（真正缺失时仍会显示「—」）。
    #>
    param($Object, [string[]]$Names = @(), $Default = $null)
    foreach ($n in @($Names)) {
        $v = Get-LctProp -Object $Object -Name $n -Default $null
        if ($null -eq $v) { continue }
        if ($v -is [string] -and $v.Trim() -eq '') { continue }
        return $v
    }
    return $Default
}

function Get-LctDataDeep {
    <#
      集成期兜底（实测 2026-10-26，backend-processes 报告 + Lead 确认）：
      引擎对「getter 返回裸数据」的几个 verb 写成 New-LctResultSafe -Verb … -Data (@(Get-…))，
      前端看到的形状就变成 data = [ <模块 Result> ]，真正负载在 data.data.*；
      此时 data.count 只是数组长度（=1），data.items 为 null —— 界面会误以为没有数据。
      这里做有界向下取值：数组只有 1 个元素就取该元素；对象没有期望的键但带 data 时再下一层。
      Lead 修好引擎接线后（data.* 直出）本函数立刻返回原对象，行为不变。
    #>
    param($Result, [string]$KeyName = '')
    $d = Get-LctProp $Result 'data' $null
    for ($i = 0; $i -lt 4; $i++) {
        if ($null -eq $d) { return $null }
        if ($d -is [System.Array]) {
            $arr = @($d)
            if (@($arr).Count -eq 1) { $d = $arr[0]; continue }
            return $d
        }
        if (-not $KeyName) { return $d }
        if ($null -ne (Get-LctProp $d $KeyName $null)) { return $d }
        $inner = Get-LctProp $d 'data' $null
        if ($null -eq $inner) { return $d }
        $d = $inner
    }
    return $d
}

function Get-LctWarningsDeep {
    # 同上：多包一层时，模块自己的 warnings 在内层 Result 上
    param($Result)
    $out = @(Get-LctArray (Get-LctProp $Result 'warnings' @()))
    $raw = Get-LctProp $Result 'data' $null
    if ($raw -is [System.Array]) {
        $arr = @($raw)
        if (@($arr).Count -eq 1) { $raw = $arr[0] } else { $raw = $null }
    }
    if ($null -ne $raw) { $out += @(Get-LctArray (Get-LctProp $raw 'warnings' @())) }
    return @($out)
}

function Format-LctBoolCn {
    param($Value)
    if ($null -eq $Value) { return '—' }
    if ($Value -is [string]) {
        $t = $Value.Trim().ToLowerInvariant()
        if ($t -eq '') { return '—' }
        if ($t -eq 'true' -or $t -eq '1' -or $t -eq 'yes' -or $t -eq '是' -or $t -eq 'on') { return '是' }
        if ($t -eq 'false' -or $t -eq '0' -or $t -eq 'no' -or $t -eq '否' -or $t -eq 'off') { return '否' }
        return $Value
    }
    if ([bool]$Value) { return '是' }
    return '否'
}

function Format-LctCanKillCn {
    param($Value)
    if ($null -eq $Value) { return '—（引擎未返回该字段）' }
    $t = [string]$Value
    if ($t -match '(?i)^(true|是|yes|ok|1)$') { return '可以 —— 实测 OpenProcess(PROCESS_TERMINATE) 成功' }
    if ($t -match '(?i)^(false|否|no|0)$') { return '不可以 —— 实测被拒绝（受保护 / 权限不足，原因见下）' }
    return $t
}

function Format-LctChangeBrief {
    param($Result)
    $parts = @()
    foreach ($c in @(Get-LctArray (Get-LctProp $Result 'changes' @()))) {
        $tg = [string](Get-LctProp $c 'target' '')
        $bf = [string](Get-LctProp $c 'before' '')
        $af = [string](Get-LctProp $c 'after' '')
        $nt = [string](Get-LctProp $c 'note' '')
        $one = "$tg  [$bf → $af]"
        if ($nt) { $one += "（$nt）" }
        $parts += $one
    }
    if (@($parts).Count -eq 0) { return '（引擎未返回 changes）' }
    return (@($parts) -join ' ; ')
}

function Test-LctCriticalProcessName {
    param([string]$Name)
    if (-not $Name) { return $false }
    $n = $Name.Trim()
    if ($n -match '(?i)\.exe$') { $n = $n.Substring(0, $n.Length - 4) }
    foreach ($c in @($script:CriticalProcNames)) { if ($n -ieq $c) { return $true } }
    if ($n -match $script:CriticalProcPattern) { return $true }
    return $false
}

function Get-LctRowCell {
    param($Row, [string]$Column)
    if ($null -eq $Row) { return '' }
    try { $c = $Row.Cells[$Column] } catch { return '' }
    if ($null -eq $c) { return '' }
    try { return [string]$c.Value } catch { return '' }
}

function New-LctScrollPage {
    # 新页面内容较多：给页面套一个可滚动画布（AutoScroll），小窗口/<1024 高时也能看到全部控件。
    # 只作用于新页面，其它 6 页布局保持原样。
    param($Body, [int]$CanvasHeight = 660)
    $sp = New-Object System.Windows.Forms.Panel
    $sp.Dock = [System.Windows.Forms.DockStyle]::Fill
    $sp.AutoScroll = $true
    $sp.BackColor = $script:C.Bg
    $null = $Body.Controls.Add($sp)

    $canvas = New-Object System.Windows.Forms.TableLayoutPanel
    $canvas.BackColor = [System.Drawing.Color]::Transparent
    $canvas.ColumnCount = 1
    $canvas.RowCount = 1
    $null = $canvas.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
    $null = $canvas.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, $CanvasHeight)))
    $canvas.Location = New-Object System.Drawing.Point(0, 0)
    $canvas.Size = New-Object System.Drawing.Size(1000, $CanvasHeight)
    $canvas.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left
    $null = $sp.Controls.Add($canvas)
    $sp.Add_Resize({
        param($s, $e)
        foreach ($c in $s.Controls) {
            try { $c.Width = [Math]::Max(700, $s.ClientSize.Width - 26) } catch { }
        }
    })
    return $canvas
}

# ---------------------------------------------------------------------------
# 七、进程监控（processes）：列表 / 详情 / 终止 / 看门狗 / IFEO 阻断
# ---------------------------------------------------------------------------

function Get-LctSelectedProcess {
    $sel = [pscustomobject]@{ pid = 0; name = ''; user = ''; path = ''; wsMB = ''; session = ''; critical = $false; key = '' }
    if ($null -eq $script:ProcGrid) { return $sel }
    if ($script:ProcGrid.SelectedRows.Count -lt 1) { return $sel }
    $row = $script:ProcGrid.SelectedRows[0]
    $sel.key = Get-LctRowCell -Row $row -Column 'rowkey'
    if ($sel.key -match '^\d+$') { $sel.pid = [int]$sel.key }
    $sel.name = Get-LctRowCell -Row $row -Column 'name'
    $sel.user = Get-LctRowCell -Row $row -Column 'user'
    $sel.path = Get-LctRowCell -Row $row -Column 'path'
    $sel.wsMB = Get-LctRowCell -Row $row -Column 'wsMB'
    $sel.session = Get-LctRowCell -Row $row -Column 'session'
    $critText = Get-LctRowCell -Row $row -Column 'critical'
    if ($critText -match '(?i)^(是|true|yes|1)') { $sel.critical = $true }
    return $sel
}

function Update-LctProcesses {
    # 只读：process.list（可按名称/用户过滤）。失败也不抛异常，一切照实显示。
    if ($null -eq $script:ProcGrid) { return }
    $nm = ''
    $us = ''
    $inc = $false
    if ($null -ne $script:ProcFilterName) { $nm = [string]$script:ProcFilterName.Text.Trim() }
    if ($null -ne $script:ProcFilterUser) { $us = [string]$script:ProcFilterUser.Text.Trim() }
    if ($null -ne $script:ProcIncludeSystem) { $inc = [bool]$script:ProcIncludeSystem.Checked }

    $r = Invoke-LctEngine -Verb 'process.list' -Args @{ name = $nm; user = $us; includeSystem = $inc; limit = 0 }

    $script:SuppressProcSel = $true
    Clear-LctGrid $script:ProcGrid
    if (-not $r.ok) {
        $script:SuppressProcSel = $false
        if ($null -ne $script:ProcInfoLabel) { $script:ProcInfoLabel.Text = '进程列表调用失败（详见底部日志；后端模块可能尚未就绪）' }
        if ($null -ne $script:ProcDetailBox) {
            $errs = @(Get-LctArray $r.errors)
            $script:ProcDetailBox.Text = "process.list 调用失败：`r`n" + (@($errs) -join "`r`n")
        }
        return
    }
    # 真实返回形状（Lead + backend-processes 实测）：data = { identity; items[]; count; matched; truncated; limit; includeSystem; filters; processTotal; session0Hidden }
    # 进程行在 items 里（不在根上）；引擎多包一层时真正负载在 data.data（见 Get-LctDataDeep）。
    $pd = Get-LctDataDeep -Result $r -KeyName 'items'
    $items = @(Get-LctArray (Get-LctProp $pd 'items' $null))
    if (@($items).Count -eq 0 -and $null -ne $pd) { $items = @(Get-LctArray $pd) }
    foreach ($p in @($items)) {
        $procId = [string](Get-LctField $p @('pid', 'id', 'processId') 0)
        $pname  = [string](Get-LctField $p @('name', 'processName') '')
        $puser  = [string](Get-LctField $p @('user', 'userName', 'owner') '')
        $psess  = [string](Get-LctField $p @('session', 'sessionId') '')
        $pws    = [string](Get-LctField $p @('wsMB', 'memoryMB', 'ws', 'workingSetMB') '')
        $ppath  = [string](Get-LctField $p @('path', 'imagePath', 'executablePath') '')
        $critText = '否'
        $pcrit = Get-LctField $p @('isCritical', 'critical', 'criticalProcess', 'inCriticalList', 'protected') $null
        if ($null -ne $pcrit) {
            if ((Format-LctBoolCn $pcrit) -eq '是') { $critText = '是（引擎判定）' }
        }
        if ($critText -eq '否' -and (Test-LctCriticalProcessName -Name $pname)) { $critText = '是（界面名单命中）' }
        Add-LctGridRow -Grid $script:ProcGrid -Key $procId -Values @($procId, $pname, $puser, $psess, $pws, $ppath, $critText)
    }
    # 身份 + 计数 + 截断/隐藏提示（引擎 warnings 很有用：例如「默认隐藏会话 0 的 113 个进程」
    # 与「结果被 Limit 截断」——不显示的话用户会以为进程列表缺失）。
    $ident = Get-LctProp $pd 'identity' $null
    $identUser = [string](Get-LctField $ident @('user') '')
    if (-not $identUser) { $identUser = "$env:USERDOMAIN\$env:USERNAME" }
    $identTail = '(引擎未返回 identity)'
    if ($null -ne $ident) {
        $identTail = "已提权=$(Format-LctBoolCn (Get-LctField $ident @('elevated') $null))  完整性=$(Get-LctField $ident @('integrity') '—')  会话=$(Get-LctField $ident @('sessionId') '—')"
    }
    $procWarns = @(Get-LctWarningsDeep -Result $r)
    $infoLines = New-Object System.Collections.ArrayList
    $null = $infoLines.Add("当前身份：$identUser   （$identTail）")
    $null = $infoLines.Add("共 $(Get-LctField $pd @('count') $script:ProcGrid.Rows.Count) 个进程（匹配 $(Get-LctField $pd @('matched') $script:ProcGrid.Rows.Count)；截断=$(Format-LctBoolCn (Get-LctField $pd @('truncated') $null))；隐藏的会话 0 进程=$(Get-LctField $pd @('session0Hidden') '—')）")
    foreach ($w in @($procWarns)) { $null = $infoLines.Add('⚠ ' + [string]$w) }
    if ($null -ne $script:ProcInfoLabel) {
        $script:ProcInfoLabel.ForeColor = $script:C.Dim
        if (@($procWarns).Count -gt 0) { $script:ProcInfoLabel.ForeColor = $script:C.Warn }
        $script:ProcInfoLabel.Text = (@($infoLines) -join "`r`n")
    }
    if ($script:ProcGrid.Rows.Count -gt 0) { $script:ProcGrid.Rows[0].Selected = $true }
    $script:SuppressProcSel = $false
    Update-LctProcessDetail
}

function Update-LctProcessDetail {
    # 只读：process.detail（显示路径 / 能否 PROCESS_TERMINATE 的实测结论 / 是否疑似受保护）
    if ($null -eq $script:ProcDetailBox) { return }
    $sel = Get-LctSelectedProcess
    if ($sel.pid -le 0) {
        $script:ProcDetailBox.Text = "（请先在上面的进程列表里选中一行，再点「查看详情」调用 process.detail）`r`n`r`n当前选中：$($sel.name)$(if ($sel.name) { '（没有可用的 PID，无法调用 process.detail）' } else { '（无）' })"
        return
    }
    $r = Invoke-LctEngine -Verb 'process.detail' -Args @{ id = $sel.pid }
    $head = "目标进程      ：$($sel.name)  (PID $($sel.pid))"
    if (-not $r.ok -or $null -eq $r.data) {
        $errs = @(Get-LctArray $r.errors)
        if (@($errs).Count -eq 0) { $errs = @('引擎未返回 data（后端模块可能尚未就绪）') }
        $script:ProcDetailBox.Text = $head + "`r`n`r`nprocess.detail 调用失败：`r`n" + (@($errs) -join "`r`n")
        return
    }
    $d = Get-LctDataDeep -Result $r -KeyName 'pid'
    # 实测形状（backend-processes）：terminate.canTerminate / terminate.win32Error /
    # terminate.win32Message / terminate.conclusion；isCritical + criticalList；suspectedProtected。
    $term = Get-LctProp $d 'terminate' $null
    $lines = New-Object System.Collections.ArrayList
    $null = $lines.Add($head)
    $null = $lines.Add("映像路径      ：$(Get-LctField $d @('path', 'imagePath', 'executablePath') '—')")
    if ((Get-LctField $d @('path') '') -eq '' -and $null -ne (Get-LctField $d @('pathError') $null)) {
        $null = $lines.Add("路径读取错误  ：Win32 $(Get-LctField $d @('pathError') '') —— $(Get-LctField $d @('pathErrorText') '')")
    }
    $null = $lines.Add("命令行        ：$(Get-LctField $d @('commandLine') '—')")
    $null = $lines.Add("用户          ：$(Get-LctField $d @('user', 'userName', 'owner') '—')")
    $null = $lines.Add("会话 / 完整性 ：$(Get-LctField $d @('session', 'sessionId') '—') / $(Get-LctField $d @('integrity') '—')")
    $null = $lines.Add("内存(MB)      ：$(Get-LctField $d @('wsMB', 'memoryMB', 'ws') '—')")
    $null = $lines.Add("启动时间      ：$(Get-LctField $d @('startTime', 'startedAt') '—')")
    $critical = Get-LctField $d @('isCritical', 'critical', 'criticalProcess', 'inCriticalList') $null
    if ($null -eq $critical) { $critical = (Test-LctCriticalProcessName -Name $sel.name) }
    $critListText = ''
    $critList = @(Get-LctArray (Get-LctField $d @('criticalList') $null))
    if (@($critList).Count -gt 0) { $critListText = '（引擎名单：' + (@($critList) -join ', ') + '）' }
    $null = $lines.Add("关键/安全名单 ：$(Format-LctBoolCn $critical)$critListText")
    if ($null -ne $term) { $canT = Get-LctField $term @('canTerminate', 'canKill', 'allowed') $null }
    else { $canT = Get-LctField $d @('canTerminate', 'canKill', 'terminateAllowed') $null }
    $null = $lines.Add("能否终止(实测)：$(Format-LctCanKillCn $canT)")
    $concl = ''
    if ($null -ne $term) { $concl = [string](Get-LctField $term @('conclusion') '') }
    if ($concl) { $null = $lines.Add("终止结论      ：$concl") }
    $w32 = ''
    if ($null -ne $term) { $w32 = [string](Get-LctField $term @('win32Message') '') }
    if (-not $w32 -and $null -ne $term) {
        $we = Get-LctField $term @('win32Error') $null
        if ($null -ne $we) { $w32 = "Win32 错误码 $we" }
    }
    if (-not $w32) { $w32 = [string](Get-LctField $d @('terminateError', 'killError', 'openError', 'reason') '') }
    $null = $lines.Add("失败原因      ：$(if ($w32) { $w32 } else { '—（引擎未返回失败原因）' })")
    $null = $lines.Add("疑似受保护    ：$(Format-LctBoolCn (Get-LctField $d @('suspectedProtected', 'protected', 'isProtected', 'ppl') $null))")
    $null = $lines.Add("")
    $null = $lines.Add("—— process.detail 原始 JSON ——")
    try { $null = $lines.Add((ConvertTo-Json -InputObject $d -Depth 8)) }
    catch { $null = $lines.Add([string]$d) }
    $script:ProcDetailBox.Text = (@($lines) -join "`r`n")
}

function Update-LctWatchStatus {
    # 只读：process.watch.status + process.watch.log（看门狗状态与事件日志）
    if ($null -eq $script:WatchStatusBox) { return }
    $rs = Invoke-LctEngine -Verb 'process.watch.status'
    $rl = Invoke-LctEngine -Verb 'process.watch.log'
    $lines = New-Object System.Collections.ArrayList
    $null = $lines.Add('—— process.watch.status ——')
    if ($rs.ok -and $null -ne $rs.data) {
        # 实测形状（backend-processes）：running/hasInstance/invocationState/killCount/failureCount/
        # skipCount/targets[{name,path,pid,isCritical}]/logPath/identity/persistence
        $d = Get-LctDataDeep -Result $rs -KeyName 'running'
        $null = $lines.Add("运行中        ：$(Format-LctBoolCn (Get-LctField $d @('running', 'active', 'isRunning') $null))   调用状态=$(Get-LctField $d @('invocationState') '—')   有实例=$(Format-LctBoolCn (Get-LctField $d @('hasInstance') $null))")
        $tg = @(Get-LctArray (Get-LctField $d @('targets', 'target') @()))
        $tgText = @()
        foreach ($oneT in @($tg)) {
            if ($oneT -is [string]) { $tgText += $oneT; continue }
            $oneLine = [string](Get-LctField $oneT @('name') '')
            $onePath = [string](Get-LctField $oneT @('path') '')
            if ($onePath) { $oneLine = "$oneLine ($onePath)" }
            if ([bool](Get-LctField $oneT @('isCritical') $false)) { $oneLine += ' [关键名单]' }
            $tgText += $oneLine
        }
        if (@($tgText).Count -eq 0) { $tgText = @('（无）') }
        $null = $lines.Add("目标          ：$((@($tgText)) -join ' / ')")
        $null = $lines.Add("间隔 / 总时长 ：$(Get-LctField $d @('intervalSec', 'interval') '—')s / $(Get-LctField $d @('durationSec', 'duration') '—')s")
        $null = $lines.Add("已终止 / 失败 / 跳过：$(Get-LctField $d @('killCount', 'killed', 'kills') '—') / $(Get-LctField $d @('failureCount') '—') / $(Get-LctField $d @('skipCount') '—')")
        $null = $lines.Add("开始 / 结束   ：$(Get-LctField $d @('startedAt') '—') → $(Get-LctField $d @('endsAt', 'endTime', 'endedAt') '—')")
        $null = $lines.Add("最近事件      ：$(Get-LctField $d @('lastEvent') '—')  $(Get-LctField $d @('lastDetail') '')")
        $null = $lines.Add("日志文件      ：$(Get-LctField $d @('logPath') '—')")
        $null = $lines.Add("持久化        ：$(Get-LctField $d @('persistence') '—')（本工具不装服务、不注册自启、不隐藏）")
        try { $null = $lines.Add("原始 JSON     ：" + (ConvertTo-Json -InputObject $d -Depth 6 -Compress)) } catch { }
    } else {
        $null = $lines.Add('（status 调用失败：' + (@(Get-LctArray $rs.errors) -join ' / ') + '）')
    }
    $null = $lines.Add('')
    $null = $lines.Add('—— process.watch.log（事件日志）——')
    $ld = Get-LctDataDeep -Result $rl -KeyName 'returned'
    $logs = @(Get-LctArray (Get-LctProp $ld 'returned' @()))
    if (@($logs).Count -eq 0) { $logs = @(Get-LctArray $ld) }
    $null = $lines.Add("日志：$(Get-LctField $ld @('path') '—')   总 $(Get-LctField $ld @('total') '—') 条，本次返回 $(Get-LctField $ld @('count') '—') 条")
    $evCounts = Get-LctProp $ld 'counts' $null
    if ($null -ne $evCounts) {
        $null = $lines.Add("计数：killOk=$(Get-LctField $evCounts @('killOk') 0)  killFail=$(Get-LctField $evCounts @('killFail') 0)  identitySkip=$(Get-LctField $evCounts @('identitySkip') 0)  other=$(Get-LctField $evCounts @('other') 0)")
    }
    if (@($logs).Count -eq 0) { $null = $lines.Add('（暂无事件：还没启动过看门狗，或后端模块尚未就绪）') }
    foreach ($ev in @($logs | Select-Object -Last 40)) {
        if ($ev -is [string]) { $null = $lines.Add($ev); continue }
        $ts = [string](Get-LctField $ev @('ts', 'time', 'timestamp', 'at') '')
        $lv = [string](Get-LctField $ev @('event', 'level', 'kind', 'type') 'info')
        $ms = [string](Get-LctField $ev @('detail', 'message', 'msg', 'text') '')
        $tp = [string](Get-LctField $ev @('target') '')
        $pp = [string](Get-LctField $ev @('pid') '')
        $tail = $ms
        if ($tp) { $tail = "$tp$(if ($pp) { " (pid $pp)" })  $ms" }
        $null = $lines.Add('[' + $ts + '] ' + $lv + '  ' + $tail)
    }
    $script:WatchStatusBox.Text = (@($lines) -join "`r`n")
}

function Update-LctBlockList {
    # 只读：process.block.list（当前由本工具设置的 IFEO 重定向清单）
    # 实测形状：data = { items, count, byUsCount, foreignCount, ifeoPaths, identity }
    #           行 = { exeName, keyPath, debugger, byUs, reason, setAt, setBy, targetPath, view, hive, honored }
    if ($null -eq $script:BlockListGrid) { return }
    $r = Invoke-LctEngine -Verb 'process.block.list'
    Clear-LctGrid $script:BlockListGrid
    if (-not $r.ok) { return }
    $bd = Get-LctDataDeep -Result $r -KeyName 'items'
    $items = @(Get-LctArray (Get-LctProp $bd 'items' $null))
    if (@($items).Count -eq 0 -and $null -ne $bd) { $items = @(Get-LctArray $bd) }
    foreach ($b in @($items)) {
        $exe = [string](Get-LctField $b @('exeName', 'path', 'target', 'exe') '')
        $keyPath = [string](Get-LctField $b @('keyPath', 'path') '')
        if (-not $exe) { $exe = $keyPath }
        Add-LctGridRow -Grid $script:BlockListGrid -Key $exe -Values @(
            $exe,
            [string](Get-LctField $b @('debugger', 'redirect', 'value') ''),
            [string](Get-LctField $b @('reason', 'note') ''),
            [string](Get-LctField $b @('setAt', 'created', 'time', 'stamp') ''),
            (Format-LctBoolCn (Get-LctField $b @('byUs') $null)),
            $keyPath)
    }
    if ($script:BlockListGrid.Rows.Count -eq 0) {
        Add-LctGridRow -Grid $script:BlockListGrid -Key '' -Values @('（当前没有由本工具设置的重定向）', '', '', '', '', '')
    }
    if ($null -ne $script:BlockNoteLabel) {
        $null = $script:BlockNoteLabel.Text = "注册表已备份，可秒级回滚：写入前引擎会先 New-LctBackup 记录原值（或「原本不存在」），可在「备份与回滚」页还原，也可点「预览：回滚 → 应用回滚」直接恢复（含 Wow6432Node 视图）。  清单：本工具设置 $(Get-LctField $bd @('byUsCount') $script:BlockListGrid.Rows.Count) 项，第三方 $(Get-LctField $bd @('foreignCount') 0) 项（第三方项不会被本工具改动）。"
    }
}

function Get-LctWatchTargets {
    $out = @()
    if ($null -eq $script:WatchTargetBox) { return $out }
    foreach ($line in @([string]$script:WatchTargetBox.Text -split "`r?`n")) {
        foreach ($piece in @($line -split ',')) {
            $t = $piece.Trim()
            if ($t) { $out += $t }
        }
    }
    return @($out | Select-Object -Unique)
}

function New-LctPageProcesses {
    param($Body)
    $t = New-LctScrollPage -Body $Body -CanvasHeight 660
    $two = New-LctTable -Parent $t -ColSpec @('100p', '470a') -RowSpec @('100p') -Col 0 -Row 0

    # ---------------- 左：进程列表 ----------------
    $c1 = New-LctCard -Title '进程列表（process.list，只读快照；过滤在后端做）' -Parent $two -Col 0 -Row 0
    $l1 = New-LctTable -Parent $c1 -ColSpec @('100p') -RowSpec @('30a', '34a', '40a', '100p')
    $l1.Margin = New-Object System.Windows.Forms.Padding(10, 24, 6, 10)

    $fr = New-LctTable -Parent $l1 -ColSpec @('66a', '180a', '66a', '180a', '100p') -RowSpec @('28a') -Col 0 -Row 0
    $fr.Margin = New-Object System.Windows.Forms.Padding(0)
    $null = New-LctLabel -Text '名称过滤' -X 2 -Y 4 -W 62 -H 22 -Parent $fr -Col 0 -Row 0
    $script:ProcFilterName = New-LctText -X 0 -Y 0 -W 100 -H 24 -Parent $fr -Col 1 -Row 0
    $script:ProcFilterName.Dock = [System.Windows.Forms.DockStyle]::Fill
    $script:ProcFilterName.Margin = New-Object System.Windows.Forms.Padding(0, 3, 8, 3)
    $null = New-LctLabel -Text '用户过滤' -X 2 -Y 4 -W 62 -H 22 -Parent $fr -Col 2 -Row 0
    $script:ProcFilterUser = New-LctText -X 0 -Y 0 -W 100 -H 24 -Parent $fr -Col 3 -Row 0
    $script:ProcFilterUser.Dock = [System.Windows.Forms.DockStyle]::Fill
    $script:ProcFilterUser.Margin = New-Object System.Windows.Forms.Padding(0, 3, 8, 3)
    $script:ProcIncludeSystem = New-Object System.Windows.Forms.CheckBox
    $script:ProcIncludeSystem.Text = '包含系统/其它会话进程（需要更高权限才能看到路径）'
    $script:ProcIncludeSystem.ForeColor = $script:C.Text
    $script:ProcIncludeSystem.BackColor = [System.Drawing.Color]::Transparent
    $script:ProcIncludeSystem.Font = New-LctFont -Size 8
    $script:ProcIncludeSystem.Dock = [System.Windows.Forms.DockStyle]::Fill
    $script:ProcIncludeSystem.Margin = New-Object System.Windows.Forms.Padding(2, 4, 2, 2)
    $null = $fr.Controls.Add($script:ProcIncludeSystem, 4, 0)

    $br = New-LctTable -Parent $l1 -ColSpec @('124a', '124a', '100p') -RowSpec @('32a') -Col 0 -Row 1
    $br.Margin = New-Object System.Windows.Forms.Padding(0)
    $bRefresh = New-LctButton -Text '刷新进程列表' -W 100 -H 30 -Parent $br -Accent -Col 0 -Row 0
    $bRefresh.Dock = [System.Windows.Forms.DockStyle]::Fill
    $bRefresh.Margin = New-Object System.Windows.Forms.Padding(0, 2, 6, 2)
    $bDetail = New-LctButton -Text '查看选中进程详情' -W 100 -H 30 -Parent $br -Col 1 -Row 0
    $bDetail.Dock = [System.Windows.Forms.DockStyle]::Fill
    $bDetail.Margin = New-Object System.Windows.Forms.Padding(0, 2, 6, 2)
    $script:ProcInfoLabel = New-LctLabel -Text '（尚未刷新：点「刷新进程列表」调 process.list；这里会显示当前身份、进程数、被隐藏或被截断的提示）' -X 0 -Y 0 -W 100 -H 38 -Parent $l1 -Dim -Size 8 -Col 0 -Row 2
    $script:ProcInfoLabel.Dock = [System.Windows.Forms.DockStyle]::Fill
    $script:ProcInfoLabel.Margin = New-Object System.Windows.Forms.Padding(0, 2, 6, 2)

    $script:ProcGrid = New-LctGrid -Parent $l1 -Name 'processes' -Cols @(
        'pid|PID|64', 'name|名称|170', 'user|用户|150', 'session|会话|58',
        'wsMB|内存MB|76', 'path|路径|fill', 'critical|关键名单|104'
    )
    $l1.SetCellPosition($script:ProcGrid, (New-Object System.Windows.Forms.TableLayoutPanelCellPosition(0, 3)))

    $bRefresh.Add_Click({ param($s, $e) Update-LctProcesses })
    $bDetail.Add_Click({ param($s, $e) Update-LctProcessDetail })
    $script:ProcGrid.Add_SelectionChanged({
        param($s, $e)
        if ($script:SuppressProcSel) { return }
        $script:SuppressProcSel = $true
        try { Update-LctProcessDetail } finally { $script:SuppressProcSel = $false }
    })

    # ---------------- 右：详情 / 终止 / 看门狗 / IFEO ----------------
    $right = New-LctTable -Parent $two -ColSpec @('100p') -RowSpec @('192a', '266a', '156a', '44a') -Col 1 -Row 0

    # --- 详情 + 终止 ---
    $c2 = New-LctCard -Title '选中进程详情（process.detail）与终止（process.kill）' -Parent $right -Col 0 -Row 0
    $i2 = New-LctTable -Parent $c2 -ColSpec @('100p', '104a', '104a') -RowSpec @('100p', '32a', '24a', '40a')
    $i2.Margin = New-Object System.Windows.Forms.Padding(10, 24, 10, 8)
    $script:ProcDetailBox = New-LctText -X 0 -Y 0 -W 100 -H 100 -Parent $i2 -Multiline -ReadOnly -Mono -Dark -Col 0 -Row 0
    $script:ProcDetailBox.Dock = [System.Windows.Forms.DockStyle]::Fill
    $script:ProcDetailBox.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 4)
    $i2.SetColumnSpan($script:ProcDetailBox, 3)
    $bKillPrev = New-LctButton -Text '① 预览：终止' -W 100 -H 28 -Parent $i2 -Col 1 -Row 1
    $bKillPrev.Dock = [System.Windows.Forms.DockStyle]::Fill
    $bKillPrev.Margin = New-Object System.Windows.Forms.Padding(4, 2, 2, 2)
    $bKillApply = New-LctButton -Text '② 应用终止' -W 100 -H 28 -Parent $i2 -Warn -Col 2 -Row 1
    $bKillApply.Dock = [System.Windows.Forms.DockStyle]::Fill
    $bKillApply.Margin = New-Object System.Windows.Forms.Padding(2, 2, 0, 2)
    $script:ProcKillState = New-LctLabel -Text '终止预览状态：未预览' -X 0 -Y 0 -W 100 -H 22 -Parent $i2 -Color $script:C.Dim -Size 8 -Col 0 -Row 2
    $script:ProcKillState.Dock = [System.Windows.Forms.DockStyle]::Fill
    $i2.SetColumnSpan($script:ProcKillState, 3)
    $killWarn = New-LctLabel -Text '风险说明：终止关键进程可能导致蓝屏、掉网、登录会话中断、杀软/安全组件失效；受保护进程（PPL）与核心服务在用户态永远杀不掉，引擎会如实返回 OpenProcess(PROCESS_TERMINATE) 的失败原因。关键/安全软件目标（契约 §11.2 名单）必须显式确认并使用 override。' -X 0 -Y 0 -W 100 -H 38 -Parent $i2 -Color $script:C.Warn -Size 8 -Col 0 -Row 3
    $killWarn.Dock = [System.Windows.Forms.DockStyle]::Fill
    $i2.SetColumnSpan($killWarn, 3)
    # 供验收脚本按真实点击路径驱动（PerformClick）
    $script:ProcKillPreviewBtn = $bKillPrev
    $script:ProcKillApplyBtn = $bKillApply

    $bKillPrev.Add_Click({
        param($s, $e)
        $sel = Get-LctSelectedProcess
        if ($sel.pid -le 0) {
            $null = [System.Windows.Forms.MessageBox]::Show('请先在左侧进程列表里选中一个进程（需要 PID 才能调 process.kill）。', '未选中进程', 'OK', 'Warning')
            return
        }
        $isCritical = ($sel.critical -or (Test-LctCriticalProcessName -Name $sel.name))
        $useOverride = $false
        if ($isCritical) {
            $msg = "⚠ 这是关键 / 安全软件目标，需显式确认（override）。`r`n`r`n目标：$($sel.name)  (PID $($sel.pid))`r`n路径：$($sel.path)`r`n`r`n后果：终止关键进程可能导致蓝屏、掉网、登录会话中断、杀软/安全组件失效；`r`n受保护进程（PPL）与核心服务在用户态永远杀不掉，引擎会如实返回失败原因。`r`n`r`n这一步只生成【预览】，不会真的终止任何进程。`r`n`r`n确定要带上 override 并对该目标生成预览吗？"
            $dr = [System.Windows.Forms.MessageBox]::Show($msg, '关键 / 安全软件目标：需要 override',
                [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Warning,
                [System.Windows.Forms.MessageBoxDefaultButton]::Button2)
            if ($dr -ne [System.Windows.Forms.DialogResult]::Yes) {
                Add-LctLogLine '  ℹ 用户取消了对关键目标的终止预览（未登记待应用）' $script:C.Dim
                return
            }
            $useOverride = $true
        }
        $killId = "kill:$($sel.pid)"
        # 身份复核：**只传 id + path，不传 name**（Lead 复核后的口径）。
        #   · 不传 name：同名进程有多个时（例如多份 ping.exe），引擎的身份复核会判定「目标不唯一」而拒绝；
        #     界面选中的是表格里的那一行，不该拿模糊目标去撞引擎的保护逻辑。
        #   · 传 path：堵住「预览 → 用户点应用」之间那几秒的 **PID 复用窗口** —— 引擎按路径复核，
        #     同 PID 但路径不符会被拒绝。path 为空（权限不足 / 已退出）时降级为只传 id，并在结果里如实标注。
        $tPath = [string]$sel.path
        $killArgs = @{ id = $sel.pid; override = $useOverride }
        if ($tPath) { $killArgs['path'] = $tPath }
        $summary = "终止进程 $($sel.name) (PID $($sel.pid))"
        if ($tPath) { $summary += "  路径复核：$tPath" } else { $summary += '  ［未能取得路径：身份复核降级为仅 PID］' }
        if ($useOverride) { $summary += '  [override：关键/安全软件目标]' }
        $r = Invoke-LctPreview -Page 'processes' -Id $killId -Verb 'process.kill' -Args $killArgs -Summary $summary
        $pathNote = ''
        if (-not $tPath) { $pathNote = '  ⚠ 未能取得该进程路径（权限不足或进程已退出）：身份复核降级为仅 PID。' }
        if ($r.ok) {
            $script:ProcKillState.Text = "【$($script:PREVIEW_BANNER)】$($sel.name) (PID $($sel.pid))$(if ($tPath) { "  [路径复核 $tPath]" } else { '  [身份复核降级：无路径]' }) → " + (Format-LctChangeBrief -Result $r) + $pathNote
            $script:ProcKillState.ForeColor = $(if ($tPath) { $script:C.Warn } else { $script:C.Err })
        } else {
            $script:ProcKillState.Text = '预览失败（未登记待应用）：' + (@(Get-LctArray $r.errors) -join ' / ') + $pathNote
            $script:ProcKillState.ForeColor = $script:C.Err
        }
    })

    $bKillApply.Add_Click({
        param($s, $e)
        $sel = Get-LctSelectedProcess
        if ($sel.pid -le 0) {
            $null = [System.Windows.Forms.MessageBox]::Show('请先在左侧进程列表里选中一个进程。', '未选中进程', 'OK', 'Warning')
            return
        }
        $killId = "kill:$($sel.pid)"
        if (@(Get-LctPending -Page 'processes' -Id $killId).Count -eq 0) {
            $null = [System.Windows.Forms.MessageBox]::Show(
                "必须先预览。`r`n请先点「① 预览：终止」，确认日志面板里的目标与 before/after 无误（且标着「$($script:PREVIEW_BANNER)」），再点这里应用。",
                '需要先预览', 'OK', 'Warning')
            return
        }
        if ($sel.critical -or (Test-LctCriticalProcessName -Name $sel.name)) {
            $msg = "⚠ 这是关键 / 安全软件目标（override 生效）。`r`n`r`n即将真实终止：$($sel.name)  (PID $($sel.pid))`r`n后果：可能导致蓝屏、掉网、登录会话中断、杀软/安全组件失效。`r`n`r`n下一步还会再弹一次二次确认。确定继续吗？"
            $dr = [System.Windows.Forms.MessageBox]::Show($msg, '关键 / 安全软件目标：再次确认',
                [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Warning,
                [System.Windows.Forms.MessageBoxDefaultButton]::Button2)
            if ($dr -ne [System.Windows.Forms.DialogResult]::Yes) {
                Add-LctLogLine '  ℹ 用户在对关键目标的二次确认处取消（未落盘）' $script:C.Dim
                return
            }
        }
        Invoke-LctApplyPending -Page 'processes' -Id $killId
    })

    # --- 看门狗 ---
    $c3 = New-LctCard -Title '会话内看门狗：仅在本次工具运行期间有效，关闭即停，不写任何自启动 / 服务（process.watch.*）' -Parent $right -Col 0 -Row 1
    $i3 = New-LctTable -Parent $c3 -ColSpec @('100p') -RowSpec @('36a', '48a', '32a', '32a', '100p')
    $i3.Margin = New-Object System.Windows.Forms.Padding(10, 24, 10, 8)
    $wNote = New-LctLabel -Text '目标（name 或完整路径；可多行 / 逗号分隔。必须显式指定目标，禁止通配与「杀全部」）。看门狗活在「引擎调用进程」内：不装服务、不注册自启、不隐藏，进程退出即停。' -X 0 -Y 0 -W 100 -H 34 -Parent $i3 -Dim -Size 8 -Col 0 -Row 0
    $wNote.Dock = [System.Windows.Forms.DockStyle]::Fill
    $script:WatchTargetBox = New-LctText -X 0 -Y 0 -W 100 -H 44 -Parent $i3 -Multiline -Mono -Dark -Col 0 -Row 1
    $script:WatchTargetBox.Dock = [System.Windows.Forms.DockStyle]::Fill
    $script:WatchTargetBox.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 4)

    $w1 = New-LctTable -Parent $i3 -ColSpec @('54a', '60a', '54a', '60a', '112a', '112a', '100p') -RowSpec @('30a') -Col 0 -Row 2
    $w1.Margin = New-Object System.Windows.Forms.Padding(0)
    $null = New-LctLabel -Text '间隔(秒)' -X 2 -Y 6 -W 50 -H 20 -Parent $w1 -Size 8 -Col 0 -Row 0
    $script:WatchInterval = New-Object System.Windows.Forms.NumericUpDown
    $script:WatchInterval.Minimum = 1
    $script:WatchInterval.Maximum = 3600
    $script:WatchInterval.Value = 2
    $script:WatchInterval.BackColor = $script:C.Panel2
    $script:WatchInterval.ForeColor = $script:C.Text
    $script:WatchInterval.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
    $script:WatchInterval.Dock = [System.Windows.Forms.DockStyle]::Fill
    $script:WatchInterval.Margin = New-Object System.Windows.Forms.Padding(0, 3, 6, 3)
    $null = $w1.Controls.Add($script:WatchInterval, 1, 0)
    $null = New-LctLabel -Text '时长(秒)' -X 2 -Y 6 -W 50 -H 20 -Parent $w1 -Size 8 -Col 2 -Row 0
    $script:WatchDuration = New-Object System.Windows.Forms.NumericUpDown
    $script:WatchDuration.Minimum = 1
    $script:WatchDuration.Maximum = 3600
    $script:WatchDuration.Value = 300
    $script:WatchDuration.BackColor = $script:C.Panel2
    $script:WatchDuration.ForeColor = $script:C.Text
    $script:WatchDuration.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
    $script:WatchDuration.Dock = [System.Windows.Forms.DockStyle]::Fill
    $script:WatchDuration.Margin = New-Object System.Windows.Forms.Padding(0, 3, 6, 3)
    $null = $w1.Controls.Add($script:WatchDuration, 3, 0)
    $bWPrev = New-LctButton -Text '① 预览：启动' -W 100 -H 28 -Parent $w1 -Accent -Col 4 -Row 0
    $bWPrev.Dock = [System.Windows.Forms.DockStyle]::Fill
    $bWPrev.Margin = New-Object System.Windows.Forms.Padding(0, 1, 6, 1)
    $bWApply = New-LctButton -Text '② 应用：启动' -W 100 -H 28 -Parent $w1 -Warn -Col 5 -Row 0
    $bWApply.Dock = [System.Windows.Forms.DockStyle]::Fill
    $bWApply.Margin = New-Object System.Windows.Forms.Padding(0, 1, 2, 1)

    $w2 = New-LctTable -Parent $i3 -ColSpec @('112a', '112a', '140a', '100p') -RowSpec @('30a') -Col 0 -Row 3
    $w2.Margin = New-Object System.Windows.Forms.Padding(0)
    $bWStopPrev = New-LctButton -Text '预览：停止' -W 100 -H 28 -Parent $w2 -Col 0 -Row 0
    $bWStopPrev.Dock = [System.Windows.Forms.DockStyle]::Fill
    $bWStopPrev.Margin = New-Object System.Windows.Forms.Padding(0, 1, 6, 1)
    $bWStopApply = New-LctButton -Text '应用：停止' -W 100 -H 28 -Parent $w2 -Col 1 -Row 0
    $bWStopApply.Dock = [System.Windows.Forms.DockStyle]::Fill
    $bWStopApply.Margin = New-Object System.Windows.Forms.Padding(0, 1, 6, 1)
    $bWStatus = New-LctButton -Text '刷新状态与事件日志' -W 100 -H 28 -Parent $w2 -Col 2 -Row 0
    $bWStatus.Dock = [System.Windows.Forms.DockStyle]::Fill
    $bWStatus.Margin = New-Object System.Windows.Forms.Padding(0, 1, 2, 1)

    $script:WatchStatusBox = New-LctText -X 0 -Y 0 -W 100 -H 100 -Parent $i3 -Multiline -ReadOnly -Mono -Dark -Col 0 -Row 4
    $script:WatchStatusBox.Dock = [System.Windows.Forms.DockStyle]::Fill

    $bWPrev.Add_Click({
        param($s, $e)
        $tg = @(Get-LctWatchTargets)
        if (@($tg).Count -eq 0) {
            $null = [System.Windows.Forms.MessageBox]::Show('请先填写看门狗目标（进程名或完整路径，每行一个）。禁止留空或使用通配。', '参数不足', 'OK', 'Warning')
            return
        }
        foreach ($one in @($tg)) {
            if ($one -match '[\*\?]' ) {
                $null = [System.Windows.Forms.MessageBox]::Show("目标不允许通配：$one`r`n必须显式指定进程名或完整路径（契约 §11.2 铁律 2）。", '非法目标', 'OK', 'Warning')
                return
            }
        }
        $iv = [int]$script:WatchInterval.Value
        $du = [int]$script:WatchDuration.Value
        $r = Invoke-LctPreview -Page 'processes' -Id 'watch:start' -Verb 'process.watch.start' `
            -Args @{ targets = @($tg); intervalSec = $iv; durationSec = $du } `
            -Summary "启动看门狗（目标 $((@($tg)) -join ', ')；间隔 ${iv}s；时长 ${du}s）" -TimeoutSec 120
        if ($r.ok) {
            $script:WatchStatusBox.ForeColor = $script:C.Warn
            $script:WatchStatusBox.Text = "【$($script:PREVIEW_BANNER)】看门狗已通过预览、登记为待应用。`r`n目标：$((@($tg)) -join ', ')`r`n间隔：${iv}s   时长：${du}s`r`n说明：看门狗只在本次工具运行期间有效，关闭即停，不写任何自启动 / 服务。`r`n再点「② 应用：启动」并二次确认后才会真正开始循环。"
        } else {
            $script:WatchStatusBox.ForeColor = $script:C.Err
            $script:WatchStatusBox.Text = '预览失败（未登记待应用）：' + (@(Get-LctArray $r.errors) -join ' / ')
        }
    })
    $bWApply.Add_Click({
        param($s, $e)
        if (@(Get-LctPending -Page 'processes' -Id 'watch:start').Count -eq 0) {
            $null = [System.Windows.Forms.MessageBox]::Show('必须先点「① 预览：启动」并通过预览，才能应用。', '需要先预览', 'OK', 'Warning')
            return
        }
        Invoke-LctApplyPending -Page 'processes' -Id 'watch:start'
        Update-LctWatchStatus
    })
    $bWStopPrev.Add_Click({
        param($s, $e)
        $null = Invoke-LctPreview -Page 'processes' -Id 'watch:stop' -Verb 'process.watch.stop' -Summary '停止看门狗（会话内循环）' -TimeoutSec 60
    })
    $bWStopApply.Add_Click({
        param($s, $e)
        if (@(Get-LctPending -Page 'processes' -Id 'watch:stop').Count -eq 0) {
            $null = [System.Windows.Forms.MessageBox]::Show('必须先点「预览：停止」并通过预览，才能应用。', '需要先预览', 'OK', 'Warning')
            return
        }
        Invoke-LctApplyPending -Page 'processes' -Id 'watch:stop'
        Update-LctWatchStatus
    })
    $bWStatus.Add_Click({ param($s, $e) Update-LctWatchStatus })
    $script:ProcWatchPreviewBtn = $bWPrev
    $script:ProcWatchApplyBtn = $bWApply
    $script:ProcWatchStopPreviewBtn = $bWStopPrev
    $script:ProcWatchStopApplyBtn = $bWStopApply

    # --- IFEO 阻断 ---
    $c4 = New-LctCard -Title '让选定程序无法启动：IFEO 重定向（process.block.set / process.block.remove）' -Parent $right -Col 0 -Row 2
    $i4 = New-LctTable -Parent $c4 -ColSpec @('100p') -RowSpec @('28a', '28a', '32a', '28a', '100p')
    $i4.Margin = New-Object System.Windows.Forms.Padding(10, 24, 10, 8)
    $script:BlockPathBox = New-LctFormRow -Parent $i4 -Row 0 -Label '目标程序' -LabelW 70 -H 28
    $script:BlockPathBox.Text = 'C:\Windows\System32\notepad.exe'
    $script:BlockReasonBox = New-LctFormRow -Parent $i4 -Row 1 -Label '原因' -LabelW 70 -H 28
    $script:BlockReasonBox.Text = 'ui-expansion: IFEO 阻断测试/滥用防护'

    $be = New-LctTable -Parent $i4 -ColSpec @('104a', '104a', '104a', '104a', '100p') -RowSpec @('30a') -Col 0 -Row 2
    $be.Margin = New-Object System.Windows.Forms.Padding(0)
    $bBkPrev = New-LctButton -Text '① 预览：阻止' -W 100 -H 28 -Parent $be -Col 0 -Row 0
    $bBkPrev.Dock = [System.Windows.Forms.DockStyle]::Fill
    $bBkPrev.Margin = New-Object System.Windows.Forms.Padding(0, 1, 4, 1)
    $bBkApply = New-LctButton -Text '② 应用阻止' -W 100 -H 28 -Parent $be -Warn -Col 1 -Row 0
    $bBkApply.Dock = [System.Windows.Forms.DockStyle]::Fill
    $bBkApply.Margin = New-Object System.Windows.Forms.Padding(0, 1, 4, 1)
    $bUnPrev = New-LctButton -Text '预览：回滚' -W 100 -H 28 -Parent $be -Col 2 -Row 0
    $bUnPrev.Dock = [System.Windows.Forms.DockStyle]::Fill
    $bUnPrev.Margin = New-Object System.Windows.Forms.Padding(0, 1, 4, 1)
    $bUnApply = New-LctButton -Text '应用回滚' -W 100 -H 28 -Parent $be -Col 3 -Row 0
    $bUnApply.Dock = [System.Windows.Forms.DockStyle]::Fill
    $bUnApply.Margin = New-Object System.Windows.Forms.Padding(0, 1, 2, 1)
    $bBkList = New-LctButton -Text '刷新重定向清单' -W 100 -H 28 -Parent $be -Col 4 -Row 0
    $bBkList.Dock = [System.Windows.Forms.DockStyle]::Fill
    $bBkList.Margin = New-Object System.Windows.Forms.Padding(0, 1, 2, 1)

    $script:BlockNoteLabel = New-LctLabel -Text '注册表已备份，可秒级回滚：写入前引擎会先 New-LctBackup 记录原值（或「原本不存在」），可在「备份与回滚」页还原，也可点「预览：回滚 → 应用回滚」直接恢复（含 Wow6432Node 视图）。' -X 0 -Y 0 -W 100 -H 26 -Parent $i4 -Color $script:C.Ok -Size 8 -Col 0 -Row 3
    $script:BlockNoteLabel.Dock = [System.Windows.Forms.DockStyle]::Fill

    $script:BlockListGrid = New-LctGrid -Parent $i4 -Name 'ifeo' -Cols @(
        'exe|被阻止的程序|fill', 'debugger|重定向到|140', 'reason|原因|110', 'setAt|设置时间|110',
        'byUs|本工具设置|74', 'keyPath|IFEO 键路径|fill'
    )
    $i4.SetCellPosition($script:BlockListGrid, (New-Object System.Windows.Forms.TableLayoutPanelCellPosition(0, 4)))

    $bBkPrev.Add_Click({
        param($s, $e)
        $p = [string]$script:BlockPathBox.Text.Trim()
        if (-not $p) {
            $null = [System.Windows.Forms.MessageBox]::Show('请填写要阻止的程序（完整 exe 路径或纯文件名）。', '参数不足', 'OK', 'Warning')
            return
        }
        $rsn = [string]$script:BlockReasonBox.Text.Trim()
        $r = Invoke-LctPreview -Page 'processes' -Id "block:set:$p" -Verb 'process.block.set' `
            -Args @{ path = $p; reason = $rsn } -Summary "IFEO 重定向：让「$p」无法启动（写注册表前会先备份）"
        $script:ProcKillState.Text = "【$($script:PREVIEW_BANNER)】IFEO $p → " + (Format-LctChangeBrief -Result $r)
        $script:ProcKillState.ForeColor = $(if ($r.ok) { $script:C.Warn } else { $script:C.Err })
    })
    $bBkApply.Add_Click({
        param($s, $e)
        $p = [string]$script:BlockPathBox.Text.Trim()
        if (-not $p) { return }
        if (@(Get-LctPending -Page 'processes' -Id "block:set:$p").Count -eq 0) {
            $null = [System.Windows.Forms.MessageBox]::Show('必须先点「① 预览：阻止」并通过预览（确认它标着「' + $script:PREVIEW_BANNER + '」），才能应用。', '需要先预览', 'OK', 'Warning')
            return
        }
        Invoke-LctApplyPending -Page 'processes' -Id "block:set:$p"
        Update-LctBlockList
    })
    $bUnPrev.Add_Click({
        param($s, $e)
        $p = [string]$script:BlockPathBox.Text.Trim()
        if (-not $p) {
            $null = [System.Windows.Forms.MessageBox]::Show('请填写要恢复的程序（完整 exe 路径或纯文件名）。', '参数不足', 'OK', 'Warning')
            return
        }
        $null = Invoke-LctPreview -Page 'processes' -Id "block:remove:$p" -Verb 'process.block.remove' `
            -Args @{ path = $p } -Summary "回滚 IFEO 重定向：恢复「$p」可启动"
    })
    $bUnApply.Add_Click({
        param($s, $e)
        $p = [string]$script:BlockPathBox.Text.Trim()
        if (-not $p) { return }
        if (@(Get-LctPending -Page 'processes' -Id "block:remove:$p").Count -eq 0) {
            $null = [System.Windows.Forms.MessageBox]::Show('必须先点「预览：回滚」并通过预览，才能应用。', '需要先预览', 'OK', 'Warning')
            return
        }
        Invoke-LctApplyPending -Page 'processes' -Id "block:remove:$p"
        Update-LctBlockList
    })
    $bBkList.Add_Click({ param($s, $e) Update-LctBlockList })
    $script:BlockPreviewBtn = $bBkPrev
    $script:BlockApplyBtn = $bBkApply
    $script:UnblockPreviewBtn = $bUnPrev
    $script:UnblockApplyBtn = $bUnApply

    $null = New-LctPendingStrip -Parent $right -Col 0 -Row 3 -PageKey 'processes'

    # 兼容别名：Lead 的 UiPageSmoke 可能按名字取变量（两个名字都指向同一控件）
    $script:ProcessGrid = $script:ProcGrid
    $script:ProcessDetailBox = $script:ProcDetailBox
    return $two
}

# ---------------------------------------------------------------------------
# 八、WDAC 黑名单（wdac）：状态 / 规则 / 策略生成 / 安全校验 / 部署 / 重启后校验
#   后端 core\Wdac.psm1 由 backend-wdac 实现（契约 §11.3）。审计优先：
#   audit 部署手输 I-UNDERSTAND-AUDIT，enforce 部署手输 I-UNDERSTAND-ENFORCE。
# ---------------------------------------------------------------------------

function Get-LctWdacExpectConfirmText {
    param([string]$Mode = 'audit')
    if ($Mode -eq 'enforce') { return $script:WdacConfirmEnforce }
    return $script:WdacConfirmAudit
}

function Read-LctConfirmTextDialog {
    <#
      手输确认文本对话框（部署闸门）：MessageBox 不能输入文本，所以这里弹一个小窗体，
      用户必须精确输入 expect 文本；取消 / 输错一律拒绝（返回空串）。
    #>
    param([string]$Title = '手输确认文本', [string]$Prompt = '', [string]$Expect = '')
    $f = New-Object System.Windows.Forms.Form
    $f.Text = $Title
    $f.BackColor = $script:C.Bg
    $f.ForeColor = $script:C.Text
    $f.Font = New-LctFont -Size 9
    $f.ClientSize = New-Object System.Drawing.Size(660, 260)
    $f.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
    $f.MaximizeBox = $false
    $f.MinimizeBox = $false
    $f.ShowInTaskbar = $false
    if ($null -ne $script:MainForm) { $f.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterParent }
    else { $f.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen }

    $txt = '必须精确输入下面这行文本（区分大小写），否则部署会被拒绝：' + "`r`n`r`n    " + $Expect + "`r`n`r`n" + $Prompt
    $null = New-LctLabel -Text $txt -X 14 -Y 12 -W 632 -H 168 -Parent $f -Color $script:C.Warn -Size 9
    $tb = New-LctText -X 14 -Y 190 -W 632 -H 26 -Parent $f -Mono
    $ok = New-LctButton -Text '确定（校验确认文本）' -X 380 -Y 222 -W 180 -H 30 -Parent $f -Warn
    $cancel = New-LctButton -Text '取消（拒绝部署）' -X 566 -Y 222 -W 80 -H 30 -Parent $f
    $f.AcceptButton = $ok
    $f.CancelButton = $cancel
    $ok.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $cancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $dr = $f.ShowDialog()
    $typed = ''
    try { $typed = [string]$tb.Text } catch { }
    try { $f.Dispose() } catch { }
    if ($dr -ne [System.Windows.Forms.DialogResult]::OK) { return '' }
    return $typed
}

function Format-LctPolicyList {
    param($Value)
    $items = @(Get-LctArray $Value)
    if (@($items).Count -eq 0) { return '（无可用策略 / 引擎未返回）' }
    $out = @()
    foreach ($it in @($items)) {
        if ($it -is [string]) { $out += $it; continue }
        $p = [string](Get-LctField $it @('path', 'name', 'id', 'policyId') '')
        $e = [string](Get-LctField $it @('enforced', 'active', 'enabled') '')
        if ($p) {
            if ($e) { $out += "$p（enforced=$e）" } else { $out += $p }
        } else {
            try { $out += (ConvertTo-Json -InputObject $it -Depth 4 -Compress) } catch { $out += '(无法显示)' }
        }
    }
    if (@($out).Count -eq 0) { return '（无）' }
    return (@($out) -join ' ; ')
}

function Invoke-LctWdacBuildPreview {
    param([string]$Mode = 'audit')
    if ($null -eq $script:WdacPolicyBox) { return }
    $sp = ''
    if ($null -ne $script:WdacScanPathBox) { $sp = [string]$script:WdacScanPathBox.Text.Trim() }
    if (-not $sp) {
        $null = [System.Windows.Forms.MessageBox]::Show(
            "扫描目录（-ScanPath）必填，否则引擎会直接拒绝 —— 契约 §11.3 铁律 4：不给 -ScanPath 时 New-CIPolicy 会做全盘 + 卷影扫描，跑很久且产出巨大 XML。`r`n`r`n请先填一个具体目录（例如待测程序所在目录）。",
            '缺少扫描目录', 'OK', 'Warning')
        return
    }
    if (-not (Test-Path -LiteralPath $sp)) {
        $null = [System.Windows.Forms.MessageBox]::Show("扫描目录不存在：$sp", '目录不存在', 'OK', 'Warning')
        return
    }
    if ($Mode -eq 'enforce') {
        $dr = [System.Windows.Forms.MessageBox]::Show(
            "⚠ 你选的是【强制模式 enforce】。`r`n`r`n强制模式会移除 Enabled:Audit Mode：策略一旦部署并重启，没有命中 allow 规则的程序会被拦下（可能包括你自己的工具）。`r`n正确路线：先 audit 部署 → 重启后用「重启后校验」确认「可安全转强制」→ 再转 enforce。`r`n`r`n这一步只生成策略（预览，不部署）。继续吗？",
            '强制模式：二次确认', [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Warning, [System.Windows.Forms.MessageBoxDefaultButton]::Button2)
        if ($dr -ne [System.Windows.Forms.DialogResult]::Yes) {
            Add-LctLogLine '  ℹ 用户取消了强制模式策略生成' $script:C.Dim
            return
        }
    }
    $r = Invoke-LctPreview -Page 'wdac' -Id "policy:build:$Mode" -Verb 'wdac.policy.build' `
        -Args @{ mode = $Mode; scanPath = $sp } -Summary "生成 WDAC 策略（$Mode 模式；扫描 $sp）" -TimeoutSec 600

    $lines = New-Object System.Collections.ArrayList
    $null = $lines.Add("生成模式        ：$Mode$(if ($Mode -eq 'audit') { '（审计：保留 Enabled:Audit Mode，只记录不拦）' } else { '（强制：会真的拦程序）' })")
    $null = $lines.Add("扫描目录        ：$sp")
    if ($r.ok -and $null -ne $r.data) {
        $d = Get-LctDataDeep -Result $r -KeyName 'stagingDir'
        $stg = [string](Get-LctField $d @('stagingDir', 'staging', 'outputDir', 'dir') '')
        $xml = [string](Get-LctField $d @('xmlPath', 'xml', 'policyXml') '')
        $cip = [string](Get-LctField $d @('cipPath', 'cip', 'binaryPath', 'policyPath') '')
        $null = $lines.Add("staging 产物目录：$(if ($stg) { $stg } else { '<工具根>\var\wdac\staging\' })")
        $null = $lines.Add("策略 XML        ：$(if ($xml) { $xml } else { '（未返回）' })")
        $null = $lines.Add("策略 CIP        ：$(if ($cip) { $cip } else { '（未返回）' })")
        $null = $lines.Add("allow 机制      ：$(Format-LctBoolCn (Get-LctField $d @('hasAllowMechanism') $null))   可审计部署=$(Format-LctBoolCn (Get-LctField $d @('canDeployAudit') $null))   可强制部署=$(Format-LctBoolCn (Get-LctField $d @('canDeployEnforce') $null))")
        $null = $lines.Add("是否需要重启    ：$(Format-LctBoolCn (Get-LctField $d @('needRestart') $null))   $(Get-LctField $d @('restartText') '')")
        foreach ($eb in @(Get-LctArray (Get-LctField $d @('enforceBlockers') $null))) { $null = $lines.Add('  强制部署拦路石：' + [string]$eb) }
        foreach ($op in @(Get-LctArray (Get-LctField $d @('options') $null))) { $null = $lines.Add('  规则选项：' + [string]$op) }
        if ($xml -and $null -ne $script:WdacXmlBox) { $script:WdacXmlBox.Text = $xml }
        $null = $lines.Add("")
        $null = $lines.Add("—— wdac.policy.build 原始 JSON ——")
        try { $null = $lines.Add((ConvertTo-Json -InputObject $d -Depth 8)) } catch { $null = $lines.Add([string]$d) }
        $null = $lines.Add("")
        $null = $lines.Add("状态：【$($script:PREVIEW_BANNER)】—— 这一步只生成 staging 产物，没有写任何系统策略。")
    } else {
        $null = $lines.Add('生成失败：' + (@(Get-LctArray $r.errors) -join ' / '))
    }
    $script:WdacPolicyBox.ForeColor = $(if ($r.ok) { $script:C.Warn } else { $script:C.Err })
    $script:WdacPolicyBox.Text = (@($lines) -join "`r`n")
    $script:WdacLastPolicyText = (@($lines) -join "`r`n")
}

function Invoke-LctWdacDeployPreview {
    param([string]$Mode = 'audit')
    if ($null -eq $script:WdacDeployBox) { return }
    $xml = ''
    if ($null -ne $script:WdacXmlBox) { $xml = [string]$script:WdacXmlBox.Text.Trim() }
    if (-not $xml) {
        $null = [System.Windows.Forms.MessageBox]::Show('请先填「策略 XML」路径（可用「生成策略」自动填入，或点「浏览 XML…」选一个）。', '缺少策略 XML', 'OK', 'Warning')
        return
    }
    if ($Mode -eq 'enforce') {
        # 强制部署前，先在界面上过一遍引擎自己的安全门（判定仍由引擎做，前端只做事前拦截，
        # 与契约 §11.3 铁律 2「无法证明安全就不许强制」一致）。
        $vr0 = Invoke-LctEngine -Verb 'wdac.policy.validate' -Args @{ xmlPath = $xml }
        $v0 = Get-LctProp $vr0 'data' $null
        $v0Errs = @(Get-LctArray $vr0.errors)
        if ($null -ne $v0) { $v0Errs += @(Get-LctArray (Get-LctProp $v0 'errors' @())) }
        $canEnf = Get-LctField $v0 @('canDeployEnforce') $null
        if (@($v0Errs).Count -gt 0 -or (Format-LctBoolCn $canEnf) -eq '否') {
            $msg = "强制部署被安全门拦下（wdac.policy.validate 未通过）：`r`n`r`n" + (@($v0Errs) -join "`r`n")
            foreach ($eb0 in @(Get-LctArray (Get-LctField $v0 @('enforceBlockers') $null))) { $msg += "`r`n· " + [string]$eb0 }
            foreach ($ch0 in @(Get-LctArray (Get-LctField $v0 @('criticalHits') $null))) { $msg += "`r`n· 命中系统关键目录：" + [string]$ch0 }
            $msg += "`r`n`r`n契约 §11.3 铁律 2：无法证明安全就不许强制。正确路线：先用审计模式部署 → 重启 → 点「重启后校验」确认「可安全转强制」→ 再转强制。"
            $null = [System.Windows.Forms.MessageBox]::Show($msg, '强制部署被拒绝', 'OK', 'Error')
            Add-LctLogLine '  ✖ 强制部署被界面安全门拒绝（未生成预览、未落盘）' $script:C.Err
            return
        }
    }
    $expect = Get-LctWdacExpectConfirmText -Mode $Mode
    $typed = Read-LctConfirmTextDialog -Title '部署 WDAC 策略：手输确认文本' -Expect $expect `
        -Prompt "模式：$Mode`r`n策略 XML：$xml`r`n`r`n文本不匹配就拒绝；部署前引擎会先把现有 System32\CodeIntegrity 策略全量备份到 var\backups\wdac-<戳>\。"
    if (-not $typed) {
        Add-LctLogLine '  ℹ 用户取消了部署（未做任何写入）' $script:C.Dim
        return
    }
    if ($typed.Trim() -cne $expect) {
        $null = [System.Windows.Forms.MessageBox]::Show(
            "确认文本不匹配，已拒绝部署（没有做任何写入）。`r`n`r`n需要精确输入：$expect`r`n你输入的是：$($typed.Trim())",
            '确认文本不匹配', 'OK', 'Error')
        Add-LctLogLine '  ✖ 部署被拒绝：手输确认文本不匹配（未落盘）' $script:C.Err
        return
    }
    $r = Invoke-LctPreview -Page 'wdac' -Id "policy:deploy:$Mode" -Verb 'wdac.deploy' `
        -Args @{ xmlPath = $xml; mode = $Mode; confirmText = $expect } `
        -Summary "部署 WDAC 策略（$Mode 模式；需重启生效）" -TimeoutSec 600

    $bk = ''
    $rv = ''
    $steps = @()
    $restartText = ''
    if ($r.ok -and $null -ne $r.data) {
        $dd = Get-LctDataDeep -Result $r -KeyName 'backupDir'
        $bk = [string](Get-LctField $dd @('backupDir', 'backupPath', 'backup') '')
        $rv = [string](Get-LctField $dd @('revertCmdPath', 'revertCmd', 'revertPath', 'revert') '')
        $steps = @(Get-LctArray (Get-LctField $dd @('recoverySteps') $null))
        $restartText = [string](Get-LctField $dd @('restartText') '')
        $bkStamp = [string](Get-LctField $dd @('backupStamp', 'stamp') '')
        if (-not $bk) { $bk = $bkStamp }
        if ($bkStamp -and $null -ne $script:WdacStampBox) { $script:WdacStampBox.Text = $bkStamp }
    }
    $lines = New-Object System.Collections.ArrayList
    $null = $lines.Add('★★ 需重启生效 ★★ —— 部署完成后必须重启，内核才会加载新的代码完整性策略。')
    $null = $lines.Add("部署模式        ：$Mode")
    $null = $lines.Add("策略 XML        ：$xml")
    $null = $lines.Add("手输确认文本    ：已核对通过（$expect）")
    $null = $lines.Add("将先全量备份    ：$(if ($bk) { $bk } else { '<工具根>\var\backups\wdac-<备份戳>\（引擎未返回则按此默认位置）' })")
    $null = $lines.Add("                 备份内容：System32\CodeIntegrity\SiPolicy.p7b + CiPolicies\Active\*")
    $null = $lines.Add("回滚脚本        ：$(if ($rv) { $rv } else { '<备份目录>\revert.cmd（部署时由引擎生成）' })")
    $null = $lines.Add("")
    $null = $lines.Add($script:WdacRecoveryText)
    if (@($steps).Count -gt 0) {
        $null = $lines.Add('引擎给出的恢复步骤：')
        foreach ($st in @($steps)) { $null = $lines.Add('  · ' + [string]$st) }
    }
    if ($restartText) { $null = $lines.Add("引擎说明        ：$restartText") }
    $null = $lines.Add("")
    if ($r.ok) {
        $null = $lines.Add("状态：【$($script:PREVIEW_BANNER)】—— 已登记为待应用；点「② 确认部署（-Apply）」并再次核实确认文本后才会真正写入。")
    } else {
        $null = $lines.Add('预览失败（未登记待应用）：' + (@(Get-LctArray $r.errors) -join ' / '))
    }
    $script:WdacDeployBox.ForeColor = $(if ($r.ok) { $script:C.Warn } else { $script:C.Err })
    $script:WdacDeployBox.Text = (@($lines) -join "`r`n")
}

function Invoke-LctWdacDeployApply {
    param([string]$Mode = 'audit')
    $id = "policy:deploy:$Mode"
    if (@(Get-LctPending -Page 'wdac' -Id $id).Count -eq 0) {
        $null = [System.Windows.Forms.MessageBox]::Show(
            "必须先预览。`r`n请先点「① 预览部署（需手输确认文本）」，核对将备份的路径后，再到这里应用（应用前还要再手输一次确认文本，并过一次 MessageBox 二次确认）。",
            '需要先预览', 'OK', 'Warning')
        return
    }
    $expect = Get-LctWdacExpectConfirmText -Mode $Mode
    $typed = Read-LctConfirmTextDialog -Title '二次确认：再次手输确认文本' -Expect $expect `
        -Prompt "即将【真实部署】WDAC 策略（$Mode 模式），部署后需重启生效。`r`n为确认这不是误触，请再手输一次同样的文本。"
    if (-not $typed -or ($typed.Trim() -cne $expect)) {
        $null = [System.Windows.Forms.MessageBox]::Show("确认文本不匹配，已拒绝部署（未落盘）。需要精确输入：$expect", '确认文本不匹配', 'OK', 'Error')
        Add-LctLogLine '  ✖ 二次确认文本不匹配：部署被拒绝（未落盘）' $script:C.Err
        return
    }
    Invoke-LctApplyPending -Page 'wdac' -Id $id
    $lr = $script:LastResult
    if ($null -ne $lr -and [bool](Get-LctProp $lr 'applied' $false)) {
        $msg = "★★ 需重启生效 ★★`r`n`r`nwdac.deploy 已完成（applied=true）。策略文件要重启后才会被内核加载；重启前系统行为不变。`r`n`r`n" + $script:WdacRecoveryText + "`r`n`r`n重启后请点「重启后校验」判定是否可安全转强制。"
        $null = [System.Windows.Forms.MessageBox]::Show($msg, '部署完成：需重启生效',
            [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning)
    }
    Update-LctWdacRules
}

function Invoke-LctWdacRevertPreview {
    $stamp = ''
    if ($null -ne $script:WdacStampBox) { $stamp = [string]$script:WdacStampBox.Text.Trim() }
    if (-not $stamp) {
        $null = [System.Windows.Forms.MessageBox]::Show('请先填「备份戳」（可从部署结果里的备份目录名 var\backups\wdac-<戳>\ 复制）。', '缺少备份戳', 'OK', 'Warning')
        return
    }
    $null = Invoke-LctPreview -Page 'wdac' -Id "policy:revert:$stamp" -Verb 'wdac.revert' `
        -Args @{ stamp = $stamp } -Summary "回滚 WDAC 策略（备份戳 $stamp；需重启生效）" -TimeoutSec 600
}

function Invoke-LctWdacRevertApply {
    $stamp = ''
    if ($null -ne $script:WdacStampBox) { $stamp = [string]$script:WdacStampBox.Text.Trim() }
    if (-not $stamp) { return }
    if (@(Get-LctPending -Page 'wdac' -Id "policy:revert:$stamp").Count -eq 0) {
        $null = [System.Windows.Forms.MessageBox]::Show('必须先点「预览回滚（revert）」并通过预览，才能应用。', '需要先预览', 'OK', 'Warning')
        return
    }
    Invoke-LctApplyPending -Page 'wdac' -Id "policy:revert:$stamp"
    $lr = $script:LastResult
    if ($null -ne $lr -and [bool](Get-LctProp $lr 'applied' $false)) {
        $null = [System.Windows.Forms.MessageBox]::Show(
            "回滚已执行（applied=true）—— 同样【需重启生效】。`r`n如果系统已经被策略拦住（连工具都起不来），请用离线恢复：`r`n`r`n" + $script:WdacRecoveryText,
            '回滚完成：需重启生效', 'OK', 'Warning')
    }
}

function Invoke-LctWdacValidateRead {
    # 只读：wdac.policy.validate（安全门）。errors 原文醒目显示。
    if ($null -eq $script:WdacValidateBox) { return }
    $xml = ''
    if ($null -ne $script:WdacXmlBox) { $xml = [string]$script:WdacXmlBox.Text.Trim() }
    if (-not $xml) {
        $null = [System.Windows.Forms.MessageBox]::Show('请先填 / 生成「策略 XML」路径，再点安全校验。', '缺少策略 XML', 'OK', 'Warning')
        return
    }
    $r = Invoke-LctEngine -Verb 'wdac.policy.validate' -Args @{ xmlPath = $xml }
    $dv = Get-LctDataDeep -Result $r -KeyName 'mode'
    $allErrs = @(Get-LctArray $r.errors)
    $allWarns = @(Get-LctArray $r.warnings)
    if ($null -ne $dv) {
        $allErrs += @(Get-LctArray (Get-LctProp $dv 'errors' @()))
        $allWarns += @(Get-LctArray (Get-LctProp $dv 'warnings' @()))
    }
    $lines = New-Object System.Collections.ArrayList
    $null = $lines.Add("校验对象：$xml")
    if (@($allErrs).Count -gt 0) {
        $script:WdacValidateBox.ForeColor = $script:C.Err
        $null = $lines.Add('结论：被安全门拦下 —— 禁止强制部署（errors 原文如下）')
    } elseif (-not $r.ok) {
        $script:WdacValidateBox.ForeColor = $script:C.Err
        $null = $lines.Add('结论：校验调用失败（后端模块可能尚未就绪）')
    } else {
        $script:WdacValidateBox.ForeColor = $script:C.Ok
        $null = $lines.Add('结论：安全门通过（引擎未返回 errors）')
    }
    foreach ($e in @($allErrs)) { $null = $lines.Add('  ✖ ' + [string]$e) }
    foreach ($w in @($allWarns)) { $null = $lines.Add('  ⚠ ' + [string]$w) }
    if ($null -ne $dv) {
        $null = $lines.Add("模式：$(Get-LctField $dv @('mode') '—')   文件存在=$(Format-LctBoolCn (Get-LctField $dv @('exists') $null))   allow 机制=$(Format-LctBoolCn (Get-LctField $dv @('hasAllowMechanism') $null))   可审计=$(Format-LctBoolCn (Get-LctField $dv @('canDeployAudit') $null))   可强制=$(Format-LctBoolCn (Get-LctField $dv @('canDeployEnforce') $null))")
        $cnts = Get-LctProp $dv 'counts' $null
        if ($null -ne $cnts) {
            $null = $lines.Add("计数：fileRules=$(Get-LctField $cnts @('fileRules') 0)  denyRules=$(Get-LctField $cnts @('denyRules') 0)  allowRules=$(Get-LctField $cnts @('allowRules') 0)  signers=$(Get-LctField $cnts @('signers') 0)  allowRefs=$(Get-LctField $cnts @('allowRefs') 0)  denyRefs=$(Get-LctField $cnts @('denyRefs') 0)")
        }
        foreach ($eb in @(Get-LctArray (Get-LctField $dv @('enforceBlockers') $null))) { $null = $lines.Add('  强制部署拦路石：' + [string]$eb) }
        foreach ($ab in @(Get-LctArray (Get-LctField $dv @('auditBlockers') $null))) { $null = $lines.Add('  审计部署拦路石：' + [string]$ab) }
        foreach ($ch in @(Get-LctArray (Get-LctField $dv @('criticalHits') $null))) { $null = $lines.Add('  命中系统关键目录：' + [string]$ch) }
        foreach ($uw in @(Get-LctArray (Get-LctField $dv @('userWritableHits') $null))) { $null = $lines.Add('  用户可写位置命中：' + [string]$uw) }
        if (Get-LctField $dv @('parseError') $null) { $null = $lines.Add('  解析错误：' + [string](Get-LctField $dv @('parseError') '')) }
        $null = $lines.Add("")
        $null = $lines.Add("—— wdac.policy.validate 原始 JSON ——")
        try { $null = $lines.Add((ConvertTo-Json -InputObject $dv -Depth 8)) } catch { }
    }
    $script:WdacValidateBox.Text = (@($lines) -join "`r`n")
}

function Invoke-LctWdacVerifyRead {
    # 只读：wdac.verify（重启后校验）—— 按三档结论着色
    if ($null -eq $script:WdacVerifyBox) { return }
    $r = Invoke-LctEngine -Verb 'wdac.verify'
    if (-not $r.ok -or $null -eq $r.data) {
        $script:WdacVerifyBox.ForeColor = $script:C.Err
        $script:WdacVerifyBox.Text = "wdac.verify 调用失败：`r`n" + (@(Get-LctArray $r.errors) -join "`r`n")
        return
    }
    $d = Get-LctDataDeep -Result $r -KeyName 'verdict'
    # 实测形状：verdict = safe-to-enforce / unclear / dangerous；verdictText = 可安全转强制 / 尚不明确 / 危险
    $verdict = [string](Get-LctField $d @('verdict') '')
    $verdictText = [string](Get-LctField $d @('verdictText') '')
    $verdictReason = [string](Get-LctField $d @('verdictReason') '')
    $blob = ''
    try { $blob = ConvertTo-Json -InputObject $d -Depth 8 } catch { $blob = [string]$d }
    $cls = 'unknown'
    $vm = $verdict.Trim().ToLowerInvariant()
    if ($vm -match 'danger') { $cls = 'danger' }
    elseif ($vm -match 'unclear') { $cls = 'unclear' }
    elseif ($vm -match 'safe') { $cls = 'safe' }
    elseif ($verdictText -match '危险') { $cls = 'danger' }
    elseif ($verdictText -match '尚不明确|不明确') { $cls = 'unclear' }
    elseif ($verdictText -match '可安全转强制|安全转强制') { $cls = 'safe' }
    elseif ($blob -match '危险') { $cls = 'danger' }
    elseif ($blob -match '尚不明确|不明确') { $cls = 'unclear' }
    elseif ($blob -match '可安全转强制|安全转强制') { $cls = 'safe' }
    $zh = $verdictText
    if (-not $zh) {
        if ($cls -eq 'safe') { $zh = '可安全转强制' }
        elseif ($cls -eq 'unclear') { $zh = '尚不明确' }
        elseif ($cls -eq 'danger') { $zh = '危险' }
        else { $zh = '未识别（引擎未返回可识别结论）' }
    }
    $head = "结论：$zh   （machine verdict=$verdict）"
    if ($verdictReason) { $head += "`r`n理由：$verdictReason" }
    $head += "`r`n三档说明：可安全转强制=绿（可以转 enforce）／尚不明确=黄（继续 audit 观察，先别转）／危险=红（疑似拦截关键程序，立即回滚并离线恢复）"
    if ($cls -eq 'safe') { $script:WdacVerifyBox.ForeColor = $script:C.Ok }
    elseif ($cls -eq 'unclear') { $script:WdacVerifyBox.ForeColor = $script:C.Warn }
    elseif ($cls -eq 'danger') { $script:WdacVerifyBox.ForeColor = $script:C.Err }
    else { $script:WdacVerifyBox.ForeColor = $script:C.Dim }
    $script:WdacVerifyBox.Text = $head + "`r`n`r`n" + $blob
}

function Update-LctWdac {
    # 只读：wdac.status + wdac.rules.list
    if ($null -eq $script:WdacStatusBox) { return }
    $r = Invoke-LctEngine -Verb 'wdac.status'
    $lines = New-Object System.Collections.ArrayList
    if ($r.ok -and $null -ne $r.data) {
        $d = Get-LctDataDeep -Result $r -KeyName 'secureBoot'
        $sb = Get-LctField $d @('secureBoot', 'secureBootEnabled') $null
        $null = $lines.Add("Secure Boot            ：$(Format-LctBoolCn $sb)（Secure Boot=False 时未签名策略可加载）")
        $null = $lines.Add("CI 强制状态            ：$(Get-LctField $d @('ciEnforcementText') '—')   （ciEnforcement=$(Get-LctField $d @('ciEnforcement') '—')，ciEnforced=$(Format-LctBoolCn (Get-LctField $d @('ciEnforced') $null))）")
        $null = $lines.Add("现有策略               ：$(Format-LctPolicyList (Get-LctField $d @('activePolicies', 'policies', 'policyList') @()))")
        $null = $lines.Add("系统策略文件           ：$(Get-LctField $d @('systemPolicyPath', 'siPolicyPath', 'policyPath') '—')   存在=$(Format-LctBoolCn (Get-LctField $d @('systemPolicyExists') $null))   长度=$(Get-LctField $d @('systemPolicyLength') '—')   修改时间=$(Get-LctField $d @('systemPolicyLastWrite') '—')")
        $null = $lines.Add("是否需要重启           ：$(Format-LctBoolCn (Get-LctField $d @('restartRequired', 'rebootRequired', 'needsReboot') $null))   $(Get-LctField $d @('restartRequiredReason') '')")
        $null = $lines.Add("staging 产物目录       ：$(Get-LctField $d @('stagingDir') '—')   该目录已有策略=$(Format-LctBoolCn (Get-LctField $d @('stagingPolicyExists') $null))")
        $null = $lines.Add("规则文件               ：$(Get-LctField $d @('rulesPath') '<工具根>\var\wdac\rules.json')   （$(Get-LctField $d @('rulesCount') '—') 条）")
        $null = $lines.Add("规则数 / 环境          ：规则 $(Get-LctField $d @('rulesCount') '—') 条   已提权=$(Format-LctBoolCn (Get-LctField $d @('elevated') $null))   CiTool=$(Format-LctBoolCn (Get-LctField $d @('ciToolPresent') $null))   ConfigCI=$(Format-LctBoolCn (Get-LctField $d @('configCiPresent') $null))")
        foreach ($nt in @(Get-LctArray (Get-LctField $d @('notes') $null))) { $null = $lines.Add('备注                   ：' + [string]$nt) }
        $null = $lines.Add("")
        $null = $lines.Add("—— wdac.status 原始 JSON ——")
        try { $null = $lines.Add((ConvertTo-Json -InputObject $d -Depth 8)) } catch { $null = $lines.Add([string]$d) }
    } else {
        $null = $lines.Add('wdac.status 调用失败（后端模块可能尚未就绪）：')
        foreach ($e in @(Get-LctArray $r.errors)) { $null = $lines.Add('  ✖ ' + [string]$e) }
    }
    $script:WdacStatusBox.Text = (@($lines) -join "`r`n")
    Update-LctWdacRules
}

function Update-LctWdacRules {
    if ($null -eq $script:WdacRuleGrid) { return }
    $r = Invoke-LctEngine -Verb 'wdac.rules.list'
    $script:SuppressWdacSel = $true
    Clear-LctGrid $script:WdacRuleGrid
    if (-not $r.ok) {
        $script:SuppressWdacSel = $false
        $script:WdacRulesCache = @()
        if ($null -ne $script:WdacRuleCount) { $script:WdacRuleCount.Text = '规则列表调用失败（见底部日志）' }
        return
    }
    # 实测形状（两种都要兜）：data = { path, exists, count, byKind, rules:[{id,kind,value,reason,added}] }
    # 或 data 直接就是规则数组；空库时引擎会把空数组折成 null（backend-wdac 实测）。
    $rd = Get-LctDataDeep -Result $r -KeyName 'rules'
    $listRaw = Get-LctProp $rd 'rules' $null
    if ($null -ne $listRaw) { $script:WdacRulesCache = @(Get-LctArray $listRaw) }
    else { $script:WdacRulesCache = @(Get-LctArray $rd) }
    foreach ($x in @($script:WdacRulesCache)) {
        if ($x -is [string]) {
            Add-LctGridRow -Grid $script:WdacRuleGrid -Key "path||$x" -ButtonTexts @('预览', '应用') -Values @('path', $x, '', '—')
            continue
        }
        $wkind = [string](Get-LctField $x @('kind', 'type') '')
        $wval = [string](Get-LctField $x @('value', 'path', 'fileName', 'hash', 'target') '')
        $wrsn = [string](Get-LctField $x @('reason', 'note', 'comment') '')
        Add-LctGridRow -Grid $script:WdacRuleGrid -Key "$wkind||$wval" -ButtonTexts @('预览', '应用') -Values @(
            $wkind, $wval, $wrsn, (Format-LctBoolCn (Get-LctField $x @('applied', 'active', 'enabled') $null))
        )
    }
    $realCount = $script:WdacRuleGrid.Rows.Count
    if ($realCount -eq 0) {
        # 空库时给一行占位（与预设包列表同风格）：避免界面看起来「坏了」，也给验收脚本一个可断言的行
        Add-LctGridRow -Grid $script:WdacRuleGrid -Key '' -ButtonTexts @('', '') -Values @(
            '（当前没有黑名单规则）', '用上面表单「① 预览：新增规则 → ② 应用」新增', '', ''
        )
    }
    $rp = [string](Get-LctField $rd @('path') '')
    if ($null -ne $script:WdacRuleCount) { $script:WdacRuleCount.Text = "规则数：$realCount$(if ($rp) { "（$rp）" })" }
    if ($script:WdacRuleGrid.Rows.Count -gt 0) { $script:WdacRuleGrid.Rows[0].Selected = $true }
    $script:SuppressWdacSel = $false
    Update-LctWdacDetail
}

function Update-LctWdacDetail {
    # 当前选中规则（或最近一次策略生成产物）的详情；不发写操作、不递归刷新。
    if ($null -eq $script:WdacDetailBox) { return }
    $key = ''
    if ($null -ne $script:WdacRuleGrid -and $script:WdacRuleGrid.SelectedRows.Count -gt 0) {
        $key = Get-LctRowCell -Row $script:WdacRuleGrid.SelectedRows[0] -Column 'rowkey'
    }
    $wkind = ''
    $wval = ''
    if ($key -match '\|\|') {
        $wkind = ($key -split '\|\|')[0]
        $wval = ($key -split '\|\|')[1]
    }
    if (-not $wval) {
        $lines = New-Object System.Collections.ArrayList
        $null = $lines.Add('（请先在上面选中一条规则，再点这里看详情）')
        if ($script:WdacLastPolicyText) {
            $null = $lines.Add('')
            $null = $lines.Add('—— 最近一次策略生成 / 部署记录 ——')
            $null = $lines.Add([string]$script:WdacLastPolicyText)
        }
        $script:WdacDetailBox.Text = (@($lines) -join "`r`n")
        return
    }
    $found = $null
    foreach ($x in @($script:WdacRulesCache)) {
        if ($x -is [string]) { if ($x -eq $wval) { $found = $x; break }; continue }
        if ([string](Get-LctField $x @('kind', 'type') '') -eq $wkind -and [string](Get-LctField $x @('value', 'path', 'fileName', 'hash', 'target') '') -eq $wval) { $found = $x; break }
    }
    $out = New-Object System.Collections.ArrayList
    $null = $out.Add("规则类型 ：$wkind")
    $null = $out.Add("规则值   ：$wval")
    if ($null -eq $found) {
        $null = $out.Add('（该行不在当前缓存里：点「刷新规则列表」重新读 wdac.rules.list）')
    } elseif ($found -is [string]) {
        $null = $out.Add('（字符串规则）')
    } else {
        $null = $out.Add("原因     ：$(Get-LctField $found @('reason', 'note', 'comment') '—')")
        $null = $out.Add("")
        $null = $out.Add("—— 规则原始 JSON ——")
        try { $null = $out.Add((ConvertTo-Json -InputObject $found -Depth 6)) } catch { $null = $out.Add([string]$found) }
    }
    $script:WdacDetailBox.Text = (@($out) -join "`r`n")
}

function Invoke-LctWdacRuleAddPreview {
    if ($null -eq $script:WdacRuleGrid) { return }
    $wkind = 'path'
    if ($null -ne $script:WdacKindBox) { $wkind = [string]$script:WdacKindBox.Text.Trim() }
    $wval = ''
    if ($null -ne $script:WdacValueBox) { $wval = [string]$script:WdacValueBox.Text.Trim() }
    if (-not $wval) {
        $null = [System.Windows.Forms.MessageBox]::Show('请先填「规则值」（完整路径 / 文件名 / SHA256 哈希）。', '参数不足', 'OK', 'Warning')
        return
    }
    if ($wkind -eq 'hash' -and $wval -notmatch '(?i)^[0-9a-f]{64}$') {
        $null = [System.Windows.Forms.MessageBox]::Show('哈希规则值应为 64 位十六进制 SHA256。', '哈希格式可疑', 'OK', 'Warning')
        return
    }
    $wrsn = ''
    if ($null -ne $script:WdacReasonBox) { $wrsn = [string]$script:WdacReasonBox.Text.Trim() }
    $null = Invoke-LctPreview -Page 'wdac' -Id "rule:add:$wkind||$wval" -Verb 'wdac.rules.add' `
        -Args @{ kind = $wkind; value = $wval; reason = $wrsn } -Summary "新增黑名单规则 [$wkind] $wval"
}

function Invoke-LctWdacRuleAddApply {
    $wkind = 'path'
    if ($null -ne $script:WdacKindBox) { $wkind = [string]$script:WdacKindBox.Text.Trim() }
    $wval = ''
    if ($null -ne $script:WdacValueBox) { $wval = [string]$script:WdacValueBox.Text.Trim() }
    if (-not $wval) { return }
    $id = "rule:add:$wkind||$wval"
    if (@(Get-LctPending -Page 'wdac' -Id $id).Count -eq 0) {
        $null = [System.Windows.Forms.MessageBox]::Show('必须先点「① 预览：新增规则」并通过预览，才能应用。', '需要先预览', 'OK', 'Warning')
        return
    }
    Invoke-LctApplyPending -Page 'wdac' -Id $id
    Update-LctWdacRules
}

function Invoke-LctWdacRuleRemovePreview {
    param([string]$Kind = '', [string]$Value = '')
    if (-not $Value) { return }
    $null = Invoke-LctPreview -Page 'wdac' -Id "rule:remove:$Kind||$Value" -Verb 'wdac.rules.remove' `
        -Args @{ kind = $Kind; value = $Value } -Summary "删除黑名单规则 [$Kind] $Value"
}

function New-LctPageWdac {
    param($Body)
    $t = New-LctScrollPage -Body $Body -CanvasHeight 660
    $two = New-LctTable -Parent $t -ColSpec @('100p', '500a') -RowSpec @('100p') -Col 0 -Row 0

    # ---------------- 左：状态 / 策略生成 / 部署 ----------------
    $left = New-LctTable -Parent $two -ColSpec @('100p') -RowSpec @('132a', '176a', '100p') -Col 0 -Row 0

    $c1 = New-LctCard -Title '代码完整性状态（wdac.status，只读）' -Parent $left -Col 0 -Row 0
    $bRef = New-LctButton -Text '刷新（wdac.status）' -X 14 -Y 22 -W 170 -H 26 -Parent $c1 -Accent
    $null = New-LctLabel -Text '★★ 需重启生效 ★★ 策略文件放进 System32\CodeIntegrity 后必须重启才加载。' -X 194 -Y 26 -W 560 -H 20 -Parent $c1 -Color $script:C.Err -Size 8
    $script:WdacStatusBox = New-LctText -X 0 -Y 0 -W 100 -H 100 -Parent $c1 -Multiline -ReadOnly -Mono -Dark
    $script:WdacStatusBox.Dock = [System.Windows.Forms.DockStyle]::Fill
    $script:WdacStatusBox.Margin = New-Object System.Windows.Forms.Padding(12, 54, 12, 10)
    $bRef.Add_Click({ param($s, $e) Update-LctWdac })

    $c2 = New-LctCard -Title '策略生成（wdac.policy.build；产物全部落在 var\wdac\staging\）' -Parent $left -Col 0 -Row 1
    $i2 = New-LctTable -Parent $c2 -ColSpec @('100p') -RowSpec @('28a', '32a', '26a', '100p')
    $i2.Margin = New-Object System.Windows.Forms.Padding(12, 24, 12, 8)
    $script:WdacScanPathBox = New-LctFormRow -Parent $i2 -Row 0 -Label '扫描目录' -LabelW 66 -H 28
    $b2 = New-LctTable -Parent $i2 -ColSpec @('176a', '176a', '100p') -RowSpec @('30a') -Col 0 -Row 1
    $b2.Margin = New-Object System.Windows.Forms.Padding(0)
    $bAudit = New-LctButton -Text '生成策略（审计模式）' -W 170 -H 28 -Parent $b2 -Accent -Col 0 -Row 0
    $bAudit.Dock = [System.Windows.Forms.DockStyle]::Fill
    $bAudit.Margin = New-Object System.Windows.Forms.Padding(0, 1, 6, 1)
    $bEnforce = New-LctButton -Text '生成策略（强制模式）' -W 170 -H 28 -Parent $b2 -Warn -Col 1 -Row 0
    $bEnforce.Dock = [System.Windows.Forms.DockStyle]::Fill
    $bEnforce.Margin = New-Object System.Windows.Forms.Padding(0, 1, 2, 1)
    $enforceNote = New-LctLabel -Text '扫描目录必填（缺省引擎直接拒绝：无 -ScanPath 会全盘扫描）。红字警告：强制模式会移除 Enabled:Audit Mode —— 未经「重启后校验」判定「可安全转强制」前，不要在真机上强制。' -X 0 -Y 0 -W 100 -H 24 -Parent $i2 -Color $script:C.Err -Size 8 -Col 0 -Row 2
    $enforceNote.Dock = [System.Windows.Forms.DockStyle]::Fill
    $script:WdacPolicyBox = New-LctText -X 0 -Y 0 -W 100 -H 100 -Parent $i2 -Multiline -ReadOnly -Mono -Dark -Col 0 -Row 3
    $script:WdacPolicyBox.Dock = [System.Windows.Forms.DockStyle]::Fill
    $script:WdacPolicyBox.Text = '(尚未生成策略。生成后的产物路径与 staging 目录会显示在这里；安全校验 / 部署都以上面「策略 XML」为准。)'
    $bAudit.Add_Click({ param($s, $e) Invoke-LctWdacBuildPreview -Mode 'audit' })
    $bEnforce.Add_Click({ param($s, $e) Invoke-LctWdacBuildPreview -Mode 'enforce' })

    $c3 = New-LctCard -Title '部署 / 回滚 / 重启后校验（wdac.deploy / wdac.revert / wdac.verify）' -Parent $left -Col 0 -Row 2
    $i3 = New-LctTable -Parent $c3 -ColSpec @('100p') -RowSpec @('28a', '28a', '28a', '32a', '32a', '100p')
    $i3.Margin = New-Object System.Windows.Forms.Padding(12, 24, 12, 8)
    $script:WdacXmlBox = New-LctFormRow -Parent $i3 -Row 0 -Label '策略 XML' -LabelW 64 -H 28
    $script:WdacModeBox = New-LctFormCombo -Parent $i3 -Row 1 -Label '部署模式' -LabelW 64 -H 28 -Items @('audit', 'enforce')
    $script:WdacStampBox = New-LctFormRow -Parent $i3 -Row 2 -Label '备份戳' -LabelW 64 -H 28

    $d1 = New-LctTable -Parent $i3 -ColSpec @('196a', '176a', '120a', '100p') -RowSpec @('32a') -Col 0 -Row 3
    $d1.Margin = New-Object System.Windows.Forms.Padding(0)
    $bDepPrev = New-LctButton -Text '① 预览部署（需手输确认文本）' -W 190 -H 30 -Parent $d1 -Accent -Col 0 -Row 0
    $bDepPrev.Dock = [System.Windows.Forms.DockStyle]::Fill
    $bDepPrev.Margin = New-Object System.Windows.Forms.Padding(0, 2, 6, 2)
    $bDepApply = New-LctButton -Text '② 确认部署（-Apply）' -W 170 -H 30 -Parent $d1 -Warn -Col 1 -Row 0
    $bDepApply.Dock = [System.Windows.Forms.DockStyle]::Fill
    $bDepApply.Margin = New-Object System.Windows.Forms.Padding(0, 2, 6, 2)
    $bBrowse = New-LctButton -Text '浏览 XML…' -W 114 -H 30 -Parent $d1 -Col 2 -Row 0
    $bBrowse.Dock = [System.Windows.Forms.DockStyle]::Fill
    $bBrowse.Margin = New-Object System.Windows.Forms.Padding(0, 2, 2, 2)

    $d2 = New-LctTable -Parent $i3 -ColSpec @('176a', '150a', '160a', '100p') -RowSpec @('32a') -Col 0 -Row 4
    $d2.Margin = New-Object System.Windows.Forms.Padding(0)
    $bRevPrev = New-LctButton -Text '预览回滚（revert）' -W 170 -H 30 -Parent $d2 -Col 0 -Row 0
    $bRevPrev.Dock = [System.Windows.Forms.DockStyle]::Fill
    $bRevPrev.Margin = New-Object System.Windows.Forms.Padding(0, 2, 6, 2)
    $bRevApply = New-LctButton -Text '确认回滚' -W 144 -H 30 -Parent $d2 -Col 1 -Row 0
    $bRevApply.Dock = [System.Windows.Forms.DockStyle]::Fill
    $bRevApply.Margin = New-Object System.Windows.Forms.Padding(0, 2, 6, 2)
    $bVerify = New-LctButton -Text '重启后校验（wdac.verify）' -W 154 -H 30 -Parent $d2 -Col 2 -Row 0
    $bVerify.Dock = [System.Windows.Forms.DockStyle]::Fill
    $bVerify.Margin = New-Object System.Windows.Forms.Padding(0, 2, 2, 2)

    $script:WdacDeployBox = New-LctText -X 0 -Y 0 -W 100 -H 100 -Parent $i3 -Multiline -ReadOnly -Dark -Mono -Col 0 -Row 5
    $script:WdacDeployBox.Dock = [System.Windows.Forms.DockStyle]::Fill
    $script:WdacDeployBox.ForeColor = $script:C.Warn
    $script:WdacDeployBox.Text = $script:WdacRecoveryText

    $bDepPrev.Add_Click({
        param($s, $e)
        $md = 'audit'
        if ($null -ne $script:WdacModeBox) { $md = [string]$script:WdacModeBox.Text.Trim().ToLowerInvariant() }
        if ($md -ne 'enforce') { $md = 'audit' }
        Invoke-LctWdacDeployPreview -Mode $md
    })
    $bDepApply.Add_Click({
        param($s, $e)
        $md = 'audit'
        if ($null -ne $script:WdacModeBox) { $md = [string]$script:WdacModeBox.Text.Trim().ToLowerInvariant() }
        if ($md -ne 'enforce') { $md = 'audit' }
        Invoke-LctWdacDeployApply -Mode $md
    })
    $bBrowse.Add_Click({
        param($s, $e)
        $dlg = New-Object System.Windows.Forms.OpenFileDialog
        $dlg.Title = '选择引擎生成的策略 XML（通常在 var\wdac\staging\ 下）'
        $dlg.Filter = '策略 XML (*.xml)|*.xml|所有文件 (*.*)|*.*'
        $dlg.CheckFileExists = $true
        if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { $script:WdacXmlBox.Text = $dlg.FileName }
    })
    $bRevPrev.Add_Click({ param($s, $e) Invoke-LctWdacRevertPreview })
    $bRevApply.Add_Click({ param($s, $e) Invoke-LctWdacRevertApply })
    $bVerify.Add_Click({ param($s, $e) Invoke-LctWdacVerifyRead })
    # 供验收脚本按真实点击路径驱动（PerformClick；注意 enforce 与「确认部署」会弹二次确认框）
    $script:WdacBuildAuditBtn = $bAudit
    $script:WdacBuildEnforceBtn = $bEnforce
    $script:WdacDeployPreviewBtn = $bDepPrev
    $script:WdacDeployApplyBtn = $bDepApply
    $script:WdacRevertPreviewBtn = $bRevPrev
    $script:WdacRevertApplyBtn = $bRevApply
    $script:WdacVerifyBtn = $bVerify

    # ---------------- 右：规则 / 安全校验 / 校验结论 / 详情 ----------------
    $right = New-LctTable -Parent $two -ColSpec @('100p') -RowSpec @('100p', '136a', '108a', '104a', '44a') -Col 1 -Row 0

    $c4 = New-LctCard -Title '黑名单规则（wdac.rules.list / rules.add / rules.remove；行内「预览 / 应用」= 删除该规则）' -Parent $right -Col 0 -Row 0
    $i4 = New-LctTable -Parent $c4 -ColSpec @('100p') -RowSpec @('22a', '28a', '28a', '28a', '30a', '100p')
    $i4.Margin = New-Object System.Windows.Forms.Padding(10, 24, 10, 8)
    $r4note = New-LctLabel -Text '新增规则：类型（path / fileName / hash）+ 规则值 + 原因；先「预览」再「应用」。' -X 0 -Y 0 -W 100 -H 20 -Parent $i4 -Dim -Size 8 -Col 0 -Row 0
    $r4note.Dock = [System.Windows.Forms.DockStyle]::Fill
    $script:WdacKindBox = New-LctFormCombo -Parent $i4 -Row 1 -Label '类型' -LabelW 66 -H 28 -Items @('path', 'fileName', 'hash')
    $script:WdacValueBox = New-LctFormRow -Parent $i4 -Row 2 -Label '规则值' -LabelW 66 -H 28
    $script:WdacValueBox.Text = 'C:\Tools\sample-tool.exe'
    $script:WdacReasonBox = New-LctFormRow -Parent $i4 -Row 3 -Label '原因' -LabelW 66 -H 28
    $script:WdacReasonBox.Text = 'ui-expansion: 黑名单规则（示例值，请改成你的实际目标）'

    $r4b = New-LctTable -Parent $i4 -ColSpec @('124a', '124a', '140a', '100p') -RowSpec @('30a') -Col 0 -Row 4
    $r4b.Margin = New-Object System.Windows.Forms.Padding(0)
    $bRulePrev = New-LctButton -Text '① 预览：新增规则' -W 120 -H 28 -Parent $r4b -Accent -Col 0 -Row 0
    $bRulePrev.Dock = [System.Windows.Forms.DockStyle]::Fill
    $bRulePrev.Margin = New-Object System.Windows.Forms.Padding(0, 1, 6, 1)
    $bRuleApply = New-LctButton -Text '② 应用：新增规则' -W 120 -H 28 -Parent $r4b -Warn -Col 1 -Row 0
    $bRuleApply.Dock = [System.Windows.Forms.DockStyle]::Fill
    $bRuleApply.Margin = New-Object System.Windows.Forms.Padding(0, 1, 6, 1)
    $bRuleList = New-LctButton -Text '刷新规则列表' -W 130 -H 28 -Parent $r4b -Col 2 -Row 0
    $bRuleList.Dock = [System.Windows.Forms.DockStyle]::Fill
    $bRuleList.Margin = New-Object System.Windows.Forms.Padding(0, 1, 6, 1)
    $script:WdacRuleCount = New-LctLabel -Text '规则数：—' -X 2 -Y 6 -W 100 -H 20 -Parent $r4b -Dim -Size 8 -Col 3 -Row 0
    $script:WdacRuleCount.Dock = [System.Windows.Forms.DockStyle]::Fill

    $script:WdacRuleGrid = New-LctGrid -Parent $i4 -Name 'wdacrules' -Buttons @(
        'btnPrev|删除·预览|84', 'btnApply|删除·应用|84'
    ) -Cols @('kind|类型|76', 'value|值|fill', 'reason|原因|130', 'applied|状态|76')
    $i4.SetCellPosition($script:WdacRuleGrid, (New-Object System.Windows.Forms.TableLayoutPanelCellPosition(0, 5)))

    $bRulePrev.Add_Click({ param($s, $e) Invoke-LctWdacRuleAddPreview })
    $bRuleApply.Add_Click({ param($s, $e) Invoke-LctWdacRuleAddApply })
    $bRuleList.Add_Click({ param($s, $e) Update-LctWdacRules })
    $script:WdacRuleAddPreviewBtn = $bRulePrev
    $script:WdacRuleAddApplyBtn = $bRuleApply
    $script:WdacRuleGrid.Add_CellContentClick({
        param($s, $e)
        if ($e.RowIndex -lt 0) { return }
        $cn = [string]$s.Columns[$e.ColumnIndex].Name
        $key = Get-LctRowCell -Row $s.Rows[$e.RowIndex] -Column 'rowkey'
        $rkind = ''
        $rval = ''
        if ($key -match '\|\|') {
            $rkind = ($key -split '\|\|')[0]
            $rval = ($key -split '\|\|')[1]
        }
        if (-not $rval) { return }
        if ($cn -eq 'btnPrev') {
            Invoke-LctWdacRuleRemovePreview -Kind $rkind -Value $rval
        } elseif ($cn -eq 'btnApply') {
            $rid = "rule:remove:$rkind||$rval"
            if (@(Get-LctPending -Page 'wdac' -Id $rid).Count -eq 0) {
                Invoke-LctWdacRuleRemovePreview -Kind $rkind -Value $rval
                $null = [System.Windows.Forms.MessageBox]::Show(
                    "已生成删除预览（$($script:PREVIEW_BANNER)）。`r`n确认无误后再点一次「应用」即可二次确认并写入。",
                    '先预览，再应用', 'OK', 'Information')
                return
            }
            Invoke-LctApplyPending -Page 'wdac' -Id $rid
            Update-LctWdacRules
        }
    })
    $script:WdacRuleGrid.Add_SelectionChanged({
        param($s, $e)
        if ($script:SuppressWdacSel) { return }
        $script:SuppressWdacSel = $true
        try { Update-LctWdacDetail } finally { $script:SuppressWdacSel = $false }
    })

    $c5 = New-LctCard -Title '安全校验（wdac.policy.validate：无 allow 机制 / 命中系统目录 / 缺救命绳 必须拦下）' -Parent $right -Col 0 -Row 1
    $i5 = New-LctTable -Parent $c5 -ColSpec @('100p') -RowSpec @('30a', '100p')
    $i5.Margin = New-Object System.Windows.Forms.Padding(10, 24, 10, 8)
    $bValidate = New-LctButton -Text '安全校验（对上面的策略 XML）' -W 240 -H 28 -Parent $i5 -Accent -Col 0 -Row 0
    $bValidate.Dock = [System.Windows.Forms.DockStyle]::Fill
    $bValidate.Margin = New-Object System.Windows.Forms.Padding(0, 1, 6, 1)
    $bValidate.Add_Click({ param($s, $e) Invoke-LctWdacValidateRead })
    $script:WdacValidateBtn = $bValidate
    $script:WdacValidateBox = New-LctText -X 0 -Y 0 -W 100 -H 100 -Parent $i5 -Multiline -ReadOnly -Mono -Dark -Col 0 -Row 1
    $script:WdacValidateBox.Dock = [System.Windows.Forms.DockStyle]::Fill
    $script:WdacValidateBox.ForeColor = $script:C.Err
    $script:WdacValidateBox.Text = '（点上面按钮调 wdac.policy.validate；被拦下时这里会显示引擎 errors 原文）'

    $c6 = New-LctCard -Title '重启后校验结论（wdac.verify：可安全转强制 / 尚不明确 / 危险）' -Parent $right -Col 0 -Row 2
    $script:WdacVerifyBox = New-LctText -X 0 -Y 0 -W 100 -H 100 -Parent $c6 -Multiline -ReadOnly -Mono -Dark
    $script:WdacVerifyBox.Dock = [System.Windows.Forms.DockStyle]::Fill
    $script:WdacVerifyBox.Margin = New-Object System.Windows.Forms.Padding(10, 22, 10, 10)
    $script:WdacVerifyBox.Text = '（部署并重启后，点左边「重启后校验（wdac.verify）」；结论按三档着色：绿=可安全转强制，黄=尚不明确，红=危险）'

    $c7 = New-LctCard -Title '选中规则详情（Update-LctWdacDetail）' -Parent $right -Col 0 -Row 3
    $script:WdacDetailBox = New-LctText -X 0 -Y 0 -W 100 -H 100 -Parent $c7 -Multiline -ReadOnly -Mono -Dark
    $script:WdacDetailBox.Dock = [System.Windows.Forms.DockStyle]::Fill
    $script:WdacDetailBox.Margin = New-Object System.Windows.Forms.Padding(10, 22, 10, 10)
    $script:WdacDetailBox.Text = '（选中一条规则后显示其原始 JSON；未选中时显示最近一次策略生成记录）'

    $null = New-LctPendingStrip -Parent $right -Col 0 -Row 4 -PageKey 'wdac'

    $script:WdacRulesCache = @()
    $script:WdacLastPolicyText = ''
    # 兼容别名：Lead 的 UiPageSmoke 可能按名字取变量（多个名字都指向同一控件）
    $script:WdacRulesGrid = $script:WdacRuleGrid
    $script:WdacGrid = $script:WdacRuleGrid
    $script:WdaGrid = $script:WdacRuleGrid
    $script:WdacRulesDetailBox = $script:WdacDetailBox
    return $two
}

# ===========================================================================
# 十二·六、页面九「驱动加载」(drivers)：状态 / 指定驱动并加载 / 清单与详情 /
#   停止与卸载 / 加载后复核 / test-signing 开关。
#   后端 core\Drivers.psm1 由 backend-drivers 实现（契约 §12）；本文件只做渲染、收集输入与闸门。
#   口径（§12.1）：签名只做信息展示，绝不是本工具的拒绝理由 —— 能不能加载交给操作系统判定；
#   结果区把系统返回码与原文【照抄】。applied=true 只代表「我们已执行动作」，
#   不代表「系统真的加载成功了」。
# ===========================================================================

$script:SuppressDrvSel = $false
$script:DriverListCache = @()
$script:DriverSecureBootValue = $null
$script:DriverTestSigningValue = $null

function Format-LctNumOrDash {
    param($Value)
    if ($null -eq $Value) { return '—' }
    if ($Value -is [string] -and $Value.Trim() -eq '') { return '—' }
    return [string]$Value
}

function Format-LctDriverPlainList {
    # 服务清单这类字段可能是「对象数组 / 字符串数组 / 单对象 / 空」（§11.6 的 JSON 折叠），
    # 一律先 @(...) 归一化再渲染，避免 0/1/n 三种形态把界面搞空白。
    param($Value)
    $arr = @(Get-LctArray $Value)
    if (@($arr).Count -eq 0) { return '（无）' }
    $parts = @()
    foreach ($x in $arr) {
        if ($null -eq $x) { continue }
        if ($x -is [string]) { if ($x.Trim()) { $parts += $x.Trim() }; continue }
        $nm = [string](Get-LctField $x @('name', 'serviceName', 'id') '')
        if (-not $nm) { continue }
        $stt = [string](Get-LctField $x @('state', 'status', 'stateText') '')
        if ($stt) { $parts += "$nm（$stt）" } else { $parts += $nm }
    }
    if (@($parts).Count -eq 0) { return '（有条目但读不到服务名）' }
    return (@($parts) -join '、')
}

function Test-LctDriverSecureBootOn {
    # Secure Boot=True 时后端会【拒绝开启】test-signing（契约 §12.4 第 6 条）。
    # 返回值：$true / $false / $null（未知）。
    $sv = $script:DriverSecureBootValue
    if ($null -eq $sv) { return $null }
    $tv = ([string]$sv).Trim().ToLowerInvariant()
    if ($tv -eq 'true' -or $tv -eq '1' -or $tv -eq 'yes' -or $tv -eq 'on') { return $true }
    if ($tv -eq 'false' -or $tv -eq '0' -or $tv -eq 'no' -or $tv -eq 'off') { return $false }
    return $null
}

function Format-LctDriverActionLines {
    # 结果区铁律：①「我们已执行什么」与 ②「系统原话是什么」必须分开写清楚。
    # verdict.exitCode / verdict.message 照抄（577 / 1058 / 1053 / 2 / 1 / 127 / 0xC000012F …）。
    param($Result)
    $out = New-Object System.Collections.ArrayList
    if ($null -eq $Result) {
        $null = $out.Add('（没有可显示的返回值）')
        return @($out)
    }
    $okV = [bool](Get-LctProp $Result 'ok' $false)
    $apV = [bool](Get-LctProp $Result 'applied' $false)
    $null = $out.Add('═══ ① 我们已执行的动作（这一栏只说明本工具做了什么）═══')
    if ($okV -and $apV) {
        $null = $out.Add('  · 已执行：applied=true —— 本工具确实向系统提交了这个动作。')
    } elseif ($okV) {
        $null = $out.Add("  · 未执行：$($script:PREVIEW_BANNER)（applied=false，系统状态未被改动）。")
    } else {
        $null = $out.Add('  · 动作失败：引擎返回 ok=false（原因见下面的 errors 与底部日志面板）。')
    }
    $null = $out.Add("  · verb=$([string](Get-LctProp $Result 'verb' ''))   ok=$okV   applied=$apV")
    $null = $out.Add('  · changes：' + (Format-LctChangeBrief -Result $Result))
    foreach ($w in @(Get-LctArray (Get-LctProp $Result 'warnings' @()))) { $null = $out.Add('  ⚠ ' + [string]$w) }
    foreach ($e in @(Get-LctArray (Get-LctProp $Result 'errors' @()))) { $null = $out.Add('  ✖ ' + [string]$e) }

    $data = Get-LctDataDeep -Result $Result -KeyName 'verdict'
    $ver = Get-LctField $data @('verdict') $null
    $ecV = $null
    $msgV = ''
    if ($null -ne $ver) {
        $ecV = Get-LctField $ver @('exitCode', 'exit', 'code', 'scExitCode', 'statusCode') $null
        $msgV = [string](Get-LctField $ver @('message', 'error', 'text', 'stderr', 'scMessage', 'details') '')
    }
    $ecText = '—（引擎未给该字段）'
    if ($null -ne $ecV) { $ecText = [string]$ecV }

    $null = $out.Add('')
    $null = $out.Add('═══ ② 系统返回的原文（照抄；不美化、不吞掉、不猜测）═══')
    if ($null -eq $ver) {
        $vnote = [string](Get-LctField $data @('verdictNote') '')
        if (-not $vnote) { $vnote = '预览：未执行任何 sc.exe 动作（data.verdict 为 null）' }
        $null = $out.Add('  （本次没有 verdict：' + $vnote + '）')
        $null = $out.Add('  真正执行（② 应用）之后，这里会照抄系统返回码与系统原文。')
    } else {
        $null = $out.Add("  verdict.exitCode ：$ecText")
        if ($msgV) { $null = $out.Add("  verdict.message  ：$msgV") }
        else { $null = $out.Add('  verdict.message  ：（空：系统没有给出文字说明）') }
        $null = $out.Add("  系统判定          ：osBlocked=$(Format-LctBoolCn (Get-LctField $ver @('osBlocked') $null))   systemAccepted=$(Format-LctBoolCn (Get-LctField $ver @('systemAccepted') $null))   goalMet=$(Format-LctNumOrDash (Get-LctField $ver @('goalMet') $null))")
        $hintV = [string](Get-LctField $ver @('hint') '')
        if ($hintV) { $null = $out.Add('  判定参考（非系统原文，仅供阅读）：' + $hintV) }
        $null = $out.Add('')
        $null = $out.Add('  ★ 「我们已执行动作」与「系统是否真的加载成功」是两件事：')
        $null = $out.Add('    exitCode=0 = 系统接受了；例：577 = 系统拒绝（无法验证数字签名）；193 = 镜像无效；')
        $null = $out.Add('    1058 / 1053 / 2 / 1 / 127 / 0xC000012F 等一律按系统原话呈现，本工具不改写。')
        $null = $out.Add('    驱动到底有没有被加载，以系统返回码为准，并请看「加载后复核」。')
    }
    $sigV = Get-LctField $data @('signature', 'authenticode', 'signatureText', 'signatureStatus', 'signatureSummary') $null
    if (-not [string]::IsNullOrEmpty([string]$sigV)) { $null = $out.Add('  签名摘要（仅信息展示，不作为拒绝理由）：' + [string]$sigV) }
    if ((Get-LctField $data @('likelyTestSigned') $null) -eq $true) { $null = $out.Add('  该镜像疑似 test-signed（仅信息展示，不构成本工具的门槛）。') }
    if (-not [string]::IsNullOrEmpty([string](Get-LctField $data @('riskNote') ''))) { $null = $out.Add('  ⚠ ' + [string](Get-LctField $data @('riskNote') '')) }
    $revV = Get-LctField $data @('revertCmdPath', 'revertCmd', 'revertFile', 'revertScript') $null
    if (-not [string]::IsNullOrEmpty([string]$revV)) {
        $null = $out.Add('  已生成回滚脚本 revert.cmd：' + [string]$revV)
        $ps1V = Get-LctField $data @('revertPs1Path') $null
        if (-not [string]::IsNullOrEmpty([string]$ps1V)) { $null = $out.Add('  另有精确重建脚本（.ps1）    ：' + [string]$ps1V) }
        $null = $out.Add('  fileKept=' + (Format-LctBoolCn (Get-LctField $data @('fileKept') $null)) + ' ⇒ 卸载只删服务项，.sys 文件保留。')
    }
    $planV = @(Get-LctArray (Get-LctField $data @('plan') $null))
    if (@($planV).Count -gt 0) {
        $null = $out.Add('')
        $null = $out.Add('—— 引擎给出的计划（plan[]，仅说明它准备做什么）——')
        foreach ($pg in $planV) { $null = $out.Add('  · ' + [string]$pg) }
    }
    $limV = @(Get-LctArray (Get-LctField $data @('limitations') $null))
    if (@($limV).Count -gt 0) {
        $null = $out.Add('')
        $null = $out.Add('—— 后端声明的边界（limitations[]）——')
        foreach ($lm in $limV) { $null = $out.Add('  · ' + [string]$lm) }
    }
    $null = $out.Add('')
    $null = $out.Add('—— 引擎原始 JSON ——')
    try { $null = $out.Add((ConvertTo-Json -InputObject $Result -Depth 8)) } catch { $null = $out.Add([string]$Result) }
    return @($out)
}

function Show-LctDriverActionResult {
    # 把动作结果写进结果区（默认「指定驱动并加载」的结果框；-ToAction 时写停止/卸载/启动的结果框）。
    param($Result, [switch]$ToAction)
    $target = $script:DriverLoadBox
    if ($ToAction) { $target = $script:DriverActionBox }
    if ($null -eq $target) { return }
    $lines = @(Format-LctDriverActionLines -Result $Result)
    $target.Text = (@($lines) -join "`r`n")
    $target.SelectionStart = 0
    $target.SelectionLength = 0
}

function Show-LctDriverTsResult {
    param($Result)
    if ($null -eq $script:DriverTsBox) { return }
    $head = New-Object System.Collections.ArrayList
    $null = $head.Add('★ test-signing 开关结果（引擎执行 bcdedit /set testsigning on|off）★')
    $null = $head.Add('  提醒：这个开关【需重启生效】—— 引擎会先记录原值，系统在重启后才按新值运行。')
    $null = $head.Add('  本工具只做动作执行与信息展示；系统是否真的接受（Secure Boot 拒绝等）看下面原文。')
    $dts = Get-LctDataDeep -Result $Result
    if ($null -ne $dts) {
        $gateObj = Get-LctField $dts @('gate') $null
        if ((Get-LctField $gateObj @('allowed') $null) -eq $false) {
            $null = $head.Add('')
            $null = $head.Add('★ 后端拒绝（gate.allowed=false，原因原文）：' + [string](Get-LctField $gateObj @('reason') '（后端未给出 reason）'))
        }
        if ((Get-LctField $dts @('needsRestart') $null) -eq $true) {
            $nrText = [string](Get-LctField $dts @('needsRestartText') '')
            if (-not $nrText) { $nrText = '★ 需重启生效 ★' }
            $null = $head.Add('★ ' + $nrText)
        }
        $bfV = Get-LctField $dts @('before') $null
        $afV = Get-LctField $dts @('after') $null
        if ($null -ne $bfV -or $null -ne $afV) { $null = $head.Add('  bcdedit testsigning：' + (Format-LctBoolCn $bfV) + ' → ' + (Format-LctBoolCn $afV)) }
        $bcdCmd = [string](Get-LctField $dts @('bcdeditCommand') '')
        if ($bcdCmd) { $null = $head.Add('  执行命令（原文）：' + $bcdCmd) }
    }
    $null = $head.Add('')
    $lines = @(Format-LctDriverActionLines -Result $Result)
    $script:DriverTsBox.Text = ((@($head) + @($lines)) -join "`r`n")
    $script:DriverTsBox.SelectionStart = 0
    $script:DriverTsBox.SelectionLength = 0
}

function Update-LctDriverTsControls {
    # Secure Boot=True ⇒ 「开启 test-signing」按钮禁用，并显示后端会拒绝的原因。
    $sbOn = Test-LctDriverSecureBootOn
    $allowed = ($sbOn -ne $true)
    if ($null -ne $script:DriverTsEnablePreviewBtn) { $script:DriverTsEnablePreviewBtn.Enabled = $allowed }
    if ($null -ne $script:DriverTsEnableApplyBtn) { $script:DriverTsEnableApplyBtn.Enabled = $allowed }
    $note = '（Secure Boot 取值未知：引擎还没返回该字段，开启前请自行确认 Secure Boot 已关闭。）'
    if ($sbOn -eq $true) {
        $note = '★ 检测到 Secure Boot=True ⇒「开启 test-signing」已禁用：后端会【拒绝开启】（Secure Boot 开启时 bcdedit /set testsigning on 不可用）。要开启请先在固件（UEFI）里关闭 Secure Boot 并重启。'
    } elseif ($sbOn -eq $false) {
        $note = 'Secure Boot=False ⇒ 可以开启 test-signing（后端会先记录原值；应用后 ★需重启生效★）。'
    }
    if ($null -ne $script:DriverTsSbNote) {
        $script:DriverTsSbNote.Text = $note
        if ($sbOn -eq $true) { $script:DriverTsSbNote.ForeColor = $script:C.Err } else { $script:DriverTsSbNote.ForeColor = $script:C.Dim }
    }
}

function Update-LctDriverStartTypeNote {
    # 危险启动类型的红字后果说明（契约 §12.4 第 2 条）。
    if ($null -eq $script:DriverStartTypeNote) { return }
    $stype = 'demand'
    if ($null -ne $script:DriverStartTypeBox) { $stype = [string]$script:DriverStartTypeBox.Text.Trim().ToLowerInvariant() }
    if ($stype -eq 'system' -or $stype -eq 'boot') {
        $script:DriverStartTypeNote.Text = "★ 危险：启动类型 $stype = 开机即载（系统启动时就尝试加载）。驱动有问题时可能蓝屏或无法启动 —— 最坏情况下次开机进不去系统，需要进安全模式或离线删除服务项。引擎对 system/boot 强制要求 override，界面会自动带上。"
        $script:DriverStartTypeNote.ForeColor = $script:C.Err
    } elseif ($stype -eq 'demand') {
        $script:DriverStartTypeNote.Text = 'demand（手动，默认）= 最安全：只有本工具或你显式启动时才加载，重启后不会自动载入。'
        $script:DriverStartTypeNote.ForeColor = $script:C.Ok
    } else {
        $script:DriverStartTypeNote.Text = "启动类型「$stype」不属于 demand/system/boot，应用时按 demand（手动）处理。"
        $script:DriverStartTypeNote.ForeColor = $script:C.Warn
    }
}

function Update-LctDriverStatus {
    # 状态区（driver.status，只读）：Secure Boot / test-signing 当前值 / nointegritychecks / VBS / 驱动数与运行数 / 自管服务。
    if ($null -eq $script:DriverStatusBox) { return }
    $r = Invoke-LctEngine -Verb 'driver.status'
    $out = New-Object System.Collections.ArrayList
    $null = $out.Add('═══ 驱动加载前提（driver.status，只读）═══')
    if ($r.ok -and $null -ne $r.data) {
        $d = Get-LctDataDeep -Result $r -KeyName 'secureBoot'
        $secV = Get-LctField $d @('secureBoot', 'secureBootEnabled', 'secureBootStatus') $null
        $secSrcV = [string](Get-LctField $d @('secureBootSource') '—')
        $tsV = Get-LctField $d @('testSigning', 'testSigningEnabled', 'testsigning', 'testSignStatus') $null
        $tsSrcV = [string](Get-LctField $d @('testSigningSource') '—')
        $niV = Get-LctField $d @('noIntegrityChecks', 'nointegritychecks', 'noIntegrityCheck') $null
        $vbsObj = Get-LctField $d @('vbs') $null
        $vbsText = [string](Get-LctField $vbsObj @('statusText', 'status') '')
        $hvRunV = Get-LctField $vbsObj @('hvciRunning') $null
        $hvCfgV = Get-LctField $vbsObj @('hvciConfigured') $null
        $bcdExitV = Get-LctField $d @('bcdeditExitCode') $null
        $sbErrV = [string](Get-LctField $d @('secureBootProbeError') '')
        $cimErrV = [string](Get-LctField $d @('cimError') '')
        $ddwNote = [string](Get-LctField $d @('driversDirectoryWritableNote') '')
        $totV = Get-LctField $d @('driverTotal', 'driverCount', 'totalDrivers', 'total') $null
        $runV = Get-LctField $d @('driverRunning', 'runningCount', 'runningDrivers', 'running') $null
        $elV = Get-LctField $d @('elevated', 'isElevated') $null
        $ownV = Get-LctField $d @('selfManagedServices', 'managedServices', 'ownServices', 'lctServices') $null
        $ownCntV = Get-LctField $d @('selfManagedCount') $null
        $ownPfxV = [string](Get-LctField $d @('selfManagedPrefix') '')
        $ddV = Get-LctField $d @('driversDirectory', 'driversDir') $null
        $tsText = Format-LctBoolCn $tsV
        $niText = Format-LctBoolCn $niV
        $ddText = ''
        if ($null -ne $ddV) { $ddText = [string]$ddV }
        if (-not $vbsText) { $vbsText = '—' }
        $ownSuffix = ''
        if ($ownPfxV) { $ownSuffix = "，前缀 $ownPfxV" }
        $ownCount = ''
        if ($null -ne $ownCntV) { $ownCount = "（$ownCntV 项$ownSuffix）" }
        $dseText = '强制（test-signing=否 且 nointegritychecks=否）'
        if ($tsText -eq '是' -or $niText -eq '是') { $dseText = "已放行（test-signing=$tsText，nointegritychecks=$niText）" }

        $null = $out.Add("Secure Boot            ：$(Format-LctBoolCn $secV)    （来源：$secSrcV）")
        $null = $out.Add("test-signing 当前值     ：$tsText    （来源：$tsSrcV）")
        $null = $out.Add("nointegritychecks      ：$niText    （来源：$([string](Get-LctField $d @('noIntegrityChecksSource') '—'))）")
        $null = $out.Add("驱动签名强制（推断）    ：$dseText")
        $null = $out.Add("VBS（DeviceGuard）      ：$vbsText")
        $null = $out.Add("HVCI                   ：运行=$(Format-LctBoolCn $hvRunV)   配置=$(Format-LctBoolCn $hvCfgV)")
        $null = $out.Add("驱动服务总数 / 运行中   ：$(Format-LctNumOrDash $totV) / $(Format-LctNumOrDash $runV)    （来自 Win32_SystemDriver 状态映射）")
        $null = $out.Add("本工具自管服务清单      ：$ownCount$(Format-LctDriverPlainList $ownV)")
        $null = $out.Add("System32\drivers 目录   ：$ddText")
        $null = $out.Add("bcdedit 读取           ：exitCode=$(Format-LctNumOrDash $bcdExitV)")
        $null = $out.Add("引擎身份 / 是否提权     ：$(Format-LctBoolCn $elV)")
        if ($ddwNote) { $null = $out.Add("可写性说明             ：$ddwNote") }
        if ($sbErrV) { $null = $out.Add("⚠ Secure Boot 探测失败  ：$sbErrV") }
        if ($cimErrV) { $null = $out.Add("⚠ 驱动枚举（CIM）失败   ：$cimErrV") }
        $bcdLines = @(Get-LctArray (Get-LctField $d @('testSigningBcdLines') $null))
        foreach ($bl in $bcdLines) {
            $blText = ([string]$bl).Trim()
            if ($blText) { $null = $out.Add('  bcdedit 原文：' + $blText) }
        }
        foreach ($lm0 in @(Get-LctArray (Get-LctField $d @('limitations') $null))) { $null = $out.Add('  · 边界：' + [string]$lm0) }
        $null = $out.Add('')
        if ($tsText -eq '是') {
            $null = $out.Add('★ test-signing = Yes ⇒ 未签名驱动现在可以被系统加载（DSE 已放行）。')
            $null = $out.Add('  口径提醒：签名只做信息展示，能不能加载一直由操作系统判定。')
        } else {
            $null = $out.Add('★ test-signing = No ⇒ 未签名驱动会被系统拒绝（典型 sc start 返回 577 无法验证数字签名）。')
            $null = $out.Add('  口径提醒：本工具不拿签名当门槛，拒绝与否以系统返回原文为准。')
        }
        $null = $out.Add('')
        $null = $out.Add('—— 引擎原始 JSON（driver.status）——')
        try { $null = $out.Add((ConvertTo-Json -InputObject $d -Depth 8)) } catch { $null = $out.Add([string]$d) }

        $script:DriverSecureBootValue = $secV
        $script:DriverTestSigningValue = $tsV
        if ($null -ne $script:DriverSbBanner) {
            $script:DriverSbBanner.Text = "Secure Boot：$(Format-LctBoolCn $secV)    test-signing：$tsText"
            if ($tsText -eq '是') { $script:DriverSbBanner.ForeColor = $script:C.Ok }
            else { $script:DriverSbBanner.ForeColor = $script:C.Warn }
        }
        if ($null -ne $script:DriverTsValueLabel) { $script:DriverTsValueLabel.Text = "test-signing 当前值：$tsText" }
    } else {
        $null = $out.Add('driver.status 调用失败（后端 core\Drivers.psm1 可能尚未就绪；这不是前端 bug）：')
        foreach ($e in @(Get-LctArray $r.errors)) { $null = $out.Add('  ✖ ' + [string]$e) }
        $null = $out.Add('')
        $null = $out.Add('（修好后端后点「刷新状态」即可；页面其它区域照常可用。）')
        if ($null -ne $script:DriverSbBanner) {
            $script:DriverSbBanner.Text = 'Secure Boot：—    test-signing：—'
            $script:DriverSbBanner.ForeColor = $script:C.Dim
        }
    }
    $script:DriverStatusBox.Text = (@($out) -join "`r`n")
    $script:DriverStatusBox.SelectionStart = 0
    $script:DriverStatusBox.SelectionLength = 0
    Update-LctDriverTsControls
}

function Update-LctDriverList {
    # 驱动清单（driver.list，只读）。后端按 Lead 要求返回包装对象 {items,count}；
    # 若返回的是裸数组（§11.6 会折成 null / 单对象 / 数组），用 @(...) 归一化兜底。
    if ($null -eq $script:DrvGrid) { return }
    $r = Invoke-LctEngine -Verb 'driver.list'
    $script:SuppressDrvSel = $true
    try {
        Clear-LctGrid $script:DrvGrid
        $script:DriverListCache = @()
        if (-not $r.ok) {
            if ($null -ne $script:DriverListCount) { $script:DriverListCount.Text = '驱动清单调用失败（见底部日志面板）' }
            Add-LctGridRow -Grid $script:DrvGrid -Key '' -Values @('（driver.list 调用失败：后端模块可能尚未就绪）', '', '', '', '', '')
            return
        }
        $rd = Get-LctDataDeep -Result $r -KeyName 'items'
        $itemsRaw = Get-LctProp $rd 'items' $null
        if ($null -ne $itemsRaw) { $script:DriverListCache = @(Get-LctArray $itemsRaw) }
        else { $script:DriverListCache = @(Get-LctArray $rd) }
        foreach ($x in @($script:DriverListCache)) {
            if ($x -is [string]) {
                Add-LctGridRow -Grid $script:DrvGrid -Key $x -Values @($x, '', '', '', '', '')
                continue
            }
            $nm = [string](Get-LctField $x @('name', 'serviceName') '')
            $stt = [string](Get-LctField $x @('state', 'status', 'stateText') '')
            $stype = [string](Get-LctField $x @('startMode', 'startType', 'start', 'startTypeText') '')
            $pth = [string](Get-LctField $x @('path', 'imagePath', 'binaryPath', 'image') '')
            $checkedV = Get-LctField $x @('infoChecked') $null
            $hash = [string](Get-LctField $x @('sha256', 'hash') '')
            if (-not $hash) {
                if ($checkedV -eq $false) { $hash = '未核验（策略：仅过滤/≤60 条时核验）' } else { $hash = '（未读到 hash）' }
            }
            $sigClass = [string](Get-LctField $x @('signatureClass', 'signature', 'authenticode') '')
            $sigStatus = [string](Get-LctField $x @('signatureStatus', 'signatureText', 'signatureSummary') '')
            $signer = [string](Get-LctField $x @('signerSubject') '')
            $sig = ''
            if ($sigClass) { $sig = $sigClass }
            if ($sigStatus) { if ($sig) { $sig += ' / ' }; $sig += $sigStatus }
            if ((Get-LctField $x @('likelyTestSigned') $null) -eq $true) { $sig += '（疑似 test-signed）' }
            if ($signer) { $sig += '  签名者：' + $signer }
            if (-not $sig) {
                if ($checkedV -eq $false) { $sig = '未核验' } else { $sig = '—' }
            }
            Add-LctGridRow -Grid $script:DrvGrid -Key $nm -Values @($nm, $stt, $stype, $pth, $hash, $sig)
        }
        $realCount = $script:DrvGrid.Rows.Count
        if ($realCount -eq 0) {
            Add-LctGridRow -Grid $script:DrvGrid -Key '' -Values @('（清单里没有驱动服务）', '', '', '', '', '')
        }
        $cntV = Get-LctField $rd @('count') $null
        $totAllV = Get-LctField $rd @('total') $null
        $icCheckedV = Get-LctField $rd @('infoChecked') $null
        if ($null -eq $script:DriverListMetaText) { $script:DriverListMetaText = '' }
        $lstErr = [string](Get-LctField $rd @('error') '')
        $infoPol = [string](Get-LctField $rd @('infoPolicy') '')
        $listNote = [string](Get-LctField $rd @('note') '')
        $cimTotV = Get-LctField $rd @('cimDriverTotal') $null
        $script:DriverListMetaText = ''
        if ($infoPol) { $script:DriverListMetaText += 'SHA256 / 签名核验策略：' + $infoPol + "`r`n" }
        if ($listNote) { $script:DriverListMetaText += '清单说明：' + $listNote + "`r`n" }
        if ($null -ne $cimTotV) { $script:DriverListMetaText += 'Win32_SystemDriver 总数：' + (Format-LctNumOrDash $cimTotV) + '（注册表 Services 权威数可能更大：从未成功启动过的服务不出现在 CIM 里）' + "`r`n" }
        if ($null -ne $icCheckedV) { $script:DriverListMetaText += '本次已核验 hash/签名条数：' + (Format-LctNumOrDash $icCheckedV) + "`r`n" }
        if ($lstErr) { $script:DriverListMetaText += 'driver.list 报告：' + $lstErr + "`r`n" }
        if ($null -ne $script:DriverListCount) {
            $cl = "驱动服务数：$(Format-LctNumOrDash $cntV)"
            if ($null -ne $totAllV) { $cl += "（注册表 kernel/fs 驱动 $(Format-LctNumOrDash $totAllV)）" }
            $cl += "   表格行 $realCount"
            if ($null -ne $icCheckedV) { $cl += "   已核验 $icCheckedV" }
            $script:DriverListCount.Text = $cl
        }
        if ($lstErr) { Add-LctLogLine "  ⚠ driver.list 报告：$lstErr" $script:C.Warn }
        if ($script:DrvGrid.Rows.Count -gt 0) { $script:DrvGrid.Rows[0].Selected = $true }
    } finally {
        $script:SuppressDrvSel = $false
    }
    Update-LctDriverDetail
}

function Update-LctDriverDetail {
    # 选中行详情（driver.info，只读）。hash / Authenticode / 是否 test-signed 全部只做信息展示。
    # 注意：任何分支都必须写出文本（UiPageSmoke 会断言详情框非空）。
    if ($null -eq $script:DrvDetailBox) { return }
    $out = New-Object System.Collections.ArrayList
    $key = ''
    if ($null -ne $script:DrvGrid -and $script:DrvGrid.SelectedRows.Count -gt 0) {
        $key = Get-LctRowCell -Row $script:DrvGrid.SelectedRows[0] -Column 'rowkey'
    }
    if (-not $key) {
        $null = $out.Add('（请先在上面的驱动清单里选中一行，这里会显示 driver.info 的 hash / Authenticode / 是否 test-signed）')
        $null = $out.Add('')
        $null = $out.Add('提示：driver.info 只读、不落盘；签名信息仅用于展示，不构成本工具的加载门槛。')
        if ($script:DriverListMetaText) {
            $null = $out.Add('')
            $null = $out.Add('—— driver.list 附加说明 ——')
            foreach ($ml in @(([string]$script:DriverListMetaText) -split "`r?`n")) {
                if ($ml.Trim()) { $null = $out.Add('  ' + $ml.Trim()) }
            }
        }
        $script:DrvDetailBox.Text = (@($out) -join "`r`n")
        return
    }
    $found = $null
    foreach ($x in @($script:DriverListCache)) {
        if ($x -is [string]) { if ($x -eq $key) { $found = $x; break }; continue }
        if ([string](Get-LctField $x @('name', 'serviceName') '') -eq $key) { $found = $x; break }
    }
    $null = $out.Add("驱动服务名 ：$key")
    $sysPath = ''
    if ($null -ne $found -and -not ($found -is [string])) {
        $stt = [string](Get-LctField $found @('state', 'status', 'stateText') '')
        $stype = [string](Get-LctField $found @('startMode', 'startType', 'start', 'startTypeText') '')
        if (-not $stt) { $stt = '—' }
        if (-not $stype) { $stype = '—' }
        $sysPath = [string](Get-LctField $found @('path', 'imagePath', 'binaryPath', 'image') '')
        $checkedV2 = Get-LctField $found @('infoChecked') $null
        $hashCol = [string](Get-LctField $found @('sha256', 'hash') '')
        if (-not $hashCol) {
            if ($checkedV2 -eq $false) { $hashCol = '未核验（策略：仅过滤/≤60 条时核验）' } else { $hashCol = '—' }
        }
        $sigCol = [string](Get-LctField $found @('signatureClass') '')
        $sigColSt = [string](Get-LctField $found @('signatureStatus') '')
        if ($sigColSt) { if ($sigCol) { $sigCol += ' / ' }; $sigCol += $sigColSt }
        $sigColSigner = [string](Get-LctField $found @('signerSubject') '')
        if ($sigColSigner) { $sigCol += '  签名者：' + $sigColSigner }
        if (-not $sigCol) { $sigCol = '—' }
        $null = $out.Add("状态       ：$stt")
        $null = $out.Add("启动类型   ：$stype    （typeText=$(Get-LctField $found @('typeText') '—')）")
        $null = $out.Add("清单里的 hash ：$hashCol")
        $null = $out.Add("清单里的签名   ：$sigCol")
    } else {
        $null = $out.Add('（该行不在当前清单缓存里：点「刷新清单（driver.list）」重读一次）')
    }
    $null = $out.Add('')
    if (-not $sysPath) {
        $null = $out.Add('这一行没有可用的镜像路径，跳过 driver.info。')
        $null = $out.Add('（driver.info 需要一个 .sys 的完整路径；也可以在左侧「驱动 .sys」框里填路径后自行核对。）')
        $script:DrvDetailBox.Text = (@($out) -join "`r`n")
        return
    }
    $null = $out.Add("镜像路径   ：$sysPath")
    $ri = Invoke-LctEngine -Verb 'driver.info' -Args @{ path = $sysPath }
    if ($ri.ok -and $null -ne $ri.data) {
        $di = Get-LctDataDeep -Result $ri -KeyName 'sha256'
        $hashV = Get-LctField $di @('sha256', 'hash') $null
        $tsV = Get-LctField $di @('likelyTestSigned', 'testSigned', 'isTestSigned') $null
        $szV = Get-LctField $di @('lengthBytes', 'size', 'length', 'sizeBytes') $null
        $mtV = Get-LctField $di @('lastWrite', 'lastWriteTime', 'modified') $null
        $exV = Get-LctField $di @('exists', 'fileExists') $null
        $hashText = '—'
        if ($null -ne $hashV) { $hashText = [string]$hashV }
        $null = $out.Add("文件存在   ：$(Format-LctBoolCn $exV)   .sys 扩展名=$(Format-LctBoolCn (Get-LctField $di @('isSysExtension') $null))")
        $null = $out.Add("大小       ：$(Format-LctNumOrDash $szV)")
        $null = $out.Add("修改时间   ：$(Format-LctNumOrDash $mtV)")
        $null = $out.Add("完整路径   ：$(Get-LctField $di @('fullPath') '—')")
        $null = $out.Add("SHA256     ：$hashText")
        $null = $out.Add("签名类别   ：$([string](Get-LctField $di @('signatureClass') '—'))")
        $null = $out.Add("签名状态   ：$([string](Get-LctField $di @('signatureStatus', 'authenticodeText', 'signatureText', 'authenticode') '—'))   $([string](Get-LctField $di @('signatureStatusMessage') ''))")
        $null = $out.Add("签名者     ：$([string](Get-LctField $di @('signerSubject') '—'))   Microsoft 签名=$(Format-LctBoolCn (Get-LctField $di @('isMicrosoftSigner') $null))")
        $null = $out.Add("是否 test-signed：$(Format-LctBoolCn $tsV)")
        $diErr = [string](Get-LctField $di @('error') '')
        if ($diErr) { $null = $out.Add("⚠ 探测报告 ：$diErr") }
        $null = $out.Add("后端说明   ：$([string](Get-LctField $di @('note') '—'))")
        $null = $out.Add('')
        $null = $out.Add('★ 口径（契约 §12.1）：以上 hash 与签名只做【信息展示】。本工具不因为「没签名」就拒绝加载；')
        $null = $out.Add('  能不能加载由操作系统判定，系统拒绝时的原文会在「① 预览 / ② 应用」结果区里照抄。')
        $null = $out.Add('')
        $null = $out.Add('—— 引擎原始 JSON（driver.info）——')
        try { $null = $out.Add((ConvertTo-Json -InputObject $di -Depth 8)) } catch { $null = $out.Add([string]$di) }
    } else {
        $null = $out.Add('driver.info 调用失败（后端模块可能尚未就绪）：')
        foreach ($e in @(Get-LctArray $ri.errors)) { $null = $out.Add('  ✖ ' + [string]$e) }
    }
    $script:DrvDetailBox.Text = (@($out) -join "`r`n")
    $script:DrvDetailBox.SelectionStart = 0
    $script:DrvDetailBox.SelectionLength = 0
}

function Update-LctDrivers {
    # 页面填充入口（Lead 的 UiPageSmoke / DriverTest 按名调用）：状态 + 清单 + 详情，全部只读。
    try { Update-LctDriverStatus }
    catch { Add-LctLogLine "  ✖ 驱动状态区渲染异常：$($_.Exception.Message)" $script:C.Err }
    try { Update-LctDriverList }
    catch { Add-LctLogLine "  ✖ 驱动清单渲染异常：$($_.Exception.Message)" $script:C.Err }
}

function Get-LctSelectedDriverName {
    $key = ''
    if ($null -ne $script:DrvGrid -and $script:DrvGrid.SelectedRows.Count -gt 0) {
        $key = Get-LctRowCell -Row $script:DrvGrid.SelectedRows[0] -Column 'rowkey'
    }
    if ($key) { return $key }
    if ($null -ne $script:DriverNameBox) { return [string]$script:DriverNameBox.Text.Trim() }
    return ''
}

function Get-LctDriverTargetName {
    # 停止 / 卸载 / 复核 / 仅启动的目标：优先左侧「服务名」框（允许手工填），否则用清单选中行。
    $nm = ''
    if ($null -ne $script:DriverNameBox) { $nm = [string]$script:DriverNameBox.Text.Trim() }
    if ($nm) { return $nm }
    return (Get-LctSelectedDriverName)
}

function Get-LctDriverLoadArgBag {
    # 待应用项的参数包必须真的装东西（本项目曾因形参用 $Args 被自动变量顶掉，导致所有页面发空 {}）。
    $pth = ''
    if ($null -ne $script:DriverPathBox) { $pth = [string]$script:DriverPathBox.Text.Trim() }
    $nm = ''
    if ($null -ne $script:DriverNameBox) { $nm = [string]$script:DriverNameBox.Text.Trim() }
    $stype = 'demand'
    if ($null -ne $script:DriverStartTypeBox) { $stype = [string]$script:DriverStartTypeBox.Text.Trim().ToLowerInvariant() }
    if ($stype -ne 'demand' -and $stype -ne 'system' -and $stype -ne 'boot') { $stype = 'demand' }
    $ovr = ($stype -eq 'system' -or $stype -eq 'boot')   # 契约 §12.4：system/boot 必须 -Override
    return @{ path = $pth; name = $nm; startType = $stype; stage = $false; override = $ovr }
}

function Invoke-LctDriverLoadPreview {
    if ($null -eq $script:DriverLoadBox) { return }
    $bag = Get-LctDriverLoadArgBag
    if (-not $bag['path']) {
        $null = [System.Windows.Forms.MessageBox]::Show('请先填「驱动 .sys」路径（或点「浏览 .sys…」选一个文件）。', '参数不足', 'OK', 'Warning')
        return
    }
    if ($bag['startType'] -eq 'system' -or $bag['startType'] -eq 'boot') {
        $dr = [System.Windows.Forms.MessageBox]::Show(
            "你选的启动类型是 $($bag['startType'])：开机即载。`r`n`r`n后果：驱动有问题时可能蓝屏，甚至无法启动（下次开机进不去系统，需要进安全模式或离线删除服务项）。`r`n引擎对 system/boot 强制要求 override，界面会自动带上它。`r`n`r`n继续预览吗？（预览本身不落盘）",
            '危险：开机即载', [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Warning,
            [System.Windows.Forms.MessageBoxDefaultButton]::Button2)
        if ($dr -ne [System.Windows.Forms.DialogResult]::Yes) { return }
    }
    $sum = "加载驱动：$($bag['path'])"
    if ($bag['name']) { $sum += "（服务名 $($bag['name'])）" } else { $sum += '（服务名由引擎按文件名推导）' }
    $sum += "  启动类型=$($bag['startType'])"
    $r = Invoke-LctPreview -Page 'drivers' -Id 'load' -Verb 'driver.load' -Args $bag -Summary $sum
    if ($null -ne $r) { Show-LctDriverActionResult -Result $r }
}

function Invoke-LctDriverLoadApply {
    $bag = Get-LctDriverLoadArgBag
    if (-not $bag['path']) {
        $null = [System.Windows.Forms.MessageBox]::Show('请先填「驱动 .sys」路径，并先点「① 预览：加载」通过预览。', '参数不足', 'OK', 'Warning')
        return
    }
    if (@(Get-LctPending -Page 'drivers' -Id 'load').Count -eq 0) {
        $null = [System.Windows.Forms.MessageBox]::Show('必须先点「① 预览：加载」并通过预览（预览不落盘），才能点「② 应用：加载」。', '需要先预览', 'OK', 'Warning')
        return
    }
    Invoke-LctApplyPending -Page 'drivers' -Id 'load'
    $lr = $script:LastResult
    if ($null -ne $lr -and [string](Get-LctProp $lr 'verb' '') -eq 'driver.load') { Show-LctDriverActionResult -Result $lr }
    Update-LctDriverList
}

function Invoke-LctDriverPendingApply {
    # 停止 / 卸载 / 仅启动 的应用闸门：没有对应的预览登记就拒绝，避免误点。
    param([string]$Id = '', [string]$Hint = '')
    if (-not $Id) { return }
    if (@(Get-LctPending -Page 'drivers' -Id $Id).Count -eq 0) {
        $msg = '必须先点对应的「① 预览」并通过预览（预览不落盘），才能点「② 应用」。'
        if ($Hint) { $msg += "`r`n`r`n$Hint" }
        $null = [System.Windows.Forms.MessageBox]::Show($msg, '需要先预览', 'OK', 'Warning')
        return
    }
    Invoke-LctApplyPending -Page 'drivers' -Id $Id
    $lr = $script:LastResult
    if ($null -ne $lr -and [string](Get-LctProp $lr 'verb' '') -like 'driver.*') { Show-LctDriverActionResult -Result $lr -ToAction }
    Update-LctDriverList
}

function Invoke-LctDriverStartPreview {
    $nm = Get-LctDriverTargetName
    if (-not $nm) {
        $null = [System.Windows.Forms.MessageBox]::Show('请先在上表选中一行，或在左侧「服务名」框里填写要启动的服务名。', '缺少目标', 'OK', 'Warning')
        return
    }
    $r = Invoke-LctPreview -Page 'drivers' -Id "start:$nm" -Verb 'driver.start' -Args @{ name = $nm } -Summary "启动已有驱动服务：$nm"
    if ($null -ne $r) { Show-LctDriverActionResult -Result $r -ToAction }
}

function Invoke-LctDriverStartApply {
    Invoke-LctDriverPendingApply -Id ('start:' + (Get-LctDriverTargetName)) -Hint '启动只会启动已存在的服务项，不创建新的服务。'
}

function Invoke-LctDriverStopPreview {
    $nm = Get-LctDriverTargetName
    if (-not $nm) {
        $null = [System.Windows.Forms.MessageBox]::Show('请先在上表选中一行，或在左侧「服务名」框里填写要停止的服务名。', '缺少目标', 'OK', 'Warning')
        return
    }
    $r = Invoke-LctPreview -Page 'drivers' -Id "stop:$nm" -Verb 'driver.stop' -Args @{ name = $nm } -Summary "停止驱动服务（不删服务项）：$nm"
    if ($null -ne $r) { Show-LctDriverActionResult -Result $r -ToAction }
}

function Invoke-LctDriverStopApply {
    Invoke-LctDriverPendingApply -Id ('stop:' + (Get-LctDriverTargetName)) -Hint '停止 = 只停服务，不删服务项，也不动 .sys 文件。'
}

function Invoke-LctDriverUnloadPreview {
    $nm = Get-LctDriverTargetName
    if (-not $nm) {
        $null = [System.Windows.Forms.MessageBox]::Show('请先在上表选中一行，或在左侧「服务名」框里填写要卸载的服务名。', '缺少目标', 'OK', 'Warning')
        return
    }
    $r = Invoke-LctPreview -Page 'drivers' -Id "unload:$nm" -Verb 'driver.unload' -Args @{ name = $nm } `
        -Summary "卸载驱动服务：$nm（只删服务项，不删 .sys 文件，并会生成 revert.cmd）"
    if ($null -ne $r) { Show-LctDriverActionResult -Result $r -ToAction }
}

function Invoke-LctDriverUnloadApply {
    Invoke-LctDriverPendingApply -Id ('unload:' + (Get-LctDriverTargetName)) -Hint '卸载 = 停服务 + 删服务项；绝不删 .sys 文件；并生成 revert.cmd（含重建命令与原始参数）供回滚。'
}

function Invoke-LctDriverVerifyRead {
    # 加载后复核（driver.verify，只读）：三档结论着色 + 系统事件原文（7000 / 7026 / 219）。
    if ($null -eq $script:DriverVerifyBox) { return }
    $nm = Get-LctDriverTargetName
    if (-not $nm) {
        $script:DriverVerifyBox.Text = '请先在上表选中一行，或在左侧「服务名」框里填写要复核的服务名（driver.verify 需要一个服务名）。'
        if ($null -ne $script:DriverVerifyTierBox) {
            $script:DriverVerifyTierBox.Text = '结论：—'
            $script:DriverVerifyTierBox.ForeColor = $script:C.Dim
        }
        return
    }
    $r = Invoke-LctEngine -Verb 'driver.verify' -Args @{ name = $nm } -TimeoutSec 120
    $out = New-Object System.Collections.ArrayList
    $null = $out.Add("═══ 加载后复核（driver.verify，只读）：$nm ═══")
    if (-not ($r.ok -and $null -ne $r.data)) {
        $null = $out.Add('driver.verify 调用失败（后端模块可能尚未就绪）：')
        foreach ($e in @(Get-LctArray $r.errors)) { $null = $out.Add('  ✖ ' + [string]$e) }
        $script:DriverVerifyBox.Text = (@($out) -join "`r`n")
        if ($null -ne $script:DriverVerifyTierBox) {
            $script:DriverVerifyTierBox.Text = '结论：状态不明（复核接口未就绪）'
            $script:DriverVerifyTierBox.ForeColor = $script:C.Warn
        }
        return
    }
    $d = Get-LctDataDeep -Result $r
    $conclV = [string](Get-LctField $d @('conclusion', 'tier', 'verdictText') '')
    $tierText = [string](Get-LctField $d @('conclusionText', 'conclusion', 'tierText', 'summary') '')
    $runVal = Get-LctField $d @('running', 'actuallyRunning', 'isRunning', 'loaded', 'started', 'serviceRunning') $null
    $stateText = [string](Get-LctField $d @('stateText', 'state', 'status', 'serviceState') '—')
    $reasonV = [string](Get-LctField $d @('verdictReason') '')
    $registeredV = Get-LctField $d @('registered') $null
    $keyPathV = [string](Get-LctField $d @('keyPath') '')
    $startModeV = [string](Get-LctField $d @('startMode', 'startModeText') '')
    $fileExistsV = Get-LctField $d @('fileExists') $null
    $evLines = @(Get-LctArray (Get-LctField $d @('events', 'eventLines', 'systemEvents', 'eventLog') $null))
    $evAll = @(Get-LctArray (Get-LctField $d @('scmDriverEventsRecent') $null))
    $evErrV = [string](Get-LctField $d @('eventsError') '')
    $evReadV = Get-LctField $d @('eventsRead') $null
    $nameValidV = Get-LctField $d @('nameValid') $null
    $dataErrV = [string](Get-LctField $d @('error') '')
    $evText = ''
    foreach ($e0 in $evLines) {
        if ($e0 -is [string]) { $evText += ' ' + $e0; continue }
        $evText += ' ' + [string](Get-LctField $e0 @('message') '')
    }

    $kind = 'unknown'
    if ($conclV -eq 'running') { $kind = 'running' }
    elseif ($conclV -eq 'os-rejected') { $kind = 'rejected' }
    elseif ($tierText) {
        if ($tierText -match '真的|运行中|正在运行|已加载|成功') { $kind = 'running' }
        elseif ($tierText -match '拒绝|被拒') { $kind = 'rejected' }
    }
    if ($kind -eq 'unknown' -and $null -ne $runVal) {
        $runText0 = ([string]$runVal).Trim().ToLowerInvariant()
        if ($runText0 -eq 'true' -or $runText0 -eq '1' -or $runText0 -eq 'yes') { $kind = 'running' }
        elseif ($runText0 -eq 'false' -or $runText0 -eq '0' -or $runText0 -eq 'no') {
            if ("$reasonV $evText" -match '577|digital signature|数字签名|0xC000012F|拒绝|rejected|denied|1058|1053|127|193') { $kind = 'rejected' }
            else { $kind = 'unknown' }
        }
    }

    $tierLabel = '状态不明：接口返回不足以判定（未被证实运行、也没有找到系统拒绝的证据；请看下面的系统事件原文）'
    $tierColor = $script:C.Warn
    if ($kind -eq 'running') {
        $tierLabel = '真的在运行（✔ 绿：Win32_SystemDriver 的 State=Running，服务已加载在内核中）'
        $tierColor = $script:C.Ok
    } elseif ($kind -eq 'rejected') {
        $tierLabel = '被系统拒绝（✖ 红：服务项存在但未运行，且系统事件里有指向它的失败原文）'
        $tierColor = $script:C.Err
    }
    if ($null -ne $script:DriverVerifyTierBox) {
        $script:DriverVerifyTierBox.Text = "结论：$tierLabel"
        $script:DriverVerifyTierBox.ForeColor = $tierColor
    }

    $runText2 = Format-LctBoolCn $runVal
    $null = $out.Add("服务实际状态         ：$stateText")
    $null = $out.Add("是否真的在运行       ：$runText2   （引擎 conclusion=$(Get-LctNumOrDashLocal $conclV)；conclusionText=$(Get-LctNumOrDashLocal $tierText)）")
    $null = $out.Add("服务项已注册         ：$(Format-LctBoolCn $registeredV)   $(if ($keyPathV) { "注册表键：$keyPathV" })")
    $null = $out.Add("启动类型 / 镜像存在   ：$startModeV   /   文件存在=$(Format-LctBoolCn $fileExistsV)")
    if (-not [string]::IsNullOrEmpty($dataErrV)) { $null = $out.Add("⚠ 引擎报告           ：$dataErrV") }
    if ($null -ne $nameValidV -and $nameValidV -eq $false) { $null = $out.Add('⚠ 服务名非法或为空：driver.verify 无法给出有效结论。') }
    $null = $out.Add('')
    $null = $out.Add('—— 系统返回原文（照抄）——')
    if ($reasonV) { $null = $out.Add("  引擎判定依据（原文）：$reasonV") }
    else { $null = $out.Add('  引擎判定依据（原文）：（空）') }
    $null = $out.Add('')
    $null = $out.Add("—— 系统事件原文（7000 / 7026 / 219，命中 $((@($evLines)).Count) 条；已扫描 $((Format-LctNumOrDash $evReadV)) 条系统日志）——")
    if (@($evLines).Count -eq 0) {
        $null = $out.Add('  （没有指向该服务的 7000/7026/219 事件；近 400 条里的全部 SCM 驱动事件见下）')
    } else {
        foreach ($ev in $evLines) {
            if ($ev -is [string]) { $null = $out.Add('  ' + $ev); continue }
            $null = $out.Add("  事件 $([string](Get-LctField $ev @('id') '?'))  $([string](Get-LctField $ev @('time') ''))  $([string](Get-LctField $ev @('provider') ''))")
            $null = $out.Add("    " + [string](Get-LctField $ev @('message') ''))
        }
    }
    if ($evErrV) { $null = $out.Add('  ⚠ 事件读取失败（原文）：' + $evErrV) }
    if (@($evAll).Count -gt 0) {
        $null = $out.Add('')
        $null = $out.Add("—— 近 400 条系统日志里全部 SCM 驱动事件（$((@($evAll)).Count) 条，未必指向本服务）——")
        foreach ($ev2 in @($evAll | Select-Object -First 8)) {
            if ($ev2 -is [string]) { $null = $out.Add('  ' + $ev2); continue }
            $null = $out.Add("  事件 $([string](Get-LctField $ev2 @('id') '?'))  $([string](Get-LctField $ev2 @('time') ''))  " + ([string](Get-LctField $ev2 @('message') '')).Split("`n")[0])
        }
    }
    $null = $out.Add('')
    $null = $out.Add('—— 引擎证据与边界 ——')
    foreach ($evd in @(Get-LctArray (Get-LctField $d @('evidence') $null))) { $null = $out.Add('  · ' + [string]$evd) }
    foreach ($lm2 in @(Get-LctArray (Get-LctField $d @('limitations') $null))) { $null = $out.Add('  · 边界：' + [string]$lm2) }
    $null = $out.Add('')
    $null = $out.Add('—— 引擎原始 JSON（driver.verify）——')
    try { $null = $out.Add((ConvertTo-Json -InputObject $d -Depth 8)) } catch { $null = $out.Add([string]$d) }
    $script:DriverVerifyBox.Text = (@($out) -join "`r`n")
    $script:DriverVerifyBox.SelectionStart = 0
    $script:DriverVerifyBox.SelectionLength = 0
}

function Get-LctNumOrDashLocal {
    param($Value)
    if ($null -eq $Value) { return '—' }
    if ($Value -is [string] -and $Value.Trim() -eq '') { return '—' }
    return [string]$Value
}

function Invoke-LctDriverTsPreview {
    param([bool]$Enable = $true)
    $way = '关闭'
    if ($Enable) { $way = '开启' }
    if ($Enable -and (Test-LctDriverSecureBootOn) -eq $true) {
        $null = [System.Windows.Forms.MessageBox]::Show('已检测到 Secure Boot=True：后端会【拒绝开启】test-signing（Secure Boot 开启时 bcdedit /set testsigning on 不可用）。请先在固件（UEFI）里关闭 Secure Boot 并重启。', '后端会拒绝开启', 'OK', 'Warning')
        return
    }
    $bag2 = @{ enable = [bool]$Enable; disable = (-not [bool]$Enable) }
    $r = Invoke-LctPreview -Page 'drivers' -Id "ts:$way" -Verb 'driver.testsigning' -Args $bag2 -Summary "$way test-signing（★需重启生效★）"
    if ($null -ne $r) { Show-LctDriverTsResult -Result $r }
}

function Invoke-LctDriverTsApply {
    param([bool]$Enable = $true)
    $way = '关闭'
    if ($Enable) { $way = '开启' }
    $id = "ts:$way"
    if (@(Get-LctPending -Page 'drivers' -Id $id).Count -eq 0) {
        $null = [System.Windows.Forms.MessageBox]::Show('必须先点「① 预览」并通过预览（预览不落盘），才能点「② 应用」。', '需要先预览', 'OK', 'Warning')
        return
    }
    Invoke-LctApplyPending -Page 'drivers' -Id $id
    $lr = $script:LastResult
    if ($null -ne $lr -and [string](Get-LctProp $lr 'verb' '') -eq 'driver.testsigning') {
        Show-LctDriverTsResult -Result $lr
        if ([bool](Get-LctProp $lr 'ok' $false) -and [bool](Get-LctProp $lr 'applied' $false)) {
            $null = [System.Windows.Forms.MessageBox]::Show(
                "test-signing 已$way（我们已执行动作）。`r`n`r`n★ 需重启生效 ★`r`nbcdedit 的取值现在已写入，但系统要在【重启之后】才按新值运行；重启前当前会话仍是旧值。`r`n`r`n系统是否真的接受（例如 Secure Boot 拒绝）以上面结果区里的系统返回原文为准。",
                '★ 需重启生效 ★', 'OK', 'Warning')
        }
    }
    Update-LctDriverStatus
}

function New-LctPageDrivers {
    param($Body)
    $t = New-LctScrollPage -Body $Body -CanvasHeight 900
    $two = New-LctTable -Parent $t -ColSpec @('100p', '560a') -RowSpec @('100p') -Col 0 -Row 0

    # ---------------- 左列：状态 / 指定驱动并加载 / 清单 ----------------
    $left = New-LctTable -Parent $two -ColSpec @('100p') -RowSpec @('150a', '344a', '100p') -Col 0 -Row 0

    $c1 = New-LctCard -Title '驱动加载前提与现状（driver.status，只读）' -Parent $left -Col 0 -Row 0
    $bStatus = New-LctButton -Text '刷新状态（driver.status）' -X 14 -Y 22 -W 190 -H 26 -Parent $c1 -Accent
    $script:DriverSbBanner = New-LctLabel -Text 'Secure Boot：—    test-signing：—' -X 210 -Y 26 -W 216 -H 20 -Parent $c1 -Color $script:C.Warn -Size 8
    $script:DriverStatusBox = New-LctText -X 0 -Y 0 -W 100 -H 100 -Parent $c1 -Multiline -ReadOnly -Mono -Dark
    $script:DriverStatusBox.Dock = [System.Windows.Forms.DockStyle]::Fill
    $script:DriverStatusBox.Margin = New-Object System.Windows.Forms.Padding(12, 54, 12, 10)
    $script:DriverStatusBox.Text = '(点「刷新状态」调 driver.status。test-signing=Yes 时会明确写出「未签名驱动现在可以被系统加载」；后端 core\Drivers.psm1 未就绪时会显示引擎给的中文错误。)'
    $bStatus.Add_Click({ param($s, $e) Update-LctDrivers })
    $script:DriverStatusRefreshBtn = $bStatus

    $c2 = New-LctCard -Title '指定驱动并加载（主功能 driver.load：先① 预览，再② 应用）' -Parent $left -Col 0 -Row 1
    $i2 = New-LctTable -Parent $c2 -ColSpec @('100p') -RowSpec @('30a', '30a', '30a', '36a', '40a', '100p')
    $i2.Margin = New-Object System.Windows.Forms.Padding(10, 24, 10, 8)

    $r2a = New-LctTable -Parent $i2 -ColSpec @('86a', '100p', '92a') -RowSpec @('30a') -Col 0 -Row 0
    $r2a.Margin = New-Object System.Windows.Forms.Padding(0)
    $null = New-LctLabel -Text '驱动 .sys' -X 2 -Y 5 -W 80 -H 20 -Parent $r2a -Col 0 -Row 0
    $script:DriverPathBox = New-LctText -X 0 -Y 0 -W 100 -H 24 -Parent $r2a -Col 1 -Row 0
    $script:DriverPathBox.Dock = [System.Windows.Forms.DockStyle]::Fill
    $script:DriverPathBox.Margin = New-Object System.Windows.Forms.Padding(0, 3, 2, 3)
    $bBrowse = New-LctButton -Text '浏览 .sys…' -X 0 -Y 0 -W 90 -H 24 -Parent $r2a -Col 2 -Row 0
    $bBrowse.Dock = [System.Windows.Forms.DockStyle]::Fill
    $bBrowse.Margin = New-Object System.Windows.Forms.Padding(4, 2, 2, 2)
    $script:DriverBrowseBtn = $bBrowse

    $script:DriverNameBox = New-LctFormRow -Parent $i2 -Row 1 -Label '服务名(可留空)' -LabelW 86 -H 30
    $script:DriverStartTypeBox = New-LctFormCombo -Parent $i2 -Row 2 -Label '启动类型' -LabelW 86 -H 30 -Items @('demand', 'system', 'boot')

    $r2b = New-LctTable -Parent $i2 -ColSpec @('100p', '100p', '100p', '100p') -RowSpec @('36a') -Col 0 -Row 3
    $r2b.Margin = New-Object System.Windows.Forms.Padding(0)
    $bLoadPrev = New-LctButton -Text '① 预览：加载' -X 0 -Y 0 -W 100 -H 32 -Parent $r2b -Accent -Col 0 -Row 0
    $bLoadPrev.Dock = [System.Windows.Forms.DockStyle]::Fill
    $bLoadPrev.Margin = New-Object System.Windows.Forms.Padding(0, 2, 4, 2)
    $bLoadApply = New-LctButton -Text '② 应用：加载' -X 0 -Y 0 -W 100 -H 32 -Parent $r2b -Warn -Col 1 -Row 0
    $bLoadApply.Dock = [System.Windows.Forms.DockStyle]::Fill
    $bLoadApply.Margin = New-Object System.Windows.Forms.Padding(4, 2, 4, 2)
    $bStartPrev = New-LctButton -Text '① 预览：仅启动' -X 0 -Y 0 -W 100 -H 32 -Parent $r2b -Col 2 -Row 0
    $bStartPrev.Dock = [System.Windows.Forms.DockStyle]::Fill
    $bStartPrev.Margin = New-Object System.Windows.Forms.Padding(4, 2, 4, 2)
    $bStartApply = New-LctButton -Text '② 应用：仅启动' -X 0 -Y 0 -W 100 -H 32 -Parent $r2b -Col 3 -Row 0
    $bStartApply.Dock = [System.Windows.Forms.DockStyle]::Fill
    $bStartApply.Margin = New-Object System.Windows.Forms.Padding(4, 2, 0, 2)
    $script:DriverLoadPreviewBtn = $bLoadPrev
    $script:DriverLoadApplyBtn = $bLoadApply
    $script:DriverStartPreviewBtn = $bStartPrev
    $script:DriverStartApplyBtn = $bStartApply

    $script:DriverStartTypeNote = New-LctLabel -Text 'demand（手动，默认）= 最安全。' -X 0 -Y 0 -W 100 -H 38 -Parent $i2 -Color $script:C.Ok -Size 8 -Col 0 -Row 4
    $script:DriverStartTypeNote.Dock = [System.Windows.Forms.DockStyle]::Fill
    $script:DriverStartTypeNote.Margin = New-Object System.Windows.Forms.Padding(0)

    $script:DriverLoadBox = New-LctText -X 0 -Y 0 -W 100 -H 100 -Parent $i2 -Multiline -ReadOnly -Mono -Dark -Col 0 -Row 5
    $script:DriverLoadBox.Dock = [System.Windows.Forms.DockStyle]::Fill
    $script:DriverLoadBox.Text = '(点「① 预览：加载」后，这里会原样显示系统返回的 verdict.exitCode / verdict.message；「② 应用」后同样照抄。签名只做信息展示，能不能加载由系统判定。)'

    $c3 = New-LctCard -Title '驱动服务清单（driver.list；选中一行 → 右侧「选中驱动详情」看 driver.info）' -Parent $left -Col 0 -Row 2
    $i3 = New-LctTable -Parent $c3 -ColSpec @('100p', '150a') -RowSpec @('30a', '100p')
    $i3.Margin = New-Object System.Windows.Forms.Padding(10, 24, 10, 8)
    $bList = New-LctButton -Text '刷新清单（driver.list）' -X 0 -Y 0 -W 100 -H 26 -Parent $i3 -Accent -Col 0 -Row 0
    $bList.Dock = [System.Windows.Forms.DockStyle]::Fill
    $bList.Margin = New-Object System.Windows.Forms.Padding(0, 2, 6, 2)
    $script:DriverListCount = New-LctLabel -Text '驱动服务数：—' -X 2 -Y 5 -W 100 -H 20 -Parent $i3 -Dim -Size 8 -Col 1 -Row 0
    $script:DriverListCount.Dock = [System.Windows.Forms.DockStyle]::Fill
    $script:DrvGrid = New-LctGrid -Parent $i3 -Name 'driverlist' -Cols @(
        'name|服务名|120', 'state|状态|76', 'startType|启动|72', 'path|镜像路径|fill', 'sha256|SHA256|110', 'signature|签名摘要(仅信息)|fill'
    )
    $i3.SetColumnSpan($script:DrvGrid, 2)
    $bList.Add_Click({ param($s, $e) Update-LctDriverList })
    $script:DriverListRefreshBtn = $bList
    $script:DrvGrid.Add_SelectionChanged({
        param($s, $e)
        if ($script:SuppressDrvSel) { return }
        $script:SuppressDrvSel = $true
        try { Update-LctDriverDetail } finally { $script:SuppressDrvSel = $false }
    })

    # ---------------- 右列：停止/卸载 / 加载后复核 / test-signing / 详情 ----------------
    $right = New-LctTable -Parent $two -ColSpec @('100p') -RowSpec @('200a', '214a', '200a', '100p', '44a') -Col 1 -Row 0

    $c4 = New-LctCard -Title '停止 / 卸载（driver.stop / driver.unload：先① 预览，再② 应用）' -Parent $right -Col 0 -Row 0
    $i4 = New-LctTable -Parent $c4 -ColSpec @('100p') -RowSpec @('22a', '32a', '30a', '100p')
    $i4.Margin = New-Object System.Windows.Forms.Padding(10, 24, 10, 8)
    $n4 = New-LctLabel -Text '目标 = 上表选中的服务名；左侧「服务名」框非空时以它为准。' -X 0 -Y 0 -W 100 -H 20 -Parent $i4 -Dim -Size 8 -Col 0 -Row 0
    $n4.Dock = [System.Windows.Forms.DockStyle]::Fill
    $r4b = New-LctTable -Parent $i4 -ColSpec @('100p', '100p', '100p', '100p') -RowSpec @('32a') -Col 0 -Row 1
    $r4b.Margin = New-Object System.Windows.Forms.Padding(0)
    $bStopPrev = New-LctButton -Text '停止①预览' -X 0 -Y 0 -W 100 -H 28 -Parent $r4b -Col 0 -Row 0
    $bStopPrev.Dock = [System.Windows.Forms.DockStyle]::Fill
    $bStopPrev.Margin = New-Object System.Windows.Forms.Padding(0, 1, 4, 1)
    $bStopApply = New-LctButton -Text '停止②应用' -X 0 -Y 0 -W 100 -H 28 -Parent $r4b -Warn -Col 1 -Row 0
    $bStopApply.Dock = [System.Windows.Forms.DockStyle]::Fill
    $bStopApply.Margin = New-Object System.Windows.Forms.Padding(4, 1, 4, 1)
    $bUnPrev = New-LctButton -Text '卸载①预览' -X 0 -Y 0 -W 100 -H 28 -Parent $r4b -Col 2 -Row 0
    $bUnPrev.Dock = [System.Windows.Forms.DockStyle]::Fill
    $bUnPrev.Margin = New-Object System.Windows.Forms.Padding(4, 1, 4, 1)
    $bUnApply = New-LctButton -Text '卸载②应用' -X 0 -Y 0 -W 100 -H 28 -Parent $r4b -Warn -Col 3 -Row 0
    $bUnApply.Dock = [System.Windows.Forms.DockStyle]::Fill
    $bUnApply.Margin = New-Object System.Windows.Forms.Padding(4, 1, 0, 1)
    $script:DriverStopPreviewBtn = $bStopPrev
    $script:DriverStopApplyBtn = $bStopApply
    $script:DriverUnloadPreviewBtn = $bUnPrev
    $script:DriverUnloadApplyBtn = $bUnApply
    $n4b = New-LctLabel -Text '卸载 = 停服务 + 删服务项；绝不删 .sys 文件；并生成 revert.cmd（含重建命令与原始参数）供一键回滚。' -X 0 -Y 0 -W 100 -H 28 -Parent $i4 -Color $script:C.Warn -Size 8 -Col 0 -Row 2
    $n4b.Dock = [System.Windows.Forms.DockStyle]::Fill
    $script:DriverActionBox = New-LctText -X 0 -Y 0 -W 100 -H 100 -Parent $i4 -Multiline -ReadOnly -Mono -Dark -Col 0 -Row 3
    $script:DriverActionBox.Dock = [System.Windows.Forms.DockStyle]::Fill
    $script:DriverActionBox.Text = '(停止 / 卸载 / 仅启动的结果都会照抄到这里；先预览再应用，应用时还会弹一次二次确认。)'

    $c5 = New-LctCard -Title '加载后复核（driver.verify：真的在运行 / 被系统拒绝 / 状态不明 + 系统事件原文 7000·7026·219）' -Parent $right -Col 0 -Row 1
    $i5 = New-LctTable -Parent $c5 -ColSpec @('100p', '300a') -RowSpec @('30a', '100p')
    $i5.Margin = New-Object System.Windows.Forms.Padding(10, 24, 10, 8)
    $bVerify = New-LctButton -Text '复核目标驱动（driver.verify）' -X 0 -Y 0 -W 100 -H 26 -Parent $i5 -Accent -Col 0 -Row 0
    $bVerify.Dock = [System.Windows.Forms.DockStyle]::Fill
    $bVerify.Margin = New-Object System.Windows.Forms.Padding(0, 2, 6, 2)
    $script:DriverVerifyBtn = $bVerify
    $script:DriverVerifyTierBox = New-LctLabel -Text '结论：—' -X 2 -Y 5 -W 100 -H 20 -Parent $i5 -Color $script:C.Dim -Size 8 -Col 1 -Row 0
    $script:DriverVerifyTierBox.Dock = [System.Windows.Forms.DockStyle]::Fill
    $script:DriverVerifyBox = New-LctText -X 0 -Y 0 -W 100 -H 100 -Parent $i5 -Multiline -ReadOnly -Mono -Dark -Col 0 -Row 1
    $i5.SetColumnSpan($script:DriverVerifyBox, 2)
    $script:DriverVerifyBox.Text = '(点上面按钮调 driver.verify；三档着色：绿=真的在运行，红=被系统拒绝，黄=状态不明。系统事件原文照抄，不美化。)'

    $c6 = New-LctCard -Title 'test-signing 开关（driver.testsigning；★ 需重启生效 ★）' -Parent $right -Col 0 -Row 2
    $i6 = New-LctTable -Parent $c6 -ColSpec @('100p') -RowSpec @('24a', '32a', '30a', '100p')
    $i6.Margin = New-Object System.Windows.Forms.Padding(10, 24, 10, 8)
    $script:DriverTsValueLabel = New-LctLabel -Text 'test-signing 当前值：—' -X 0 -Y 0 -W 100 -H 22 -Parent $i6 -Bold -Color $script:C.Warn -Col 0 -Row 0
    $script:DriverTsValueLabel.Dock = [System.Windows.Forms.DockStyle]::Fill
    $r6 = New-LctTable -Parent $i6 -ColSpec @('100p', '100p', '100p', '100p') -RowSpec @('32a') -Col 0 -Row 1
    $r6.Margin = New-Object System.Windows.Forms.Padding(0)
    $bTsOnPrev = New-LctButton -Text '① 预览：开启' -X 0 -Y 0 -W 100 -H 28 -Parent $r6 -Accent -Col 0 -Row 0
    $bTsOnPrev.Dock = [System.Windows.Forms.DockStyle]::Fill
    $bTsOnPrev.Margin = New-Object System.Windows.Forms.Padding(0, 1, 4, 1)
    $bTsOnApply = New-LctButton -Text '② 应用：开启' -X 0 -Y 0 -W 100 -H 28 -Parent $r6 -Warn -Col 1 -Row 0
    $bTsOnApply.Dock = [System.Windows.Forms.DockStyle]::Fill
    $bTsOnApply.Margin = New-Object System.Windows.Forms.Padding(4, 1, 4, 1)
    $bTsOffPrev = New-LctButton -Text '① 预览：关闭' -X 0 -Y 0 -W 100 -H 28 -Parent $r6 -Col 2 -Row 0
    $bTsOffPrev.Dock = [System.Windows.Forms.DockStyle]::Fill
    $bTsOffPrev.Margin = New-Object System.Windows.Forms.Padding(4, 1, 4, 1)
    $bTsOffApply = New-LctButton -Text '② 应用：关闭' -X 0 -Y 0 -W 100 -H 28 -Parent $r6 -Warn -Col 3 -Row 0
    $bTsOffApply.Dock = [System.Windows.Forms.DockStyle]::Fill
    $bTsOffApply.Margin = New-Object System.Windows.Forms.Padding(4, 1, 0, 1)
    $script:DriverTsEnablePreviewBtn = $bTsOnPrev
    $script:DriverTsEnableApplyBtn = $bTsOnApply
    $script:DriverTsDisablePreviewBtn = $bTsOffPrev
    $script:DriverTsDisableApplyBtn = $bTsOffApply
    $script:DriverTsSbNote = New-LctLabel -Text '（Secure Boot=True 时「开启」会被后端拒绝：原因显示在这里）' -X 0 -Y 0 -W 100 -H 28 -Parent $i6 -Color $script:C.Dim -Size 8 -Col 0 -Row 2
    $script:DriverTsSbNote.Dock = [System.Windows.Forms.DockStyle]::Fill
    $script:DriverTsBox = New-LctText -X 0 -Y 0 -W 100 -H 100 -Parent $i6 -Multiline -ReadOnly -Mono -Dark -Col 0 -Row 3
    $script:DriverTsBox.Dock = [System.Windows.Forms.DockStyle]::Fill
    $script:DriverTsBox.Text = '(开关结果与「★需重启生效★」提示显示在这里；系统是否真的接受以后端返回原文为准。)'

    $c7 = New-LctCard -Title '选中驱动详情（Update-LctDriverDetail → driver.info：hash + Authenticode + 是否 test-signed，全部仅信息）' -Parent $right -Col 0 -Row 3
    $script:DrvDetailBox = New-LctText -X 0 -Y 0 -W 100 -H 100 -Parent $c7 -Multiline -ReadOnly -Mono -Dark
    $script:DrvDetailBox.Dock = [System.Windows.Forms.DockStyle]::Fill
    $script:DrvDetailBox.Margin = New-Object System.Windows.Forms.Padding(10, 22, 10, 10)
    $script:DrvDetailBox.Text = '(选中清单里的一行后显示 driver.info 的 SHA256 / Authenticode / 是否 test-signed。这些只做信息展示，不是加载门槛。)'

    $null = New-LctPendingStrip -Parent $right -Col 0 -Row 4 -PageKey 'drivers'

    # 事件接线
    $bBrowse.Add_Click({
        param($s, $e)
        $dlg = New-Object System.Windows.Forms.OpenFileDialog
        $dlg.Title = '选择要加载的驱动镜像（.sys）'
        $dlg.Filter = '驱动镜像 (*.sys)|*.sys|所有文件 (*.*)|*.*'
        $dlg.CheckFileExists = $true
        if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            $script:DriverPathBox.Text = $dlg.FileName
        }
    })
    $script:DriverStartTypeBox.Add_SelectedIndexChanged({ param($s, $e) Update-LctDriverStartTypeNote })
    $bLoadPrev.Add_Click({ param($s, $e) Invoke-LctDriverLoadPreview })
    $bLoadApply.Add_Click({ param($s, $e) Invoke-LctDriverLoadApply })
    $bStartPrev.Add_Click({ param($s, $e) Invoke-LctDriverStartPreview })
    $bStartApply.Add_Click({ param($s, $e) Invoke-LctDriverStartApply })
    $bStopPrev.Add_Click({ param($s, $e) Invoke-LctDriverStopPreview })
    $bStopApply.Add_Click({ param($s, $e) Invoke-LctDriverStopApply })
    $bUnPrev.Add_Click({ param($s, $e) Invoke-LctDriverUnloadPreview })
    $bUnApply.Add_Click({ param($s, $e) Invoke-LctDriverUnloadApply })
    $bVerify.Add_Click({ param($s, $e) Invoke-LctDriverVerifyRead })
    $bTsOnPrev.Add_Click({ param($s, $e) Invoke-LctDriverTsPreview -Enable $true })
    $bTsOnApply.Add_Click({ param($s, $e) Invoke-LctDriverTsApply -Enable $true })
    $bTsOffPrev.Add_Click({ param($s, $e) Invoke-LctDriverTsPreview -Enable $false })
    $bTsOffApply.Add_Click({ param($s, $e) Invoke-LctDriverTsApply -Enable $false })

    Update-LctDriverStartTypeNote
    Update-LctDriverTsControls

    # 兼容别名：Lead 的 UiPageSmoke / DriverTest 按名字取变量（多个别名指向同一控件）
    $script:DriverGrid = $script:DrvGrid
    $script:DriversGrid = $script:DrvGrid
    $script:DriverListGrid = $script:DrvGrid
    $script:DriverDetailBox = $script:DrvDetailBox
    $script:DriversDetailBox = $script:DrvDetailBox
    $script:DriverGridDetailBox = $script:DrvDetailBox
    return $two
}

# ===========================================================================
# 十二·六、新增能力：页面十「驱动 Profile」(driverprofiles)
#   作者：task-4 (ui-driverprofiles)。铁则不变：本段不含任何后端逻辑 —— 所有动作都经
#   Invoke-LctEngine（参数走临时文件 -ArgsFile + -EncodedCommand）调引擎 verb；写操作一律
#   「预览（橙色标注「仅预览，未落盘/未发送」）→ 登记待应用 → 点应用 + MessageBox 二次确认
#   → 才带 -Apply」。
#   规格：docs\CONTRACT.md §13（profile 形状 §13.4 / verb §13.5 / 铁律 §13.6）
#         与 docs\DRIVER-ABI.md（自研驱动的固定 ABI ⇒ 无需 profile 即被识别）。
#   字段名与 backend-driverprofiles（core\DriverProfiles.psm1）逐个对齐（不再兜底猜名）：
#     list    : data.items[].{id,source,path,targetFileName,riskLevel,actionCount,actions[],valid,problem}
#     show    : data.{profile,schemaOk,schemaErrors[],info,path,source}
#     validate: data.{schemaOk,fingerprintMatch,declaredSha256[],actualSha256,sysFile{...},checks[],sandbox{}}
#     draft   : data.{needsReview,confidence,draft,draftJson,hint,candidatesFound,ioctlCandidateCount}
#     ctl.send 预览: data.action{ioctlHex,...} + data.request{hex,hexDump[],fields[]} + data.device.verdict
#     ctl.send 应用: data.result + data.rawOutHex + data.bytesReturned + data.gate.refused
#                    + data.before/after/restore（写类）
#     ctl.verify   : data.proofLevel(none|file-fingerprint|openable|handshake) + data.canary{}
#     profile.save : args {id,json,override}；data.{id,path,source,overwritten,validated,bytes}
#   自动化驱动方式（本项目老办法）：StartPosition=Manual + Location(-4000,-4000) +
#   ShowInTaskbar=false + Show()，并先 Switch-LctPage -Key 'driverprofiles'；否则 PerformClick 不触发。
#   ★ 「② 应用：发送」会弹 MessageBox —— 自动化探针只走「① 预览」路径，别去点那个确认框。
# ===========================================================================

$script:SuppressProfSel = $false
$script:SuppressProfCtl = $false
$script:ProfListCache = @()
$script:ProfShowCache = @{}
$script:ProfCtlPlan = $null
$script:ProfSaveJson = ''
$script:ProfSaveId = ''

function Test-LctVerbAvailable {
    # 可用性驱动：并发开发期后端 verb 可能还没落地 —— 有就点亮按钮，没有就明确显示「引擎未提供」。
    # 只查 engine.verbs 自描述表，不发任何写请求，不假装成功。
    # 注意：VerbTable 平时由概览页（Update-LctOverview）填充；若用户直接进本页它还是空的，
    # 这里就先拉一次 engine.verbs 并缓存，否则「可用性检测」会误报为不可用（会把能用的按钮禁用）。
    param([string]$Verb)
    if (@($script:VerbTable).Count -eq 0) {
        $rv = Invoke-LctEngine -Verb 'engine.verbs'
        $script:LastVerbsResult = $rv
        $vd = Get-LctProp $rv 'data' $null
        $maybeVerbs = Get-LctProp $vd 'verbs' $null
        if ($null -ne $maybeVerbs) { $script:VerbTable = @(Get-LctArray $maybeVerbs) }
        elseif ($null -ne $vd) { $script:VerbTable = @(Get-LctArray $vd) }
        if (-not $rv.ok) { $script:VerbTable = @() }
    }
    foreach ($v in @($script:VerbTable)) {
        if ([string](Get-LctProp $v 'verb' '') -eq $Verb) { return $true }
    }
    return $false
}

function Write-LctProfBox {
    param($Box, $Lines)
    if ($null -eq $Box) { return }
    $arr = New-Object System.Collections.ArrayList
    foreach ($l in @($Lines)) { $null = $arr.Add([string]$l) }
    $Box.Text = (@($arr) -join "`r`n")
    try {
        $Box.SelectionStart = 0
        $Box.SelectionLength = 0
    } catch { }
}

function New-LctProfComboCell {
    # 在指定单元格里放「标签 + 下拉框」（New-LctFormCombo 只能落在 Col 0，多列布局需要这个）。
    param($CellParent, [int]$CellCol = 0, [int]$CellRow = 0, [string]$CellLabel = '', [int]$CellLabelW = 56, [string[]]$CellItems = @(), [int]$CellH = 30)
    $t = New-LctTable -Parent $CellParent -ColSpec @("$($CellLabelW)a", '100p') -RowSpec @("$($CellH)a") -Col $CellCol -Row $CellRow
    $t.Margin = New-Object System.Windows.Forms.Padding(0, 0, 4, 0)
    $null = New-LctLabel -Text $CellLabel -X 2 -Y 4 -W ($CellLabelW - 6) -H ($CellH - 6) -Parent $t
    $cb = New-Object System.Windows.Forms.ComboBox
    $cb.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
    $cb.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $cb.BackColor = $script:C.Panel2
    $cb.ForeColor = $script:C.Text
    $cb.Font = New-LctFont -Size 9
    foreach ($i in @($CellItems)) { $null = $cb.Items.Add([string]$i) }
    if ($cb.Items.Count -gt 0) { $cb.SelectedIndex = 0 }
    $cb.Dock = [System.Windows.Forms.DockStyle]::Fill
    $cb.Margin = New-Object System.Windows.Forms.Padding(0, 3, 2, 3)
    $null = $t.Controls.Add($cb, 1, 0)
    return $cb
}

function Get-LctProfSelectedId {
    param()
    if ($null -ne $script:ProfGrid -and $script:ProfGrid.SelectedRows.Count -gt 0) {
        return [string](Get-LctRowCell -Row $script:ProfGrid.SelectedRows[0] -Column 'rowkey')
    }
    return ''
}

function Get-LctProfObjFromShow {
    param($ShowData)
    if ($null -eq $ShowData) { return $null }
    $profObj = Get-LctProp $ShowData 'profile' $null
    if ($null -eq $profObj) {
        $items = Get-LctArray (Get-LctProp $ShowData 'items' @())
        if (@($items).Count -gt 0) { $profObj = $items[0] }
    }
    return $profObj
}

function Get-LctProfShowData {
    param([string]$Id, [switch]$Refresh)
    if (-not $Id) { return $null }
    if ((-not $Refresh) -and $script:ProfShowCache.ContainsKey($Id)) { return $script:ProfShowCache[$Id] }
    $r = Invoke-LctEngine -Verb 'driver.profile.show' -Args @{ id = $Id }
    if (-not $r.ok) { return $null }
    $d = Get-LctDataDeep -Result $r -KeyName 'profile'
    if ($null -eq $d) { $d = Get-LctProp $r 'data' $null }
    if ($null -ne $d) { $script:ProfShowCache[$Id] = $d }
    return $d
}

function Get-LctProfActionNames {
    # list 的 data.items[].actions 已是动作名字符串数组；这里同时兼容 show 的 actions 对象/字典形态。
    param($ShowData)
    $names = @()
    if ($null -eq $ShowData) { return @() }
    $profObj = Get-LctProfObjFromShow $ShowData
    $acts = Get-LctProp $profObj 'actions' $null
    if ($acts -is [System.Collections.IDictionary]) {
        foreach ($k in @($acts.Keys)) { $names += [string]$k }
    } elseif ($null -ne $acts) {
        foreach ($a in @(Get-LctArray $acts)) {
            if ($a -is [string]) { $names += $a; continue }
            $nm = [string](Get-LctProp $a 'name' '')
            if ($nm) { $names += $nm }
        }
    }
    if (@($names).Count -eq 0) {
        $info = Get-LctProp $ShowData 'info' $null
        foreach ($n in @(Get-LctArray (Get-LctProp $info 'actions' @()))) { $names += [string]$n }
    }
    return @($names)
}

function Get-LctProfActionObj {
    param($ShowData, [string]$Action)
    if (-not $Action) { return $null }
    $profObj = Get-LctProfObjFromShow $ShowData
    $acts = Get-LctProp $profObj 'actions' $null
    if ($acts -is [System.Collections.IDictionary]) {
        if ($acts.Contains($Action)) { return $acts[$Action] }
        return $null
    }
    if ($null -ne $acts) {
        foreach ($a in @(Get-LctArray $acts)) {
            if ($a -is [string]) { continue }
            if ([string](Get-LctProp $a 'name' '') -eq $Action) { return $a }
        }
    }
    return $null
}

function Get-LctProfRiskLevel {
    param($ProfObj)
    if ($null -eq $ProfObj) { return '' }
    $risk = Get-LctProp $ProfObj 'risk' $null
    if ($risk -is [string]) { return [string]$risk }
    return [string](Get-LctProp $risk 'level' '')
}

function Format-LctProfRiskCn {
    param([string]$Level)
    if ($Level -eq 'low') { return '低（profile 声明）' }
    if ($Level -eq 'medium') { return '中（profile 声明）' }
    if ($Level -eq 'bsod') { return '★高：可能立刻蓝屏★' }
    if (-not $Level) { return '—' }
    return $Level
}

function Test-LctProfBsodAction {
    # risk.level=bsod 默认禁用发送：profile 级 risk.level 或动作级 risk 命中都算。
    param($ShowData, [string]$Action)
    if ($null -eq $ShowData) { return $false }
    $profObj = Get-LctProfObjFromShow $ShowData
    if ((Get-LctProfRiskLevel $profObj) -eq 'bsod') { return $true }
    $actObj = Get-LctProfActionObj -ShowData $ShowData -Action $Action
    $ar = Get-LctProp $actObj 'risk' $null
    if ($ar -is [string] -and ([string]$ar -eq 'bsod')) { return $true }
    if ([string](Get-LctProp $ar 'level' '') -eq 'bsod') { return $true }
    return $false
}

function Format-LctProfFieldsHint {
    param($ShowData, [string]$Action)
    $actObj = Get-LctProfActionObj -ShowData $ShowData -Action $Action
    if ($null -eq $actObj) { return '（该动作的字段规格读不到：profile 可能未通过 schema；payload 仍按 JSON 手填）' }
    $parts = @()
    foreach ($side in @('in', 'out')) {
        $fl = @(Get-LctArray (Get-LctProp $actObj $side @()))
        if (@($fl).Count -eq 0) { continue }
        $one = @()
        foreach ($f in $fl) {
            if ($f -is [string]) { $one += [string]$f; continue }
            $nm = [string](Get-LctProp $f 'name' '')
            $ty = [string](Get-LctProp $f 'type' '')
            if (-not $nm) { continue }
            $s = "${nm}:$ty"
            $ln = Get-LctProp $f 'len' $null
            if ($null -ne $ln) { $s += "[$ln]" }
            $one += $s
        }
        $parts += ($side + ' = ' + (@($one) -join ', '))
    }
    if (@($parts).Count -eq 0) { return '（该动作没有声明 in/out 字段）' }
    return (@($parts) -join '   |   ')
}

function Get-LctProfPayloadSkeleton {
    # 仅把 profile 的 in[] 字段规格渲染成一份「待你填写」的 JSON 文本（界面便利，不是后端逻辑）。
    param($ShowData, [string]$Action)
    $actObj = Get-LctProfActionObj -ShowData $ShowData -Action $Action
    if ($null -eq $actObj) { return '{}' }
    $bag = @{}
    foreach ($f in @(Get-LctArray (Get-LctProp $actObj 'in' @()))) {
        if ($f -is [string]) { continue }
        $nm = [string](Get-LctProp $f 'name' '')
        $ty = [string](Get-LctProp $f 'type' '')
        if (-not $nm) { continue }
        if ($ty -match '^(u8|u16|u32|u64|i32|i64)$') { $bag[$nm] = '0x0' }
        elseif ($ty -match '^(bytes|cstr|guid|handle)$') { $bag[$nm] = '' }
        else { $bag[$nm] = '' }
    }
    try { return (ConvertTo-Json -InputObject $bag -Depth 6) } catch { return '{}' }
}

function Get-LctProfCtlArgBag {
    # 当前界面上的「将发送」参数包（不落盘、不发 IOCTL；仅在点预览/应用时交给引擎）。
    param()
    $id = ''
    if ($null -ne $script:ProfCtlProfileBox) { $id = [string]$script:ProfCtlProfileBox.Text }
    $action = ''
    if ($null -ne $script:ProfCtlActionBox) { $action = [string]$script:ProfCtlActionBox.Text }
    $payload = '{}'
    if ($null -ne $script:ProfCtlPayloadBox) {
        $payload = [string]$script:ProfCtlPayloadBox.Text
        if (-not $payload.Trim()) { $payload = '{}' }
    }
    $ack = $false
    if ($null -ne $script:ProfBsodAckBox) { $ack = [bool]$script:ProfBsodAckBox.Checked }
    return @{
        profile       = $id
        action        = $action
        payload       = $payload
        overrideBsod  = $ack
    }
}

function Test-LctProfCtlPlanMatches {
    # 当前界面参数与「已预览的计划」是否逐字段一致：一致才允许应用，否则强制重新预览
    # （绝不用一份界面上没看过的参数去发 IOCTL）。逐字段比较，避免依赖 hashtable 枚举顺序。
    param()
    if ($null -eq $script:ProfCtlPlan) { return $false }
    $planBag = $script:ProfCtlPlan.Bag
    $curBag = Get-LctProfCtlArgBag
    if ([string]$planBag.profile -ne [string]$curBag.profile) { return $false }
    if ([string]$planBag.action -ne [string]$curBag.action) { return $false }
    if ([string]$planBag.payload -ne [string]$curBag.payload) { return $false }
    if ([bool]$planBag.overrideBsod -ne [bool]$curBag.overrideBsod) { return $false }
    return $true
}

function Update-LctDriverProfileList {
    # profile 清单（driver.profile.list，只读）。Source 可切 builtin / user / plugin / all。
    param()
    if ($null -eq $script:ProfGrid) { return }
    $src = 'all'
    if ($null -ne $script:ProfSourceBox) { $src = [string]$script:ProfSourceBox.Text }
    if (-not $src) { $src = 'all' }
    $r = Invoke-LctEngine -Verb 'driver.profile.list' -Args @{ source = $(if ($src -eq 'all') { '' } else { $src }) }
    $script:SuppressProfSel = $true
    try {
        Clear-LctGrid $script:ProfGrid
        $script:ProfListCache = @()
        $script:ProfShowCache = @{}
        if (-not $r.ok) {
            if ($null -ne $script:ProfCountLabel) { $script:ProfCountLabel.Text = '清单调用失败（见底部日志面板）' }
            Add-LctGridRow -Grid $script:ProfGrid -Key '' -Values @('（driver.profile.list 调用失败：后端模块可能尚未就绪）', '', '', '', '', '', '')
            return
        }
        $rd = Get-LctDataDeep -Result $r -KeyName 'items'
        $itemsRaw = Get-LctProp $rd 'items' $null
        if ($null -ne $itemsRaw) { $script:ProfListCache = @(Get-LctArray $itemsRaw) }
        else { $script:ProfListCache = @(Get-LctArray $rd) }
        foreach ($it in @($script:ProfListCache)) {
            if ($it -is [string]) {
                Add-LctGridRow -Grid $script:ProfGrid -Key $it -Values @($it, '', '', '', '', '', '')
                continue
            }
            $id = [string](Get-LctProp $it 'id' '')
            $tf = [string](Get-LctProp $it 'targetFileName' '')
            $rl = [string](Get-LctProp $it 'riskLevel' '')
            $sc = [string](Get-LctProp $it 'source' '')
            $ac = [string](Get-LctProp $it 'actionCount' '')
            $okv = Get-LctProp $it 'valid' $null
            $prb = [string](Get-LctProp $it 'problem' '')
            if (-not $tf) { $tf = '—' }
            if (-not $sc) { $sc = '—' }
            if ($null -eq $ac -or "$ac" -eq '') { $ac = '0' }
            $vtext = Format-LctBoolCn $okv
            if ((Get-LctProp $it 'isDraft' $false) -eq $true -and -not $prb) { $prb = '静态草案（needsReview=true）' }
            Add-LctGridRow -Grid $script:ProfGrid -Key $id -Values @($id, $tf, (Format-LctProfRiskCn $rl), $sc, $ac, $vtext, $prb)
        }
        if ($script:ProfGrid.Rows.Count -eq 0) {
            Add-LctGridRow -Grid $script:ProfGrid -Key '' -Values @('（当前没有任何 profile：内置 core\driver-profiles 允许为空；用下面「静态草案」起草后另存到 var\driver-profiles）', '', '', '', '', '', '')
        }
        if ($null -ne $script:ProfCountLabel) {
            $cntV = Get-LctProp $rd 'count' $null
            $validV = Get-LctProp $rd 'validCount' $null
            $c = "profile 数：$(Format-LctNumOrDash $cntV)"
            if ($null -ne $validV) { $c += "（schema 通过 $(Format-LctNumOrDash $validV)）" }
            $c += "  来源＝$src  行数 $($script:ProfGrid.Rows.Count)"
            $script:ProfCountLabel.Text = $c
        }
        if ($script:ProfGrid.Rows.Count -gt 0) { $script:ProfGrid.Rows[0].Selected = $true }
    } finally {
        $script:SuppressProfSel = $false
    }
    Update-LctDriverProfileDetail
    Update-LctProfCtlControls
}

function Update-LctDriverProfileDetail {
    param()
    # 选中行详情（driver.profile.show，只读）。任何分支都必须写出文本（UiPageSmoke 断言详情框非空）。
    if ($null -eq $script:ProfDetailBox) { return }
    $out = New-Object System.Collections.ArrayList
    $id = Get-LctProfSelectedId
    if (-not $id) {
        $null = $out.Add('（请先在上面的 profile 清单里选中一行，这里会显示 driver.profile.show 的可读化详情）')
        $null = $out.Add('')
        $null = $out.Add('profile 是纯数据：只描述「怎么定位这个驱动、发哪个 IOCTL、结构怎么排、风险多大」，')
        $null = $out.Add('不含任何可执行代码（引擎永不 eval profile 内容）。')
        $null = $out.Add('')
        $null = $out.Add('★ 执行前必须先用「校验（driver.profile.validate）」过指纹门：target.sha256 与实际 .sys 不符 ⇒ 拒绝（布局错版本必蓝屏）。')
        Write-LctProfBox -Box $script:ProfDetailBox -Lines $out
        return
    }
    $sd = Get-LctProfShowData -Id $id
    if ($null -eq $sd) {
        $null = $out.Add("profile id ：$id")
        $null = $out.Add('driver.profile.show 调用失败（后端模块可能尚未就绪；错误原文见底部日志面板）。')
        Write-LctProfBox -Box $script:ProfDetailBox -Lines $out
        return
    }
    $profObj = Get-LctProfObjFromShow $sd
    $info = Get-LctProp $sd 'info' $null
    $null = $out.Add("profile id ：$id")
    $null = $out.Add("来源 / 文件 ：$([string](Get-LctProp $sd 'source' '—'))   $([string](Get-LctProp $sd 'path' '—'))")
    $null = $out.Add("kind       ：$([string](Get-LctProp $profObj 'kind' '—'))    engineApi：$(Format-LctNumOrDash (Get-LctProp $profObj 'engineApi' $null))")
    $tgt = Get-LctProp $profObj 'target' $null
    $null = $out.Add("目标 .sys  ：$([string](Get-LctProp $tgt 'fileName' '—'))")
    $null = $out.Add("目标 sha256：$([string](Get-LctProp $tgt 'sha256' '—'))")
    foreach ($x in @(Get-LctArray (Get-LctProp $tgt 'sha256AnyOf' @()))) { $null = $out.Add("  （或）     ：$([string]$x)") }
    $loc = Get-LctProp $profObj 'locate' $null
    $null = $out.Add("定位策略   ：$([string](Get-LctProp $loc 'strategy' '—'))    serviceNameHint：$([string](Get-LctProp $loc 'serviceNameHint' '—'))")
    $null = $out.Add("接口 GUID  ：$([string](Get-LctProp $loc 'interfaceGuid' '—'))")
    $cands = @(Get-LctArray (Get-LctProp $loc 'candidates' @()))
    $null = $out.Add("符号链接候选（$(@($cands).Count)）：$((@($cands) | ForEach-Object { [string]$_ }) -join '  ' )")
    $hs = Get-LctProp $profObj 'handshake' $null
    if ($null -ne $hs) {
        $ex = Get-LctProp $hs 'expect' $null
        $null = $out.Add("握手        ：action=$([string](Get-LctProp $hs 'action' '—'))  expect.ioctl=$([string](Get-LctProp $ex 'ioctl' '—'))  minOutBytes=$([string](Get-LctProp $ex 'minOutBytes' '—'))")
    } else {
        $null = $out.Add('握手        ：（未声明 handshake：canary 只能做到 file-fingerprint/openable 档）')
    }
    $null = $out.Add('')
    $null = $out.Add('—— 动作（actions）：每个动作一条 IOCTL 与 in/out 结构 ——')
    $names = @(Get-LctProfActionNames $sd)
    if (@($names).Count -eq 0) { $null = $out.Add('  （没有任何动作：这种 profile 不能执行；静态草案的 actions 故意为空）') }
    foreach ($nm in @($names)) {
        $actObj = Get-LctProfActionObj -ShowData $sd -Action $nm
        $null = $out.Add("  · $nm   ioctl=$([string](Get-LctProp $actObj 'ioctlHex' (Get-LctProp $actObj 'ioctl' '—')))   风险=$([string](Get-LctProp $actObj 'riskLevel' '—'))")
        $hint = Format-LctProfFieldsHint -ShowData $sd -Action $nm
        $null = $out.Add("      $hint")
        $nt = [string](Get-LctProp $actObj 'notes' '')
        if ($nt) { $null = $out.Add("      说明：$nt") }
    }
    $lay = Get-LctProp $profObj 'layout' $null
    $null = $out.Add('')
    $null = $out.Add("布局        ：method=$([string](Get-LctProp $lay 'method' 'buffered'))  align=$([string](Get-LctProp $lay 'align' 8))  endian=$([string](Get-LctProp $lay 'endian' 'little'))")
    $lvl = Get-LctProfRiskLevel $profObj
    $null = $out.Add("风险评估    ：$(Format-LctProfRiskCn $lvl)")
    $rn = Get-LctProp (Get-LctProp $profObj 'risk' $null) 'notes' $null
    if ($null -eq $rn) { $rn = Get-LctProp $profObj 'risk' $null }
    if ($rn -is [string] -and $rn) { $null = $out.Add("  风险说明  ：$rn") }
    $req = Get-LctProp $profObj 'requires' $null
    $null = $out.Add("要求        ：elevation=$([string](Get-LctProp $req 'elevation' '—'))  admin=$(Format-LctBoolCn (Get-LctProp $req 'admin' $null))  restart=$(Format-LctBoolCn (Get-LctProp $req 'restart' $null))")
    $null = $out.Add('')
    $null = $out.Add("schema 校验 ：$(Format-LctBoolCn (Get-LctProp $sd 'schemaOk' $null))   engineApi=$(Format-LctNumOrDash (Get-LctProp $info 'engineApi' $null))  actionCount=$(Format-LctNumOrDash (Get-LctProp $info 'actionCount' $null))")
    foreach ($se in @(Get-LctArray (Get-LctProp $sd 'schemaErrors' @()))) { $null = $out.Add("  ✖ $se") }
    $null = $out.Add('  （schemaOk 只代表字段/类型/ioctl/risk/layout 合法，**不含** .sys 指纹比对 —— 指纹请用「校验」按钮）')
    $null = $out.Add('')
    $null = $out.Add('—— 引擎原始 JSON（driver.profile.show）——')
    try { $null = $out.Add((ConvertTo-Json -InputObject $sd -Depth 12)) } catch { $null = $out.Add([string]$sd) }
    Write-LctProfBox -Box $script:ProfDetailBox -Lines $out
}

function Update-LctProfCtlControls {
    param()
    # 同步「通用原语控制台」的 profile 下拉（来自清单缓存；不额外发引擎调用）。
    if ($null -eq $script:ProfCtlProfileBox) { return }
    if ($script:SuppressProfCtl) { return }
    $script:SuppressProfCtl = $true
    try {
        $keep = [string]$script:ProfCtlProfileBox.Text
        $script:ProfCtlProfileBox.Items.Clear()
        foreach ($it in @($script:ProfListCache)) {
            if ($it -is [string]) { $script:ProfCtlProfileBox.Items.Add($it); continue }
            $id = [string](Get-LctProp $it 'id' '')
            if ($id) { $script:ProfCtlProfileBox.Items.Add($id) }
        }
        if ($script:ProfCtlProfileBox.Items.Count -gt 0) {
            $idx = $script:ProfCtlProfileBox.Items.IndexOf($keep)
            if ($idx -ge 0) { $script:ProfCtlProfileBox.SelectedIndex = $idx } else { $script:ProfCtlProfileBox.SelectedIndex = 0 }
        } else {
            $script:ProfCtlActionBox.Items.Clear()
            Write-LctProfBox -Box $script:ProfCtlPlanBox -Lines @('（清单里没有 profile：先「刷新 profile 清单」，或用下面的静态草案起草后另存到 var\driver-profiles）')
        }
    } finally {
        $script:SuppressProfCtl = $false
    }
    Update-LctProfCtlActionList
}

function Update-LctProfCtlActionList {
    param()
    # 选中的 profile → 动作下拉（driver.profile.show 的 actions 键）+ 风险与蓝屏闸门。
    if ($null -eq $script:ProfCtlActionBox) { return }
    $id = ''
    if ($null -ne $script:ProfCtlProfileBox) { $id = [string]$script:ProfCtlProfileBox.Text }
    $script:SuppressProfCtl = $true
    try {
        $keep = [string]$script:ProfCtlActionBox.Text
        $script:ProfCtlActionBox.Items.Clear()
        if ($id) {
            $sd = Get-LctProfShowData -Id $id
            foreach ($nm in @(Get-LctProfActionNames $sd)) { $script:ProfCtlActionBox.Items.Add($nm) }
            if ($script:ProfCtlActionBox.Items.Count -gt 0) {
                $idx = $script:ProfCtlActionBox.Items.IndexOf($keep)
                if ($idx -ge 0) { $script:ProfCtlActionBox.SelectedIndex = $idx } else { $script:ProfCtlActionBox.SelectedIndex = 0 }
            }
        }
    } finally {
        $script:SuppressProfCtl = $false
    }
    Update-LctProfActionHint
    Update-LctProfBsodGate
}

function Update-LctProfActionHint {
    param()
    # 把该动作的 in/out 字段规格显示出来（payload 该填什么，一眼能看懂）。
    if ($null -eq $script:ProfActionHintLabel) { return }
    $bag = Get-LctProfCtlArgBag
    if (-not $bag.profile -or -not $bag.action) {
        $script:ProfActionHintLabel.Text = '（先选 profile 与 action：这里显示该动作声明的 in/out 字段，payload 按它填 JSON）'
        $script:ProfActionHintLabel.ForeColor = $script:C.Dim
        return
    }
    $sd = Get-LctProfShowData -Id ([string]$bag.profile)
    $hint = Format-LctProfFieldsHint -ShowData $sd -Action ([string]$bag.action)
    $lv = Get-LctProfRiskLevel (Get-LctProfObjFromShow $sd)
    $script:ProfActionHintLabel.Text = "该动作字段：$hint     profile 风险=$lv"
    $script:ProfActionHintLabel.ForeColor = $script:C.Text
}

function Update-LctProfBsodGate {
    param()
    # risk.level=bsod 的 action 默认禁用发送：必须勾选「我知道可能蓝屏」才允许点（且需重新预览）。
    $isBsod = $false
    $bag = Get-LctProfCtlArgBag
    if ($bag.profile -and $bag.action) {
        $sd = Get-LctProfShowData -Id ([string]$bag.profile)
        $isBsod = Test-LctProfBsodAction -ShowData $sd -Action ([string]$bag.action)
    }
    $ack = $false
    if ($null -ne $script:ProfBsodAckBox) { $ack = [bool]$script:ProfBsodAckBox.Checked }
    if ($isBsod) {
        if ($null -ne $script:ProfBsodNoteLabel) {
            $script:ProfBsodNoteLabel.Text = '★ 后果说明：这个动作被 profile 标为 risk.level=bsod —— 参数写错（地址/长度/结构布局不符）会让内核立刻 bugcheck，机器蓝屏，未保存的工作全部丢失。'
            $script:ProfBsodNoteLabel.ForeColor = $script:C.Err
        }
        if ($null -ne $script:ProfBsodAckBox) { $script:ProfBsodAckBox.Enabled = $true }
    } else {
        if ($null -ne $script:ProfBsodNoteLabel) {
            $script:ProfBsodNoteLabel.Text = '（当前 profile/action 未标 bsod；仍建议：先只点「① 预览」，确认 IOCTL 与缓冲区十六进制无误。写类动作必须能拿到原值才允许发送。）'
            $script:ProfBsodNoteLabel.ForeColor = $script:C.Dim
        }
    }
    # 「② 应用：发送」的可用性：必须有预览过的计划、且计划与当前界面参数一致；
    # bsod 动作还必须在勾选后重新预览过（参数包里带 overrideBsod=true）。
    $planOk = ($null -ne $script:ProfCtlPlan)
    $planMatch = $false
    if ($planOk) { $planMatch = Test-LctProfCtlPlanMatches }
    if ($null -ne $script:ProfCtlApplyBtn) {
        $enable = $false
        if ($planOk -and $planMatch) {
            $planBsod = [bool]$script:ProfCtlPlan.IsBsod
            if (-not $planBsod) { $enable = $true }
            elseif ($ack -and [bool]$script:ProfCtlPlan.OverrideBsod) { $enable = $true }
        }
        $script:ProfCtlApplyBtn.Enabled = $enable
    }
    if ($null -ne $script:ProfCtlGateLabel) {
        if (-not $planOk) {
            $script:ProfCtlGateLabel.Text = '待应用：无（先点「① 预览：发送」）'
            $script:ProfCtlGateLabel.ForeColor = $script:C.Dim
        } elseif (-not $planMatch) {
            $script:ProfCtlGateLabel.Text = '待应用：已预览，但界面参数变了（profile / action / payload / 勾选项）—— 请重新点「① 预览：发送」；本工具不拿你没看过的参数去发 IOCTL。'
            $script:ProfCtlGateLabel.ForeColor = $script:C.Dim
        } elseif ($isBsod -and -not $ack) {
            $script:ProfCtlGateLabel.Text = '待应用：已预览，但该动作是 bsod 级 —— 需勾选「我知道可能蓝屏」后**重新点一次① 预览**，才允许「② 应用：发送」。'
            $script:ProfCtlGateLabel.ForeColor = $script:C.Warn
        } else {
            $script:ProfCtlGateLabel.Text = "待应用：1 项（已预览，$($script:PREVIEW_BANNER)；点「② 应用：发送」并确认后才真的发 IOCTL）"
            $script:ProfCtlGateLabel.ForeColor = $script:C.Warn
        }
    }
}

function Invoke-LctProfValidate {
    param()
    # driver.profile.validate：schema + .sys 指纹 + 内存沙盒；不碰内核。errors 原文醒目显示。
    $id = Get-LctProfSelectedId
    $sys = ''
    if ($null -ne $script:ProfValidateSysBox) { $sys = [string]$script:ProfValidateSysBox.Text.Trim() }
    if (-not $id -and -not $sys) {
        $null = [System.Windows.Forms.MessageBox]::Show(
            "请先在左边的 profile 清单里选中一行（或在下面的 .sys 框里填一个 .sys 再校验）。`r`n`r`ndriver.profile.validate 只做三件事：schema 校验、.sys 指纹比对、内存沙盒打包/解包往返 —— 不碰内核、不 CreateFile 设备。",
            '需要先选 profile', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
        return
    }
    $bag = @{}
    if ($id) { $bag.id = $id }
    if ($sys) { $bag.path = $sys }
    $r = Invoke-LctEngine -Verb 'driver.profile.validate' -Args $bag
    $out = New-Object System.Collections.ArrayList
    $null = $out.Add("driver.profile.validate   id=$($(if ($id) { $id } else { '（未给 -Id）' }))   path=$($(if ($sys) { $sys } else { '（未给 -Path）' }))")
    $null = $out.Add('（本调用不碰内核：没有 CreateFile 设备、没有发任何 IOCTL；沙盒只在内存里做打包/解包往返）')
    $null = $out.Add('')
    if (-not $r.ok -and $null -eq $r.data) {
        $null = $out.Add('★ 校验失败（errors 原文，逐条照抄，未美化）：')
        foreach ($e in @(Get-LctArray $r.errors)) { $null = $out.Add('  ✖ ' + [string]$e) }
        Write-LctProfBox -Box $script:ProfValidateBox -Lines $out
        if ($null -ne $script:ProfValidateTierLabel) {
            $script:ProfValidateTierLabel.Text = '校验结果：不通过（拒绝）—— 见左侧 errors 原文'
            $script:ProfValidateTierLabel.ForeColor = $script:C.Err
        }
        return
    }
    $d = Get-LctDataDeep -Result $r -KeyName 'fingerprintMatch'
    if ($null -eq $d) { $d = Get-LctProp $r 'data' $null }
    $matchV = Get-LctProp $d 'fingerprintMatch' $null
    $schemaV = Get-LctProp $d 'schemaOk' $null
    $null = $out.Add("schema 校验 ：$(Format-LctBoolCn $schemaV)")
    $null = $out.Add("指纹门      ：$(Format-LctBoolCn $matchV)")
    $declared = @(Get-LctArray (Get-LctProp $d 'declaredSha256' @()))
    $actual = [string](Get-LctProp $d 'actualSha256' '')
    $sf = Get-LctProp $d 'sysFile' $null
    $null = $out.Add("  .sys 文件 ：$([string](Get-LctProp $sf 'path' '—'))   （解析方式 $([string](Get-LctProp $sf 'resolution' '—'))）")
    $null = $out.Add("  声明 sha256：$((@($declared) | ForEach-Object { [string]$_ }) -join ', ' )")
    $null = $out.Add("  实际 sha256：$actual")
    if ($matchV -eq $false) {
        $null = $out.Add('')
        $null = $out.Add('★★ 指纹不符 ⇒ 拒绝执行 ★★')
        $null = $out.Add('  含义：这份 profile 声明的 .sys SHA256 与实际文件不一致（版本/布局可能不同）。')
        $null = $out.Add('  为什么必须拒绝：profile 里的 IOCTL 与结构布局是按某个版本逆向写死的，版本错 ⇒ 打包结构错 ⇒')
        $null = $out.Add('  内核按错误布局解引用 ⇒ 极大概率立刻蓝屏。契约 §13.6 第 2 条：不符即拒绝，没有"先试试看"的选项。')
        $null = $out.Add('  怎么修：用目标版本的 .sys 重新 driver.profile.draft，并按实际文件核对 IOCTL 与 in/out 结构后再另存。')
    }
    $sb = Get-LctProp $d 'sandbox' $null
    $null = $out.Add("内存沙盒    ：$(Format-LctBoolCn (Get-LctProp $sb 'passed' $null))   （动作数 $(Format-LctNumOrDash (Get-LctProp $sb 'actionCount' $null))；只做打包/解包往返，不碰设备）")
    $null = $out.Add('')
    $null = $out.Add('—— 逐项检查（checks）——')
    foreach ($c in @(Get-LctArray (Get-LctProp $d 'checks' @()))) {
        $mark = '✖'
        if ((Get-LctProp $c 'passed' $null) -eq $true) { $mark = '✔' }
        $null = $out.Add("  $mark $([string](Get-LctProp $c 'name' '')) : $([string](Get-LctProp $c 'detail' ''))")
    }
    $null = $out.Add('')
    $null = $out.Add('—— errors 原文（未美化）——')
    if (@(Get-LctArray $r.errors).Count -eq 0) { $null = $out.Add('  （无 errors）') }
    foreach ($e in @(Get-LctArray $r.errors)) { $null = $out.Add('  ✖ ' + [string]$e) }
    $null = $out.Add('—— warnings 原文 ——')
    if (@(Get-LctArray $r.warnings).Count -eq 0) { $null = $out.Add('  （无 warnings）') }
    foreach ($w in @(Get-LctArray $r.warnings)) { $null = $out.Add('  ⚠ ' + [string]$w) }
    $null = $out.Add('')
    $null = $out.Add('—— 引擎原始 JSON（driver.profile.validate）——')
    try { $null = $out.Add((ConvertTo-Json -InputObject $d -Depth 12)) } catch { $null = $out.Add([string]$d) }
    Write-LctProfBox -Box $script:ProfValidateBox -Lines $out
    if ($null -ne $script:ProfValidateTierLabel) {
        if ($r.ok -and $matchV -eq $true -and $schemaV -eq $true) {
            $script:ProfValidateTierLabel.Text = '校验结果：通过（schema ✔ + 指纹 ✔ + 沙盒 ✔）—— 仍需人工确认动作语义后才发送'
            $script:ProfValidateTierLabel.ForeColor = $script:C.Ok
        } else {
            $script:ProfValidateTierLabel.Text = '校验结果：不通过（拒绝）—— errors 原文见左侧（指纹不符 ⇒ 拒绝）'
            $script:ProfValidateTierLabel.ForeColor = $script:C.Err
        }
    }
}

function Invoke-LctProfDraft {
    param()
    # driver.profile.draft：静态草案（只读，不发 IOCTL、不加载驱动）。产物必须带 confidence 与 needsReview=true。
    $path = ''
    if ($null -ne $script:ProfDraftPathBox) { $path = [string]$script:ProfDraftPathBox.Text.Trim() }
    if (-not $path) {
        $null = [System.Windows.Forms.MessageBox]::Show(
            "请先选一个 .sys 文件（或直接填完整路径）。`r`n`r`ndriver.profile.draft 只做静态解析：PE 头/节表、设备名候选字符串、dispatch 里的候选 IOCTL —— 它不加载驱动、不发 IOCTL、不执行被解析文件里的任何代码。",
            '需要先选 .sys', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
        return
    }
    $r = Invoke-LctEngine -Verb 'driver.profile.draft' -Args @{ path = $path }
    $out = New-Object System.Collections.ArrayList
    $null = $out.Add('★★ 这是【静态草案】，不是可用 profile：不可以直接执行、不可以直接拿去发 IOCTL ★★')
    $null = $out.Add('   草案的 actions 故意为空，draft.needsReview=true 永远为真；必须人工确认设备名/IOCTL/输入结构后补全，')
    $null = $out.Add('   另存到 var\driver-profiles\<id>.json，再用「校验」过指纹门与 schema，才可能被允许执行。')
    $null = $out.Add('')
    $null = $out.Add("输入 .sys ：$path")
    if (-not $r.ok) {
        $null = $out.Add("driver.profile.draft 调用失败（errors 原文）：")
        foreach ($e in @(Get-LctArray $r.errors)) { $null = $out.Add('  ✖ ' + [string]$e) }
        Write-LctProfBox -Box $script:ProfDraftBox -Lines $out
        if ($null -ne $script:ProfDraftTierLabel) {
            $script:ProfDraftTierLabel.Text = '草案生成失败（见下方原文）—— 未产出任何文件，未加载任何驱动'
            $script:ProfDraftTierLabel.ForeColor = $script:C.Err
        }
        return
    }
    $d = Get-LctDataDeep -Result $r -KeyName 'confidence'
    if ($null -eq $d) { $d = Get-LctProp $r 'data' $null }
    $conf = Get-LctProp $d 'confidence' $null
    $nr = Get-LctProp $d 'needsReview' $null
    $script:ProfSaveJson = [string](Get-LctProp $d 'draftJson' '')
    $draftObj = Get-LctProp $d 'draft' $null
    $script:ProfSaveId = [string](Get-LctProp $draftObj 'id' '')
    if (-not $script:ProfSaveId) { $script:ProfSaveId = 'draft-profile' }
    $null = $out.Add("路径        ：$([string](Get-LctProp $d 'path' $path))")
    $null = $out.Add("confidence  ：$(Format-LctNumOrDash $conf)    needsReview：$(Format-LctBoolCn $nr)（恒为 是）")
    $null = $out.Add("设备名候选数：$(Format-LctNumOrDash (Get-LctProp $d 'candidatesFound' $null))    IOCTL 候选数：$(Format-LctNumOrDash (Get-LctProp $d 'ioctlCandidateCount' $null))    有 xref 证据的设备名：$(Format-LctNumOrDash (Get-LctProp $d 'devNameXrefCount' $null))")
    $null = $out.Add("草案 id     ：$($script:ProfSaveId)（另存时的目标文件名就是它）")
    $null = $out.Add("引擎提示    ：$([string](Get-LctProp $d 'hint' ''))")
    $null = $out.Add('')
    $null = $out.Add('—— 草案 JSON（draftJson 原文；这就是「另存」将要写进 var\driver-profiles 的内容）——')
    $dj = [string](Get-LctProp $d 'draftJson' '')
    if (-not $dj) { $null = $out.Add('（引擎没有返回 draftJson）') }
    else {
        $lines = @($dj -split "`r?`n")
        if (@($lines).Count -gt 120) {
            $lines = @($lines | Select-Object -First 120)
            $lines += '…（草案 JSON 过长已截断显示；另存写盘的是完整内容）'
        }
        foreach ($l in @($lines)) { $null = $out.Add($l) }
    }
    $null = $out.Add('')
    $null = $out.Add('—— warnings / errors 原文 ——')
    foreach ($w in @(Get-LctArray $r.warnings)) { $null = $out.Add('  ⚠ ' + [string]$w) }
    foreach ($e in @(Get-LctArray $r.errors)) { $null = $out.Add('  ✖ ' + [string]$e) }
    Write-LctProfBox -Box $script:ProfDraftBox -Lines $out
    if ($null -ne $script:ProfDraftTierLabel) {
        $script:ProfDraftTierLabel.Text = "草案已生成（confidence=$conf，needsReview=是）—— 草案不可直接执行，必须人工审定后另存"
        $script:ProfDraftTierLabel.ForeColor = $script:C.Warn
    }
    Update-LctProfSaveButtons
}

function Update-LctProfSaveButtons {
    param()
    # 可用性驱动：引擎有 driver.profile.save 才点亮「另存」两个按钮（并发开发期后端可能还没落地）。
    $has = Test-LctVerbAvailable -Verb 'driver.profile.save'
    $hasJson = [bool]$script:ProfSaveJson
    foreach ($b in @($script:ProfSavePreviewBtn, $script:ProfSaveApplyBtn)) {
        if ($null -eq $b) { continue }
        if ($has -and $hasJson) { $b.Enabled = $true; $b.BackColor = $script:C.Panel2 }
        else { $b.Enabled = $false; $b.BackColor = $script:C.Panel }
    }
    if ($null -ne $script:ProfSaveNoteLabel) {
        if (-not $has) {
            $script:ProfSaveNoteLabel.Text = '另存不可用：引擎未提供保存 verb（driver.profile.save）。前端不写盘（契约 §1：前端不含后端逻辑），后端落地该 verb 后这两个按钮会自动点亮。'
            $script:ProfSaveNoteLabel.ForeColor = $script:C.Warn
        } elseif (-not $hasJson) {
            $script:ProfSaveNoteLabel.Text = '另存不可用：还没有草案 JSON —— 先点「① 静态起草（driver.profile.draft，只读）」。'
            $script:ProfSaveNoteLabel.ForeColor = $script:C.Dim
        } else {
            $script:ProfSaveNoteLabel.Text = "另存目标：var\driver-profiles\$($script:ProfSaveId).json（用户来源，不是内置 core\driver-profiles；同名已存在需 override，覆盖前引擎会把原文件备份进 var\backups）。"
            $script:ProfSaveNoteLabel.ForeColor = $script:C.Ok
        }
    }
}

function Invoke-LctProfSavePreview {
    param()
    # ① 预览另存：driver.profile.save 不带 -Apply —— 只给出目标路径/校验结果/是否将覆盖，绝不写盘。
    $out = New-Object System.Collections.ArrayList
    $null = $out.Add('★ 草案身份提醒：needsReview=true 的 profile 不应直接用于真机发送 IOCTL；')
    $null = $out.Add('  另存只是把草案落到你的 var\driver-profiles，仍必须人工审定后再谈执行。')
    $null = $out.Add('')
    if (-not (Test-LctVerbAvailable -Verb 'driver.profile.save')) {
        $null = $out.Add('引擎未提供保存 verb（driver.profile.save）—— 本次没有做任何事，也没有落盘。')
        $null = $out.Add('前端不实现写盘逻辑（契约 §1）；后端落地该 verb 后这两个按钮会自动点亮。')
        $null = $out.Add('现在可以做的：把上面草案 JSON 自行另存为 var\driver-profiles\<id>.json，再回来用「校验」按钮过指纹门。')
        Write-LctProfBox -Box $script:ProfDraftBox -Lines $out
        if ($null -ne $script:ProfSaveStatusLabel) {
            $script:ProfSaveStatusLabel.Text = '另存预览：未执行（引擎未提供 driver.profile.save）—— 没有落盘'
            $script:ProfSaveStatusLabel.ForeColor = $script:C.Warn
        }
        return
    }
    if (-not $script:ProfSaveJson) {
        $null = $out.Add('还没有草案 JSON：请先点「① 静态起草（driver.profile.draft，只读）」。')
        Write-LctProfBox -Box $script:ProfDraftBox -Lines $out
        return
    }
    $bag = @{ id = $script:ProfSaveId; json = $script:ProfSaveJson; override = $false }
    $r = Invoke-LctPreview -Page 'driverprofiles' -Id ('draftsave:' + $script:ProfSaveId) -Verb 'driver.profile.save' -Args $bag -Summary ('另存草案到 var\driver-profiles\' + $script:ProfSaveId + '.json') -TimeoutSec 120
    $null = $out.Add("引擎调用：driver.profile.save（无 -Apply）   id=$($script:ProfSaveId)")
    $null = $out.Add("$($script:PREVIEW_BANNER)：没有写任何文件。")
    $null = $out.Add('')
    if (-not $r.ok) {
        $null = $out.Add('预览被拒绝 / 失败（errors 原文）：')
        foreach ($e in @(Get-LctArray $r.errors)) { $null = $out.Add('  ✖ ' + [string]$e) }
        foreach ($w in @(Get-LctArray $r.warnings)) { $null = $out.Add('  ⚠ ' + [string]$w) }
        Write-LctProfBox -Box $script:ProfDraftBox -Lines $out
        if ($null -ne $script:ProfSaveStatusLabel) {
            $script:ProfSaveStatusLabel.Text = '另存预览：被拒绝 —— 未落盘'
            $script:ProfSaveStatusLabel.ForeColor = $script:C.Err
        }
        return
    }
    $d = Get-LctDataDeep -Result $r -KeyName 'path'
    if ($null -eq $d) { $d = Get-LctProp $r 'data' $null }
    $null = $out.Add("目标路径    ：$([string](Get-LctProp $d 'path' '—'))")
    $null = $out.Add("来源        ：$([string](Get-LctProp $d 'source' 'user'))   （用户来源 = var\driver-profiles）")
    $ovV = Get-LctProp $d 'wouldOverwrite' $null
    if ($null -eq $ovV) { $ovV = Get-LctProp $d 'overwritten' $null }
    $vdO = Get-LctProp $d 'validated' $null
    $null = $out.Add("目标已存在  ：$(Format-LctBoolCn (Get-LctProp $d 'exists' $null))   将覆盖：$(Format-LctBoolCn $ovV)   （同名已存在需 override；覆盖前引擎把原文件复制进 var\backups，不删原文件）")
    $null = $out.Add("真实已落盘  ：$(Format-LctBoolCn (Get-LctProp $d 'overwritten' $null))（预览阶段恒为 否 = $($script:PREVIEW_BANNER)）")
    $null = $out.Add("保存前校验  ：schema=$(Format-LctBoolCn (Get-LctProp $vdO 'ok' $null))   actionCount=$(Format-LctNumOrDash (Get-LctProp $vdO 'actionCount' $null))   risk=$([string](Get-LctProp $vdO 'riskLevel' '—'))   （不合法直接拒，未落盘）")
    $null = $out.Add("字节数      ：$(Format-LctNumOrDash (Get-LctProp $d 'bytes' $null))")
    $null = $out.Add("写盘格式    ：UTF-8 无 BOM（JSON 是数据不是脚本）；文件里 profile.id 必须与 id 一致")
    $null = $out.Add('')
    $null = $out.Add('已登记为待应用：点「② 应用：另存」并在确认框选「是」，才会真正写盘。')
    $null = $out.Add('')
    $null = $out.Add('—— 保存前的校验原文（请先看它是否已通过）——')
    $null = $out.Add('（保存 verb 会先校验；若下方为空，请点左侧「校验（driver.profile.validate）」看 fingerprintMatch / schemaOk / errors 原文。）')
    foreach ($w in @(Get-LctArray $r.warnings)) { $null = $out.Add('  ⚠ ' + [string]$w) }
    foreach ($e in @(Get-LctArray $r.errors)) { $null = $out.Add('  ✖ ' + [string]$e) }
    Write-LctProfBox -Box $script:ProfDraftBox -Lines $out
    if ($null -ne $script:ProfSaveStatusLabel) {
        $script:ProfSaveStatusLabel.Text = "另存预览：$($script:PREVIEW_BANNER)（目标 $([string](Get-LctProp $d 'path' '—'))）"
        $script:ProfSaveStatusLabel.ForeColor = $script:C.Warn
    }
}

function Invoke-LctProfSaveApply {
    param()
    # ② 应用另存：走统一闸门（待应用 + MessageBox 二次确认）后才带 -Apply。
    if (-not (Test-LctVerbAvailable -Verb 'driver.profile.save')) {
        if ($null -ne $script:ProfSaveStatusLabel) {
            $script:ProfSaveStatusLabel.Text = '另存应用：未执行（引擎未提供 driver.profile.save）—— 没有落盘'
            $script:ProfSaveStatusLabel.ForeColor = $script:C.Warn
        }
        return
    }
    Invoke-LctApplyPending -Page 'driverprofiles' -Id ('draftsave:' + $script:ProfSaveId)
}

function Invoke-LctProfCtlPreview {
    param()
    # ① 预览：发送 —— 不带 -Apply。引擎只打包并打印「将发送的 IOCTL + 缓冲区十六进制」，不 CreateFile 设备。
    $bag = Get-LctProfCtlArgBag
    if (-not $bag.profile -or -not $bag.action) {
        $null = [System.Windows.Forms.MessageBox]::Show(
            "请先选 profile 与 action（清单为空时先「刷新 profile 清单」）。",
            '需要先选 profile / action', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
        return
    }
    $script:ProfCtlPlan = $null
    $r = Invoke-LctEngine -Verb 'driver.ctl.send' -Args $bag
    $out = New-Object System.Collections.ArrayList
    $null = $out.Add("$($script:PREVIEW_BANNER) / 未发送：本次没有打开设备、没有发任何 IOCTL（引擎 mode=preview）。")
    $null = $out.Add('')
    if (-not $r.ok) {
        $null = $out.Add('预览被拒绝 / 失败（errors 原文）：')
        foreach ($e in @(Get-LctArray $r.errors)) { $null = $out.Add('  ✖ ' + [string]$e) }
        foreach ($w in @(Get-LctArray $r.warnings)) { $null = $out.Add('  ⚠ ' + [string]$w) }
        Write-LctProfBox -Box $script:ProfCtlSendBox -Lines $out
        Write-LctProfBox -Box $script:ProfCtlResultBox -Lines @('（没有可展示的返回：预览未通过，未发送任何数据）')
        Update-LctProfBsodGate
        return
    }
    $d = Get-LctDataDeep -Result $r -KeyName 'action'
    if ($null -eq $d) { $d = Get-LctProp $r 'data' $null }
    $act = Get-LctProp $d 'action' $null
    $req = Get-LctProp $d 'request' $null
    $dev = Get-LctProp $d 'device' $null
    $gate = Get-LctProp $d 'gate' $null
    $null = $out.Add('—— 将发送 ——')
    $null = $out.Add("profile/action ：$([string]$bag.profile)  /  $([string]$bag.action)")
    $null = $out.Add("IOCTL          ：$([string](Get-LctProp $act 'ioctlHex' '—'))   （十进制 $([string](Get-LctProp $act 'ioctl' '—'))，method=$([string](Get-LctProp $act 'method' '—'))）")
    $null = $out.Add("动作风险       ：$([string](Get-LctProp $act 'riskLevel' '—'))（来源 $([string](Get-LctProp $act 'riskSource' '—'))）   需要 overrideBsod=$(Format-LctBoolCn (Get-LctProp $act 'requiresOverrideBsod' $null))   需要 IUnderstand=$(Format-LctBoolCn (Get-LctProp $act 'requiresUnderstand' $null))")
    $null = $out.Add("输入缓冲大小   ：$(Format-LctNumOrDash (Get-LctProp $req 'size' $null)) 字节   打开权限=$([string](Get-LctProp $act 'openAccess' '—'))")
    $null = $out.Add('')
    $null = $out.Add('—— 将发送的输入缓冲区（十六进制）——')
    $hx = [string](Get-LctProp $req 'hex' '')
    $dump = @(Get-LctArray (Get-LctProp $req 'hexDump' @()))
    if ($hx) { $null = $out.Add("hex（连续）：$hx") }
    if (@($dump).Count -gt 0) {
        foreach ($l in @($dump)) { $null = $out.Add([string]$l) }
    } elseif (-not $hx) {
        $null = $out.Add('（无输入缓冲区：该动作没有声明 in 字段）')
    }
    $null = $out.Add('')
    $null = $out.Add('—— 打包字段（按 profile 的 in/out 布局，小端对齐）——')
    foreach ($f in @(Get-LctArray (Get-LctProp $req 'fields' @()))) {
        $null = $out.Add("  in  $([string](Get-LctProp $f 'name' ''))：$([string](Get-LctProp $f 'type' (Get-LctProp $f 'kind' ''))) @offset $(Format-LctNumOrDash (Get-LctProp $f 'offset' $null))  size=$(Format-LctNumOrDash (Get-LctProp $f 'size' $null))  value=$([string](Get-LctProp $f 'value' ''))")
    }
    foreach ($f in @(Get-LctArray (Get-LctProp $req 'outFields' @()))) {
        $null = $out.Add("  out $([string](Get-LctProp $f 'name' ''))：$([string](Get-LctProp $f 'type' (Get-LctProp $f 'kind' ''))) @offset $(Format-LctNumOrDash (Get-LctProp $f 'offset' $null))  size=$(Format-LctNumOrDash (Get-LctProp $f 'size' $null))")
    }
    $null = $out.Add("预期输出大小   ：$(Format-LctNumOrDash (Get-LctProp $req 'outSize' $null))（$([string](Get-LctProp $req 'outNote' ''))）")
    $null = $out.Add('')
    $null = $out.Add('—— 设备定位（预览阶段不打开设备）——')
    $null = $out.Add("策略 / GUID    ：$([string](Get-LctProp $dev 'strategy' '—'))  /  $([string](Get-LctProp $dev 'interfaceGuid' '—'))")
    $null = $out.Add("候选入口       ：$((@(Get-LctArray (Get-LctProp $dev 'candidates' @())) | ForEach-Object { [string]$_ }) -join '  ' )")
    $null = $out.Add("本次是否已打开 ：$(Format-LctBoolCn (Get-LctProp $dev 'opened' $null))      device.verdict=$([string](Get-LctProp $dev 'verdict' '—'))")
    $null = $out.Add("闸门状态       ：bsodOverride=$(Format-LctBoolCn (Get-LctProp $gate 'bsodOverride' $null))  understand=$(Format-LctBoolCn (Get-LctProp $gate 'understand' $null))  refused=$([string](Get-LctProp $gate 'refused' '（无）'))")
    $null = $out.Add('')
    foreach ($n in @(Get-LctArray (Get-LctProp $d 'notes' @()))) { $null = $out.Add('说明：' + [string]$n) }
    $null = $out.Add('')
    $null = $out.Add('—— 引擎原始 JSON（driver.ctl.send 预览）——')
    try { $null = $out.Add((ConvertTo-Json -InputObject $d -Depth 12)) } catch { $null = $out.Add([string]$d) }
    Write-LctProfBox -Box $script:ProfCtlSendBox -Lines $out
    Write-LctProfBox -Box $script:ProfCtlResultBox -Lines @('（这是预览：没有发送，所以没有返回数据。点「② 应用：发送」并在确认框选「是」后，这里显示 data.result 与 data.rawOutHex。）')

    # 蓝屏闸门：bsod 级动作必须勾选「我知道可能蓝屏」才登记待应用（否则连待应用都不登记，避免被别的路径绕过）
    $sd = Get-LctProfShowData -Id ([string]$bag.profile)
    $isBsod = Test-LctProfBsodAction -ShowData $sd -Action ([string]$bag.action)
    $ack = [bool](Get-LctProp $bag 'overrideBsod' $false)
    $script:ProfCtlPlan = @{
        Bag         = $bag
        IsBsod      = $isBsod
        OverrideBsod = $ack
        Summary     = ("发送原语：$([string]$bag.profile) / $([string]$bag.action)")
    }
    if ((Test-LctVerbAvailable -Verb 'driver.ctl.send') -and ((-not $isBsod) -or $ack)) {
        Add-LctPending -Page 'driverprofiles' -Id ('ctl:' + [string]$bag.profile) -Verb 'driver.ctl.send' -Args $bag -Summary ([string]$script:ProfCtlPlan.Summary) -TimeoutSec 180
        Add-LctLogLine "        ✔ 预览通过，已登记为待应用（还差一次「应用」+ 确认）" $script:C.Ok
    } elseif ($isBsod -and -not $ack) {
        Add-LctLogLine "        ⚠ 该动作 risk.level=bsod：未登记待应用（请勾选「我知道可能蓝屏」后重新点① 预览）" $script:C.Warn
    }
    Update-LctProfBsodGate
}

function Invoke-LctProfCtlApply {
    param()
    # ② 应用：发送 —— 必须「已预览」+（bsod 级则已勾选并重新预览）+ MessageBox 二次确认，才带 -Apply。
    if ($null -eq $script:ProfCtlPlan) {
        $null = [System.Windows.Forms.MessageBox]::Show(
            "还没有通过预览的发送计划。`r`n请先点「① 预览：发送」，确认「将发送」区的 IOCTL 与缓冲区十六进制无误，再点这里。",
            '需要先预览', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
        return
    }
    $plan = $script:ProfCtlPlan
    if (-not (Test-LctProfCtlPlanMatches)) {
        $null = [System.Windows.Forms.MessageBox]::Show(
            "界面上的参数与上次预览的不一致（profile / action / payload / 勾选项变了）。`r`n请重新点「① 预览：发送」——本工具不会拿一份你没看过的参数去发 IOCTL。",
            '需要重新预览', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning)
        return
    }
    if ([bool]$plan.IsBsod) {
        $ack = $false
        if ($null -ne $script:ProfBsodAckBox) { $ack = [bool]$script:ProfBsodAckBox.Checked }
        if (-not $ack -or -not [bool]$plan.OverrideBsod) {
            $null = [System.Windows.Forms.MessageBox]::Show(
                "这个动作被 profile 标为 risk.level=bsod（可能立刻蓝屏）。`r`n必须先勾选「我知道可能蓝屏」并重新点一次「① 预览：发送」，才允许应用。",
                'bsod 级动作：默认禁用发送', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning)
            return
        }
    }
    $bag = $plan.Bag
    $msg = "即将向设备【真实发送】一个 IOCTL：`r`n`r`n"
    $msg += "  profile ：$([string]$bag.profile)`r`n"
    $msg += "  action  ：$([string]$bag.action)`r`n"
    $msg += "  payload ：$([string]$bag.payload)`r`n"
    $msg += "  overrideBsod：$(Format-LctBoolCn ([bool]$bag.overrideBsod))`r`n`r`n"
    if ([bool]$plan.IsBsod) {
        $msg += "★★ 高风险：该动作 risk.level=bsod —— 参数写错（地址/长度/结构布局不符）会让内核立刻 bugcheck 蓝屏，"
        $msg += "未保存的工作全部丢失，可能要强制重启。★★`r`n`r`n"
    }
    $msg += "请先回到「将发送」区核对 IOCTL 与缓冲区十六进制是否与你预期一致。`r`n"
    $msg += "写类动作必须能拿到写前原值（无原值不写）；拿不到时引擎会拒绝，不会硬写。`r`n`r`n确定真的发送吗？"
    $dr = [System.Windows.Forms.MessageBox]::Show($msg, '二次确认：真的发 IOCTL 吗？',
        [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Warning,
        [System.Windows.Forms.MessageBoxDefaultButton]::Button2)
    if ($dr -ne [System.Windows.Forms.DialogResult]::Yes) {
        Add-LctLogLine '  ℹ 用户取消了发送（未发 IOCTL）' $script:C.Dim
        return
    }
    $r = Invoke-LctEngine -Verb 'driver.ctl.send' -Args $bag -Apply -TimeoutSec 180
    Remove-LctPending -Page 'driverprofiles' -Id ('ctl:' + [string]$bag.profile)
    $out = New-Object System.Collections.ArrayList
    $null = $out.Add("已执行：driver.ctl.send -Apply（applied=$(Format-LctBoolCn $r.applied)）")
    $null = $out.Add('')
    if (-not $r.ok -and $null -eq $r.data) {
        $null = $out.Add('发送失败（errors 原文）：')
        foreach ($e in @(Get-LctArray $r.errors)) { $null = $out.Add('  ✖ ' + [string]$e) }
        Write-LctProfBox -Box $script:ProfCtlResultBox -Lines $out
        return
    }
    $d = Get-LctDataDeep -Result $r -KeyName 'result'
    if ($null -eq $d) { $d = Get-LctProp $r 'data' $null }
    $gate = Get-LctProp $d 'gate' $null
    $dev = Get-LctProp $d 'device' $null
    $null = $out.Add("模式 / 是否已发 ：$([string](Get-LctProp $d 'mode' '—'))  ioctlSent=$(Format-LctBoolCn (Get-LctProp $d 'ioctlSent' $null))")
    $null = $out.Add("设备 verdict    ：$([string](Get-LctProp $dev 'verdict' '—'))   实际打开：$([string](Get-LctProp $dev 'openPath' '—'))")
    $null = $out.Add("闸门 refused    ：$([string](Get-LctProp $gate 'refused' '（无：没有被拒绝）'))")
    $null = $out.Add("bytesReturned   ：$(Format-LctNumOrDash (Get-LctProp $d 'bytesReturned' $null))")
    $null = $out.Add('')
    $null = $out.Add('—— data.result（按 profile 的 out 布局解出的字段）——')
    $res = Get-LctProp $d 'result' $null
    if ($null -eq $res) {
        $null = $out.Add('（null：该动作没有声明 out 字段，或驱动没有回数据）')
    } else {
        try { $null = $out.Add((ConvertTo-Json -InputObject $res -Depth 10)) } catch { $null = $out.Add([string]$res) }
    }
    $null = $out.Add('')
    $null = $out.Add("—— data.rawOutHex ——`r`n$([string](Get-LctProp $d 'rawOutHex' '（无）'))")
    $bf = Get-LctProp $d 'before' $null
    if ($null -ne $bf) {
        $null = $out.Add('')
        $null = $out.Add('—— 写类动作：写前原值（before）——')
        $null = $out.Add("  action=$([string](Get-LctProp $bf 'action' '—'))   rawHex=$([string](Get-LctProp $bf 'rawHex' '—'))")
        $null = $out.Add("  解出的值：$([string](Get-LctProp $bf 'valueField' '—'))   来源=$([string](Get-LctProp $bf 'source' '—'))")
    }
    $af = Get-LctProp $d 'after' $null
    if ($null -ne $af) { $null = $out.Add("  写后 rawHex=$([string](Get-LctProp $af 'rawHex' '—'))") }
    $rs = Get-LctProp $d 'restore' $null
    if ($null -ne $rs) {
        $null = $out.Add('—— 还原脚本 ——')
        $null = $out.Add("  生成成功=$(Format-LctBoolCn (Get-LctProp $rs 'ok' $null))  目录=$([string](Get-LctProp $rs 'dir' '—'))")
        $null = $out.Add("  PowerShell：$([string](Get-LctProp $rs 'ps1' '—'))")
        $null = $out.Add("  CMD       ：$([string](Get-LctProp $rs 'cmd' '—'))")
        $null = $out.Add("  说明      ：$([string](Get-LctProp $rs 'note' '—'))")
    }
    $null = $out.Add('')
    $null = $out.Add('—— warnings / errors 原文 ——')
    foreach ($w in @(Get-LctArray $r.warnings)) { $null = $out.Add('  ⚠ ' + [string]$w) }
    foreach ($e in @(Get-LctArray $r.errors)) { $null = $out.Add('  ✖ ' + [string]$e) }
    $null = $out.Add('')
    $null = $out.Add('—— 引擎原始 JSON（driver.ctl.send -Apply）——')
    try { $null = $out.Add((ConvertTo-Json -InputObject $d -Depth 12)) } catch { $null = $out.Add([string]$d) }
    Write-LctProfBox -Box $script:ProfCtlResultBox -Lines $out
    $script:ProfCtlPlan = $null
    Update-LctProfBsodGate
}

function Invoke-LctProfVerify {
    param()
    # driver.ctl.verify：canary 握手。三档显示：确实是这个驱动且能通 / 不通 / 状态不明。
    $id = ''
    if ($null -ne $script:ProfCtlProfileBox) { $id = [string]$script:ProfCtlProfileBox.Text }
    if (-not $id) { $id = Get-LctProfSelectedId }
    if (-not $id) {
        $null = [System.Windows.Forms.MessageBox]::Show(
            "请先选一个 profile（清单里选中一行，或在原语控制台的下拉里选）。",
            '需要先选 profile', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
        return
    }
    $r = Invoke-LctEngine -Verb 'driver.ctl.verify' -Args @{ profile = $id }
    $out = New-Object System.Collections.ArrayList
    $null = $out.Add("driver.ctl.verify   profile=$id")
    $null = $out.Add('（该 verb 在引擎里 mutating=false：默认只做文件指纹/可开性判定，canary IOCTL 只有握手档才会真的发）')
    $null = $out.Add('')
    if (-not $r.ok -and $null -eq $r.data) {
        $null = $out.Add('调用失败（errors 原文）：')
        foreach ($e in @(Get-LctArray $r.errors)) { $null = $out.Add('  ✖ ' + [string]$e) }
        Write-LctProfBox -Box $script:ProfCtlVerifyBox -Lines $out
        if ($null -ne $script:ProfVerifyTierLabel) {
            $script:ProfVerifyTierLabel.Text = '结论：状态不明（调用失败，见下方原文）'
            $script:ProfVerifyTierLabel.ForeColor = $script:C.Warn
        }
        return
    }
    $d = Get-LctDataDeep -Result $r -KeyName 'proofLevel'
    if ($null -eq $d) { $d = Get-LctProp $r 'data' $null }
    $lvl = [string](Get-LctProp $d 'proofLevel' 'none')
    $ff = Get-LctProp $d 'fileFingerprint' $null
    $cv = Get-LctProp $d 'canary' $null
    $dev = Get-LctProp $d 'device' $null
    $tier = 'unknown'
    $tierText = '状态不明'
    $tierColor = $script:C.Warn
    if ($lvl -eq 'handshake') {
        if ((Get-LctProp $cv 'ok' $null) -eq $true) {
            $tier = 'ok'; $tierText = '确认：这个设备确实是这个驱动，且能通（canary 握手成功）'; $tierColor = $script:C.Ok
        } else {
            $tier = 'fail'; $tierText = '不通：canary IOCTL 已发但握手失败（见下方 canary.message）'; $tierColor = $script:C.Err
        }
    } elseif ($lvl -eq 'openable') {
        $tierText = '状态不明（偏可用）：设备入口能打开，但没有握手证据证明"确实是这个驱动"'
    } elseif ($lvl -eq 'file-fingerprint') {
        $tierText = '状态不明：只证明 .sys 指纹匹配（文件对得上），没有接触设备'
    } elseif ($lvl -eq 'none') {
        if ((Get-LctProp $ff 'match' $null) -eq $false) {
            $tier = 'fail'; $tierText = '不通：文件指纹不匹配，且没有可用的设备证据'; $tierColor = $script:C.Err
        } else {
            $tierText = '状态不明：没有任何可用证据（none）'
        }
    }
    $null = $out.Add("proofLevel  ：$lvl   （none < file-fingerprint < openable < handshake）")
    $null = $out.Add('')
    $null = $out.Add('—— 文件指纹 ——')
    $null = $out.Add("  path      ：$([string](Get-LctProp $ff 'path' '—'))  exists=$(Format-LctBoolCn (Get-LctProp $ff 'exists' $null))  resolution=$([string](Get-LctProp $ff 'resolution' '—'))")
    $null = $out.Add("  declared  ：$([string](Get-LctProp $ff 'declared' '—'))")
    $null = $out.Add("  实际       ：$([string](Get-LctProp $ff 'actual' '—'))   match=$(Format-LctBoolCn (Get-LctProp $ff 'match' $null))   skipped=$(Format-LctBoolCn (Get-LctProp $ff 'skipped' $null))")
    $null = $out.Add('')
    $null = $out.Add('—— canary 握手 ——')
    $null = $out.Add("  declared=$(Format-LctBoolCn (Get-LctProp $cv 'declared' $null))  action=$([string](Get-LctProp $cv 'action' '—'))  ioctl=$([string](Get-LctProp $cv 'ioctl' '—'))  minOutBytes=$([string](Get-LctProp $cv 'minOutBytes' '—'))")
    $null = $out.Add("  sent=$(Format-LctBoolCn (Get-LctProp $cv 'sent' $null))  ok=$(Format-LctBoolCn (Get-LctProp $cv 'ok' $null))  message=$([string](Get-LctProp $cv 'message' ''))")
    $null = $out.Add('')
    $null = $out.Add('—— 设备入口 ——')
    $null = $out.Add("  strategy=$([string](Get-LctProp $dev 'strategy' '—'))  verdict=$([string](Get-LctProp $dev 'verdict' '—'))")
    $null = $out.Add("  候选：$((@(Get-LctArray (Get-LctProp $dev 'candidates' @())) | ForEach-Object { [string]$_ }) -join '  ' )")
    $null = $out.Add('')
    $null = $out.Add('—— warnings / errors 原文 ——')
    foreach ($w in @(Get-LctArray $r.warnings)) { $null = $out.Add('  ⚠ ' + [string]$w) }
    foreach ($e in @(Get-LctArray $r.errors)) { $null = $out.Add('  ✖ ' + [string]$e) }
    $null = $out.Add('')
    $null = $out.Add('—— 引擎原始 JSON（driver.ctl.verify）——')
    try { $null = $out.Add((ConvertTo-Json -InputObject $d -Depth 12)) } catch { $null = $out.Add([string]$d) }
    Write-LctProfBox -Box $script:ProfCtlVerifyBox -Lines $out
    if ($null -ne $script:ProfVerifyTierLabel) {
        $script:ProfVerifyTierLabel.Text = "结论：$tierText"
        $script:ProfVerifyTierLabel.ForeColor = $tierColor
    }
}

function Update-LctDriverProfiles {
    param()
    # 页面填充入口（Lead 的 UiPageSmoke 按名调用）：清单 + 详情 + 控制台同步，全部只读。
    try { Update-LctDriverProfileList }
    catch { Add-LctLogLine "  ✖ 驱动 profile 清单渲染异常：$($_.Exception.Message)" $script:C.Err }
    try { Update-LctProfSaveButtons }
    catch { Add-LctLogLine "  ✖ 另存按钮状态刷新异常：$($_.Exception.Message)" $script:C.Err }
    try { if ($null -ne $script:ProfMapBtn) { $script:ProfMapBtn.Enabled = [bool](Test-LctVerbAvailable -Verb 'driver.map') } }
    catch { Add-LctLogLine "  ✖ 对象图映射按钮状态刷新异常：$($_.Exception.Message)" $script:C.Err }
}

function Invoke-LctDriverMapClick {
    param()
    # driver.map：对象图映射（只读）。不打开设备、不发 IOCTL、不写注册表。
    $out = New-Object System.Collections.ArrayList
    $null = $out.Add('driver.map —— 设备对象 ↔ 驱动对象 ↔ 服务名（只读；不打开设备、不发 IOCTL、不写注册表）')
    $svc = ''
    if ($null -ne $script:ProfMapSvcBox) { $svc = ([string]$script:ProfMapSvcBox.Text).Trim() }
    $null = $out.Add('服务过滤：' + $(if ($svc -ne '') { $svc } else { '（留空 = 全量）' }))
    if (-not (Test-LctVerbAvailable -Verb 'driver.map')) {
        $null = $out.Add('')
        $null = $out.Add('引擎未提供 driver.map（依赖未就绪）。检查 core\DriverMap.psm1 是否加载：engine.verbs 的 availability.DriverMap。')
        if ($null -ne $script:ProfMapTierLabel) { $script:ProfMapTierLabel.Text = '映射结果：引擎未提供 driver.map' }
        Write-LctProfBox -Box $script:ProfMapBox -Lines $out
        return
    }
    $bag = @{}
    if ($svc -ne '') { $bag.service = $svc }
    $r = Invoke-LctEngine -Verb 'driver.map' -Args $bag
    if ($null -eq $r) {
        $null = $out.Add('引擎没有返回可解析的 JSON。')
        Write-LctProfBox -Box $script:ProfMapBox -Lines $out
        return
    }
    $d = $r.data
    $null = $out.Add('')
    if ($null -ne $d -and $null -ne $d.stats) {
        $st = $d.stats
        $null = $out.Add(('对象统计：设备对象 {0} / 驱动对象 {1} / 全局链接 {2}（解析成功 {3}，失败 {4}）' -f $st.deviceObjects, $st.driverObjects, $st.linksTotal, $st.linksResolved, $st.linksFailed))
        $null = $out.Add(('映射结果：已映射 {0}（exact {1} / via-link {2}）  未映射 {3}' -f $st.mapped, $st.byConfidence.exact, $st.byConfidence.'via-link-name', $st.unresolved))
    }
    $items = @()
    if ($null -ne $d) { $items = @($d.items) }
    $mappedItems = @($items | Where-Object { [string]$_.confidence -ne 'unresolved' })
    if (@($mappedItems).Count -gt 0) {
        $null = $out.Add('')
        $null = $out.Add('—— 已映射（前 40 条）——')
        $i = 0
        foreach ($it in $mappedItems) {
            $i++
            if ($i -gt 40) { break }
            $verified = $(if ($it.serviceVerified -eq $true) { '服务键已核验' } else { '服务键未核验' })
            $null = $out.Add(('  {0,-42} ⇒ {1,-24} [{2}] svc={3}（{4}）' -f [string]$it.device, [string]$it.driverObject, [string]$it.confidence, [string]$it.serviceName, $verified))
        }
        if (@($mappedItems).Count -gt 40) { $null = $out.Add(('  …另有 {0} 条已映射未显示' -f (@($mappedItems).Count - 40))) }
    }
    $unresItems = @($items | Where-Object { [string]$_.confidence -eq 'unresolved' })
    if (@($unresItems).Count -gt 0) {
        $null = $out.Add('')
        $null = $out.Add(('—— 未映射 {0} 条（用户态没有权威「设备对象→驱动对象」API，按约定不猜；列前 15 条）——' -f @($unresItems).Count))
        $i = 0
        foreach ($it in $unresItems) { $i++; if ($i -gt 15) { break }; $null = $out.Add('  ' + [string]$it.device) }
    }
    $pnp = @()
    if ($null -ne $d) { $pnp = @($d.pnpDevices) }
    if (@($pnp).Count -gt 0) {
        $null = $out.Add('')
        $null = $out.Add(('—— PnP 权威旁证：服务 {0} 下的设备实例 {1} 个（Win32_PnPEntity.Service）——' -f $svc, @($pnp).Count))
        foreach ($p in $pnp) { $null = $out.Add('  ' + [string]$p.deviceId + '  [' + [string]$p.service + ']  ' + [string]$p.name) }
    }
    if (@($r.warnings).Count -gt 0) { $null = $out.Add(''); $null = $out.Add('—— warnings ——'); foreach ($w in @($r.warnings)) { $null = $out.Add('  ' + [string]$w) } }
    if (@($r.errors).Count -gt 0) { $null = $out.Add(''); $null = $out.Add('—— errors ——'); foreach ($e2 in @($r.errors)) { $null = $out.Add('  ' + [string]$e2) } }
    if ($null -ne $d -and @($d.notes).Count -gt 0) { $null = $out.Add(''); $null = $out.Add('—— 边界说明（引擎原文）——'); foreach ($n in @($d.notes)) { $null = $out.Add('  ' + [string]$n) } }
    if ($null -ne $script:ProfMapTierLabel) {
        $mapped = 0; $unres = 0
        if ($null -ne $d -and $null -ne $d.stats) { $mapped = [int]$d.stats.mapped; $unres = [int]$d.stats.unresolved }
        $script:ProfMapTierLabel.Text = ('映射结果：已映射 ' + $mapped + ' / 未映射 ' + $unres + '（只读；unresolved 不猜驱动名）')
    }
    Write-LctProfBox -Box $script:ProfMapBox -Lines $out
    Add-LctLogLine ("  driver.map  service=" + $(if ($svc -ne '') { $svc } else { '(全量)' })) $script:C.Dim
}

function New-LctPageDriverProfiles {
    param($Body)
    $t = New-LctScrollPage -Body $Body -CanvasHeight 1700
    $two = New-LctTable -Parent $t -ColSpec @('100p', '560a') -RowSpec @('100p') -Col 0 -Row 0

    # ---------------- 左列：清单 / 校验 / 静态草案 ----------------
    $left = New-LctTable -Parent $two -ColSpec @('100p') -RowSpec @('330a', '320a', '100p', '340a') -Col 0 -Row 0

    # 卡片 1：profile 清单
    $c1 = New-LctCard -Title 'profile 清单（driver.profile.list；选中一行 → 下方「profile 详情」driver.profile.show）' -Parent $left -Col 0 -Row 0
    $i1 = New-LctTable -Parent $c1 -ColSpec @('100p') -RowSpec @('30a', '100p')
    $i1.Margin = New-Object System.Windows.Forms.Padding(10, 24, 10, 8)
    $h1 = New-LctTable -Parent $i1 -ColSpec @('100p', '150a', '150a') -RowSpec @('30a') -Col 0 -Row 0
    $script:ProfSourceBox = New-LctFormCombo -Parent $h1 -Row 0 -Label '来源' -LabelW 48 -H 30 -Items @('all', 'builtin', 'user', 'plugin')
    $bProfList = New-LctButton -Text '刷新 profile 清单' -X 0 -Y 0 -W 100 -H 26 -Parent $h1 -Accent -Col 1 -Row 0
    $bProfList.Dock = [System.Windows.Forms.DockStyle]::Fill
    $bProfList.Margin = New-Object System.Windows.Forms.Padding(6, 2, 6, 2)
    $script:ProfCountLabel = New-LctLabel -Text 'profile 数：—' -X 2 -Y 4 -W 100 -H 20 -Parent $h1 -Dim -Size 8 -Col 2 -Row 0
    $script:ProfCountLabel.Dock = [System.Windows.Forms.DockStyle]::Fill
    $script:ProfGrid = New-LctGrid -Parent $i1 -Name 'driverprofilelist' -Cols @(
        'id|profile id|fill', 'targetFileName|目标 .sys|fill', 'riskLevel|风险等级|80', 'source|来源|72',
        'actionCount|动作数|58', 'valid|schema|58', 'problem|备注|fill'
    )
    $bProfList.Add_Click({ param($s, $e) Update-LctDriverProfileList })
    $script:ProfListRefreshBtn = $bProfList
    $script:ProfGrid.Add_SelectionChanged({
        param($s, $e)
        if ($script:SuppressProfSel) { return }
        $script:SuppressProfSel = $true
        try { Update-LctDriverProfileDetail } finally { $script:SuppressProfSel = $false }
    })

    # 卡片 2：校验（errors 原文醒目）
    $c2 = New-LctCard -Title '校验（driver.profile.validate：schema + .sys 指纹 + 内存沙盒；不碰内核）' -Parent $left -Col 0 -Row 1
    $i2 = New-LctTable -Parent $c2 -ColSpec @('100p') -RowSpec @('30a', '30a', '22a', '100p')
    $i2.Margin = New-Object System.Windows.Forms.Padding(10, 24, 10, 8)
    $bVal = New-LctButton -Text '校验选中 profile（driver.profile.validate）' -X 0 -Y 0 -W 100 -H 26 -Parent $i2 -Accent -Col 0 -Row 0
    $bVal.Dock = [System.Windows.Forms.DockStyle]::Fill
    $bVal.Margin = New-Object System.Windows.Forms.Padding(0, 2, 0, 2)
    $h2 = New-LctTable -Parent $i2 -ColSpec @('100p', '110a') -RowSpec @('30a') -Col 0 -Row 1
    $script:ProfValidateSysBox = New-LctText -X 0 -Y 0 -W 100 -H 24 -Parent $h2 -Col 0 -Row 0
    $script:ProfValidateSysBox.Dock = [System.Windows.Forms.DockStyle]::Fill
    $script:ProfValidateSysBox.Margin = New-Object System.Windows.Forms.Padding(0, 3, 4, 3)
    $bValSys = New-LctButton -Text '浏览 .sys…' -X 0 -Y 0 -W 100 -H 26 -Parent $h2 -Col 1 -Row 0
    $bValSys.Dock = [System.Windows.Forms.DockStyle]::Fill
    $bValSys.Margin = New-Object System.Windows.Forms.Padding(4, 2, 2, 2)
    $script:ProfValidateTierLabel = New-LctLabel -Text '校验结果：—（指纹不符 ⇒ 拒绝：这一条必须在界面上第一眼看懂）' -X 0 -Y 1 -W 100 -H 20 -Parent $i2 -Bold -Color $script:C.Dim -Size 8 -Col 0 -Row 2
    $script:ProfValidateTierLabel.Dock = [System.Windows.Forms.DockStyle]::Fill
    $script:ProfValidateBox = New-LctText -X 0 -Y 0 -W 100 -H 100 -Parent $i2 -Multiline -ReadOnly -Mono -Dark -Col 0 -Row 3
    $script:ProfValidateBox.Dock = [System.Windows.Forms.DockStyle]::Fill
    $script:ProfValidateBox.Text = '(点上面按钮调 driver.profile.validate。第二个框可留空：填了 .sys 就做「profile 声明的 sha256 ↔ 实际文件」指纹比对。指纹不符 ⇒ 拒绝执行，errors 原文会原样贴在这里。)'

    # 卡片 3：静态草案 + 另存
    $c3 = New-LctCard -Title '静态草案（driver.profile.draft，只读）→ 另存到 var\driver-profiles（预览/应用两段式）' -Parent $left -Col 0 -Row 2
    $i3 = New-LctTable -Parent $c3 -ColSpec @('100p') -RowSpec @('30a', '30a', '24a', '30a', '100p')
    $i3.Margin = New-Object System.Windows.Forms.Padding(10, 24, 10, 8)
    $h3 = New-LctTable -Parent $i3 -ColSpec @('100p', '110a') -RowSpec @('30a') -Col 0 -Row 0
    $script:ProfDraftPathBox = New-LctText -X 0 -Y 0 -W 100 -H 24 -Parent $h3 -Col 0 -Row 0
    $script:ProfDraftPathBox.Dock = [System.Windows.Forms.DockStyle]::Fill
    $script:ProfDraftPathBox.Margin = New-Object System.Windows.Forms.Padding(0, 3, 4, 3)
    $bDraftBrowse = New-LctButton -Text '浏览 .sys…' -X 0 -Y 0 -W 100 -H 26 -Parent $h3 -Col 1 -Row 0
    $bDraftBrowse.Dock = [System.Windows.Forms.DockStyle]::Fill
    $bDraftBrowse.Margin = New-Object System.Windows.Forms.Padding(4, 2, 2, 2)
    $h3b = New-LctTable -Parent $i3 -ColSpec @('100p', '100p', '100p') -RowSpec @('30a') -Col 0 -Row 1
    $bDraft = New-LctButton -Text '① 静态起草（只读）' -X 0 -Y 0 -W 100 -H 26 -Parent $h3b -Accent -Col 0 -Row 0
    $bDraft.Dock = [System.Windows.Forms.DockStyle]::Fill
    $bDraft.Margin = New-Object System.Windows.Forms.Padding(0, 2, 4, 2)
    $bDraftSavePrev = New-LctButton -Text '① 预览：另存' -X 0 -Y 0 -W 100 -H 26 -Parent $h3b -Col 1 -Row 0
    $bDraftSavePrev.Dock = [System.Windows.Forms.DockStyle]::Fill
    $bDraftSavePrev.Margin = New-Object System.Windows.Forms.Padding(4, 2, 4, 2)
    $bDraftSaveApply = New-LctButton -Text '② 应用：另存' -X 0 -Y 0 -W 100 -H 26 -Parent $h3b -Warn -Col 2 -Row 0
    $bDraftSaveApply.Dock = [System.Windows.Forms.DockStyle]::Fill
    $bDraftSaveApply.Margin = New-Object System.Windows.Forms.Padding(4, 2, 0, 2)
    $script:ProfDraftTierLabel = New-LctLabel -Text '草案状态：—（草案不可直接执行；必须人工审定后另存）' -X 0 -Y 1 -W 100 -H 22 -Parent $i3 -Bold -Color $script:C.Warn -Size 8 -Col 0 -Row 2
    $script:ProfDraftTierLabel.Dock = [System.Windows.Forms.DockStyle]::Fill
    $script:ProfSaveNoteLabel = New-LctLabel -Text '另存说明：—' -X 0 -Y 1 -W 100 -H 20 -Parent $i3 -Dim -Size 8 -Col 0 -Row 3
    $script:ProfSaveNoteLabel.Dock = [System.Windows.Forms.DockStyle]::Fill
    $script:ProfDraftBox = New-LctText -X 0 -Y 0 -W 100 -H 100 -Parent $i3 -Multiline -ReadOnly -Mono -Dark -Col 0 -Row 4
    $script:ProfDraftBox.Dock = [System.Windows.Forms.DockStyle]::Fill
    $script:ProfDraftBox.Text = '(选一个 .sys 后点「① 静态起草」：显示 confidence 与 needsReview=true，并注明「这是草案，不可直接执行」。另存走「① 预览 → ② 应用 + 确认」两段式，只写 var\driver-profiles；若引擎还没提供 driver.profile.save，按钮会保持禁用并明确说明，绝不假装保存成功。)'
    $script:ProfSavePreviewBtn = $bDraftSavePrev
    $script:ProfSaveApplyBtn = $bDraftSaveApply
    $script:ProfValidateBtn = $bVal
    $script:ProfValidateSysBrowseBtn = $bValSys
    $script:ProfDraftBtn = $bDraft
    $script:ProfDraftBrowseBtn = $bDraftBrowse

    # 卡片 4：对象图映射（driver.map）—— 解决「服务名 ↔ 设备对象」对不上的问题
    $c3b = New-LctCard -Title '对象图映射（driver.map：\Device 设备对象 ↔ \Driver 驱动对象 ↔ 服务名；只读，附 PnP 权威旁证）' -Parent $left -Col 0 -Row 3
    $i3b = New-LctTable -Parent $c3b -ColSpec @('100p') -RowSpec @('30a', '22a', '100p')
    $i3b.Margin = New-Object System.Windows.Forms.Padding(10, 24, 10, 8)
    $h3c = New-LctTable -Parent $i3b -ColSpec @('100p', '190a') -RowSpec @('30a') -Col 0 -Row 0
    $script:ProfMapSvcBox = New-LctText -X 0 -Y 0 -W 100 -H 24 -Parent $h3c -Col 0 -Row 0
    $script:ProfMapSvcBox.Dock = [System.Windows.Forms.DockStyle]::Fill
    $script:ProfMapSvcBox.Margin = New-Object System.Windows.Forms.Padding(0, 3, 4, 3)
    $bMap = New-LctButton -Text '对象图映射（留空=全量）' -X 0 -Y 0 -W 100 -H 26 -Parent $h3c -Accent -Col 1 -Row 0
    $bMap.Dock = [System.Windows.Forms.DockStyle]::Fill
    $bMap.Margin = New-Object System.Windows.Forms.Padding(4, 2, 0, 2)
    $script:ProfMapTierLabel = New-LctLabel -Text '映射结果：—（只读；未映射的一律标 unresolved，不猜驱动名）' -X 0 -Y 1 -W 100 -H 20 -Parent $i3b -Dim -Size 8 -Col 0 -Row 1
    $script:ProfMapTierLabel.Dock = [System.Windows.Forms.DockStyle]::Fill
    $script:ProfMapBox = New-LctText -X 0 -Y 0 -W 100 -H 100 -Parent $i3b -Multiline -ReadOnly -Mono -Dark -Col 0 -Row 2
    $script:ProfMapBox.Dock = [System.Windows.Forms.DockStyle]::Fill
    $script:ProfMapBox.Text = ("(左边留空 = 全量；填服务名（如 disk / tcpip / KSecDD）= 只看该服务。`r`n" + "本查询全部只读：枚举 \Device / \Driver / \GLOBAL?? 与 Win32_PnPEntity，不打开设备、不发 IOCTL、不写注册表。`r`n" + "注意：\Device\HarddiskVolume3 这类驱动自造名字在用户态没有权威映射，会如实列为 unresolved —— 这是边界，不是失败。)")
    $bMap.Add_Click({ param($s, $e) Invoke-LctDriverMapClick })
    $script:ProfMapBtn = $bMap

    # ---------------- 右列：原语控制台 / canary / ABI 引导 / 详情 ----------------
    $right = New-LctTable -Parent $two -ColSpec @('100p') -RowSpec @('560a', '240a', '210a', '230a', '100p', '44a') -Col 1 -Row 0

    $c4 = New-LctCard -Title '★ 通用原语控制台（driver.ctl.send：① 预览不发送 → ② 应用 + 二次确认才发 IOCTL）' -Parent $right -Col 0 -Row 0
    $i4 = New-LctTable -Parent $c4 -ColSpec @('100p') -RowSpec @('30a', '20a', '110a', '30a', '34a', '100p', '100p')
    $i4.Margin = New-Object System.Windows.Forms.Padding(10, 24, 10, 8)
    $h4 = New-LctTable -Parent $i4 -ColSpec @('100p', '100p') -RowSpec @('30a') -Col 0 -Row 0
    $script:ProfCtlProfileBox = New-LctProfComboCell -CellParent $h4 -CellCol 0 -CellRow 0 -CellLabel 'profile' -CellLabelW 56
    $script:ProfCtlActionBox = New-LctProfComboCell -CellParent $h4 -CellCol 1 -CellRow 0 -CellLabel 'action' -CellLabelW 50
    $script:ProfActionHintLabel = New-LctLabel -Text '（先选 profile 与 action：这里显示该动作声明的 in/out 字段）' -X 0 -Y 1 -W 100 -H 18 -Parent $i4 -Dim -Size 8 -Col 0 -Row 1
    $script:ProfActionHintLabel.Dock = [System.Windows.Forms.DockStyle]::Fill
    $script:ProfCtlPayloadBox = New-LctText -Text '{}' -X 0 -Y 0 -W 100 -H 100 -Parent $i4 -Multiline -Mono -Dark -Col 0 -Row 2
    $script:ProfCtlPayloadBox.Dock = [System.Windows.Forms.DockStyle]::Fill
    $script:ProfCtlPayloadBox.Margin = New-Object System.Windows.Forms.Padding(0, 2, 0, 2)
    $h4c = New-LctTable -Parent $i4 -ColSpec @('100p', '100p', '100p') -RowSpec @('30a') -Col 0 -Row 3
    $bCtlPrev = New-LctButton -Text '① 预览：发送' -X 0 -Y 0 -W 100 -H 28 -Parent $h4c -Accent -Col 0 -Row 0
    $bCtlPrev.Dock = [System.Windows.Forms.DockStyle]::Fill
    $bCtlPrev.Margin = New-Object System.Windows.Forms.Padding(0, 1, 4, 1)
    $bCtlApply = New-LctButton -Text '② 应用：发送' -X 0 -Y 0 -W 100 -H 28 -Parent $h4c -Warn -Col 1 -Row 0
    $bCtlApply.Dock = [System.Windows.Forms.DockStyle]::Fill
    $bCtlApply.Margin = New-Object System.Windows.Forms.Padding(4, 1, 4, 1)
    $bCtlSkeleton = New-LctButton -Text '按 profile 生成 payload 骨架' -X 0 -Y 0 -W 100 -H 28 -Parent $h4c -Col 2 -Row 0
    $bCtlSkeleton.Dock = [System.Windows.Forms.DockStyle]::Fill
    $bCtlSkeleton.Margin = New-Object System.Windows.Forms.Padding(4, 1, 0, 1)
    $script:ProfCtlPreviewBtn = $bCtlPrev
    $script:ProfCtlApplyBtn = $bCtlApply
    $script:ProfCtlSkeletonBtn = $bCtlSkeleton
    $h4d = New-LctTable -Parent $i4 -ColSpec @('210a', '100p') -RowSpec @('34a') -Col 0 -Row 4
    $script:ProfBsodAckBox = New-Object System.Windows.Forms.CheckBox
    $script:ProfBsodAckBox.Text = '我知道可能蓝屏'
    $script:ProfBsodAckBox.ForeColor = $script:C.Err
    $script:ProfBsodAckBox.BackColor = [System.Drawing.Color]::Transparent
    $script:ProfBsodAckBox.Font = New-LctFont -Size 9 -Bold
    $script:ProfBsodAckBox.Dock = [System.Windows.Forms.DockStyle]::Fill
    $null = $h4d.Controls.Add($script:ProfBsodAckBox, 0, 0)
    $script:ProfCtlGateLabel = New-LctLabel -Text '待应用：无（先点「① 预览：发送」）' -X 0 -Y 4 -W 100 -H 20 -Parent $h4d -Dim -Size 8 -Col 1 -Row 0
    $script:ProfCtlGateLabel.Dock = [System.Windows.Forms.DockStyle]::Fill
    $script:ProfBsodNoteLabel = New-LctLabel -Text '（当前未标 bsod）' -X 0 -Y 1 -W 100 -H 30 -Parent $i4 -Color $script:C.Dim -Size 8 -Col 0 -Row 5
    $script:ProfBsodNoteLabel.Dock = [System.Windows.Forms.DockStyle]::Fill
    $script:ProfCtlSendBox = New-LctText -X 0 -Y 0 -W 100 -H 100 -Parent $i4 -Multiline -ReadOnly -Mono -Dark -Col 0 -Row 6
    $script:ProfCtlSendBox.Dock = [System.Windows.Forms.DockStyle]::Fill
    $script:ProfCtlSendBox.Text = '(点「① 预览：发送」后，这里显示「将发送」：IOCTL 与输入缓冲区的十六进制 + 打包字段。预览阶段引擎不打开设备、不发任何 IOCTL。)'
    $c4b = New-LctCard -Title '返回结果（data.result / data.rawOutHex；写类动作还有写前原值与还原脚本）' -Parent $right -Col 0 -Row 1
    $i4b = New-LctTable -Parent $c4b -ColSpec @('100p') -RowSpec @('100p')
    $i4b.Margin = New-Object System.Windows.Forms.Padding(10, 24, 10, 8)
    $script:ProfCtlResultBox = New-LctText -X 0 -Y 0 -W 100 -H 100 -Parent $i4b -Multiline -ReadOnly -Mono -Dark -Col 0 -Row 0
    $script:ProfCtlResultBox.Dock = [System.Windows.Forms.DockStyle]::Fill
    $script:ProfCtlResultBox.Text = '(「② 应用：发送」+ 确认后，这里显示 data.result（按 out 布局解出的字段）、data.rawOutHex，写类动作还会显示写前原值与还原脚本路径。)'

    $c5 = New-LctCard -Title 'canary 握手（driver.ctl.verify：证明「这个设备确实是这个驱动且能通」）' -Parent $right -Col 0 -Row 2
    $i5 = New-LctTable -Parent $c5 -ColSpec @('100p') -RowSpec @('30a', '22a', '100p')
    $i5.Margin = New-Object System.Windows.Forms.Padding(10, 24, 10, 8)
    $bVerify = New-LctButton -Text '握手（driver.ctl.verify）' -X 0 -Y 0 -W 100 -H 26 -Parent $i5 -Accent -Col 0 -Row 0
    $bVerify.Dock = [System.Windows.Forms.DockStyle]::Fill
    $bVerify.Margin = New-Object System.Windows.Forms.Padding(0, 2, 0, 2)
    $script:ProfVerifyTierLabel = New-LctLabel -Text '结论：—（三档：确实是这个驱动且能通 / 不通 / 状态不明）' -X 0 -Y 1 -W 100 -H 20 -Parent $i5 -Bold -Color $script:C.Dim -Size 8 -Col 0 -Row 1
    $script:ProfVerifyTierLabel.Dock = [System.Windows.Forms.DockStyle]::Fill
    $script:ProfCtlVerifyBox = New-LctText -X 0 -Y 0 -W 100 -H 100 -Parent $i5 -Multiline -ReadOnly -Mono -Dark -Col 0 -Row 2
    $script:ProfCtlVerifyBox.Dock = [System.Windows.Forms.DockStyle]::Fill
    $script:ProfCtlVerifyBox.Text = '(proofLevel：none < file-fingerprint < openable < handshake。常态是文件指纹/可开性档 —— 该 verb 默认不发 IOCTL。)'
    $script:ProfVerifyBtn = $bVerify

    $c6 = New-LctCard -Title '自研驱动 ABI 引导（按 ABI 实现 ⇒ 无需 profile 即可被识别）' -Parent $right -Col 0 -Row 3
    $i6 = New-LctTable -Parent $c6 -ColSpec @('100p') -RowSpec @('100p')
    $i6.Margin = New-Object System.Windows.Forms.Padding(10, 24, 10, 8)
    $abiBox = New-LctText -X 0 -Y 0 -W 100 -H 100 -Parent $i6 -Multiline -ReadOnly -Mono -Dark -Col 0 -Row 0
    $abiBox.Dock = [System.Windows.Forms.DockStyle]::Fill
    $abiBox.BackColor = $script:C.Panel
    $script:ProfAbiBox = $abiBox
    $abiBox.Text = @'
自研驱动 ABI（v1）—— 照着实现，加载后【无需任何 profile】就能被本工具识别与调用

为什么有这条线：驱动控制接口不自描述（.sys 里没有 IOCTL 元数据、设备名无标准），
所以「通用」只有两条路 —— ① 自研驱动遵守固定 ABI（本区）；② 为每个第三方/漏洞驱动写一份
profile（左边那套）。通用的是这两套契约，不是驱动本身。

固定 ABI（逐字照做）：
  设备名   \Device\LctCtl        符号链接  \??\LctCtl（用户态 \\.\LctCtl）
  接口 GUID {6C7A47B0-6D2A-4C4E-9E1F-2A5B7C8D9E01}  ← 注册它，工具按 GUID 找你，不必猜名字
  IOCTL（全部 METHOD_BUFFERED + FILE_ANY_ACCESS + DeviceType 0x22）
    LCT_PING  = 0x00222000（必须实现：回 Abi=1 / Version / Caps / MaxTransfer）
    LCT_CAPS  = 0x00222004     LCT_KREAD = 0x00222008     LCT_KWRITE = 0x0022200C
  能力位 Caps：0x1 CAP_KREAD · 0x4 CAP_KWRITE（0x2 / 0x10 保留）
  结构：8 字节对齐、小端；LCT_KWRITE 必须回填写前原值（工具「无原值不写」）
  安全：设备 ACL 只放行已提权打开者；Len <= MaxTransfer；回准确 NTSTATUS；不做隐藏/对抗安全产品

工具侧接入步骤（详见 docs\DRIVER-ABI.md §7）：
  ① driver.load -Apply 载入你的 .sys（能不能加载由系统判定，工具照抄回显）
  ② driver.devices -Name <服务名>      定位入口（接口 GUID → 符号链接候选 → CreateFile canary）
  ③ driver.profile.draft -Path <.sys>  对本 ABI 驱动可直接产出可用 profile
  ④ driver.ctl.verify -Profile <id>    LCT_PING 握手：校验 Abi=1 / Version / Caps / MaxTransfer
  ⑤ driver.ctl.send -Profile <id> -Action kread|kwrite -Payload {...}（默认只预览，-Apply 才真发）

文档路径（相对工具根）：docs\DRIVER-ABI.md  ← 规格全文（含 C 参考实现骨架、陷阱与安全要求）
能力层说明：exec.cmd / kill.protected 这类能力建立在少量内核原语（kread/kwrite）之上，由通用
用户态 stager 完成（内核改 token / 解 PPL → 用户态起进程）—— 换驱动不用改一行命令执行代码。
'@

    $c7 = New-LctCard -Title 'profile 详情（Update-LctDriverProfileDetail → driver.profile.show 可读化）' -Parent $right -Col 0 -Row 4
    $script:ProfDetailBox = New-LctText -X 0 -Y 0 -W 100 -H 100 -Parent $c7 -Multiline -ReadOnly -Mono -Dark
    $script:ProfDetailBox.Dock = [System.Windows.Forms.DockStyle]::Fill
    $script:ProfDetailBox.Margin = New-Object System.Windows.Forms.Padding(10, 22, 10, 10)
    $script:ProfDetailBox.Text = '(选中清单里的一行后，这里显示 driver.profile.show 的可读化详情：id / 目标 .sys 与 sha256 / 定位策略与候选 / handshake / 每个动作的 IOCTL 与 in-out 字段 / layout / risk / requires / schemaErrors / 原始 JSON。)'

    $null = New-LctPendingStrip -Parent $right -Col 0 -Row 5 -PageKey 'driverprofiles'

    # 事件接线（先建控件、后接线；避免构造期触发 SelectedIndexChanged）
    $script:ProfSourceBox.Add_SelectedIndexChanged({ param($s, $e) Update-LctDriverProfileList })
    $script:ProfCtlProfileBox.Add_SelectedIndexChanged({ param($s, $e) Update-LctProfCtlActionList })
    $script:ProfCtlActionBox.Add_SelectedIndexChanged({ param($s, $e) Update-LctProfActionHint; Update-LctProfBsodGate })
    $script:ProfBsodAckBox.Add_CheckedChanged({ param($s, $e) Update-LctProfBsodGate })
    $bVal.Add_Click({ param($s, $e) Invoke-LctProfValidate })
    $bValSys.Add_Click({
        param($s, $e)
        $dlg = New-Object System.Windows.Forms.OpenFileDialog
        $dlg.Title = '选择用于指纹比对的 .sys（profile 声明的 sha256 ↔ 实际文件）'
        $dlg.Filter = '驱动镜像 (*.sys)|*.sys|所有文件 (*.*)|*.*'
        $dlg.CheckFileExists = $true
        if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { $script:ProfValidateSysBox.Text = $dlg.FileName }
    })
    $bDraftBrowse.Add_Click({
        param($s, $e)
        $dlg = New-Object System.Windows.Forms.OpenFileDialog
        $dlg.Title = '选择要静态起草 profile 的 .sys（只读解析，不加载）'
        $dlg.Filter = '驱动镜像 (*.sys)|*.sys|所有文件 (*.*)|*.*'
        $dlg.CheckFileExists = $true
        if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { $script:ProfDraftPathBox.Text = $dlg.FileName }
    })
    $bDraft.Add_Click({ param($s, $e) Invoke-LctProfDraft })
    $bDraftSavePrev.Add_Click({ param($s, $e) Invoke-LctProfSavePreview })
    $bDraftSaveApply.Add_Click({ param($s, $e) Invoke-LctProfSaveApply })
    $bCtlPrev.Add_Click({ param($s, $e) Invoke-LctProfCtlPreview })
    $bCtlApply.Add_Click({ param($s, $e) Invoke-LctProfCtlApply })
    $bCtlSkeleton.Add_Click({
        param($s, $e)
        $bag = Get-LctProfCtlArgBag
        if (-not $bag.profile -or -not $bag.action) { return }
        $sd = Get-LctProfShowData -Id ([string]$bag.profile)
        $script:ProfCtlPayloadBox.Text = Get-LctProfPayloadSkeleton -ShowData $sd -Action ([string]$bag.action)
        Update-LctProfActionHint
    })
    $bVerify.Add_Click({ param($s, $e) Invoke-LctProfVerify })

    Update-LctProfSaveButtons
    Update-LctProfBsodGate

    # 兼容别名：Lead 的 UiPageSmoke / 验收脚本按名字取变量（多个别名指向同一控件）
    $script:ProfileGrid = $script:ProfGrid
    $script:DriverProfileGrid = $script:ProfGrid
    $script:ProfileDetailBox = $script:ProfDetailBox
    $script:DriverProfileDetailBox = $script:ProfDetailBox
    $script:ProfileValidateBox = $script:ProfValidateBox
    $script:ProfileDraftBox = $script:ProfDraftBox
    $script:ProfileCtlSendBox = $script:ProfCtlSendBox
    $script:ProfileCtlResultBox = $script:ProfCtlResultBox
    $script:ProfileCtlVerifyBox = $script:ProfCtlVerifyBox
    $script:ProfileSourceBox = $script:ProfSourceBox
    return $two
}

# ===========================================================================
# 十三、主窗体
# ===========================================================================

function New-LctMainForm {
    $form = New-Object System.Windows.Forms.Form
    $form.Text = "LocalConfigTool — 本地安全配置与提权工具（前端 v$($script:UiVersion)）"
    $form.BackColor = $script:C.Bg
    $form.ForeColor = $script:C.Text
    $form.Font = New-LctFont -Size 9
    $form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
    $form.MinimumSize = New-Object System.Drawing.Size(1124, 760)
    $form.ClientSize = New-Object System.Drawing.Size(1240, 800)
    $form.KeyPreview = $true

    $root = New-LctTable -Parent $form -ColSpec @('100p') -RowSpec @('58a', '100p', '200a', '30a')

    # 头部
    $hdr = New-Object System.Windows.Forms.Panel
    $hdr.Dock = [System.Windows.Forms.DockStyle]::Fill
    $hdr.BackColor = $script:C.Panel
    $null = $root.Controls.Add($hdr, 0, 0)
    $null = New-LctLabel -Text 'LocalConfigTool' -X 16 -Y 8 -W 400 -H 26 -Parent $hdr -Bold -Size 13 -Color $script:C.Accent
    $null = New-LctLabel -Text '本地安全配置与提权工具 · 深色前端 · 所有数据经引擎 CLI 获取 · 写操作默认只预览，二次确认才落盘' -X 18 -Y 34 -W 1100 -H 20 -Parent $hdr -Dim

    # 主体：左导航 + 右内容
    $body = New-LctTable -Parent $root -ColSpec @('190a', '100p') -RowSpec @('100p')
    $null = $root.Controls.Add($body, 0, 1)

    $nav = New-Object System.Windows.Forms.FlowLayoutPanel
    $nav.Dock = [System.Windows.Forms.DockStyle]::Fill
    $nav.FlowDirection = [System.Windows.Forms.FlowDirection]::TopDown
    $nav.WrapContents = $false
    $nav.AutoScroll = $true
    $nav.BackColor = $script:C.Panel
    $nav.Padding = New-Object System.Windows.Forms.Padding(8, 10, 8, 8)
    $null = $body.Controls.Add($nav, 0, 0)

    $content = New-Object System.Windows.Forms.Panel
    $content.Dock = [System.Windows.Forms.DockStyle]::Fill
    $content.BackColor = $script:C.Bg
    $null = $body.Controls.Add($content, 1, 0)

    $navItems = [ordered]@{
        'overview'  = '概览'
        'account'   = '账户与登录'
        'registry'  = '注册表'
        'plugins'   = '提权工具（插件）'
        'processes' = '进程监控'
        'wdac'      = 'WDAC 黑名单'
        'drivers'   = '驱动加载'
        'driverprofiles' = '驱动 Profile'
        'backup'    = '备份与回滚'
        'about'     = '关于 / 说明'
    }
    foreach ($k in @($navItems.Keys)) {
        $b = New-LctButton -Text $navItems[$k] -X 0 -Y 0 -W 168 -H 40 -Parent $nav
        $b.Margin = New-Object System.Windows.Forms.Padding(4)
        $b.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
        $b.Padding = New-Object System.Windows.Forms.Padding(8, 0, 0, 0)
        $b.Tag = $k
        $b.Add_Click({ param($s, $e) Switch-LctPage -Key ([string]$s.Tag) })
        $script:NavButtons[$k] = $b
    }

    # 十个页面（原有 6 页 + 新增「进程监控」「WDAC 黑名单」「驱动加载」「驱动 Profile」）
    $b1 = New-LctPage -Key 'overview' -Title '概览' -Subtitle '引擎能力清单、当前用户与是否提权、工具版本、var\logs 最近日志（全部经 engine.verbs / account.status 获取）' -Parent $content
    $null = New-LctPageOverview -Body $b1
    $b2 = New-LctPage -Key 'account' -Title '账户与登录' -Subtitle 'account.status 展示 users / groups / uac / autologon；三个操作（内置 Administrator、UAC、自动登录）均「先预览、再应用」' -Parent $content
    $null = New-LctPageAccount -Body $b2
    $b3 = New-LctPage -Key 'registry' -Title '注册表' -Subtitle '任意 path/name 的读取与写入（写入需选类型）；下面是预设包 presets.list/show 的项目列表，每项一行「预览」「应用」' -Parent $content
    $null = New-LctPageRegistry -Body $b3
    $b4 = New-LctPage -Key 'plugins' -Title '提权工具（插件）' -Subtitle 'plugins.list → plugins.show 详情 → 按 params 动态生成参数控件（secret 为密码框）→ 预览命令 → 执行前二次确认' -Parent $content
    $null = New-LctPagePlugins -Body $b4
    $b5 = New-LctPage -Key 'processes' -Title '进程监控' -Subtitle 'process.list 快照（引擎默认隐藏会话 0）→ process.detail 详情（能否 PROCESS_TERMINATE 的实测结论）→ 终止先预览再二次确认；另有会话内看门狗与 IFEO 加载阻断（均可秒级回滚）' -Parent $content
    $null = New-LctPageProcesses -Body $b5
    $b6 = New-LctPage -Key 'wdac' -Title 'WDAC 黑名单' -Subtitle 'wdac.status → 黑名单规则（rules.add/remove，先预览）→ 生成策略（审计优先，产物落 var\wdac\staging）→ 安全校验（wdac.policy.validate）→ 手输确认文本后部署（★需重启生效★）→ 重启后校验' -Parent $content
    $null = New-LctPageWdac -Body $b6
    $b9 = New-LctPage -Key 'drivers' -Title '驱动加载' -Subtitle 'driver.status 前提（Secure Boot / test-signing / DSE / 驱动数）→ 指定 .sys 后「① 预览：加载 → ② 应用：加载」（系统返回 verdict.exitCode/message 原样照抄）→ 清单 driver.list + 详情 driver.info → 停止 / 卸载（只删服务项，不删 .sys，生成 revert.cmd）→ 加载后复核 driver.verify（三档着色 + 系统事件 7000/7026/219 原文）→ test-signing 开关（★需重启生效★，Secure Boot=True 时禁用开启）。签名只做信息展示，能否加载交给系统判定' -Parent $content
    $null = New-LctPageDrivers -Body $b9
    $b10 = New-LctPage -Key 'driverprofiles' -Title '驱动 Profile' -Subtitle '驱动通用化（契约 §13）：第三方/漏洞驱动走「每驱一份 profile」这条线 —— 清单（driver.profile.list，可切 builtin/user/plugin/all）→ 详情（driver.profile.show）→ 校验（driver.profile.validate：schema + .sys 指纹 + 内存沙盒；target.sha256 与文件不符 ⇒ 拒绝）→ 静态草案（driver.profile.draft，草案不可直接执行）→ 另存到 var\driver-profiles（预览/应用两段式）→ 通用原语控制台（driver.ctl.send：① 预览只显示将发送的 IOCTL 与缓冲区十六进制，② 应用 + 二次确认才真发；risk.level=bsod 的动作默认禁用发送，需勾选「我知道可能蓝屏」）→ canary 握手（driver.ctl.verify 三档）→ 自研驱动 ABI 引导（按 docs\DRIVER-ABI.md 实现 ⇒ 无需 profile 即被识别）' -Parent $content
    $null = New-LctPageDriverProfiles -Body $b10
    $b7 = New-LctPage -Key 'backup' -Title '备份与回滚' -Subtitle 'backup.list 列表 → backup.show 详情 → 「预览还原」确认无误后再「执行还原」' -Parent $content
    $null = New-LctPageBackup -Body $b7
    $b8 = New-LctPage -Key 'about' -Title '关于 / 说明' -Subtitle '工具用途、安全说明（默认预览 / 先备份后写 / 删除走回收站）、插件风险提示、进程与 WDAC 的高风险后果说明' -Parent $content
    $null = New-LctPageAbout -Body $b8

    # 日志面板
    $logHost = New-Object System.Windows.Forms.Panel
    $logHost.Dock = [System.Windows.Forms.DockStyle]::Fill
    $logHost.BackColor = $script:C.Panel
    $null = $root.Controls.Add($logHost, 0, 2)
    $logRoot = New-LctTable -Parent $logHost -ColSpec @('100p') -RowSpec @('32a', '100p')
    $logBar = New-LctTable -Parent $logRoot -ColSpec @('100p', '150a') -RowSpec @('32a') -Col 0 -Row 0
    $logBar.Margin = New-Object System.Windows.Forms.Padding(14, 4, 14, 0)
    $null = New-LctLabel -Text '引擎结果 / 日志（changes / warnings / errors —— 写操作会标注是否已落盘）' -X 0 -Y 6 -W 100 -H 22 -Parent $logBar -Bold -Color $script:C.Accent
    $bc = New-LctButton -Text '清空日志面板' -X 0 -Y 2 -W 130 -H 26 -Parent $logBar
    $bc.Dock = [System.Windows.Forms.DockStyle]::Fill
    $bc.Margin = New-Object System.Windows.Forms.Padding(10, 2, 0, 2)
    $bc.Add_Click({
        param($s, $e)
        if ($null -ne $script:LogBox) { $script:LogBox.Clear() }
    })
    $script:LogBox = New-Object System.Windows.Forms.RichTextBox
    $script:LogBox.BackColor = $script:C.Black
    $script:LogBox.ForeColor = $script:C.Text
    $script:LogBox.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
    $script:LogBox.ReadOnly = $true
    $script:LogBox.WordWrap = $false
    $script:LogBox.ScrollBars = [System.Windows.Forms.RichTextBoxScrollBars]::Both
    $script:LogBox.Font = New-LctFont -Size 9 -Name 'Consolas'
    $script:LogBox.Dock = [System.Windows.Forms.DockStyle]::Fill
    $script:LogBox.Margin = New-Object System.Windows.Forms.Padding(14, 4, 14, 10)
    $null = $logRoot.Controls.Add($script:LogBox, 0, 1)

    # 状态栏
    $st = New-Object System.Windows.Forms.Panel
    $st.Dock = [System.Windows.Forms.DockStyle]::Fill
    $st.BackColor = $script:C.Panel
    $null = $root.Controls.Add($st, 0, 3)
    $stT = New-LctTable -Parent $st -ColSpec @('100p', '330a') -RowSpec @('100p') -Margin '14,0,14,0'
    $script:StatusLeft = New-LctLabel -Text '  当前用户：—' -X 0 -Y 5 -W 100 -H 22 -Parent $stT -Dim -Col 0 -Row 0
    $script:StatusRight = New-LctLabel -Text "前端 v$($script:UiVersion)   |   ui\ConfigUI.ps1" -X 0 -Y 5 -W 100 -H 22 -Parent $stT -Dim -Col 1 -Row 0

    $form.Add_Shown({
        param($s, $e)
        Switch-LctPage -Key 'overview'
    })
    $form.Add_FormClosed({
        param($s, $e)
        Remove-LctAllTempFiles
    })

    $script:MainForm = $form
    return $form
}

function Show-LctMainForm {
    $form = New-LctMainForm
    Switch-LctPage -Key 'overview'
    $null = $form.ShowDialog()
}

function Get-LctControlCount {
    param($Control)
    $n = 1
    foreach ($c in $Control.Controls) { $n += (Get-LctControlCount -Control $c) }
    return $n
}

function Invoke-LctSelfCheck {
    Write-Host "[SelfCheck] 引擎脚本：$($script:EngineScript)"
    if (-not $script:EngineScript -or -not (Test-Path -LiteralPath $script:EngineScript)) {
        Write-Host '[SelfCheck] 引擎脚本不存在 —— 前端自检未通过（等 Lead 提供 core\Engine.ps1）'
        Write-Host 'FAIL'
        return 2
    }
    $form = New-LctMainForm
    $cnt = Get-LctControlCount -Control $form
    Write-Host "[SelfCheck] 已构建主窗体与全部控件（$($script:Pages.Keys.Count) 个页面）：控件数 $cnt"
    Switch-LctPage -Key 'overview'

    $verbs = $script:LastVerbsResult
    if ($null -eq $verbs -or -not $verbs.ok) {
        $msg = '未调用'
        if ($null -ne $verbs) { $msg = (@(Get-LctArray $verbs.errors) -join ' / ') }
        Write-Host "[SelfCheck] engine.verbs 调用失败：$msg"
        Write-Host 'FAIL'
        return 2
    }
    $nv = @($script:VerbTable).Count
    Write-Host "[SelfCheck] engine.verbs 调用成功：可用能力 $nv 项，进程退出码 $($verbs.exitCode)"
    Write-Host "[SelfCheck] 参数传递：临时文件 + 引擎 -ArgsFile，命令行仅有 base64 wrapper（无明文 JSON）"
    Write-Host "[SelfCheck] 预览标注文案：$($script:PREVIEW_BANNER)"
    Write-Host 'OK'
    return 0
}

# ===========================================================================
# 十四、入口分派（Harness 从这里截断）
# >>>HARNESS-CUT<<<
# ===========================================================================

$script:EngineScript = Find-LctEngineScript -Override $EnginePath
if ($script:EngineScript) { $script:ToolRoot = Split-Path -Parent (Split-Path -Parent $script:EngineScript) }
$script:PsExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
if (-not (Test-Path -LiteralPath $script:PsExe)) { $script:PsExe = 'powershell.exe' }

if ($SelfCheck) {
    $code = Invoke-LctSelfCheck
    Remove-LctAllTempFiles
    exit $code
} else {
    Show-LctMainForm
    Remove-LctAllTempFiles
    exit 0
}