@echo off
setlocal
chcp 65001 >nul
if /i "%~1"=="--status" set "PM_STATUSONLY=1"
if not defined PM_STATUSONLY if not defined PM_TRIED_ELEVATE (
    powershell -NoProfile -Command "if (([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { exit 0 } else { exit 1 }"
    if errorlevel 1 (
        set "PM_TRIED_ELEVATE=1"
        echo Requesting administrator privileges...
        powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
        exit /b
    )
)
powershell -NoProfile -ExecutionPolicy Bypass -Command "$src = Get-Content -LiteralPath '%~f0' -Raw -Encoding UTF8; $mark = '#>>>' + 'PSSTART'; $idx = $src.IndexOf($mark); if ($idx -lt 0) { Write-Host 'internal marker missing'; exit 1 }; Invoke-Expression $src.Substring($idx)"
if defined PM_STATUSONLY (
    echo.
    pause
)
exit /b
#>>>PSSTART
$ErrorActionPreference = 'Continue'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

$BaseDir   = Join-Path $env:LOCALAPPDATA 'PowerModeTool'
$StateFile = Join-Path $BaseDir 'backup.json'
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

    [DllImport("user32.dll", EntryPoint = "EnumDisplaySettingsW", SetLastError = true)]
    public static extern bool EnumDisplaySettings(IntPtr deviceName, int modeNum, ref DEVMODE devMode);

    [DllImport("user32.dll", EntryPoint = "ChangeDisplaySettingsExW", SetLastError = true)]
    public static extern int ChangeDisplaySettingsEx(IntPtr deviceName, ref DEVMODE devMode, IntPtr hwnd, int flags, IntPtr lParam);

    [DllImport("user32.dll")] public static extern IntPtr GetDC(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern int ReleaseDC(IntPtr hWnd, IntPtr hDC);
    [DllImport("gdi32.dll")] public static extern bool SetDeviceGammaRamp(IntPtr hdc, ushort[] ramp);
    [DllImport("gdi32.dll")] public static extern bool GetDeviceGammaRamp(IntPtr hdc, ushort[] ramp);
}
'@

$Script:DevModeSize = [System.Runtime.InteropServices.Marshal]::SizeOf([type]'NativeDisplay+DEVMODE')

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

# ---------------------------------------------------------------- 显示相关
function Get-DisplayInfo {
    $dm = New-Object 'NativeDisplay+DEVMODE'
    $dm.dmSize = [int16]$Script:DevModeSize
    if (-not [NativeDisplay]::EnumDisplaySettings([IntPtr]::Zero, -1, [ref]$dm)) { return $null }
    return [pscustomobject]@{
        Width  = [int]$dm.dmPelsWidth
        Height = [int]$dm.dmPelsHeight
        Freq   = [int]$dm.dmDisplayFrequency
        Bits   = [int]$dm.dmBitsPerPel
    }
}

function Get-DisplayFreqList {
    $cur = Get-DisplayInfo
    if (-not $cur) { return @() }
    $list = New-Object System.Collections.Generic.List[int]
    $i = 0
    while ($true) {
        $d = New-Object 'NativeDisplay+DEVMODE'
        $d.dmSize = [int16]$Script:DevModeSize
        if (-not [NativeDisplay]::EnumDisplaySettings([IntPtr]::Zero, $i, [ref]$d)) { break }
        if ($d.dmPelsWidth -eq $cur.Width -and $d.dmPelsHeight -eq $cur.Height -and $d.dmBitsPerPel -ge 32 -and $d.dmDisplayFrequency -ge 24 -and $d.dmDisplayFrequency -le 500) {
            if (-not $list.Contains([int]$d.dmDisplayFrequency)) { $list.Add([int]$d.dmDisplayFrequency) }
        }
        $i++
    }
    return ($list | Sort-Object)
}

