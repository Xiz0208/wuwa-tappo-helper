<#
  鸣潮桌宠 · 自动让位（全屏时自动隐藏）
  ------------------------------------------------------------
  做什么：
    检测前台是否有一个窗口盖住了整块屏幕（连任务栏都看不到）。
      · 是  → 把桌宠隐藏起来，不挡画面
      · 否  → 让它回来（并恢复置顶）
    按 Win+D 回桌面、Alt+Tab 切走、关掉全屏，都会自动恢复。

  判定标准（两条同时满足才算全屏）：
    1) 窗口盖住整块显示器；
    2) 它不是一个"普通的最大化窗口"（带标题栏 + 可调边框）。
    所以：游戏全屏 / 无边框全屏 / 视频全屏 → 藏；
          浏览器、文件夹、任何程序的"最大化窗口" → 不藏。
    这样即使任务栏设成自动隐藏（最大化也会铺满屏幕），也不会误判。

  排除：
    桌面 / 任务栏 / 任务视图 / 动态壁纸(Wallpaper Engine) / 桌宠自己。

  为什么需要管理员：
    桌宠以管理员权限运行，普通权限改不动它的窗口。

  用法：
    WuwaAutoHide.ps1                 后台常驻（会被 自动让位.bat 调用）
    WuwaAutoHide.ps1 -Diagnose       前台实时显示判定结果（不隐藏）
    WuwaAutoHide.ps1 -Stop           停止并恢复桌宠
    WuwaAutoHide.ps1 -Install        设为开机自启（计划任务，最高权限，不弹 UAC）
    WuwaAutoHide.ps1 -Uninstall      取消开机自启
    WuwaAutoHide.ps1 -Status         查看当前状态
#>

param(
    [int]$TickMs = 500,
    [int]$RunForSec = 0,
    [switch]$Diagnose,
    [switch]$Stop,
    [switch]$Install,
    [switch]$Uninstall,
    [switch]$Status
)

$ErrorActionPreference = 'Stop'
$Root     = $PSScriptRoot
$LogFile  = Join-Path $Root 'autohide.log'
$StopFlag = Join-Path $Root 'autohide.stop'
$TaskName = 'WuwaPetAutoHide'

# ---------- 权限 ----------
$wi = [Security.Principal.WindowsIdentity]::GetCurrent()
$wp = New-Object Security.Principal.WindowsPrincipal($wi)
$IsAdmin = $wp.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

# ---------- 原生接口 ----------
if (-not ('AH' -as [type])) {
Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Runtime.InteropServices;

public class AH
{
    public delegate bool EnumProc(IntPtr h, IntPtr l);

    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left, Top, Right, Bottom; }

    [StructLayout(LayoutKind.Sequential)]
    public struct MONITORINFO
    {
        public int cbSize;
        public RECT rcMonitor;
        public RECT rcWork;
        public int dwFlags;
    }

    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr l);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
    [DllImport("user32.dll")] public static extern bool IsZoomed(IntPtr h);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowTextW(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassNameW(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern IntPtr MonitorFromWindow(IntPtr h, int flags);
    [DllImport("user32.dll")] public static extern bool GetMonitorInfoW(IntPtr m, ref MONITORINFO mi);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
    [DllImport("user32.dll")] public static extern int GetWindowLong(IntPtr h, int idx);
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();

    public static readonly IntPtr HWND_TOPMOST = new IntPtr(-1);

    public static bool RectOf(IntPtr h, out int L, out int T, out int R, out int B)
    {
        L = T = R = B = 0;
        RECT rc;
        if (!GetWindowRect(h, out rc)) return false;
        L = rc.Left; T = rc.Top; R = rc.Right; B = rc.Bottom;
        return true;
    }

    public static bool MonitorRectOf(IntPtr h, out int L, out int T, out int R, out int B)
    {
        L = T = R = B = 0;
        IntPtr mon = MonitorFromWindow(h, 2);
        if (mon == IntPtr.Zero) return false;
        MONITORINFO mi = new MONITORINFO();
        mi.cbSize = Marshal.SizeOf(typeof(MONITORINFO));
        if (!GetMonitorInfoW(mon, ref mi)) return false;
        L = mi.rcMonitor.Left;
        T = mi.rcMonitor.Top;
        R = mi.rcMonitor.Right;
        B = mi.rcMonitor.Bottom;
        return true;
    }
}
'@
}

