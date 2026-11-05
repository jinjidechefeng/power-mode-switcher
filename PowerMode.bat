@echo off
setlocal
chcp 65001 >nul
set "PM_SELF=%~f0"
set "PM_ARGS=%*"
powershell -NoProfile -ExecutionPolicy Bypass -Command "$src = Get-Content -LiteralPath $env:PM_SELF -Raw -Encoding UTF8; $mark = '#>>>' + 'PSSTART'; $idx = $src.IndexOf($mark); if ($idx -lt 0) { Write-Host 'internal marker missing'; exit 1 }; Invoke-Expression $src.Substring($idx)"
exit /b
#>>>PSSTART
# ===========================================================================
#  PowerMode - Windows 电源模式一键切换（极致续航 / 极致性能）
#  单文件实现：批处理外壳 + 内嵌 PowerShell
# ===========================================================================
$ErrorActionPreference = 'Continue'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

$SelfPath = $env:PM_SELF
if (-not $SelfPath) { $SelfPath = $PSCommandPath }
$SelfDir  = if ($SelfPath) { Split-Path -Parent $SelfPath } else { (Get-Location).Path }
$IniFile  = Join-Path $SelfDir 'PowerMode.ini'

$BaseDir   = Join-Path $env:LOCALAPPDATA 'PowerModeTool'
$StateFile = Join-Path $BaseDir 'backup.json'
$GpuFile   = Join-Path $BaseDir 'gpu_disabled.json'
$ModeFile  = Join-Path $BaseDir 'mode.txt'
$GammaFile = Join-Path $BaseDir 'gamma_original.bin'
if (-not (Test-Path -LiteralPath $BaseDir)) { New-Item -ItemType Directory -Path $BaseDir -Force | Out-Null }