function Set-RefreshRateValue {
    param([int]$Freq)
    $cur = Get-DisplayInfo
    if (-not $cur) { return $false }
    if ($cur.Freq -eq $Freq) { return $true }
    $best = $null
    $i = 0
    while ($true) {
        $d = New-Object 'NativeDisplay+DEVMODE'
        $d.dmSize = [int16]$Script:DevModeSize
        if (-not [NativeDisplay]::EnumDisplaySettings([IntPtr]::Zero, $i, [ref]$d)) { break }
        if ($d.dmPelsWidth -eq $cur.Width -and $d.dmPelsHeight -eq $cur.Height -and $d.dmBitsPerPel -ge 32 -and $d.dmDisplayFrequency -eq $Freq) { $best = $d; break }
        $i++
    }
    if ($null -eq $best) { return $false }
    $rc = [NativeDisplay]::ChangeDisplaySettingsEx([IntPtr]::Zero, [ref]$best, [IntPtr]::Zero, 1, [IntPtr]::Zero)
    if ($rc -ne 0) { return $false }
    Start-Sleep -Milliseconds 800
    return $true
}

function Set-RefreshRate {
    param([ValidateSet('eco', 'perf')][string]$Mode)
    $cur = Get-DisplayInfo
    if (-not $cur) { return [pscustomobject]@{ Ok = $false; Message = '无法读取当前显示设置' } }

    $best = $null
    $i = 0
    while ($true) {
        $d = New-Object 'NativeDisplay+DEVMODE'
        $d.dmSize = [int16]$Script:DevModeSize
        if (-not [NativeDisplay]::EnumDisplaySettings([IntPtr]::Zero, $i, [ref]$d)) { break }
        if ($d.dmPelsWidth -eq $cur.Width -and $d.dmPelsHeight -eq $cur.Height -and $d.dmBitsPerPel -ge 32 -and $d.dmDisplayFrequency -ge 24 -and $d.dmDisplayFrequency -le 500) {
            if ($Mode -eq 'perf') {
                if ($null -eq $best -or $d.dmDisplayFrequency -gt $best.dmDisplayFrequency) { $best = $d }
            } else {
                if ($d.dmDisplayFrequency -le 60) {
                    if ($null -eq $best -or $d.dmDisplayFrequency -gt $best.dmDisplayFrequency) { $best = $d }
                }
            }
        }
        $i++
    }
    if ($null -eq $best) { return [pscustomobject]@{ Ok = $false; Message = '当前分辨率下没有可用刷新率' } }

    $target = [int]$best.dmDisplayFrequency
    if ($cur.Freq -eq $target) { return [pscustomobject]@{ Ok = $true; Message = "已经是 $target Hz" } }

    $rc = [NativeDisplay]::ChangeDisplaySettingsEx([IntPtr]::Zero, [ref]$best, [IntPtr]::Zero, 1, [IntPtr]::Zero)
    if ($rc -ne 0) { return [pscustomobject]@{ Ok = $false; Message = "切换失败（错误码 $rc）" } }
    Start-Sleep -Milliseconds 800
    return [pscustomobject]@{ Ok = $true; Message = "已切换到 $target Hz" }
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
            [System.Buffer]::BlockCopy($bytes, 0, $base, 0, 1536)
        }
        $ramp = New-Object 'UInt16[]' 768
        for ($i = 0; $i -lt 256; $i++) {
            $r = [int]$base[$i]
            $g = [int]$base[256 + $i]
            $b = [int]$base[512 + $i]
            $g = [int][Math]::Round($g * 0.93)
            $b = [int][Math]::Round($b * 0.62)
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
        if ($rMax -gt 0 -and $bMax -lt ($rMax * 0.8)) { return '暖色（低蓝光）' }
        return '正常'
    } finally {
        [void][NativeDisplay]::ReleaseDC([IntPtr]::Zero, $dc)
    }
}