try { [void][AH]::SetProcessDPIAware() } catch { }

# ---------- 排除清单 ----------
$ExcludeClass = @(
    'Progman',                          # 桌面
    'WorkerW',                          # 桌面壁纸层
    'Shell_TrayWnd',                    # 任务栏
    'Shell_SecondaryTrayWnd',           # 副屏任务栏
    'ForegroundStaging',
    'MultitaskingViewFrame',            # 任务视图
    'TaskSwitcherWnd',                  # Alt+Tab
    'XamlExplorerHostIslandWindow',
    'Windows.Internal.Shell.TabProxyWindow',
    'ApplicationManager_DesktopShellWindow',
    'SysListView32'
)
$ExcludeProc = @(
    'wallpaper32', 'wallpaper64',       # Wallpaper Engine
    'WuwaTappo',                        # 桌宠自己
    'explorer',
    'LockApp', 'LogonUI'
)

# ---------- 小工具 ----------
function Get-WinClass {
    param([IntPtr]$h)
    $sb = New-Object System.Text.StringBuilder 256
    [void][AH]::GetClassNameW($h, $sb, 256)
    return $sb.ToString()
}

function Get-WinTitle {
    param([IntPtr]$h)
    $sb = New-Object System.Text.StringBuilder 512
    [void][AH]::GetWindowTextW($h, $sb, 512)
    return $sb.ToString()
}

function Get-WinPid {
    param([IntPtr]$h)
    $p = 0
    [void][AH]::GetWindowThreadProcessId($h, [ref]$p)
    return [int]$p
}

function Get-ProcName {
    param([int]$procId)
    if ($procId -le 0) { return '' }
    try { return (Get-Process -Id $procId -ErrorAction Stop).ProcessName } catch { return '' }
}

function Log {
    param([string]$msg)
    try {
        $line = (Get-Date).ToString('MM-dd HH:mm:ss') + '  ' + $msg
        Add-Content -Path $LogFile -Value $line -Encoding UTF8 -ErrorAction SilentlyContinue
    } catch { }
}

# ---------- 全屏判定 ----------
function Test-FullscreenWindow {
    param([IntPtr]$h)

    if ($h -eq [IntPtr]::Zero) { return $false }
    if (-not [AH]::IsWindowVisible($h)) { return $false }
    if ([AH]::IsIconic($h)) { return $false }

    $cls = Get-WinClass $h
    if ($ExcludeClass -contains $cls) { return $false }

    $wpid = Get-WinPid $h
    if ($wpid -eq $PID) { return $false }
    $pn = Get-ProcName $wpid
    if ($ExcludeProc -contains $pn) { return $false }

    $L = 0; $T = 0; $R = 0; $B = 0
    if (-not [AH]::RectOf($h, [ref]$L, [ref]$T, [ref]$R, [ref]$B)) { return $false }

    $ML = 0; $MT = 0; $MR = 0; $MB = 0
    if (-not [AH]::MonitorRectOf($h, [ref]$ML, [ref]$MT, [ref]$MR, [ref]$MB)) { return $false }

    $tol = 3
    if ($L -gt ($ML + $tol)) { return $false }
    if ($T -gt ($MT + $tol)) { return $false }
    if ($R -lt ($MR - $tol)) { return $false }
    if ($B -lt ($MB - $tol)) { return $false }

    # 铺满整块屏幕了。接着分辨"最大化窗口"和"真全屏"：
    #   最大化窗口   = 处于最大化状态 + 还带着标题栏(WS_CAPTION) + 可调边框(WS_THICKFRAME)
    #   真全屏       = 去掉了这些边框修饰，或者根本不是最大化状态
    # 这步是关键：任务栏设成自动隐藏时，最大化窗口同样铺满整屏，
    # 光看尺寸永远分不出来，必须看窗口自己的状态。
    $style  = [AH]::GetWindowLong($h, -16)
    $zoomed = [AH]::IsZoomed($h)
    if ($zoomed -and (($style -band 0x00C00000) -ne 0) -and (($style -band 0x00040000) -ne 0)) {
        return $false
    }

    return $true
}