# ---------------------------------------------------------------- Win32 API
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public class NativeDisplay
{
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct DEVMODE
    {
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmDeviceName;
        public short dmSpecVersion;
        public short dmDriverVersion;
        public short dmSize;
        public short dmDriverExtra;
        public int dmFields;
        public int dmPositionX;
        public int dmPositionY;
        public int dmDisplayOrientation;
        public int dmDisplayFixedOutput;
        public short dmColor;
        public short dmDuplex;
        public short dmYResolution;
        public short dmTTOption;
        public short dmCollate;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmFormName;
        public short dmLogPixels;
        public int dmBitsPerPel;
        public int dmPelsWidth;
        public int dmPelsHeight;
        public int dmDisplayFlags;
        public int dmDisplayFrequency;
        public int dmICMMethod;
        public int dmICMIntent;
        public int dmMediaType;
        public int dmDitherType;
        public int dmReserved1;
        public int dmReserved2;
        public int dmPanningWidth;
        public int dmPanningHeight;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct DISPLAY_DEVICE
    {
        public int cb;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string DeviceName;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceString;
        public int StateFlags;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceID;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceKey;
    }

    [DllImport("user32.dll", EntryPoint = "EnumDisplaySettingsW", SetLastError = true)]
    public static extern bool EnumDisplaySettings(IntPtr deviceName, int modeNum, ref DEVMODE devMode);

    [DllImport("user32.dll", EntryPoint = "EnumDisplaySettingsW", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern bool EnumDisplaySettingsDev(string deviceName, int modeNum, ref DEVMODE devMode);

    [DllImport("user32.dll", EntryPoint = "ChangeDisplaySettingsExW", SetLastError = true)]
    public static extern int ChangeDisplaySettingsEx(IntPtr deviceName, ref DEVMODE devMode, IntPtr hwnd, int flags, IntPtr lParam);

    [DllImport("user32.dll", EntryPoint = "ChangeDisplaySettingsExW", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern int ChangeDisplaySettingsExDev(string deviceName, ref DEVMODE devMode, IntPtr hwnd, int flags, IntPtr lParam);

    [DllImport("user32.dll", EntryPoint = "EnumDisplayDevicesW", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern bool EnumDisplayDevices(IntPtr device, int devNum, ref DISPLAY_DEVICE dd, int flags);

    [DllImport("user32.dll")] public static extern IntPtr GetDC(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern int ReleaseDC(IntPtr hWnd, IntPtr hDC);
    [DllImport("gdi32.dll")] public static extern bool SetDeviceGammaRamp(IntPtr hdc, ushort[] ramp);
    [DllImport("gdi32.dll")] public static extern bool GetDeviceGammaRamp(IntPtr hdc, ushort[] ramp);
}
'@

$Script:DevModeSize = [System.Runtime.InteropServices.Marshal]::SizeOf([type]'NativeDisplay+DEVMODE')
$Script:DevInfoSize = [System.Runtime.InteropServices.Marshal]::SizeOf([type]'NativeDisplay+DISPLAY_DEVICE')

# ---------------------------------------------------------------- 电源设置常量
$SUB_VIDEO     = '7516b95f-f776-4464-8c53-06167f40cc99'
$SET_VIDEOIDLE = '3c0bc021-c8a8-4e07-a973-6b14cbcb2b7e'
$SUB_PROC      = '54533251-82be-4824-96c1-47b60b740d00'
$SET_PROCMAX   = 'bc5038f7-23e0-4960-96da-33abaf5935ec'
$SET_PROCMIN   = '893dee8e-2bef-41e0-89c6-b55d0929964c'
$SUB_ES        = 'de830923-a562-41af-a086-e3a2c6bad2da'
$SET_ESTHRESH  = 'e69653ca-cf7f-4f05-aa73-cb833fa90ad4'

$OVERLAY_ECO  = 'ded574b5-45a0-4f42-8737-46345c09c238'
$OVERLAY_PERF = '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c'
$OVERLAY_BAL  = '00000000-0000-0000-0000-000000000000'

$SCHEME_BAL   = '381b4222-f694-41f0-9685-ff5bb260df2e'
$SCHEME_ECO   = 'a1841308-3541-4fab-bc81-f71556f20b4a'
$SCHEME_PERF  = '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c'
$SCHEME_ULTRA = 'e9a42b02-d5df-448d-aa00-03f14749eb61'

# ---------------------------------------------------------------- 配置
$Script:Cfg = [ordered]@{
    EcoMonitorTimeoutSec      = 30
    ApplyTimeoutsToAC         = $false
    EcoCpuMaxPercent          = 50
    PerfCpuMaxPercent         = 100
    PerfCpuMinPercent         = 100
    EcoRefreshMaxHz           = 60
    ApplyRefreshToAllDisplays = $true
    EcoWarmScreen             = $true
    EcoWarmBlue               = 0.62
    EcoWarmGreen              = 0.93
    EcoBatterySaver           = $true
    EcoBatterySaverThreshold  = 100
    EcoDisableGpu             = $true
    ConfirmGpuDisable         = $true
    PauseOnFinish             = $true
}

$Script:CfgLoaded = $false

function Import-Config {
    if (-not (Test-Path -LiteralPath $IniFile)) { return }
    $applied = 0
    foreach ($raw in [IO.File]::ReadAllLines($IniFile, [Text.Encoding]::UTF8)) {
        $line = $raw.Trim()
        if ($line -eq '') { continue }
        if ($line.StartsWith(';') -or $line.StartsWith('#')) { continue }
        if ($line -match '^\[.+\]$') { continue }
        if ($line -notmatch '^([^=]+)=(.*)$') { continue }
        $key = $matches[1].Trim()
        $val = $matches[2].Trim()
        if (-not $Script:Cfg.Contains($key)) { continue }
        try {
            $cur = $Script:Cfg[$key]
            if ($cur -is [bool]) {
                $Script:Cfg[$key] = ($val -match '^(1|true|yes|on)$')
            } elseif ($cur -is [int]) {
                $Script:Cfg[$key] = [int]$val
            } else {
                $Script:Cfg[$key] = [double]::Parse($val, [Globalization.CultureInfo]::InvariantCulture)
            }
            $applied++
        } catch { }
    }
    if ($applied -gt 0) { $Script:CfgLoaded = $true }

    if ($Script:Cfg.EcoMonitorTimeoutSec -lt 0) { $Script:Cfg.EcoMonitorTimeoutSec = 0 }
    if ($Script:Cfg.EcoCpuMaxPercent -lt 5) { $Script:Cfg.EcoCpuMaxPercent = 5 }
    if ($Script:Cfg.EcoCpuMaxPercent -gt 100) { $Script:Cfg.EcoCpuMaxPercent = 100 }
    if ($Script:Cfg.PerfCpuMaxPercent -lt 5) { $Script:Cfg.PerfCpuMaxPercent = 5 }
    if ($Script:Cfg.PerfCpuMinPercent -lt 5) { $Script:Cfg.PerfCpuMinPercent = 5 }
    if ($Script:Cfg.EcoRefreshMaxHz -lt 0) { $Script:Cfg.EcoRefreshMaxHz = 0 }
    if ($Script:Cfg.EcoWarmBlue -lt 0.2) { $Script:Cfg.EcoWarmBlue = 0.2 }
    if ($Script:Cfg.EcoWarmBlue -gt 1) { $Script:Cfg.EcoWarmBlue = 1 }
    if ($Script:Cfg.EcoWarmGreen -lt 0.2) { $Script:Cfg.EcoWarmGreen = 0.2 }
    if ($Script:Cfg.EcoWarmGreen -gt 1) { $Script:Cfg.EcoWarmGreen = 1 }
}

function Write-DefaultConfig {
    $lines = @(
        '; PowerMode 配置文件 —— 修改后重新启动本工具生效',
        '; 布尔值写法：1 = 开启，0 = 关闭',
        '',
        '; ==================== 极致续航 ====================',
        '; 息屏等待秒数（仅电池供电；0 = 从不息屏）',
        'EcoMonitorTimeoutSec=30',
        '; 息屏时间是否也套用到“接电源”状态',
        'ApplyTimeoutsToAC=0',
        '; 电池供电时的 CPU 最大性能百分比',
        'EcoCpuMaxPercent=50',
        '; 续航模式的刷新率上限（Hz），会自动选当前分辨率下不超过该值的最接近者',
        'EcoRefreshMaxHz=60',
        '; 是否启用暖色屏幕（低蓝光）',
        'EcoWarmScreen=1',
        '; 暖色强度：绿/蓝通道缩放系数，1 = 不变，越小越黄',
        'EcoWarmGreen=0.93',
        'EcoWarmBlue=0.62',
        '; 是否开启 Windows 节能模式（把电量阈值设为下面的值，相当于始终开启）',
        'EcoBatterySaver=1',
        'EcoBatterySaverThreshold=100',
        '; 续航模式是否禁用独立显卡',
        'EcoDisableGpu=1',
        '',
        '; ==================== 极致性能 ====================',
        '; CPU 下限/上限百分比（100 = 始终满频）',
        'PerfCpuMinPercent=100',
        'PerfCpuMaxPercent=100',
        '',
        '; ==================== 通用 ====================',
        '; 刷新率是否应用到所有已连接显示器（0 = 只改主屏）',
        'ApplyRefreshToAllDisplays=1',
        '; 禁用独显前是否询问确认',
        'ConfirmGpuDisable=1',
        '; 操作结束后是否等待回车（脚本调用可设 0）',
        'PauseOnFinish=1'
    )
    [IO.File]::WriteAllLines($IniFile, $lines, (New-Object Text.UTF8Encoding($true)))
}

# ---------------------------------------------------------------- 输出helper
function Write-Ok   { param([string]$Name, [string]$Text) Write-Host "  [完成] $Name：$Text" -ForegroundColor Green }
function Write-Warn { param([string]$Name, [string]$Text) Write-Host "  [注意] $Name：$Text" -ForegroundColor Yellow }
function Write-Info { param([string]$Text) Write-Host "  $Text" -ForegroundColor Gray }

# ---------------------------------------------------------------- 显示器
function Get-DisplayDevices {
    $res = @()
    $i = 0
    while ($true) {
        $dd = New-Object 'NativeDisplay+DISPLAY_DEVICE'
        $dd.cb = [int]$Script:DevInfoSize
        if (-not [NativeDisplay]::EnumDisplayDevices([IntPtr]::Zero, $i, [ref]$dd, 0)) { break }
        if (($dd.StateFlags -band 1) -ne 0 -and ($dd.StateFlags -band 8) -eq 0) {
            $res += [pscustomobject]@{ Name = $dd.DeviceName; Description = $dd.DeviceString; Primary = (($dd.StateFlags -band 4) -ne 0) }
        }
        $i++
    }
    return $res
}

function Get-DeviceCurrent {
    param([string]$Device)
    $dm = New-Object 'NativeDisplay+DEVMODE'
    $dm.dmSize = [int16]$Script:DevModeSize
    $ok = if ($Device) {
        [NativeDisplay]::EnumDisplaySettingsDev($Device, -1, [ref]$dm)
    } else {
        [NativeDisplay]::EnumDisplaySettings([IntPtr]::Zero, -1, [ref]$dm)
    }
    if (-not $ok) { return $null }
    return [pscustomobject]@{
        Width  = [int]$dm.dmPelsWidth
        Height = [int]$dm.dmPelsHeight
        Freq   = [int]$dm.dmDisplayFrequency
        Bits   = [int]$dm.dmBitsPerPel
    }
}

function Get-PrimaryDisplay {
    $devs = @(Get-DisplayDevices)
    foreach ($d in $devs) { if ($d.Primary) { return $d } }
    if ($devs.Count -gt 0) { return $devs[0] }
    return [pscustomobject]@{ Name = ''; Description = '主显示器'; Primary = $true }
}

function Get-DisplayFreqList {
    param([string]$Device)
    $cur = Get-DeviceCurrent $Device
    if (-not $cur) { return @() }
    $list = New-Object System.Collections.Generic.List[int]
    $i = 0
    while ($true) {
        $d = New-Object 'NativeDisplay+DEVMODE'
        $d.dmSize = [int16]$Script:DevModeSize
        $ok = if ($Device) {
            [NativeDisplay]::EnumDisplaySettingsDev($Device, $i, [ref]$d)
        } else {
            [NativeDisplay]::EnumDisplaySettings([IntPtr]::Zero, $i, [ref]$d)
        }
        if (-not $ok) { break }
        if ($d.dmPelsWidth -eq $cur.Width -and $d.dmPelsHeight -eq $cur.Height -and $d.dmBitsPerPel -ge 32 -and $d.dmDisplayFrequency -ge 24 -and $d.dmDisplayFrequency -le 500) {
            if (-not $list.Contains([int]$d.dmDisplayFrequency)) { $list.Add([int]$d.dmDisplayFrequency) }
        }
        $i++
    }
    return ($list | Sort-Object)
}

function Select-DeviceMode {
    param([string]$Device, [ValidateSet('max', 'cap', 'exact')][string]$Select, [int]$Number = 0)
    $cur = Get-DeviceCurrent $Device
    if (-not $cur) { return $null }
    $best = $null
    $i = 0
    while ($true) {
        $d = New-Object 'NativeDisplay+DEVMODE'
        $d.dmSize = [int16]$Script:DevModeSize
        $ok = if ($Device) {
            [NativeDisplay]::EnumDisplaySettingsDev($Device, $i, [ref]$d)
        } else {
            [NativeDisplay]::EnumDisplaySettings([IntPtr]::Zero, $i, [ref]$d)
        }
        if (-not $ok) { break }
        if ($d.dmPelsWidth -eq $cur.Width -and $d.dmPelsHeight -eq $cur.Height -and $d.dmBitsPerPel -ge 32 -and $d.dmDisplayFrequency -ge 24 -and $d.dmDisplayFrequency -le 500) {
            $accept = switch ($Select) {
                'max'   { $true }
                'cap'   { $d.dmDisplayFrequency -le $Number }
                'exact' { $d.dmDisplayFrequency -eq $Number }
            }
            if ($accept -and ($null -eq $best -or $d.dmDisplayFrequency -gt $best.dmDisplayFrequency)) { $best = $d }
        }
        $i++
    }
    if ($null -eq $best) { return $null }
    return [pscustomobject]@{ Current = $cur; Mode = $best; Freq = [int]$best.dmDisplayFrequency }
}

function Set-DeviceRefresh {
    param([string]$Device, [ValidateSet('max', 'cap', 'exact')][string]$Select, [int]$Number = 0)
    $m = Select-DeviceMode -Device $Device -Select $Select -Number $Number
    if (-not $m) { return [pscustomobject]@{ Ok = $false; From = 0; To = 0; Changed = $false; Message = '没有匹配的显示模式' } }
    if ($m.Current.Freq -eq $m.Freq) {
        return [pscustomobject]@{ Ok = $true; From = $m.Current.Freq; To = $m.Freq; Changed = $false; Message = "已经是 $($m.Freq) Hz" }
    }
    $rc = if ($Device) {
        [NativeDisplay]::ChangeDisplaySettingsExDev($Device, [ref]$m.Mode, [IntPtr]::Zero, 1, [IntPtr]::Zero)
    } else {
        [NativeDisplay]::ChangeDisplaySettingsEx([IntPtr]::Zero, [ref]$m.Mode, [IntPtr]::Zero, 1, [IntPtr]::Zero)
    }
    if ($rc -ne 0) {
        return [pscustomobject]@{ Ok = $false; From = $m.Current.Freq; To = $m.Freq; Changed = $false; Message = "切换失败（错误码 $rc）" }
    }
    return [pscustomobject]@{ Ok = $true; From = $m.Current.Freq; To = $m.Freq; Changed = $true; Message = "已切换到 $($m.Freq) Hz" }
}

function Update-Refresh {
    param([ValidateSet('max', 'cap', 'exact')][string]$Select, [int]$Number = 0)
    $devs = @(Get-DisplayDevices)
    if ($devs.Count -eq 0) { $devs = @([pscustomobject]@{ Name = ''; Description = '主显示器'; Primary = $true }) }
    if (-not $Script:Cfg.ApplyRefreshToAllDisplays -and $devs.Count -gt 1) {
        $devs = @(($devs | Sort-Object -Property @{ Expression = { -not $_.Primary } }) | Select-Object -First 1)
    }
    $out = @()
    foreach ($d in $devs) {
        $r = Set-DeviceRefresh -Device $d.Name -Select $Select -Number $Number
        $out += [pscustomobject]@{ Device = $d.Name; Description = $d.Description; Result = $r }
    }
    Start-Sleep -Milliseconds 700
    return $out
}

function Format-RefreshResults {
    param($Results)
    $parts = @()
    foreach ($r in $Results) {
        $short = if ($r.Device) { $r.Device -replace '^\\\\\.\\', '' } else { '主屏' }
        $res = $r.Result
        if (-not $res.Ok) { $parts += "$short 失败" }
        elseif ($res.Changed) { $parts += "$short $($res.From)→$($res.To)Hz" }
        else { $parts += "$short $($res.To)Hz" }
    }
    return ($parts -join '，')
}

# ---------------------------------------------------------------- 色温（Gamma）
function Set-GammaWarm {
    $dc = [NativeDisplay]::GetDC([IntPtr]::Zero)
    if ($dc -eq [IntPtr]::Zero) { return $false }
    try {
        $base = New-Object 'UInt16[]' 768
        if (-not (Test-Path -LiteralPath $GammaFile)) {
            if (-not [NativeDisplay]::GetDeviceGammaRamp($dc, $base)) { return $false }
            $bytes = New-Object 'Byte[]' 1536
            [System.Buffer]::BlockCopy($base, 0, $bytes, 0, 1536)
            [System.IO.File]::WriteAllBytes($GammaFile, $bytes)
        } else {
            $bytes = [System.IO.File]::ReadAllBytes($GammaFile)
            if ($bytes.Length -lt 1536) { return $false }
            [System.Buffer]::BlockCopy($bytes, 0, $base, 0, 1536)
        }
        $ramp = New-Object 'UInt16[]' 768
        for ($i = 0; $i -lt 256; $i++) {
            $r = [int]$base[$i]
            $g = [int][Math]::Round([int]$base[256 + $i] * $Script:Cfg.EcoWarmGreen)
            $b = [int][Math]::Round([int]$base[512 + $i] * $Script:Cfg.EcoWarmBlue)
            if ($g -gt 65535) { $g = 65535 }
            if ($b -gt 65535) { $b = 65535 }
            $ramp[$i]       = [uint16]$r
            $ramp[256 + $i] = [uint16]$g
            $ramp[512 + $i] = [uint16]$b
        }
        return [NativeDisplay]::SetDeviceGammaRamp($dc, $ramp)
    } finally {
        [void][NativeDisplay]::ReleaseDC([IntPtr]::Zero, $dc)
    }
}

function Set-GammaNormal {
    $dc = [NativeDisplay]::GetDC([IntPtr]::Zero)
    if ($dc -eq [IntPtr]::Zero) { return $false }
    try {
        $ramp = New-Object 'UInt16[]' 768
        if (Test-Path -LiteralPath $GammaFile) {
            $bytes = [System.IO.File]::ReadAllBytes($GammaFile)
            if ($bytes.Length -ge 1536) { [System.Buffer]::BlockCopy($bytes, 0, $ramp, 0, 1536) }
        } else {
            for ($i = 0; $i -lt 256; $i++) {
                $v = [uint16]($i * 257)
                $ramp[$i] = $v
                $ramp[256 + $i] = $v
                $ramp[512 + $i] = $v
            }
        }
        return [NativeDisplay]::SetDeviceGammaRamp($dc, $ramp)
    } finally {
        [void][NativeDisplay]::ReleaseDC([IntPtr]::Zero, $dc)
    }
}

function Get-GammaState {
    $dc = [NativeDisplay]::GetDC([IntPtr]::Zero)
    if ($dc -eq [IntPtr]::Zero) { return '未知' }
    try {
        $ramp = New-Object 'UInt16[]' 768
        if (-not [NativeDisplay]::GetDeviceGammaRamp($dc, $ramp)) { return '未知' }
        $rMax = [int]$ramp[255]
        $bMax = [int]$ramp[767]
        if ($rMax -gt 0 -and $bMax -lt ($rMax * 0.8)) { return '暖色' }
        return '正常'
    } finally {
        [void][NativeDisplay]::ReleaseDC([IntPtr]::Zero, $dc)
    }
}

# ---------------------------------------------------------------- 电源设置
function Get-ActiveSchemeGuid {
    $v = (Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Power\User\PowerSchemes' -Name 'ActivePowerScheme' -ErrorAction SilentlyContinue).ActivePowerScheme
    if ($v) { return $v.ToLower() }
    return $null
}

function Get-SchemeName {
    param([string]$Guid)
    switch ($Guid) {
        $SCHEME_BAL   { '平衡' }
        $SCHEME_ECO   { '节能' }
        $SCHEME_PERF  { '高性能' }
        $SCHEME_ULTRA { '卓越性能' }
        default { '自定义 / 其他' }
    }
}

function Get-PowerValue {
    param([string]$Sub, [string]$Setting, [bool]$Ac)
    $scheme = Get-ActiveSchemeGuid
    if (-not $scheme) { return $null }
    $path = "HKLM:\SYSTEM\CurrentControlSet\Control\Power\User\PowerSchemes\$scheme\$Sub\$Setting"
    $name = if ($Ac) { 'ACSettingIndex' } else { 'DCSettingIndex' }
    $p = Get-ItemProperty -Path $path -ErrorAction SilentlyContinue
    if ($null -eq $p) { return $null }
    $prop = $p.PSObject.Properties[$name]
    if ($null -eq $prop) { return $null }
    return [int]$prop.Value
}

function Set-PowerValue {
    param([string]$Sub, [string]$Setting, [bool]$Ac, [int]$Value)
    $flag = if ($Ac) { '/setacvalueindex' } else { '/setdcvalueindex' }
    & powercfg.exe $flag SCHEME_CURRENT $Sub $Setting $Value 2>&1 | Out-Null
    return ($LASTEXITCODE -eq 0)
}

function Remove-PowerValue {
    param([string]$Sub, [string]$Setting, [bool]$Ac)
    $scheme = Get-ActiveSchemeGuid
    if (-not $scheme) { return }
    $path = "HKLM:\SYSTEM\CurrentControlSet\Control\Power\User\PowerSchemes\$scheme\$Sub\$Setting"
    $name = if ($Ac) { 'ACSettingIndex' } else { 'DCSettingIndex' }
    Remove-ItemProperty -Path $path -Name $name -ErrorAction SilentlyContinue
}

function Apply-PowerScheme {
    & powercfg.exe /setactive SCHEME_CURRENT 2>&1 | Out-Null
}

function Set-PowerModeOverlay {
    param([ValidateSet('eco', 'perf', 'bal')][string]$Kind)
    $guid = switch ($Kind) {
        'eco'  { $OVERLAY_ECO }
        'perf' { $OVERLAY_PERF }
        default { $OVERLAY_BAL }
    }
    & powercfg.exe /overlaysetactive $guid 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) { return 'overlay' }

    if ($Kind -eq 'bal') { return 'none' }
    $scheme = if ($Kind -eq 'eco') { $SCHEME_ECO } else { $SCHEME_PERF }
    if (Test-Path "HKLM:\SYSTEM\CurrentControlSet\Control\Power\PowerSchemes\$scheme") {
        & powercfg.exe /setactive $scheme 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) { return 'scheme' }
    }
    return 'none'
}

function Get-OverlayForScheme {
    param([string]$Guid)
    switch ($Guid) {
        $SCHEME_ECO  { $OVERLAY_ECO }
        $SCHEME_PERF { $OVERLAY_PERF }
        default      { $OVERLAY_BAL }
    }
}

# ---------------------------------------------------------------- 显卡
function Get-AdapterKind {
    param([string]$Name)
    if (-not $Name) { return 'unknown' }
    $n = $Name.ToLowerInvariant()

    $virtualPatterns = 'virtual|basic display|basic render|remote display|parsec|todesk|sunlogin|anydesk|citrix|hyper-v|vmware|virtualbox|qemu|spacedesk|mumu|bluestacks|ldplayer'
    if ($n -match $virtualPatterns) { return 'virtual' }

    $discretePatterns = 'geforce|quadro|tesla|radeon rx|radeon pro|firepro|radeon vii|intel.*arc|iris xe max|nvidia rtx|nvidia gt\b|dg1|dg2'
    if ($n -match $discretePatterns) { return 'discrete' }

    $integratedPatterns = 'intel.*(hd|uhd) graphics|intel.*iris|intel.*graphics|radeon.*(graphics|vega)|\bradeon \d{3}m|adreno|mali|apple m\d|graphics \(integrated'
    if ($n -match $integratedPatterns) { return 'integrated' }

    return 'unknown'
}

function Get-GpuInfo {
    $list = @()
    $devs = @()
    try {
        $devs = @(Get-PnpDevice -Class Display -ErrorAction Stop)
    } catch {
        try {
            $devs = @(Get-CimInstance -ClassName Win32_PnPEntity -ErrorAction Stop | Where-Object { $_.PNPClass -eq 'Display' })
        } catch { $devs = @() }
    }
    foreach ($d in $devs) {
        $name = $null; $id = $null; $enabled = $false
        if ($d.PSObject.Properties['FriendlyName']) {
            $name = $d.FriendlyName
            $id = $d.InstanceId
            $enabled = ($d.Status -eq 'OK')
        } else {
            $name = $d.Name
            $id = $d.DeviceID
            $enabled = ($d.ConfigManagerErrorCode -eq 0 -and $d.Status -eq 'OK')
        }
        if (-not $name) { continue }
        $list += [pscustomobject]@{
            Name       = $name
            InstanceId = $id
            Enabled    = $enabled
            Kind       = (Get-AdapterKind $name)
        }
    }
    return $list
}

function Get-KindText {
    param([string]$Kind)
    switch ($Kind) {
        'discrete'   { '独显' }
        'integrated' { '集显' }
        'virtual'    { '虚拟' }
        default      { '未知' }
    }
}

function Disable-GpuAdapter {
    param([string]$InstanceId)
    try {
        Disable-PnpDevice -InstanceId $InstanceId -Confirm:$false -ErrorAction Stop
        return $true
    } catch {
        & pnputil.exe /disable-device "$InstanceId" 2>&1 | Out-Null
        return ($LASTEXITCODE -eq 0)
    }
}

function Enable-GpuAdapter {
    param([string]$InstanceId)
    try {
        Enable-PnpDevice -InstanceId $InstanceId -Confirm:$false -ErrorAction Stop
        return $true
    } catch {
        & pnputil.exe /enable-device "$InstanceId" 2>&1 | Out-Null
        return ($LASTEXITCODE -eq 0)
    }
}

function Get-RecordedGpus {
    if (-not (Test-Path -LiteralPath $GpuFile)) { return @() }
    try {
        $data = Get-Content -LiteralPath $GpuFile -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($data.Gpus) { return @($data.Gpus) }
    } catch { }
    return @()
}

function Save-RecordedGpus {
    param($Gpus)
    $list = @()
    foreach ($g in $Gpus) {
        if ($g -and $g.InstanceId) { $list += [pscustomobject]@{ InstanceId = $g.InstanceId; Name = $g.Name } }
    }
    if ($list.Count -eq 0) {
        Remove-Item -LiteralPath $GpuFile -Force -ErrorAction SilentlyContinue
        return
    }
    ([pscustomobject]@{ Gpus = $list } | ConvertTo-Json -Depth 4) | Set-Content -LiteralPath $GpuFile -Encoding UTF8 -Force
}

function Invoke-GpuOff {
    param([bool]$SkipConfirm = $false)
    $gpus = @(Get-GpuInfo)
    if ($gpus.Count -eq 0) { Write-Warn '独立显卡' '未检测到显示适配器，已跳过'; return $false }

    $enabled  = @($gpus | Where-Object { $_.Enabled })
    $targets  = @($enabled | Where-Object { $_.Kind -eq 'discrete' })
    $others   = @($enabled | Where-Object { $_.Kind -ne 'discrete' })

    if ($targets.Count -eq 0) { Write-Info '没有检测到可禁用的独立显卡，已跳过。'; return $false }
    if ($others.Count -eq 0) {
        Write-Warn '独立显卡' '禁用后没有其他可用显卡（可能是独显直连模式），已跳过'
        return $false
    }

    Write-Host ''
    Write-Host '  将要禁用以下独立显卡：' -ForegroundColor Yellow
    foreach ($t in $targets) { Write-Host "    - $($t.Name)" -ForegroundColor Yellow }
    Write-Info '禁用后桌面会短暂闪烁，使用该显卡的程序会切换到集显运行。'

    if (-not $SkipConfirm -and $Script:Cfg.ConfirmGpuDisable) {
        $ans = Read-Host '  确认禁用？[Y/n]'
        if ($ans -and $ans -notmatch '^[Yy]') { Write-Info '已取消禁用显卡。'; return $false }
    }

    $done = @()
    foreach ($t in $targets) {
        if (Disable-GpuAdapter -InstanceId $t.InstanceId) {
            Write-Ok '独立显卡' "已禁用 $($t.Name)"
            $done += $t
        } else {
            Write-Warn '独立显卡' "禁用失败：$($t.Name)（可能需要在设备管理器中手动操作）"
        }
    }
    if ($done.Count -gt 0) {
        Save-RecordedGpus (@(Get-RecordedGpus) + @($done))
        Start-Sleep -Milliseconds 1200
        return $true
    }
    return $false
}

function Invoke-GpuOn {
    $recorded = @(Get-RecordedGpus)
    if ($recorded.Count -eq 0) { Write-Info '没有记录到由本工具禁用的显卡。'; return $false }
    $ok = 0
    $failed = @()
    foreach ($g in $recorded) {
        if (Enable-GpuAdapter -InstanceId $g.InstanceId) {
            Write-Ok '独立显卡' "已启用 $($g.Name)"
            $ok++
        } else {
            Write-Warn '独立显卡' "启用失败：$($g.Name)"
            $failed += $g
        }
    }
    Save-RecordedGpus $failed
    if ($ok -gt 0) {
        Start-Sleep -Milliseconds 1500
        return $true
    }
    return $false
}

# ---------------------------------------------------------------- 备份 / 恢复
$BackupSpec = @(
    [pscustomobject]@{ Id = 'MonitorAC'; Sub = $SUB_VIDEO; Set = $SET_VIDEOIDLE; Ac = $true  }
    [pscustomobject]@{ Id = 'MonitorDC'; Sub = $SUB_VIDEO; Set = $SET_VIDEOIDLE; Ac = $false }
    [pscustomobject]@{ Id = 'ProcMaxAC'; Sub = $SUB_PROC;  Set = $SET_PROCMAX;  Ac = $true  }
    [pscustomobject]@{ Id = 'ProcMaxDC'; Sub = $SUB_PROC;  Set = $SET_PROCMAX;  Ac = $false }
    [pscustomobject]@{ Id = 'ProcMinAC'; Sub = $SUB_PROC;  Set = $SET_PROCMIN;  Ac = $true  }
    [pscustomobject]@{ Id = 'ProcMinDC'; Sub = $SUB_PROC;  Set = $SET_PROCMIN;  Ac = $false }
    [pscustomobject]@{ Id = 'EsThreshDC'; Sub = $SUB_ES;   Set = $SET_ESTHRESH; Ac = $false }
)

function Save-Backup {
    if (Test-Path -LiteralPath $StateFile) { return }
    $data = [ordered]@{
        Version  = 2
        Created  = (Get-Date).ToString('s')
        Scheme   = (Get-ActiveSchemeGuid)
        Values   = @{}
        Displays = @{}
    }
    foreach ($s in $BackupSpec) {
        $v = Get-PowerValue -Sub $s.Sub -Setting $s.Set -Ac $s.Ac
        $data.Values[$s.Id] = @{ Has = ($null -ne $v); Value = $v }
    }
    foreach ($d in @(Get-DisplayDevices)) {
        $cur = Get-DeviceCurrent $d.Name
        if ($cur) { $data.Displays[$d.Name] = $cur.Freq }
    }
    ($data | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $StateFile -Encoding UTF8 -Force
}

function Restore-PowerOnly {
    if (-not (Test-Path -LiteralPath $StateFile)) { return $false }
    $data = Get-Content -LiteralPath $StateFile -Raw -Encoding UTF8 | ConvertFrom-Json

    if ($data.Scheme) {
        $current = Get-ActiveSchemeGuid
        if ($current -ne ([string]$data.Scheme).ToLower()) {
            & powercfg.exe /setactive ([string]$data.Scheme) 2>&1 | Out-Null
        }
    }
    $valuesNode = $data.Values
    if ($null -eq $valuesNode -and $data.Items) { $valuesNode = $data.Items }
    foreach ($s in $BackupSpec) {
        if ($null -eq $valuesNode) { continue }
        $rec = $valuesNode.($s.Id)
        if ($null -eq $rec) { continue }
        if ($rec.Has -eq $true) {
            Set-PowerValue -Sub $s.Sub -Setting $s.Set -Ac $s.Ac -Value ([int]$rec.Value) | Out-Null
        } else {
            Remove-PowerValue -Sub $s.Sub -Setting $s.Set -Ac $s.Ac
        }
    }
    Apply-PowerScheme
    return $true
}

function Restore-All {
    $did = $false

    if (@(Get-RecordedGpus).Count -gt 0) { if (Invoke-GpuOn) { $did = $true } }

    if (Test-Path -LiteralPath $StateFile) {
        $data = Get-Content -LiteralPath $StateFile -Raw -Encoding UTF8 | ConvertFrom-Json
        Restore-PowerOnly | Out-Null

        $targets = @()
        if ($data.Displays) {
            foreach ($name in $data.Displays.PSObject.Properties.Name) {
                $targets += [pscustomobject]@{ Name = $name; Freq = [int]$data.Displays.$name }
            }
        } elseif ($data.Refresh -and [int]$data.Refresh -gt 0) {
            $targets += [pscustomobject]@{ Name = (Get-PrimaryDisplay).Name; Freq = [int]$data.Refresh }
        }
        foreach ($t in $targets) {
            if ($t.Freq -le 0) { continue }
            $r = Set-DeviceRefresh -Device $t.Name -Select 'exact' -Number $t.Freq
            if ($r.Ok) { Write-Ok '刷新率' ("$($t.Name) → $($t.Freq) Hz") }
        }

        Set-GammaNormal | Out-Null
        Write-Ok '屏幕色温' '恢复正常'

        $ov = Get-OverlayForScheme ([string]$data.Scheme)
        & powercfg.exe /overlaysetactive $ov 2>&1 | Out-Null

        Remove-Item -LiteralPath $StateFile -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $ModeFile -Force -ErrorAction SilentlyContinue
        $did = $true
    }

    return $did
}

# ---------------------------------------------------------------- 格式化
function Format-Seconds {
    param([int]$Seconds)
    if ($Seconds -eq 0) { return '从不' }
    if ($Seconds -lt 60) { return "$Seconds 秒" }
    $m = [int][Math]::Floor($Seconds / 60)
    $sec = [int]($Seconds % 60)
    if ($sec -eq 0) { return "$m 分钟" }
    return "$m 分 $sec 秒"
}

function Format-Minutes {
    param([int]$Minutes)
    if ($Minutes -lt 0) { return '未知' }
    if ($Minutes -lt 1) { return '不足 1 分钟' }
    if ($Minutes -lt 60) { return "$Minutes 分钟" }
    $h = [int][Math]::Floor($Minutes / 60)
    $m = $Minutes % 60
    if ($m -eq 0) { return "$h 小时" }
    return "$h 小时 $m 分钟"
}

# 电池状态：百分比、是否接电、是否充电、按当前放电功率估算的剩余分钟数
function Get-BatteryState {
    $res = [pscustomobject]@{
        Percent  = -1
        OnAc     = $null
        Charging = $false
        Minutes  = -1
    }

    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue
        $ps = [System.Windows.Forms.SystemInformation]::PowerStatus
        if (([int]$ps.BatteryChargeStatus -band 128) -eq 0) {
            $res.Percent = [int][Math]::Round($ps.BatteryLifePercent * 100)
        }
    } catch { }

    if ($res.Percent -lt 0) {
        try {
            $bat = @(Get-CimInstance -ClassName Win32_Battery -ErrorAction Stop)
            if ($bat.Count -gt 0) { $res.Percent = [int]$bat[0].EstimatedChargeRemaining }
        } catch { }
    }

    $wmi = @()
    try { $wmi = @(Get-CimInstance -Namespace root\wmi -ClassName BatteryStatus -ErrorAction Stop) } catch { }

    if ($wmi.Count -gt 0) {
        if (@($wmi | Where-Object { $_.PowerOnline -eq $true }).Count -gt 0) { $res.OnAc = $true }
        elseif (@($wmi | Where-Object { $_.PowerOnline -eq $false }).Count -gt 0) { $res.OnAc = $false }
        if (@($wmi | Where-Object { $_.Charging -eq $true }).Count -gt 0) { $res.Charging = $true }
        elseif ((($wmi | Measure-Object -Property ChargeRate -Sum -ErrorAction SilentlyContinue).Sum) -gt 0) { $res.Charging = $true }
    } else {
        try {
            $ps2 = [System.Windows.Forms.SystemInformation]::PowerStatus
            if ([int]$ps2.PowerLineStatus -eq 1) { $res.OnAc = $true }
            elseif ([int]$ps2.PowerLineStatus -eq 0) { $res.OnAc = $false }
        } catch { }
    }

    # 剩余容量 / 当前放电功率 = 剩余时间；取三次采样的平均值削掉抖动
    if ($wmi.Count -gt 0 -and $res.OnAc -ne $true -and -not $res.Charging) {
        $rates = @()
        $capacity = 0
        for ($k = 0; $k -lt 3; $k++) {
            $sample = @()
            try { $sample = @(Get-CimInstance -Namespace root\wmi -ClassName BatteryStatus -ErrorAction Stop) } catch { }
            $rate = ($sample | Measure-Object -Property DischargeRate -Sum -ErrorAction SilentlyContinue).Sum
            $cap  = ($sample | Measure-Object -Property RemainingCapacity -Sum -ErrorAction SilentlyContinue).Sum
            if ($rate -gt 0) { $rates += [double]$rate }
            if ($cap -gt 0) { $capacity = [double]$cap }
            if ($k -lt 2) { Start-Sleep -Milliseconds 250 }
        }
        if ($rates.Count -gt 0 -and $capacity -gt 0) {
            $avg = ($rates | Measure-Object -Average).Average
            if ($avg -gt 0) { $res.Minutes = [int][Math]::Round($capacity / $avg * 60) }
        }
    }

    # 拿不到放电功率时退回系统估算
    if ($res.Minutes -lt 0 -and $res.OnAc -ne $true) {
        try {
            $ps3 = [System.Windows.Forms.SystemInformation]::PowerStatus
            if ($ps3.BatteryLifeRemaining -gt 0) { $res.Minutes = [int][Math]::Round($ps3.BatteryLifeRemaining / 60) }
        } catch { }
    }

    return $res
}

# ---------------------------------------------------------------- 状态
function Show-Header {
    Write-Host ''
    Write-Host '  ============================================================' -ForegroundColor DarkCyan
    Write-Host '                     PowerMode  电源模式切换工具            ' -ForegroundColor Cyan
    Write-Host '  ============================================================ ' -ForegroundColor DarkCyan
}

function Show-Status {
    $primary = Get-PrimaryDisplay
    $info = Get-DeviceCurrent $primary.Name
    $scheme = Get-ActiveSchemeGuid
    $bat = Get-BatteryState

    $pctText = if ($bat.Percent -ge 0) { "$($bat.Percent)%" } else { '' }
    if ($bat.OnAc -eq $true) {
        $powerText = ('插电 ' + $pctText).Trim()
        if ($bat.Charging) { $powerText += ' 充电中' }
    } elseif ($bat.OnAc -eq $false) {
        $powerText = ('电池 ' + $pctText).Trim()
        if ($bat.Minutes -ge 0) { $powerText += '  预计 ' + (Format-Minutes $bat.Minutes) }
    } else {
        if ($pctText) { $powerText = $pctText } else { $powerText = '无电池' }
    }

    $resText = '未知'
    if ($info) { $resText = "$($info.Width) x $($info.Height) @ $($info.Freq) Hz" }
    $devCount = @(Get-DisplayDevices).Count
    if ($devCount -gt 1) { $resText += " ×$devCount" }

    $freqs = @(Get-DisplayFreqList $primary.Name)
    $freqText = '未知'
    if ($freqs.Count -gt 0) { $freqText = ($freqs -join ' / ') + ' Hz' }

    $monAc = Get-PowerValue -Sub $SUB_VIDEO -Setting $SET_VIDEOIDLE -Ac $true
    $monDc = Get-PowerValue -Sub $SUB_VIDEO -Setting $SET_VIDEOIDLE -Ac $false
    $cpuAc = Get-PowerValue -Sub $SUB_PROC -Setting $SET_PROCMAX -Ac $true
    $cpuDc = Get-PowerValue -Sub $SUB_PROC -Setting $SET_PROCMAX -Ac $false
    $esDc  = Get-PowerValue -Sub $SUB_ES -Setting $SET_ESTHRESH -Ac $false

    $monAcTxt = '默认'; $monDcTxt = '默认'; $cpuAcTxt = '默认'; $cpuDcTxt = '默认'
    if ($null -ne $monAc) { $monAcTxt = Format-Seconds $monAc }
    if ($null -ne $monDc) { $monDcTxt = Format-Seconds $monDc }
    if ($null -ne $cpuAc) { $cpuAcTxt = "$cpuAc%" }
    if ($null -ne $cpuDc) { $cpuDcTxt = "$cpuDc%" }

    if ($null -eq $esDc) { $esText = '默认' }
    elseif ($esDc -ge 100) { $esText = '100%' }
    else { $esText = "$esDc%" }

    $modeText = '未设置'
    if (Test-Path -LiteralPath $ModeFile) {
        $m = (Get-Content -LiteralPath $ModeFile -Raw -Encoding UTF8).Trim()
        if ($m -eq 'eco') { $modeText = '极致续航' }
        elseif ($m -eq 'perf') { $modeText = '极致性能' }
    }

    Write-Host ''
    Write-Host ('  时间     : ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
    Write-Host ('  电源     : ' + $powerText)
    Write-Host ('  电源计划 : ' + (Get-SchemeName $scheme))
    Write-Host ('  屏幕     : ' + $resText)
    Write-Host ('  刷新率   : ' + $freqText)
    Write-Host ('  息屏     : 接 ' + $monAcTxt + ' / 电池 ' + $monDcTxt)
    Write-Host ('  CPU      : 接 ' + $cpuAcTxt + ' / 电池 ' + $cpuDcTxt)
    Write-Host ('  节能     : ' + $esText)
    Write-Host ('  色温     : ' + (Get-GammaState))
    Write-Host ('  模式     : ' + $modeText) -ForegroundColor Green

    $gpus = @(Get-GpuInfo | Where-Object { $_.Enabled -or $_.Kind -ne 'virtual' })
    $first = $true
    foreach ($g in $gpus) {
        $kind = Get-KindText $g.Kind
        $line = if ($g.Enabled) { "$($g.Name)（$kind）" } else { "$($g.Name)（$kind，已禁用）" }
        if ($first) { Write-Host ('  显卡     : ' + $line); $first = $false }
        else { Write-Host ('             ' + $line) }
    }
    if ($first) { Write-Host '  显卡     : 未检测到' }

    $cfgText = if ($Script:CfgLoaded) { 'PowerMode.ini' } else { '默认' }
    Write-Host ('  配置文件 : ' + $cfgText)
}

# ---------------------------------------------------------------- 模式
function Invoke-EcoMode {
    Write-Host ''
    Write-Host '  正在应用 [极致续航] 模式...' -ForegroundColor Green
    Save-Backup

    $method = Set-PowerModeOverlay -Kind 'eco'
    if ($method -eq 'overlay') { Write-Ok '电源模式' '最佳能效' }
    elseif ($method -eq 'scheme') { Write-Ok '电源模式' '已切换到「节能」电源计划' }
    else { Write-Warn '电源模式' '当前系统不支持切换，已跳过' }

    $timeout = [int]$Script:Cfg.EcoMonitorTimeoutSec
    if (Set-PowerValue -Sub $SUB_VIDEO -Setting $SET_VIDEOIDLE -Ac $false -Value $timeout) {
        Write-Ok '息屏时间' ("电池 " + (Format-Seconds $timeout))
    } else { Write-Warn '息屏时间' '写入失败' }
    if ($Script:Cfg.ApplyTimeoutsToAC) {
        Set-PowerValue -Sub $SUB_VIDEO -Setting $SET_VIDEOIDLE -Ac $true -Value $timeout | Out-Null
    }

    if ($Script:Cfg.EcoBatterySaver) {
        $th = [int]$Script:Cfg.EcoBatterySaverThreshold
        if (Set-PowerValue -Sub $SUB_ES -Setting $SET_ESTHRESH -Ac $false -Value $th) {
            Write-Ok '电池节能' ("电量 ≤ $th% 时始终开启")
        } else { Write-Warn '电池节能' '当前系统不支持该设置，已跳过' }
    }

    $cpu = [int]$Script:Cfg.EcoCpuMaxPercent
    if (Set-PowerValue -Sub $SUB_PROC -Setting $SET_PROCMAX -Ac $false -Value $cpu) {
        Write-Ok 'CPU 上限' "电池供电时 $cpu%"
    } else { Write-Warn 'CPU 上限' '写入失败' }

    Apply-PowerScheme

    $cap = [int]$Script:Cfg.EcoRefreshMaxHz
    if ($cap -gt 0) {
        $res = Update-Refresh -Select 'cap' -Number $cap
        $okAll = $true
        foreach ($r in $res) { if (-not $r.Result.Ok) { $okAll = $false } }
        if ($okAll) { Write-Ok '刷新率' (Format-RefreshResults $res) }
        else { Write-Warn '刷新率' (Format-RefreshResults $res) }
    } else {
        $res = Update-Refresh -Select 'max'
        Write-Ok '刷新率' (Format-RefreshResults $res)
    }

    if ($Script:Cfg.EcoWarmScreen) {
        if (Set-GammaWarm) { Write-Ok '屏幕色温' '暖色' }
        else { Write-Warn '屏幕色温' '设置失败（HDR 或驱动不支持）' }
    }

    if ($Script:Cfg.EcoDisableGpu) { Invoke-GpuOff -SkipConfirm $Script:Yes | Out-Null }

    Set-Content -LiteralPath $ModeFile -Value 'eco' -Encoding UTF8 -Force
    Write-Host ''
    Write-Host '  极致续航已启用。原始设置已备份，可用 [4] 恢复。' -ForegroundColor Green
}

function Invoke-PerfMode {
    Write-Host ''
    Write-Host '  正在应用 [极致性能] 模式...' -ForegroundColor Yellow
    Save-Backup

    if (@(Get-RecordedGpus).Count -gt 0) { Invoke-GpuOn | Out-Null }
    Restore-PowerOnly | Out-Null

    $method = Set-PowerModeOverlay -Kind 'perf'
    if ($method -eq 'overlay') { Write-Ok '电源模式' '最佳性能' }
    elseif ($method -eq 'scheme') { Write-Ok '电源模式' '已切换到「高性能」电源计划' }
    else { Write-Warn '电源模式' '当前系统不支持切换，已跳过' }

    $cpuMax = [int]$Script:Cfg.PerfCpuMaxPercent
    $cpuMin = [int]$Script:Cfg.PerfCpuMinPercent
    $okMaxAc = Set-PowerValue -Sub $SUB_PROC -Setting $SET_PROCMAX -Ac $true -Value $cpuMax
    $okMaxDc = Set-PowerValue -Sub $SUB_PROC -Setting $SET_PROCMAX -Ac $false -Value $cpuMax
    $okMinAc = Set-PowerValue -Sub $SUB_PROC -Setting $SET_PROCMIN -Ac $true -Value $cpuMin
    $okMinDc = Set-PowerValue -Sub $SUB_PROC -Setting $SET_PROCMIN -Ac $false -Value $cpuMin
    if ($okMaxAc -and $okMaxDc -and $okMinAc -and $okMinDc) { Write-Ok 'CPU 频率' "锁定 $cpuMin% - $cpuMax%" }
    else { Write-Warn 'CPU 频率' '部分写入失败' }

    Apply-PowerScheme

    $res = Update-Refresh -Select 'max'
    $okAll = $true
    foreach ($r in $res) { if (-not $r.Result.Ok) { $okAll = $false } }
    if ($okAll) { Write-Ok '刷新率' (Format-RefreshResults $res) }
    else { Write-Warn '刷新率' (Format-RefreshResults $res) }

    if (Set-GammaNormal) { Write-Ok '屏幕色温' '恢复正常' }
    else { Write-Warn '屏幕色温' '恢复失败' }

    Set-Content -LiteralPath $ModeFile -Value 'perf' -Encoding UTF8 -Force
    Write-Host ''
    Write-Host '  极致性能已启用。原始设置已备份，可用 [4] 恢复。' -ForegroundColor Yellow
}

function Invoke-RestoreAction {
    Write-Host ''
    if (@(Get-RecordedGpus).Count -eq 0 -and -not (Test-Path -LiteralPath $StateFile)) {
        Write-Info '没有找到备份，无需恢复。'
        return
    }
    Write-Host '  正在恢复原始设置...' -ForegroundColor Cyan
    Restore-All | Out-Null
    Write-Host '  已恢复：显卡、息屏时间、CPU 上下限、节能阈值、刷新率、色温、电源模式。' -ForegroundColor Green
}

# ---------------------------------------------------------------- 参数解析
Import-Config

$Script:Yes = $false
$Cmd = 'menu'
$GpuAction = ''

$argList = @()
if ($env:PM_ARGS) { $argList = @($env:PM_ARGS -split '\s+' | Where-Object { $_ -ne '' }) }

$i = 0
while ($i -lt $argList.Count) {
    $a = $argList[$i].ToLowerInvariant()
    switch ($a) {
        '--status'       { $Cmd = 'status' }
        '-s'             { $Cmd = 'status' }
        '--eco'          { $Cmd = 'eco' }
        '--perf'         { $Cmd = 'perf' }
        '--restore'      { $Cmd = 'restore' }
        '--list-gpus'    { $Cmd = 'listgpus' }
        '--write-config' { $Cmd = 'writeconfig' }
        '--help'         { $Cmd = 'help' }
        '-h'             { $Cmd = 'help' }
        '--gpu' {
            $Cmd = 'gpu'
            if ($i + 1 -lt $argList.Count) { $i++; $GpuAction = $argList[$i].ToLowerInvariant() }
        }
        '--gpu-off'      { $Cmd = 'gpu'; $GpuAction = 'off' }
        '--gpu-on'       { $Cmd = 'gpu'; $GpuAction = 'on' }
        '--no-gpu'       { $Script:Cfg.EcoDisableGpu = $false }
        '--yes'          { $Script:Yes = $true }
        '--no-pause'     { $Script:Cfg.PauseOnFinish = $false }
    }
    $i++
}

if ($Script:Yes) { $Script:Cfg.PauseOnFinish = $false }

# ---------------------------------------------------------------- 提权
$isAdmin = $false
try { $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) } catch { }

$needAdmin = ($Cmd -in @('menu', 'eco', 'perf', 'restore', 'gpu'))
if ($needAdmin -and -not $isAdmin -and $env:PM_TRIED_ELEVATE -ne '1' -and $SelfPath -and $env:ComSpec) {
    $env:PM_TRIED_ELEVATE = '1'
    $argLine = '/c "' + $SelfPath + '"'
    if ($env:PM_ARGS) { $argLine += ' ' + $env:PM_ARGS }
    try {
        Start-Process -FilePath $env:ComSpec -ArgumentList $argLine -Verb RunAs -ErrorAction Stop
        exit
    } catch {
        # 用户取消了 UAC，继续以普通权限运行
    }
}

# ---------------------------------------------------------------- 帮助
function Show-Help {
    Show-Header
    Write-Host ''
    Write-Host '  用法: PowerMode.bat [命令] [选项]'
    Write-Host ''
    Write-Host '  命令:' -ForegroundColor Cyan
    Write-Host '    (无)              交互菜单'
    Write-Host '    --status, -s      只显示当前电源 / 显示 / 显卡状态'
    Write-Host '    --eco             直接应用极致续航'
    Write-Host '    --perf            直接应用极致性能'
    Write-Host '    --restore         恢复原始设置'
    Write-Host '    --gpu off|on      禁用 / 启用独立显卡'
    Write-Host '    --list-gpus       列出所有显示适配器及识别结果'
    Write-Host '    --write-config    生成默认配置文件（PowerMode.ini）'
    Write-Host '    --help, -h        显示本帮助'
    Write-Host ''
    Write-Host '  选项:' -ForegroundColor Cyan
    Write-Host '    --no-gpu          本次不禁用独显'
    Write-Host '    --yes             跳过确认提示，不等待回车（适合计划任务）'
    Write-Host ''
    Write-Host ('  配置文件: ' + $IniFile)
}

# ---------------------------------------------------------------- 入口分发
switch ($Cmd) {
    'status' {
        Show-Header
        Show-Status
        Write-Host ''
    }
    'listgpus' {
        Show-Header
        Write-Host ''
        $gpus = @(Get-GpuInfo)
        if ($gpus.Count -eq 0) { Write-Host '  未检测到显示适配器。' }
        foreach ($g in $gpus) {
            $state = if ($g.Enabled) { '启用' } else { '已禁用' }
            Write-Host ("  [{0}] {1}" -f (Get-KindText $g.Kind), $g.Name)
            Write-Host ("        状态: $state")
            Write-Host ("        实例: $($g.InstanceId)")
        }
        Write-Host ''
    }
    'eco'     { Show-Header; Show-Status; Invoke-EcoMode }
    'perf'    { Show-Header; Show-Status; Invoke-PerfMode }
    'restore' { Show-Header; Show-Status; Invoke-RestoreAction }
    'gpu' {
        Show-Header
        if ($GpuAction -eq 'off') { Invoke-GpuOff -SkipConfirm $Script:Yes | Out-Null }
        elseif ($GpuAction -eq 'on') { Invoke-GpuOn | Out-Null }
        else {
            Write-Host ''
            Write-Host '  用法: PowerMode.bat --gpu off|on' -ForegroundColor Yellow
        }
    }
    'writeconfig' {
        Show-Header
        if (Test-Path -LiteralPath $IniFile) {
            Write-Info "配置文件已存在：$IniFile"
        } else {
            Write-DefaultConfig
            Write-Ok '配置文件' "已生成 $IniFile"
        }
    }
    'help' { Show-Help }
    default {
        while ($true) {
            try { Clear-Host } catch { }
            Show-Header
            if (-not $isAdmin) { Write-Host '  [警告] 当前没有管理员权限，部分设置写入会失败。' -ForegroundColor Red }
            Show-Status
            Write-Host ''

            $gpuOffByUs = (@(Get-RecordedGpus).Count -gt 0)
            $gpuLabel = if ($gpuOffByUs) { '启用独立显卡' } else { '禁用独立显卡' }

            Write-Host '  [1] 极致续航' -ForegroundColor Green
            Write-Host '  [2] 极致性能' -ForegroundColor Yellow
            Write-Host ("  [3] " + $gpuLabel) -ForegroundColor Magenta
            Write-Host '  [4] 恢复原始设置' -ForegroundColor Gray
            Write-Host '  [5] 配置文件' -ForegroundColor DarkGray
            Write-Host '  [0] 退出' -ForegroundColor DarkGray
            Write-Host ''
            $choice = Read-Host '  请输入数字并回车'

            if ($choice -eq '0') { break }
            elseif ($choice -eq '1') { Invoke-EcoMode; Read-Host '  按回车返回菜单' | Out-Null }
            elseif ($choice -eq '2') { Invoke-PerfMode; Read-Host '  按回车返回菜单' | Out-Null }
            elseif ($choice -eq '3') {
                Show-Header
                if ($gpuOffByUs) { Invoke-GpuOn | Out-Null } else { Invoke-GpuOff | Out-Null }
                Read-Host '  按回车返回菜单' | Out-Null
            }
            elseif ($choice -eq '4') { Invoke-RestoreAction; Read-Host '  按回车返回菜单' | Out-Null }
            elseif ($choice -eq '5') {
                Show-Header
                if (-not (Test-Path -LiteralPath $IniFile)) {
                    Write-DefaultConfig
                    Write-Ok '配置文件' "已生成 $IniFile"
                }
                Write-Info '修改保存后，重新启动本工具即可生效。'
                try { Start-Process notepad.exe -ArgumentList "`"$IniFile`"" } catch { Write-Warn '打开失败' $IniFile }
                Read-Host '  按回车返回菜单' | Out-Null
            }
        }
    }
}

# ---------------------------------------------------------------- 结束
if ($Cmd -ne 'menu' -and $Cmd -ne 'help' -and $Script:Cfg.PauseOnFinish) {
    Write-Host ''
    Read-Host '  按回车退出' | Out-Null
}
