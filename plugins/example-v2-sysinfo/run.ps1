# LocalConfigTool 示例插件（v2 清单参考实现）：系统状态只读快照
#
# 本文件是**只读**的：不写注册表、不改任何系统设置、不启停任何服务。
# 它存在的意义是给"自定义插件"当骨架：把这个目录复制成 plugins\<你的id>\，
# 改 plugin.json 的 id/name/description 与 capabilities，再改这个脚本即可。
#
# 为什么故意不写 param() 块：引擎可能以命名参数、位置参数或带额外开关的形式调用入口，
# 没有 param() 的脚本会把它们全收进自动变量 $args 并忽略 —— 对参考实现来说最不容易出错。
# （注意：$args 是自动变量，**不能**把它用作函数形参名，那是本项目踩过的坑，契约 §10.8。）

$ErrorActionPreference = 'Continue'

function Get-Safe {
    # 任何一项读不到都不许让整个插件失败：失败即返回 $null，由调用方判断
    param([scriptblock]$Probe)
    try { return (& $Probe) } catch { return $null }
}

$os = Get-Safe { (Get-CimInstance Win32_OperatingSystem).Caption }
$build = Get-Safe { [string](Get-CimInstance Win32_OperatingSystem).BuildNumber }
$ubr = Get-Safe { [int](Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -Name UBR -ErrorAction Stop).UBR }
$arch = Get-Safe { $env:PROCESSOR_ARCHITECTURE }
$user = Get-Safe { ($env:USERDOMAIN + '\' + $env:USERNAME) }
$elevated = Get-Safe {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    ([Security.Principal.WindowsPrincipal]::new($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}
$uac = Get-Safe { [int](Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' -Name EnableLUA -ErrorAction Stop).EnableLUA }
$autologon = Get-Safe { [string](Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon' -Name AutoAdminLogon -ErrorAction Stop).AutoAdminLogon }
$ci = Get-Safe {
    $dg = Get-CimInstance -ClassName Win32_DeviceGuard -Namespace 'root\Microsoft\Windows\DeviceGuard' -ErrorAction Stop
    [int]$dg.CodeIntegrityPolicyEnforcementStatus
}
$secureBoot = Get-Safe { [bool](Confirm-SecureBootUEFI) }
$drivers = Get-Safe {
    $d = @(Get-CimInstance Win32_SystemDriver -ErrorAction Stop)
    [pscustomobject]@{ running = @($d | Where-Object { $_.State -eq 'Running' }).Count; total = @($d).Count }
}

$snapshot = [ordered]@{
    plugin      = 'example-v2-sysinfo'
    readOnly    = $true
    os          = $os
    build       = $build
    ubr         = $ubr
    arch        = $arch
    user        = $user
    elevated    = $elevated
    uacEnableLUA = $uac
    autoAdminLogon = $autologon
    ciEnforcement = $ci
    secureBoot  = $secureBoot
    driverRunning = $(if ($drivers) { $drivers.running } else { $null })
    driverTotal   = $(if ($drivers) { $drivers.total } else { $null })
    capturedAt  = (Get-Date).ToString('s')
}

# 单行 JSON 输出，便于调用方直接解析（插件契约：结构化输出走 stdout，见 docs\PLUGIN-SDK.md §7）
Write-Output ($snapshot | ConvertTo-Json -Compress -Depth 4)
exit 0