# 诊断用：把判定依据摊开显示，方便核对
function Get-FsDetail {
    param([IntPtr]$h)

    $o = [ordered]@{
        Zoomed = $false; Caption = $false; Frame = $false
        W = 0; H = 0; MW = 0; MH = 0
    }
    if ($h -eq [IntPtr]::Zero) { return New-Object psobject -Property $o }

    $style = [AH]::GetWindowLong($h, -16)
    $o.Zoomed  = [AH]::IsZoomed($h)
    $o.Caption = (($style -band 0x00C00000) -ne 0)
    $o.Frame   = (($style -band 0x00040000) -ne 0)

    $L = 0; $T = 0; $R = 0; $B = 0
    if ([AH]::RectOf($h, [ref]$L, [ref]$T, [ref]$R, [ref]$B)) { $o.W = $R - $L; $o.H = $B - $T }

    $ML = 0; $MT = 0; $MR = 0; $MB = 0
    if ([AH]::MonitorRectOf($h, [ref]$ML, [ref]$MT, [ref]$MR, [ref]$MB)) { $o.MW = $MR - $ML; $o.MH = $MB - $MT }

    return New-Object psobject -Property $o
}

# ---------- 找桌宠窗口 ----------
# 只处理"带置顶样式"的顶层窗口（桌宠的显示层/输入层/气泡），
# 不碰它内部的 WebView 辅助窗口，避免影响渲染。
function Get-PetWindows {
    param([switch]$IncludeHidden)

    $list = New-Object System.Collections.ArrayList
    $proc = Get-Process -Name WuwaTappo -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $proc) { return @() }

    $script:_petPid = $proc.Id
    $script:_petBuf = $list
    $script:_petAll = [bool]$IncludeHidden

    $cb = [AH+EnumProc]{
        param($hw, $lp)
        $p = 0
        [void][AH]::GetWindowThreadProcessId($hw, [ref]$p)
        if ($p -eq $script:_petPid) {
            if ($script:_petAll -or [AH]::IsWindowVisible($hw)) {
                [void]$script:_petBuf.Add($hw)
            }
        }
        return $true
    }
    [void][AH]::EnumWindows($cb, [IntPtr]::Zero)

    $arr = @()
    foreach ($x in $list) { $arr += $x }
    return $arr
}

function Hide-Pet {
    $n = 0
    foreach ($h in @(Get-PetWindows)) {
        $ex = [AH]::GetWindowLong($h, -20)
        if (($ex -band 0x8) -eq 0) { continue }
        [void][AH]::ShowWindow($h, 0)
        $n++
    }
    return $n
}

function Show-Pet {
    $n = 0
    foreach ($h in @(Get-PetWindows -IncludeHidden)) {
        $ex = [AH]::GetWindowLong($h, -20)
        if (($ex -band 0x8) -eq 0) { continue }
        if (-not [AH]::IsWindowVisible($h)) {
            [void][AH]::ShowWindow($h, 8)
            $n++
        }
        [void][AH]::SetWindowPos($h, [AH]::HWND_TOPMOST, 0, 0, 0, 0, 0x13)
    }
    return $n
}

function Get-PetState {
    $wins = @(Get-PetWindows -IncludeHidden)
    if ($wins.Count -eq 0) { return 'not-running' }
    foreach ($h in $wins) {
        if ([AH]::IsWindowVisible($h)) { return 'visible' }
    }
    return 'hidden'
}

