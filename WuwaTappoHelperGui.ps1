<#
  ============================================================
  Wuwa Tappo 计数助手 · 托盘版
  ------------------------------------------------------------
  以随机间隔向系统发送一个“没有副作用的虚拟按键”（F24），
  让 Wuwa Tappo 的键鼠计数增长。带可视化窗口，可缩到托盘。

  不联网 / 不读写任何文件 / 不碰游戏和桌宠的程序文件
  / 不注入进程 / 不改内存 / 不模拟鼠标点击

  【重要】只在“你手离开键鼠”时才发送。你一旦打字或点鼠标，
  助手立刻让路，绝不和你的输入抢时间，不会卡输入法。
  节奏模仿真人打字：一小串快按 + 偶尔停一下，不是机械节拍。

  操作：窗口上三个按钮；关窗口 = 缩到托盘（不是退出）
        托盘图标双击 = 打开窗口
        托盘右键 = 显示 / 暂停 / 退出
  ============================================================
#>

$ErrorActionPreference = 'Stop'

# ======================== 可调参数 ==========================
$VirtualKey  = 0x87    # F24。普通键盘没有这个键，其他软件不响应
$IdleGateMs  = 700     # 你手停下多少毫秒后，才认定“人离开了”，开始补计数
$PollMs      = 15      # 内部检查节律（毫秒），别调大
# ---- 发送节奏：模拟真人“打一串、停一下” ----
$BurstMinMs  = 40      # 连发时最快间隔
$BurstMaxMs  = 120     # 连发时最慢间隔
$RestChance  = 0.10    # 每次按完，有这个概率进入“停顿”
$RestMinMs   = 350     # 停顿长度（短）
$RestMaxMs   = 800     # 停顿长度（长）
$PauseOnGame = $true   # 下列进程在前台时自动暂停
$GameKeywords = @('wuthering', 'client-win64', 'launcher', 'kuro', 'deltaforce')
# 满箱提醒由独立的“宝箱计时器”负责，这里不做提醒
# ============================================================

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