# ---------------------------------------------------------------- 电源设置读写
function Get-ActiveSchemeGuid {
    $v = (Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Power\User\PowerSchemes' -Name 'ActivePowerScheme' -ErrorAction SilentlyContinue).ActivePowerScheme
    if ($v) { return $v.ToLower() }
    return $null
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

# ---------------------------------------------------------------- 备份 / 恢复
$BackupSpec = @(
    [pscustomobject]@{ Id = 'MonitorAC'; Sub = $SUB_VIDEO; Set = $SET_VIDEOIDLE; Ac = $true;  Text = '息屏（接电源）' }
    [pscustomobject]@{ Id = 'MonitorDC'; Sub = $SUB_VIDEO; Set = $SET_VIDEOIDLE; Ac = $false; Text = '息屏（电池）' }
    [pscustomobject]@{ Id = 'ProcMaxAC'; Sub = $SUB_PROC;  Set = $SET_PROCMAX;  Ac = $true;  Text = 'CPU 上限（接电源）' }
    [pscustomobject]@{ Id = 'ProcMaxDC'; Sub = $SUB_PROC;  Set = $SET_PROCMAX;  Ac = $false; Text = 'CPU 上限（电池）' }
    [pscustomobject]@{ Id = 'ProcMinAC'; Sub = $SUB_PROC;  Set = $SET_PROCMIN;  Ac = $true;  Text = 'CPU 下限（接电源）' }
    [pscustomobject]@{ Id = 'ProcMinDC'; Sub = $SUB_PROC;  Set = $SET_PROCMIN;  Ac = $false; Text = 'CPU 下限（电池）' }
    [pscustomobject]@{ Id = 'EsThreshDC'; Sub = $SUB_ES;   Set = $SET_ESTHRESH; Ac = $false; Text = '节能阈值（电池）' }
)

function Save-Backup {
    if (Test-Path -LiteralPath $StateFile) { return }
    $data = [ordered]@{
        Created = (Get-Date).ToString('s')
        Scheme  = (Get-ActiveSchemeGuid)
        Refresh = 0
        Items   = @{}
    }
    $info = Get-DisplayInfo
    if ($info) { $data.Refresh = $info.Freq }
    foreach ($s in $BackupSpec) {
        $v = Get-PowerValue -Sub $s.Sub -Setting $s.Set -Ac $s.Ac
        $data.Items[$s.Id] = @{ Has = ($null -ne $v); Value = $v }
    }
    ($data | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $StateFile -Encoding UTF8 -Force
}

function Restore-PowerOnly {
    if (-not (Test-Path -LiteralPath $StateFile)) { return }
    $data = Get-Content -LiteralPath $StateFile -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($s in $BackupSpec) {
        $rec = $data.Items.($s.Id)
        if ($null -eq $rec) { continue }
        if ($rec.Has -eq $true) {
            Set-PowerValue -Sub $s.Sub -Setting $s.Set -Ac $s.Ac -Value ([int]$rec.Value) | Out-Null
        } else {
            Remove-PowerValue -Sub $s.Sub -Setting $s.Set -Ac $s.Ac
        }
    }
    Apply-PowerScheme
}

function Restore-Backup {
    if (-not (Test-Path -LiteralPath $StateFile)) { return $false }
    $data = Get-Content -LiteralPath $StateFile -Raw -Encoding UTF8 | ConvertFrom-Json
    Restore-PowerOnly
    if ($data.Refresh -and [int]$data.Refresh -gt 0) { Set-RefreshRateValue -Freq ([int]$data.Refresh) | Out-Null }
    Set-GammaNormal | Out-Null
    & powercfg.exe /overlaysetactive $OVERLAY_BAL 2>&1 | Out-Null
    Remove-Item -LiteralPath $StateFile -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $ModeFile -Force -ErrorAction SilentlyContinue
    return $true
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

function Format-Remain {
    param([int]$Seconds)
    if ($Seconds -lt 0) { return '未知' }
    $h = [int][Math]::Floor($Seconds / 3600)
    $m = [int][Math]::Floor(($Seconds % 3600) / 60)
    if ($h -gt 0) { return "$h 小时 $m 分钟" }
    return "$m 分钟"
}

function Write-Ok { param([string]$Name, [string]$Text) Write-Host "  [完成] $Name：$Text" -ForegroundColor Green }
function Write-Warn { param([string]$Name, [string]$Text) Write-Host "  [注意] $Name：$Text" -ForegroundColor Yellow }

# ---------------------------------------------------------------- 状态显示
function Show-Header {
    Write-Host ''
    Write-Host '  ============================================================' -ForegroundColor DarkCyan
    Write-Host '                        电源模式切换工具  v1.0                ' -ForegroundColor Cyan
    Write-Host '  ============================================================' -ForegroundColor DarkCyan
}

function Show-Status {
    $info = Get-DisplayInfo
    $scheme = Get-ActiveSchemeGuid
    $schemeName = switch ($scheme) {
        '381b4222-f694-41f0-9685-ff5bb260df2e' { '平衡' }
        'a1841308-3541-4fab-bc81-f71556f20b4a' { '节能' }
        '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c' { '高性能' }
        'e9a42b02-d5df-448d-aa00-03f14749eb61' { '卓越性能' }
        default { '自定义 / 其他' }
    }

    $acText = '未知'
    $pctText = ''
    $remainText = ''
    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue
        $ps = [System.Windows.Forms.SystemInformation]::PowerStatus
        $lineStatus = [int]$ps.PowerLineStatus
        if ($lineStatus -eq 1) { $acText = '已接通电源' }
        elseif ($lineStatus -eq 2) { $acText = '使用电池' }

        $cs = [int]$ps.BatteryChargeStatus
        if (($cs -band 128) -ne 0) {
            $pctText = '（无电池）'
        } else {
            $pctText = "$([int][Math]::Round($ps.BatteryLifePercent * 100))%"
            if (($cs -band 8) -ne 0) { $pctText = $pctText + ' 充电中' }
            if ($ps.BatteryLifeRemaining -gt 0) { $remainText = '  预计可用 ' + (Format-Remain ([int]$ps.BatteryLifeRemaining)) }
        }
    } catch { }

    $resText = '未知'
    if ($info) { $resText = "$($info.Width) x $($info.Height) @ $($info.Freq) Hz" }

    $freqs = Get-DisplayFreqList
    $freqText = '未知'
    if ($freqs -and $freqs.Count -gt 0) { $freqText = ($freqs -join ' / ') + ' Hz' }

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

    if ($null -eq $esDc) { $esText = '系统默认' }
    elseif ($esDc -ge 100) { $esText = '电量 ≤ 100% 时始终开启' }
    else { $esText = "电量 ≤ $esDc% 时开启" }

    $modeText = '未设置'
    if (Test-Path -LiteralPath $ModeFile) {
        $m = (Get-Content -LiteralPath $ModeFile -Raw -Encoding UTF8).Trim()
        if ($m -eq 'eco') { $modeText = '极致续航' }
        elseif ($m -eq 'perf') { $modeText = '极致性能' }
    }

    Write-Host ''
    Write-Host ('  时间     : ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
    Write-Host ('  电源     : ' + $acText + '  ' + $pctText + $remainText)
    Write-Host ('  电源计划 : ' + $schemeName)
    Write-Host ('  屏幕     : ' + $resText)
    Write-Host ('  可用刷新 : ' + $freqText)
    Write-Host ('  息屏     : 接电源 ' + $monAcTxt + ' / 电池 ' + $monDcTxt)
    Write-Host ('  CPU 上限 : 接电源 ' + $cpuAcTxt + ' / 电池 ' + $cpuDcTxt)
    Write-Host ('  电池节能 : ' + $esText)
    Write-Host ('  屏幕色温 : ' + (Get-GammaState))
    Write-Host ('  当前模式 : ' + $modeText) -ForegroundColor Green
}

# ---------------------------------------------------------------- 模式切换
function Invoke-EcoMode {
    Write-Host ''
    Write-Host '  正在应用 [极致续航] 模式...' -ForegroundColor Green
    Save-Backup

    & powercfg.exe /overlaysetactive $OVERLAY_ECO 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) { Write-Ok '电源模式' '最佳能效' }
    else { Write-Warn '电源模式' '当前系统不支持叠加设置，已跳过' }

    if (Set-PowerValue -Sub $SUB_VIDEO -Setting $SET_VIDEOIDLE -Ac $false -Value 30) { Write-Ok '息屏时间' '使用电池时 30 秒' }
    else { Write-Warn '息屏时间' '写入失败' }

    if (Set-PowerValue -Sub $SUB_ES -Setting $SET_ESTHRESH -Ac $false -Value 100) { Write-Ok '电池节能' '电量 ≤ 100% 时始终开启' }
    else { Write-Warn '电池节能' '写入失败' }

    if (Set-PowerValue -Sub $SUB_PROC -Setting $SET_PROCMAX -Ac $false -Value 50) { Write-Ok 'CPU 上限' '使用电池时 50%' }
    else { Write-Warn 'CPU 上限' '写入失败' }

    Apply-PowerScheme

    $r = Set-RefreshRate -Mode 'eco'
    if ($r.Ok) { Write-Ok '刷新率' $r.Message } else { Write-Warn '刷新率' $r.Message }

    if (Set-GammaWarm) { Write-Ok '屏幕色温' '暖色（低蓝光）' }
    else { Write-Warn '屏幕色温' '设置失败（HDR 模式或显卡驱动不支持）' }

    Set-Content -LiteralPath $ModeFile -Value 'eco' -Encoding UTF8 -Force
    Write-Host ''
    Write-Host '  极致续航已启用。原始设置已备份，随时可选 [3] 恢复。' -ForegroundColor Green
}

function Invoke-PerfMode {
    Write-Host ''
    Write-Host '  正在应用 [极致性能] 模式...' -ForegroundColor Yellow
    Save-Backup
    Restore-PowerOnly

    & powercfg.exe /overlaysetactive $OVERLAY_PERF 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) { Write-Ok '电源模式' '最佳性能' }
    else { Write-Warn '电源模式' '当前系统不支持叠加设置，已跳过' }

    $okMaxAc = Set-PowerValue -Sub $SUB_PROC -Setting $SET_PROCMAX -Ac $true -Value 100
    $okMaxDc = Set-PowerValue -Sub $SUB_PROC -Setting $SET_PROCMAX -Ac $false -Value 100
    $okMinAc = Set-PowerValue -Sub $SUB_PROC -Setting $SET_PROCMIN -Ac $true -Value 100
    $okMinDc = Set-PowerValue -Sub $SUB_PROC -Setting $SET_PROCMIN -Ac $false -Value 100
    if ($okMaxAc -and $okMaxDc -and $okMinAc -and $okMinDc) { Write-Ok 'CPU 频率' '锁定 100%（始终最高频率）' }
    else { Write-Warn 'CPU 频率' '部分写入失败' }

    Apply-PowerScheme

    $r = Set-RefreshRate -Mode 'perf'
    if ($r.Ok) { Write-Ok '刷新率' $r.Message } else { Write-Warn '刷新率' $r.Message }

    if (Set-GammaNormal) { Write-Ok '屏幕色温' '恢复正常' }
    else { Write-Warn '屏幕色温' '恢复失败' }

    Set-Content -LiteralPath $ModeFile -Value 'perf' -Encoding UTF8 -Force
    Write-Host ''
    Write-Host '  极致性能已启用。原始设置已备份，随时可选 [3] 恢复。' -ForegroundColor Yellow
}

function Invoke-RestoreAction {
    Write-Host ''
    if (-not (Test-Path -LiteralPath $StateFile)) {
        Write-Host '  没有找到原始备份，无需恢复（或先切换到任一模式）。' -ForegroundColor Yellow
        return
    }
    Write-Host '  正在恢复原始设置...' -ForegroundColor Cyan
    Restore-Backup | Out-Null
    Write-Host '  已恢复：息屏时间、CPU 上下限、节能阈值、刷新率、色温、电源模式。' -ForegroundColor Green
}

# ---------------------------------------------------------------- 主流程
if ($env:PM_STATUSONLY -eq '1') {
    Show-Header
    Show-Status
    Write-Host ''
    exit
}

$isAdmin = $false
try { $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) } catch { }

while ($true) {
    try { Clear-Host } catch { }
    Show-Header
    if (-not $isAdmin) { Write-Host '  [警告] 当前没有管理员权限，部分设置写入会失败。' -ForegroundColor Red }
    Show-Status
    Write-Host ''
    Write-Host '  [1] 极致续航   30 秒息屏 + 电池节能 + 暖色屏幕 + 60Hz' -ForegroundColor Green
    Write-Host '  [2] 极致性能   最高刷新率 + CPU 满血 + 正常色温' -ForegroundColor Yellow
    Write-Host '  [3] 恢复原始设置' -ForegroundColor Gray
    Write-Host '  [0] 退出' -ForegroundColor DarkGray
    Write-Host ''
    $choice = Read-Host '  请输入数字并回车'

    if ($choice -eq '0') { break }
    elseif ($choice -eq '1') { Invoke-EcoMode; Read-Host '  按回车返回菜单' | Out-Null }
    elseif ($choice -eq '2') { Invoke-PerfMode; Read-Host '  按回车返回菜单' | Out-Null }
    elseif ($choice -eq '3') { Invoke-RestoreAction; Read-Host '  按回车返回菜单' | Out-Null }
}