# ---------- 动作：安装 / 卸载 / 停止 / 状态 ----------
if ($Install) {
    if (-not $IsAdmin) { Write-Host '  需要管理员权限。' -ForegroundColor Red; exit 1 }
    $scriptPath = Join-Path $Root 'WuwaAutoHide.ps1'
    $arg = '-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + $scriptPath + '"'
    $act = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $arg
    $trg = New-ScheduledTaskTrigger -AtLogOn
    $prn = New-ScheduledTaskPrincipal -UserId $env:USERNAME -RunLevel Highest -LogonType Interactive
    $set = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero)
    Register-ScheduledTask -TaskName $TaskName -Action $act -Trigger $trg -Principal $prn -Settings $set -Force | Out-Null
    Write-Host ''
    Write-Host '  开机自启已装好：登录后自动运行，不会再弹管理员确认框。' -ForegroundColor Green
    Write-Host ''
    exit 0
}

if ($Uninstall) {
    if (-not $IsAdmin) { Write-Host '  需要管理员权限。' -ForegroundColor Red; exit 1 }
    try { Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction Stop; Write-Host '  已取消开机自启。' -ForegroundColor Green }
    catch { Write-Host '  没有找到自启项（本来就没装）。' -ForegroundColor Yellow }
    exit 0
}

if ($Stop) {
    if (Test-Path $StopFlag) { Remove-Item $StopFlag -Force -ErrorAction SilentlyContinue }
    Set-Content -Path $StopFlag -Value 'stop' -Encoding ASCII
    $waited = 0
    while ($waited -lt 6) {
        Start-Sleep -Milliseconds 500
        $waited++
        $running = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
                     Where-Object { $_.CommandLine -like '*WuwaAutoHide*' -and $_.ProcessId -ne $PID })
        if ($running.Count -eq 0) { break }
    }
    # 兜底：确保桌宠是显示状态
    if ($IsAdmin) {
        $s = Get-PetState
        if ($s -eq 'hidden') { [void](Show-Pet) }
    }
    if (Test-Path $StopFlag) { Remove-Item $StopFlag -Force -ErrorAction SilentlyContinue }
    Write-Host ''
    Write-Host '  已停止，桌宠已恢复显示。' -ForegroundColor Green
    Write-Host ''
    exit 0
}

if ($Status) {
    $running = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
                 Where-Object { $_.CommandLine -like '*WuwaAutoHide*' -and $_.ProcessId -ne $PID })
    $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    $pet  = Get-PetState
    $fg   = [AH]::GetForegroundWindow()

    $stTxt = '没在运行'
    switch ($pet) {
        'visible' { $stTxt = '显示中' }
        'hidden'  { $stTxt = '已隐藏' }
    }
    $fsTxt = '不是全屏'
    if (Test-FullscreenWindow -h $fg) { $fsTxt = '是全屏（现在该隐藏）' }

    Write-Host ''
    Write-Host '  ---------------- 自动让位 · 当前状态 ----------------'
    Write-Host ('  后台程序    : ' + $(if ($running.Count -gt 0) { '正在运行（PID ' + $running[0].ProcessId + '）' } else { '没在运行' }))
    Write-Host ('  开机自启    : ' + $(if ($task) { '已开启' } else { '没开启' }))
    Write-Host ('  桌宠        : ' + $stTxt)
    Write-Host ('  当前前台    : ' + (Get-WinTitle $fg) + '  [' + (Get-WinClass $fg) + ']')
    Write-Host ('  全屏判断    : ' + $fsTxt)
    Write-Host '  ----------------------------------------------------'
    Write-Host ''
    exit 0
}

# ---------- 主循环 ----------
if (-not $IsAdmin -and -not $Diagnose) {
    Write-Host ''
    Write-Host '  [需要管理员权限]' -ForegroundColor Red
    Write-Host '  请用「自动让位.bat」启动，它会自动申请权限。' -ForegroundColor Yellow
    Write-Host ''
    exit 1
}

# 诊断模式下若没有管理员权限，只判定、不动手
$ReadOnly = ($Diagnose -and -not $IsAdmin)