try {

Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;

public static class Native
{
    [StructLayout(LayoutKind.Sequential)]
    public struct INPUT { public uint type; public InputUnion U; }

    [StructLayout(LayoutKind.Explicit)]
    public struct InputUnion
    {
        [FieldOffset(0)] public MOUSEINPUT mi;
        [FieldOffset(0)] public KEYBDINPUT ki;
        [FieldOffset(0)] public HARDWAREINPUT hi;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct MOUSEINPUT {
        public int dx; public int dy; public uint mouseData;
        public uint dwFlags; public uint time; public IntPtr dwExtraInfo;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct KEYBDINPUT {
        public ushort wVk; public ushort wScan;
        public uint dwFlags; public uint time; public IntPtr dwExtraInfo;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct HARDWAREINPUT {
        public uint uMsg; public ushort wParamL; public ushort wParamH;
    }

    [DllImport("user32.dll", SetLastError = true)]
    public static extern uint SendInput(uint nInputs, INPUT[] pInputs, int cbSize);

    [DllImport("user32.dll")]
    public static extern short GetAsyncKeyState(int vKey);

    [DllImport("user32.dll")]
    public static extern IntPtr GetForegroundWindow();

    [DllImport("user32.dll")]
    public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint lpdwProcessId);

    [DllImport("user32.dll")]
    public static extern bool SetProcessDPIAware();

    [StructLayout(LayoutKind.Sequential)]
    public struct LASTINPUTINFO { public uint cbSize; public uint dwTime; }

    [DllImport("user32.dll")]
    public static extern bool GetLastInputInfo(ref LASTINPUTINFO plii);

    // 返回“全系统最后一次键鼠输入”的时间戳（GetTickCount 基准）
    // 用它判断：最后这次输入，是用户按的，还是我们自己注入的
    public static uint LastInputTick()
    {
        LASTINPUTINFO li = new LASTINPUTINFO();
        li.cbSize = (uint)Marshal.SizeOf(typeof(LASTINPUTINFO));
        if (!GetLastInputInfo(ref li)) { return 0; }
        return li.dwTime;
    }

    public static uint NowTick() { return unchecked((uint)Environment.TickCount); }

    public static bool TapKey(ushort vk)
    {
        INPUT[] seq = new INPUT[2];
        seq[0].type = 1; seq[0].U.ki.wVk = vk; seq[0].U.ki.dwFlags = 0;
        seq[1].type = 1; seq[1].U.ki.wVk = vk; seq[1].U.ki.dwFlags = 2;
        return SendInput(2, seq, Marshal.SizeOf(typeof(INPUT))) == 2;
    }
}
"@ -ErrorAction Stop

[void][Native]::SetProcessDPIAware()

# ---- 状态（事件里读写统一带 $script:）----
$script:sent       = 0
$script:paused     = $false
$script:blocked    = $false
$script:reallyExit = $false
$script:startTime  = Get-Date
$script:rand       = New-Object System.Random
$script:fgName     = ''
$script:ti         = 0
$script:lastState  = ''
$script:yielding   = $false
$script:lastSeen    = [uint32]0     # 上次观测到的“最后输入”时间戳
$script:lastSentTick= [uint32]0     # 上次我们注入的时刻
$script:userActiveAt= Get-Date      # 用户最后一次真实操作的时间
$script:nextSendAt  = Get-Date
$script:recentSends = New-Object System.Collections.Generic.List[datetime]

function Get-ForegroundName {
    $h = [Native]::GetForegroundWindow()
    if ($h -eq [IntPtr]::Zero) { return '(无窗口)' }
    $procId = [uint32]0
    [void][Native]::GetWindowThreadProcessId($h, [ref]$procId)
    if ($procId -eq 0) { return '(未知)' }
    try { return (Get-Process -Id $procId -ErrorAction Stop).ProcessName }
    catch { return '(读不到)' }
}

# ---- 配色 ----
$cBg     = [System.Drawing.Color]::FromArgb(28, 28, 32)
$cPanel  = [System.Drawing.Color]::FromArgb(44, 44, 51)
$cText   = [System.Drawing.Color]::FromArgb(232, 232, 238)
$cDim    = [System.Drawing.Color]::FromArgb(138, 138, 150)
$cAccent = [System.Drawing.Color]::FromArgb(255, 200, 96)
$cGreen  = [System.Drawing.Color]::FromArgb(96, 208, 128)
$cYellow = [System.Drawing.Color]::FromArgb(240, 196, 88)
$cGray   = [System.Drawing.Color]::FromArgb(150, 150, 158)

[void][System.Windows.Forms.Application]::EnableVisualStyles()

$form = New-Object System.Windows.Forms.Form
$form.Text            = 'Wuwa Tappo 计数助手'
$form.ClientSize      = [System.Drawing.Size]::new(384, 262)
$form.StartPosition   = 'CenterScreen'
$form.FormBorderStyle = 'FixedSingle'
$form.MaximizeBox     = $false
$form.BackColor       = $cBg
$form.Font            = [System.Drawing.Font]::new('Microsoft YaHei UI', [float]9)

function New-Label($text, $x, $y, $size, $color, $bold) {
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $text
    $l.Location = [System.Drawing.Point]::new($x, $y)
    $l.AutoSize = $true
    if ($bold) { $style = [System.Drawing.FontStyle]::Bold } else { $style = [System.Drawing.FontStyle]::Regular }
    $l.Font = [System.Drawing.Font]::new('Microsoft YaHei UI', [float]$size, $style)
    $l.ForeColor = $color
    [void]$form.Controls.Add($l)
    return $l
}

$lblTitle  = New-Label 'Wuwa Tappo 计数助手' 22 16 10.5 $cText $true
$lblStatus = New-Label '● 正在启动…' 22 47 9.5 $cGray $false
$lblBig    = New-Label '0' 18 70 28 $cAccent $true
$lblBig.Font = [System.Drawing.Font]::new('Segoe UI', [float]28, [System.Drawing.FontStyle]::Bold)
$lblInfo   = New-Label '累计发送 0 次' 24 130 8.5 $cDim $false
$lblTime   = New-Label '已运行 00:00:00' 24 152 8.5 $cDim $false

function New-Btn($text, $x, $w) {
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $text
    $b.Location = [System.Drawing.Point]::new($x, 200)
    $b.Size = [System.Drawing.Size]::new($w, 34)
    $b.FlatStyle = 'Flat'
    $b.BackColor = $cPanel
    $b.ForeColor = $cText
    $b.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(74, 74, 84)
    $b.FlatAppearance.BorderSize = 1
    $b.Font = [System.Drawing.Font]::new('Microsoft YaHei UI', [float]9)
    $b.Cursor = [System.Windows.Forms.Cursors]::Hand
    [void]$form.Controls.Add($b)
    return $b
}

$btnPause = New-Btn '暂停' 22 100
$btnHide  = New-Btn '隐藏到托盘' 132 120
$btnExit  = New-Btn '退出' 262 100

# ---- 托盘图标 ----
$notify = New-Object System.Windows.Forms.NotifyIcon
$notify.Icon    = [System.Drawing.SystemIcons]::Application
$notify.Text    = 'Wuwa Tappo 计数助手'
$notify.Visible = $true

$menu = New-Object System.Windows.Forms.ContextMenuStrip
$miShow = New-Object System.Windows.Forms.ToolStripMenuItem
$miShow.Text = '显示窗口'
$miPause = New-Object System.Windows.Forms.ToolStripMenuItem
$miPause.Text = '暂停'
$miSep = New-Object System.Windows.Forms.ToolStripSeparator
$miExit = New-Object System.Windows.Forms.ToolStripMenuItem
$miExit.Text = '退出'
[void]$menu.Items.Add($miShow)
[void]$menu.Items.Add($miPause)
[void]$menu.Items.Add($miSep)
[void]$menu.Items.Add($miExit)
$notify.ContextMenuStrip = $menu

# ---- 动作 ----
function Show-Window {
    $form.Show()
    $form.WindowState = [System.Windows.Forms.FormWindowState]::Normal
    [void]$form.Activate()
}

function Hide-ToTray {
    $form.Hide()
    $notify.ShowBalloonTip(1500, '仍在后台运行', '助手已缩到托盘，双击图标可以打开。', [System.Windows.Forms.ToolTipIcon]::Info)
}

function Toggle-Pause {
    $script:paused = -not $script:paused
    if ($script:paused) {
        $btnPause.Text = '继续'
        $miPause.Text  = '继续'
    } else {
        $btnPause.Text = '暂停'
        $miPause.Text  = '暂停'
    }
}

function Exit-App {
    $script:reallyExit = $true
    $sendTimer.Stop()
    $uiTimer.Stop()
    $notify.Visible = $false
    $notify.Dispose()
    [System.Windows.Forms.Application]::Exit()
}

# ---- 发键计时器 ----
# 核心思路：区分“最后这次输入是谁打的”。
#   - 我们自己注入的键，时间戳会等于 lastSentTick（误差几十毫秒内）
#   - 你一按键，时间戳就跳到更晚，一眼就能认出来 → 立刻停火
# 所以你打字时它是完全不发的；你一停手，它马上接着跑。
$sendTimer = New-Object System.Windows.Forms.Timer
$sendTimer.Interval = $PollMs
$sendTimer.Add_Tick({
    if ($script:reallyExit) { return }
    if ($script:paused -or $script:blocked) { return }

    $now = Get-Date
    $li  = [Native]::LastInputTick()

    if ($li -ne $script:lastSeen) {
        $d = [int64]$li - [int64]$script:lastSentTick
        if ($d -lt 0) { $d += 4294967296 }
        # 只认“比我自己那一下晚了 40ms 以上、且不是天文数字”的变化，才算你的操作
        # 上限 10000ms 是为了躲开时间戳回绕造成的假信号
        if ($d -gt 40 -and $d -lt 10000) { $script:userActiveAt = $now }
        $script:lastSeen = $li
    }

    if (($now - $script:userActiveAt).TotalMilliseconds -lt $IdleGateMs) {
        $script:yielding = $true
        return
    }
    $script:yielding = $false

    if ($now -lt $script:nextSendAt) { return }

    if ([Native]::TapKey([uint16]$VirtualKey)) {
        $script:sent++
        $script:lastSentTick = [Native]::NowTick()
        $script:lastSeen     = [Native]::LastInputTick()
        $script:recentSends.Add($now)
        if ($script:recentSends.Count -gt 60) { $script:recentSends.RemoveAt(0) }
    }

    # 节奏：一小串快按，偶尔停一下（像真人手速，不像机器节拍）
    $iv = $script:rand.Next($BurstMinMs, $BurstMaxMs + 1)
    if ($script:rand.NextDouble() -lt $RestChance) {
        $iv = $script:rand.Next($RestMinMs, $RestMaxMs + 1)
    }
    $script:nextSendAt = $now.AddMilliseconds($iv)
})

# ---- 界面 / 热键计时器 ----
$uiTimer = New-Object System.Windows.Forms.Timer
$uiTimer.Interval = 300
$uiTimer.Add_Tick({
    if ($script:reallyExit) { return }

    # 每约 1.8 秒看一眼前台窗口
    $script:ti++
    if ((($script:ti % 6) -eq 0) -and $PauseOnGame) {
        $script:fgName = Get-ForegroundName
        $script:blocked = $false
        foreach ($kw in $GameKeywords) {
            if ($script:fgName -like "*$kw*") { $script:blocked = $true; break }
        }
    }

    # 刷新面板
    $sentText = '{0:N0}' -f $script:sent
    $lblBig.Text = $sentText
    $box = [math]::Floor($script:sent / 1000)
    $rate = 0.0
    if ($script:recentSends.Count -ge 3) {
        $spanSec = ($script:recentSends[$script:recentSends.Count-1] - $script:recentSends[0]).TotalSeconds
        if ($spanSec -gt 0.5) { $rate = [math]::Round(($script:recentSends.Count - 1) / $spanSec, 1) }
    }
    $lblInfo.Text = "累计 $sentText 次 · 当前 $rate 次/秒 · 折合 $box 个箱子"

    $span = (Get-Date) - $script:startTime
    $lblTime.Text = '已运行 {0:00}:{1:00}:{2:00}' -f [int]$span.TotalHours, $span.Minutes, $span.Seconds

    # 状态展示
    if ($script:paused) {
        $lblStatus.Text = '● 已暂停（点“继续”恢复）'
        $lblStatus.ForeColor = $cGray
        $st = 'paused'
    }
    elseif ($script:blocked) {
        $nm = $script:fgName
        if ($nm.Length -gt 16) { $nm = $nm.Substring(0, 16) + '…' }
        $lblStatus.Text = "● 游戏在前台，自动暂停（$nm）"
        $lblStatus.ForeColor = $cYellow
        $st = 'blocked'
    }
    elseif ($script:yielding) {
        $lblStatus.Text = '● 你正在操作，助手让路中'
        $lblStatus.ForeColor = $cGray
        $st = 'yield'
    }
    else {
        $lblStatus.Text = '● 补计数中'
        $lblStatus.ForeColor = $cGreen
        $st = 'run'
    }

    if ($st -ne $script:lastState) {
        $script:lastState = $st
        if ($st -eq 'run') {
            $notify.Icon = [System.Drawing.SystemIcons]::Application
            $notify.Text = '计数助手 · 补计数中'
        }
        elseif ($st -eq 'yield') {
            $notify.Icon = [System.Drawing.SystemIcons]::Application
            $notify.Text = '计数助手 · 你在操作，让路中'
        }
        else {
            $notify.Icon = [System.Drawing.SystemIcons]::Warning
            if ($st -eq 'paused') { $notify.Text = '计数助手 · 已暂停' }
            else { $notify.Text = '计数助手 · 游戏在前台，已暂停' }
        }
    }
})

# ---- 事件绑定 ----
$btnPause.Add_Click({ Toggle-Pause })
$btnHide.Add_Click({ Hide-ToTray })
$btnExit.Add_Click({ Exit-App })
$miShow.Add_Click({ Show-Window })
$miPause.Add_Click({ Toggle-Pause })
$miExit.Add_Click({ Exit-App })
$notify.Add_DoubleClick({ Show-Window })

$form.Add_Resize({
    if ($form.WindowState -eq [System.Windows.Forms.FormWindowState]::Minimized) { $form.Hide() }
})

$form.Add_FormClosing({
    param($s, $e)
    if (($e.CloseReason -eq [System.Windows.Forms.CloseReason]::UserClosing) -and (-not $script:reallyExit)) {
        $e.Cancel = $true
        Hide-ToTray
    }
})

# ---- 起飞 ----
$script:startTime = Get-Date
$sendTimer.Start()
$uiTimer.Start()
[void][System.Windows.Forms.Application]::Run($form)

}
catch {
    $msg = "启动失败：`r`n`r`n" + $_.Exception.Message + "`r`n`r`n" + $_.ScriptStackTrace
    [void][System.Windows.Forms.MessageBox]::Show($msg, 'Wuwa Tappo 计数助手', 'OK', 'Error')
}