# 日志超过 200KB 就清空重来
try {
    if ((Test-Path $LogFile) -and ((Get-Item $LogFile).Length -gt 200KB)) {
        Remove-Item $LogFile -Force -ErrorAction SilentlyContinue
    }
} catch { }

if (Test-Path $StopFlag) { Remove-Item $StopFlag -Force -ErrorAction SilentlyContinue }

$hidden = $false
$lastNote = ''

if ($Diagnose) {
    Write-Host ''
    Write-Host '  ============ 实时诊断（按 Ctrl+C 退出）============' -ForegroundColor Cyan
    if ($ReadOnly) { Write-Host '  只读模式：没有管理员权限，只判断、不隐藏。' -ForegroundColor Yellow }
    Write-Host '  这行会跟着你切换的窗口实时变化，用来核对判断准不准：' -ForegroundColor Gray
    Write-Host '    · 游戏 / 视频全屏   → 应显示「算全屏」' -ForegroundColor Gray
    Write-Host '    · 浏览器 / 文件夹最大化 → 应显示「不算全屏」' -ForegroundColor Gray
    Write-Host ''
}
else {
    Log ('启动（PID ' + $PID + '，间隔 ' + $TickMs + 'ms）')
}

try {
    $t0 = Get-Date
    while ($true) {
        if ($RunForSec -gt 0 -and ((Get-Date) - $t0).TotalSeconds -ge $RunForSec) { break }

        # 停止信号
        if (Test-Path $StopFlag) {
            if ($hidden -and -not $ReadOnly) { [void](Show-Pet) }
            Remove-Item $StopFlag -Force -ErrorAction SilentlyContinue
            Log '收到停止信号，恢复桌宠后退出'
            break
        }

        $fg = [AH]::GetForegroundWindow()
        $isFull = Test-FullscreenWindow -h $fg

        if ($isFull) {
            if (-not $ReadOnly) {
                if (-not $hidden) {
                    $n = Hide-Pet
                    $hidden = $true
                    Log ('全屏 → 隐藏桌宠（' + $n + ' 个窗口）  前台: ' + (Get-WinTitle $fg) + ' [' + (Get-WinClass $fg) + ']')
                }
                else {
                    # 持续压制：万一它自己冒回来，再藏一次
                    [void](Hide-Pet)
                }
            }
        }
        else {
            if ($hidden -and -not $ReadOnly) {
                $n = Show-Pet
                $hidden = $false
                Log ('退出全屏 → 恢复桌宠（' + $n + ' 个窗口）')
            }
        }

        if ($Diagnose) {
            $d = Get-FsDetail -h $fg
            $pn = Get-ProcName (Get-WinPid $fg)
            $st = '未知'
            switch (Get-PetState) {
                'visible'     { $st = '显示中' }
                'hidden'      { $st = '已隐藏' }
                'not-running' { $st = '没在运行' }
            }
            $verdict = '不算全屏'
            if ($isFull) { $verdict = '算全屏 → 该隐藏' }
            $line = '[' + (Get-Date).ToString('HH:mm:ss') + '] ' + $pn + ' | ' + (Get-WinClass $fg)
            $line += ' | 窗口 ' + $d.W + 'x' + $d.H + ' / 屏幕 ' + $d.MW + 'x' + $d.MH
            $line += ' | 最大化=' + $(if ($d.Zoomed) { '是' } else { '否' })
            $line += ' 标题栏=' + $(if ($d.Caption) { '有' } else { '无' })
            $line += ' | ' + $verdict + ' | 桌宠' + $st
            if ($line -ne $lastNote) {
                Write-Host $line
                $lastNote = $line
            }
            Start-Sleep -Milliseconds 1000
        }
        else {
            Start-Sleep -Milliseconds $TickMs
        }
    }
}
finally {
    if ($hidden -and -not $ReadOnly) {
        try { [void](Show-Pet) } catch { }
    }
    if (-not $Diagnose) { Log '退出' }
}

if ($Diagnose) {
    Write-Host ''
    Write-Host '  诊断结束。' -ForegroundColor Cyan
    Write-Host ''
}
