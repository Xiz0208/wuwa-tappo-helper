<#
  ============================================================
  Wuwa Tappo 宝箱计时器
  ------------------------------------------------------------
  为什么单独做一个：计数助手只知道“我发了多少次键”，
  它不知道你什么时候开了箱，所以提醒必然错位。
  这个程序只盯宝箱本身，和软件的 30 分钟规则对齐。

  规则（已实测确认）：
    · 【双槽独立】两个槽位各自跑一个 30 分钟倒计时，互不影响
    · 某个槽位倒计时走完 → 该槽位出现 1 个宝箱，这个槽位停表
    · 槽位有箱子就不再产，领走一个 → 那个槽位重新从 0 开始 30 分钟
    · 关掉桌宠 / 关机 / 睡眠，计时【照常走】（实测确认）
    所以两个倒计时会不一样长，这是正常的，不是 bug。

  为什么双槽反而更好算：
    每次开箱只影响“一个”槽位。而你要开的那个箱子，一定是等得最久的那个。
    于是「点了箱子 → 把最早出现的那个槽位重置为现在」是唯一解，不用问你、也不用猜。

  它怎么知道你开了箱（时刻精确到秒，不用你输任何数字）：
    0) 推荐：点「定位宝箱」→ 15 秒内去点一下宝箱。位置就锁定了，
       以后你点到宝箱附近（半径 80px）+ 快速点击，自动记时，零操作。
       拖着桌宠换位置后，再点一次「定位宝箱」即可。
       保险：按住拖动 / 松开前挪动大 / 桌宠没开 / 点到自己窗口，都不会误判。
       再保险：只有“已有箱子 / 剩余 ≤5 分钟 / 还没对表”时才认点击——
       所以你在计时中途进桌宠设置、手滑点到宝箱附近，不会被记成开箱。
       万一还是误记了：按 Ctrl+Alt+Z（或点「撤销上一次」）原样还原。
    1) 兜底：开完箱子按 Ctrl+Alt+B（任何窗口下都行）。日常两个箱子一起领，
       它会把“有箱子”的槽位全部重新计时；只开了一个也不会误伤另一个。
    2) 或者点界面上的「开了两个」「只开一个」，托盘右键菜单里也有
    3) 倒计时和桌宠对不齐的时候（不管偏差怎么来的）：点「对表」，
       照着桌宠上显示的“还剩几分钟”各填一个数，两边立刻完全一致。
       这是最终的裁判，比任何推算都准。
    4) 想让箱子满了推送到微信：点「提醒设置」粘一个地址

  不注入进程 / 不改内存 / 不读桌宠的存档文件 / 不发任何按键。
  只读取“鼠标位置 + 左键和热键的按键状态 + 前台进程名”，零侵入。
  唯一可选联网：宝箱满了时推送到手机（$PushUrl 填了才发）。
  ============================================================
#>

param(
    # 开机自启时传这个，启动后直接缩到托盘，不弹窗打扰
    [switch]$Minimized
)

$ErrorActionPreference = 'Stop'

# ======================== 可调参数 ==========================
$ChestIntervalMin = 30      # 官方规则，别改
$MaxChests        = 2       # 官方规则，别改
# 计时模型版本。4 = 双槽独立 + 点击对表（当前）。
# 老版本的状态文件没有这个字段，读到就会带你重新对一次表。
$StateModel       = 4
$TickMs           = 100     # 内部检测节律
$GameKeywords     = @('wuthering', 'client-win64', 'launcher', 'kuro', 'deltaforce')
$HotkeyEnabled    = $true   # Ctrl+Alt+B = 记一次开箱（任何时候都能按）
# 定点自动记时：点「定位宝箱」锁定宝箱位置后，点到那个位置附近就自动记时，
# 不用再按热键/点按钮。桌宠挪了位置就再点一次「定位宝箱」。
$AutoDetect       = $true
$ChestRadiusPx    = 80      # 判定半径（像素）：离锁定点多远以内算“点了宝箱”
$ClickMaxMs       = 600     # 按下到松开超过这么久 = 按住拖桌宠，不算开箱
$ClickMaxMovePx   = 15      # 按下到松开挪动超过这么多 = 拖动，不算开箱

# ---- 桌宠挪位置后，宝箱点自动跟着走 ----
# 桌宠的窗口是一层铺满屏幕的透明层（2560x1440），你拖动角色时窗口矩形根本不变，
# 所以从窗口层面看不出“它被挪了”。但它自己会把角色位置存进 localStorage，
# 形如  {"x":{"ratio":1,"maxEdge":true},"y":{"ratio":0.828...}}  —— ratio 是相对屏幕的比例。
# 定位宝箱时把当时的 ratio 记下来当锚点，之后 ratio 一变就知道角色挪了多少像素，
# 宝箱点按同样的位移平移，你就不用重新定位了。
$PetFollowOn      = $true   # 关掉的话就只提醒、不自动调坐标
$PetMoveTolPx     = 4       # 位移小于这么多像素当作抖动，不处理
$PetCheckEvery    = 30      # 每多少拍（100ms/拍）查一次角色位置 = 3 秒
$PetNoticeGapSec  = 8       # 两次“桌宠挪了”的提示之间至少隔这么久
# 自动记时只在“两个槽位都满了”的时候才认点击：
# 只有这一刻你才可能是在开箱。计时走在半路上时点桌宠设置、手滑点到宝箱附近，
# 一律不记时 —— 所以只认这一种状态，最稳，也不会误记。
# 托盘图标：常驻显示（双击打开、右键有菜单）。缩到托盘后一定能找回来。
$EnableSound      = $true   # 提醒时响一下系统提示音
# 点击诊断日志：只有“点在宝箱附近、但那一下没落到桌宠窗口上”时才会写。
$ClickDiagFile    = Join-Path $PSScriptRoot '点击诊断.log'
$PushUrl          = ''      # 推送地址。建议用界面上的「提醒设置」填，存在 push-url.txt
$StateFile        = Join-Path $PSScriptRoot 'box-state.json'
$PushFile         = Join-Path $PSScriptRoot 'push-url.txt'
if (Test-Path $PushFile) {
    # 「提醒设置」里保存的地址优先
    try {
        $u = (Get-Content $PushFile -Raw -Encoding UTF8).Trim()
        if ($u) { $PushUrl = $u }
    } catch { }
}
# ============================================================

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

try {

Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;

public static class BoxNative
{
    [StructLayout(LayoutKind.Sequential)]
    public struct POINT { public int X, Y; }

    [DllImport("user32.dll")]
    public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")]
    public static extern short GetAsyncKeyState(int vk);
    [DllImport("user32.dll")]
    public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")]
    public static extern bool SetProcessDPIAware();
    [DllImport("user32.dll")]
    public static extern bool GetCursorPos(out POINT p);

    public static int ForegroundPid()
    {
        IntPtr h = GetForegroundWindow();
        uint p;
        GetWindowThreadProcessId(h, out p);
        return (int)p;
    }
}
"@ -ErrorAction Stop

[void][BoxNative]::SetProcessDPIAware()

# ---- 附加能力：看“某个屏幕坐标上盖着的是哪个窗口” ----
# 只为回答一个问题：你点宝箱的那一下，到底落到了桌宠身上，还是被别的窗口吃掉了。
# 单独放在 try/catch 里：万一这段没编译成功，计时照常跑，只是少了这条诊断。
$script:hitReady = $false
try {
    Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public class BoxHit {
    [DllImport("user32.dll")] public static extern IntPtr WindowFromPoint(POINT p);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    public struct POINT { public int X; public int Y; }
    public static int PidAt(int x, int y) {
        POINT p; p.X = x; p.Y = y;
        IntPtr h = WindowFromPoint(p);
        if (h == IntPtr.Zero) { return 0; }
        uint pid; GetWindowThreadProcessId(h, out pid);
        return (int)pid;
    }
}
"@ -ErrorAction Stop
    $script:hitReady = $true
} catch { }

# ---- 只允许跑一个 ----
# 双击两次、或者开机自启和你手动开撞在一起，就会出现两个实例：
# 两个都在提醒、两个都在写存档，很乱。这里用系统互斥量把第二个挡掉。
$script:mutex = $null
try {
    $script:mutex = New-Object System.Threading.Mutex($false, 'Local\WuwaBoxTimerSingle')
    if (-not $script:mutex.WaitOne(0)) {
        if (-not $Minimized) {
            try { [void][System.Windows.Forms.MessageBox]::Show('宝箱计时器已经在运行了，看右下角的托盘图标。', '宝箱计时', 'OK', 'Information') } catch { }
        }
        exit
    }
} catch { }

# ---- 配色 ----
$cBg     = [System.Drawing.Color]::FromArgb(28, 28, 32)
$cPanel  = [System.Drawing.Color]::FromArgb(44, 44, 51)
$cText   = [System.Drawing.Color]::FromArgb(232, 232, 238)
$cDim    = [System.Drawing.Color]::FromArgb(138, 138, 150)
$cAccent = [System.Drawing.Color]::FromArgb(255, 200, 96)
$cGreen  = [System.Drawing.Color]::FromArgb(96, 208, 128)
$cRed    = [System.Drawing.Color]::FromArgb(232, 108, 108)
$cEmpty  = [System.Drawing.Color]::FromArgb(72, 72, 82)

# ---- 状态 ----
# 两个槽位，各自独立：
#   start   = 这个槽位本轮计时的起点（空槽位就是“从什么时候开始攒下一个”）
#   full    = 这个槽位已经有箱子了（停表，等你来领）
#   unknown = 还一次都没对上表（不知道它现在攒了多久），等你点一次箱子/按一次热键
$script:slots = @(
    [pscustomobject]@{ start = (Get-Date); full = $false; unknown = $true; lastM = $null },
    [pscustomobject]@{ start = (Get-Date); full = $false; unknown = $true; lastM = $null }
)
$script:chests      = 0       # 由 slots 推出来的“手上有几个箱子”
$script:totalOpened = 0
$script:tappoRun    = $false
$script:gameFg      = $false
$script:fgName      = ''
$script:pending     = $false
$script:reallyExit  = $false
$script:btnPrev     = $false
$script:hkPrev      = $false
$script:hkAt        = [datetime]::MinValue
$script:tickNo      = 0
$script:needCalib   = $false  # 从旧模型升级上来的，带你重新对一次表
# 定点自动记时
$script:chestX      = -1      # 锁定的宝箱位置；-1 = 还没定位
$script:chestY      = -1
$script:locateUntil = [datetime]::MinValue
$script:downX       = 0       # 鼠标按下那一刻的位置/时间（判定快速点击用）
$script:downY       = 0
$script:downAt      = [datetime]::MinValue
# 撤销：每次记时之前先把两个槽位的样子存一份，万一被误记（比如点设置时手滑），
# 按一下 Ctrl+Alt+Z 就能原样还原。只留最近一步。
$script:undoSnap    = $null
$script:hkZPrev     = $false
$script:hkZAt       = [datetime]::MinValue
$script:fullIcon    = $false                  # 托盘图标当前是不是“满”的样子
$script:coordReset  = $false                  # 换了屏幕/分辨率导致宝箱坐标作废
# 桌宠角色位置的锚点（定位宝箱那一刻的样子），用来算“它挪了多少”
$script:petAX       = $null    # x.ratio；$null = 还没有锚点
$script:petAY       = $null    # y.ratio
$script:petAEdge    = ''       # 横向状态：'right' / 'left' / 'free'
$script:petMovedAt  = [datetime]::MinValue   # 上次提示“挪了位置”的时间（限流）

function Get-ChestCount {
    $n = 0
    foreach ($s in $script:slots) { if ($s.full) { $n = $n + 1 } }
    return $n
}

# ---- 读上次状态 ----
if (Test-Path $StateFile) {
    try {
        $o = Get-Content $StateFile -Raw -Encoding UTF8 | ConvertFrom-Json
        $script:totalOpened = [int]$o.totalOpened

        $oldModel = 0
        if ($null -ne $o.model) { $oldModel = [int]$o.model }

        if ($oldModel -ge 3 -and $null -ne $o.slots -and @($o.slots).Count -ge 2) {
            # 当前格式：两个槽位各自读回来
            $i = 0
            foreach ($so in $o.slots) {
                if ($i -ge 2) { break }
                $script:slots[$i].start = [datetime]::Parse([string]$so.start, [System.Globalization.CultureInfo]::InvariantCulture)
                $script:slots[$i].full  = [bool]$so.full
                # 老状态文件（model 3）没有 unknown 字段：当时是按推算走过来的，算“已知”
                if ($null -ne $so.unknown) { $script:slots[$i].unknown = [bool]$so.unknown }
                else                       { $script:slots[$i].unknown = $false }
                $i = $i + 1
            }
            if ($oldModel -lt 4) { $script:needCalib = $true }
        }
        # 锁定的宝箱位置（老存档没有这两个字段 = 没定位过）
        if ($null -ne $o.chestX -and $null -ne $o.chestY) {
            $script:chestX = [int]$o.chestX
            $script:chestY = [int]$o.chestY
            # 定位那一刻桌宠角色的位置（老存档没有 = 下次查到就补记，不据此平移）
            if ($null -ne $o.petAX -and $null -ne $o.petAY) {
                $script:petAX    = [double]$o.petAX
                $script:petAY    = [double]$o.petAY
                if ($null -ne $o.petAEdge) { $script:petAEdge = [string]$o.petAEdge }
            }
        }
        else {
            # 旧格式（单一计时器）：只能粗转一下，然后带你重新对表。
            $oldChests = [int]$o.chests
            $oldStart  = Get-Date
            if ($o.timerStart) { $oldStart = [datetime]::Parse([string]$o.timerStart, [System.Globalization.CultureInfo]::InvariantCulture) }
            if ($oldChests -ge 2) {
                $script:slots[0].start = $oldStart; $script:slots[0].full = $true;  $script:slots[0].unknown = $false
                $script:slots[1].start = $oldStart; $script:slots[1].full = $true;  $script:slots[1].unknown = $false
            }
            elseif ($oldChests -eq 1) {
                $script:slots[0].start = $oldStart; $script:slots[0].full = $true;  $script:slots[0].unknown = $false
                $script:slots[1].start = Get-Date;  $script:slots[1].full = $false; $script:slots[1].unknown = $true
            }
            else {
                $script:slots[0].start = $oldStart; $script:slots[0].full = $false; $script:slots[0].unknown = $false
                $script:slots[1].start = Get-Date;  $script:slots[1].full = $false; $script:slots[1].unknown = $true
            }
            $script:needCalib = $true
        }
    } catch { }
}

$script:chests = Get-ChestCount

# 启动时如果两个槽位都是满的，补一次提醒 —— 否则重启或开机自启后
# 用户可能一直没被提醒过。只在确实积压了一阵（最早那个停了 20 分钟以上）时才补，
# 避免反复重启程序时反复弹气泡。
if ($script:chests -ge $MaxChests) {
    $oldest = $null
    foreach ($s in $script:slots) {
        if (-not $s.full) { continue }
        if ($null -eq $oldest -or $s.start -lt $oldest) { $oldest = $s.start }
    }
    if ($null -ne $oldest -and ((Get-Date) - $oldest).TotalMinutes -ge 20) { $script:pending = $true }
}


# ---- 开机自启自愈 ----
# 启动文件夹里那个 bat 写的是绝对路径（Windows 的自启项只认绝对路径，没法写相对路径）。
# 所以你把整个文件夹挪了位置、或者换台电脑解压到别的目录，它就指向旧地方了。
# 这里每次启动对一下：只要那个 bat 还在、但指向的不是现在这个路径，就按现在的位置重写。
# 效果：挪完文件夹手动打开一次，自启就自动修好了，不用重新点「安装开机自启」。
function Repair-Autostart {
    try {
        $startup = [Environment]::GetFolderPath('Startup')
        if (-not $startup) { return }
        $bat = Join-Path $startup 'WuwaBoxTimer.bat'
        if (-not (Test-Path $bat)) { return }              # 本来就没装自启，不擅自装
        $now = Join-Path $PSScriptRoot 'WuwaBoxTimer.ps1'
        $txt = Get-Content $bat -Raw -ErrorAction SilentlyContinue
        if ($null -eq $txt) { return }
        if ($txt -like "*$now*") { return }                # 已经指对了
        if ($txt -notlike '*WuwaBoxTimer.ps1*') { return } # 不是我们的文件，不碰
        $line = '@echo off' + "`r`n" +
                'start "" powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' +
                $now + '" -Minimized' + "`r`n"
        Set-Content -Path $bat -Value $line -Encoding Default
    } catch { }
}
Repair-Autostart

function Save-State {
    try {
        [ordered]@{
            model       = $StateModel
            slots       = @($script:slots | ForEach-Object { [ordered]@{ start = $_.start.ToString('o'); full = $_.full; unknown = $_.unknown } })
            chestX      = $script:chestX
            chestY      = $script:chestY
            petAX       = $script:petAX
            petAY       = $script:petAY
            petAEdge    = $script:petAEdge
            totalOpened = $script:totalOpened
            savedAt     = (Get-Date).ToString('o')
        } | ConvertTo-Json -Depth 4 | Set-Content -Path $StateFile -Encoding UTF8
    } catch { }
}

# ---- 推送（可选）----
# Invoke-Push 返回 @{ ok = $true/$false; msg = '给人看的一句话' }。
# 这样「提醒设置」里能直接显示服务端到底回了什么，而不是笼统的“发送失败”。
function Invoke-Push {
    param([string]$title, [string]$body)
    if ([string]::IsNullOrWhiteSpace($PushUrl)) {
        return [pscustomobject]@{ ok = $false; msg = '还没有填推送地址。' }
    }
    try {
        if ($PushUrl -match 'qyapi\.weixin\.qq\.com') {
            $json = @{ msgtype = 'text'; text = @{ content = "$title`n$body" } } | ConvertTo-Json -Depth 5
            $r = Invoke-RestMethod -Uri $PushUrl -Method Post -Body $json -ContentType 'application/json' -TimeoutSec 10
            if ($null -ne $r.errcode -and [int]$r.errcode -ne 0) {
                return [pscustomobject]@{ ok = $false; msg = "企业微信返回 errcode=$($r.errcode)：$($r.errmsg)" }
            }
        }
        elseif ($PushUrl -match 'sctapi\.ftqq\.com|push\.ft07\.com') {
            # Server酱 Turbo（sctapi.ftqq.com）和 Server酱³（xxx.push.ft07.com）都是 GET 带参数
            $sep = '?'
            if ($PushUrl -match '\?') { $sep = '&' }
            $u = $PushUrl + $sep + 'title=' + [uri]::EscapeDataString($title) + '&desp=' + [uri]::EscapeDataString($body)
            $r = Invoke-RestMethod -Uri $u -TimeoutSec 12
            if ($null -ne $r.code -and [int]$r.code -ne 0) {
                return [pscustomobject]@{ ok = $false; msg = "Server酱返回 code=$($r.code)：$($r.message)" }
            }
        }
        else {
            $json = @{ title = $title; content = $body } | ConvertTo-Json -Depth 5
            Invoke-RestMethod -Uri $PushUrl -Method Post -Body $json -ContentType 'application/json' -TimeoutSec 10 | Out-Null
        }
        return [pscustomobject]@{ ok = $true; msg = '已发出。' }
    } catch {
        # 失败时服务端其实会用 400 回一段 JSON（比如 code=40001 错误的Key），
        # 但 PowerShell 会先抛异常把它藏起来。这里把响应体挖出来，好让你看到真正的原因。
        $detail = $_.Exception.Message
        $raw = ''
        try { if ($null -ne $_.ErrorDetails -and $_.ErrorDetails.Message) { $raw = [string]$_.ErrorDetails.Message } } catch { }
        if (-not $raw) {
            try {
                $resp = $_.Exception.Response
                if ($null -ne $resp) {
                    $sr = New-Object System.IO.StreamReader($resp.GetResponseStream())
                    $raw = $sr.ReadToEnd()
                    $sr.Close()
                }
            } catch { }
        }
        if ($raw) {
            $j = $null
            try { $j = $raw | ConvertFrom-Json } catch { }
            if ($null -ne $j -and $null -ne $j.code)       { $detail = "code=$($j.code) $($j.message)" }
            elseif ($null -ne $j -and $null -ne $j.errmsg) { $detail = "errcode=$($j.errcode) $($j.errmsg)" }
            else { $detail = $raw.Trim() }
        }
        return [pscustomobject]@{ ok = $false; msg = $detail }
    }
}

# 老接口：只要成功/失败
function Send-Push {
    param([string]$title, [string]$body)
    return (Invoke-Push -title $title -body $body).ok
}

# ======================== 界面 ==========================
[void][System.Windows.Forms.Application]::EnableVisualStyles()

# ---- 换了显示器 / 改过分辨率：老的宝箱坐标可能已经不在屏幕上了 ----
# 不处理的话你点箱子会一直没反应，还找不到原因。坐标越界就当作“没定位过”。
if ($script:chestX -ge 0) {
    try {
        $vs = [System.Windows.Forms.SystemInformation]::VirtualScreen
        if ($script:chestX -lt $vs.Left -or $script:chestX -gt $vs.Right -or
            $script:chestY -lt $vs.Top  -or $script:chestY -gt $vs.Bottom) {
            $script:chestX = -1
            $script:chestY = -1
            $script:coordReset = $true
        }
    } catch { }
}

$form = New-Object System.Windows.Forms.Form
$form.Text            = 'Wuwa Tappo 宝箱计时'
$form.ClientSize      = [System.Drawing.Size]::new(416, 378)
$form.StartPosition   = 'CenterScreen'
$form.FormBorderStyle = 'FixedSingle'
$form.MaximizeBox     = $false
$form.BackColor       = $cBg
$form.Font            = [System.Drawing.Font]::new('Microsoft YaHei UI', [float]9)

# 版式说明（改坐标前先看这里，免得又把字压在一起）：
#   槽位块高 66px：倒计时（18pt，约 32px 高）→ 空 6px → 说明行（8.5pt，约 16px 高）
#   说明行放在倒计时下面单独一行，不再和数字挤在同一高度。
function New-Label($text, $x, $y, $size, $color, $bold) {
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $text
    $l.Location = [System.Drawing.Point]::new($x, $y)
    $l.AutoSize = $true
    if ($bold) { $l.Font = [System.Drawing.Font]::new('Microsoft YaHei UI', [float]$size, [System.Drawing.FontStyle]::Bold) }
    else       { $l.Font = [System.Drawing.Font]::new('Microsoft YaHei UI', [float]$size) }
    $l.ForeColor = $color
    $l.BackColor = [System.Drawing.Color]::Transparent
    [void]$form.Controls.Add($l)
    return $l
}

# 进度条：深色底、细条，放在右边，和倒计时错开高度，不压任何文字
function New-Bar($x, $y, $w) {
    $b = New-Object System.Windows.Forms.ProgressBar
    $b.Location = [System.Drawing.Point]::new($x, $y)
    $b.Size     = [System.Drawing.Size]::new($w, 8)
    $b.Minimum  = 0
    $b.Maximum  = 100
    $b.Value    = 0
    [void]$form.Controls.Add($b)
    return $b
}

$lblTitle = New-Label '宝箱计时' 24 12 12 $cText $true

$lblTotal = New-Object System.Windows.Forms.Label
$lblTotal.Text      = '累计已开 0 个'
$lblTotal.AutoSize  = $false
$lblTotal.SetBounds(230, 14, 162, 22)
$lblTotal.TextAlign = 'MiddleRight'
$lblTotal.Font      = [System.Drawing.Font]::new('Microsoft YaHei UI', [float]8.5)
$lblTotal.ForeColor = $cDim
$lblTotal.BackColor = [System.Drawing.Color]::Transparent
[void]$form.Controls.Add($lblTotal)

# —— 槽位 1 ——
$lblS1 = New-Label '◆' 24 50 13 $cEmpty $false
$lblT1 = New-Label '30:00' 56 42 18 $cAccent $true
$lblN1 = New-Label '槽位 1 · 计时中' 58 86 8.5 $cDim $false
$bar1  = New-Bar 238 56 154

# —— 槽位 2 ——
$lblS2 = New-Label '◆' 24 120 13 $cEmpty $false
$lblT2 = New-Label '30:00' 56 112 18 $cAccent $true
$lblN2 = New-Label '槽位 2 · 计时中' 58 156 8.5 $cDim $false
$bar2  = New-Bar 238 126 154

$lblHint = New-Label '' 24 184 8.5 $cDim $false

function New-Btn($text, $x, $w, $y) {
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $text
    $b.Location = [System.Drawing.Point]::new($x, $y)
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

$btnOpen2  = New-Btn '开了两个' 24 116 210
$btnOpen1  = New-Btn '只开一个' 148 116 210
$btnLocate = New-Btn '定位宝箱' 272 120 210
$btnPush   = New-Btn '提醒设置' 24 116 252
$btnCal    = New-Btn '对表' 148 116 252
$btnHide   = New-Btn '缩到托盘' 272 120 252
$btnExit   = New-Btn '退出' 24 80 294
$btnUndo   = New-Btn '撤销上一次' 112 132 294

$lblLock = New-Label '' 24 338 8.5 $cDim $false

# 主按钮高亮：日常就是“两个箱子一起领”
$btnOpen2.BackColor = $cAccent
$btnOpen2.ForeColor = [System.Drawing.Color]::FromArgb(30, 30, 34)
$btnOpen2.FlatAppearance.BorderSize = 0

# ---- 托盘 ----
$notify = New-Object System.Windows.Forms.NotifyIcon
$notify.Icon    = [System.Drawing.SystemIcons]::Application
$notify.Text    = '宝箱计时'
$notify.Visible = $true

$menu = New-Object System.Windows.Forms.ContextMenuStrip
$miShow  = New-Object System.Windows.Forms.ToolStripMenuItem; $miShow.Text  = '显示窗口'
$miOpen2 = New-Object System.Windows.Forms.ToolStripMenuItem; $miOpen2.Text = '连开两个 (Ctrl+Alt+B)'
$miOpen  = New-Object System.Windows.Forms.ToolStripMenuItem; $miOpen.Text  = '只开一个'
$miUndo  = New-Object System.Windows.Forms.ToolStripMenuItem; $miUndo.Text  = '撤销上一次记时 (Ctrl+Alt+Z)'
$miSync  = New-Object System.Windows.Forms.ToolStripMenuItem; $miSync.Text  = '对表（照桌宠数字填）…'
$miLocate = New-Object System.Windows.Forms.ToolStripMenuItem; $miLocate.Text = '定位宝箱（自动记时）…'
$miPush  = New-Object System.Windows.Forms.ToolStripMenuItem; $miPush.Text  = '提醒设置…'
$miSep   = New-Object System.Windows.Forms.ToolStripSeparator
$miExit  = New-Object System.Windows.Forms.ToolStripMenuItem; $miExit.Text = '退出'
[void]$menu.Items.Add($miShow)
[void]$menu.Items.Add($miOpen2)
[void]$menu.Items.Add($miOpen)
[void]$menu.Items.Add($miUndo)
[void]$menu.Items.Add($miSync)
[void]$menu.Items.Add($miLocate)
[void]$menu.Items.Add($miPush)
[void]$menu.Items.Add($miSep)
[void]$menu.Items.Add($miExit)
$notify.ContextMenuStrip = $menu

# ---- 动作 ----
# 两个槽位都满了：响一声 + 弹一条通知 + 推送。一次就够，不重复。
function Show-Alert {
    $title = '两个槽位都满了'
    $body  = '计时已经停下。去桌宠旁边开掉一个，计时才会继续走。'
    $notify.ShowBalloonTip(10000, $title, $body, [System.Windows.Forms.ToolTipIcon]::Warning)
    if ($EnableSound) { try { [System.Media.SystemSounds]::Exclamation.Play() } catch { } }
    Send-Push '鸣潮桌宠：箱子满了' '两个槽位都满了，计时已经停下。去开掉一个。' | Out-Null
}

# ---- 撤销：记时前存一份快照，误记了就还原 ----
function Save-Undo {
    $script:undoSnap = @{
        at          = (Get-Date)
        chests      = $script:chests
        totalOpened = $script:totalOpened
        pending     = $script:pending
        slots       = @($script:slots | ForEach-Object {
            [pscustomobject]@{ start = $_.start; full = $_.full; unknown = $_.unknown; lastM = $_.lastM }
        })
    }
}

function Undo-Last {
    if ($null -eq $script:undoSnap) {
        $notify.ShowBalloonTip(2500, '没有可撤销的记时', '只有刚记下的那一次能撤销。', [System.Windows.Forms.ToolTipIcon]::None)
        return
    }
    $snap = $script:undoSnap
    for ($i = 0; $i -lt 2; $i++) {
        $s = $script:slots[$i]
        $o = $snap.slots[$i]
        $s.start   = $o.start
        $s.full    = $o.full
        $s.unknown = $o.unknown
        $s.lastM   = $o.lastM
    }
    $script:chests      = $snap.chests
    $script:totalOpened = $snap.totalOpened
    $script:pending     = $snap.pending
    $script:undoSnap    = $null          # 只撤一步，防止连按把更早的状态也撤乱
    $script:sessionUntil = [datetime]::MinValue   # 撤销后关掉“连开窗口”
    Save-State
    if ($EnableSound) { try { [System.Media.SystemSounds]::Asterisk.Play() } catch { } }
    $notify.ShowBalloonTip(3000, '已撤销上一次记时', '两个槽位还原成记时之前的样子了。', [System.Windows.Forms.ToolTipIcon]::Info)
}

# ---- 自动记时的前提：两个槽位都满了才认 ----
# 只有“两个都有箱子”的时候，你点宝箱才可能是在开箱。
# 其他任何时刻（计时走在半路上、两个都在倒计时）点到的都不记，
# 也不弹提示 —— 摆弄桌宠、开设置、手滑都不会被误记。
#
# 一个例外：从“两个都满”里开掉一个之后，紧接着往往还要开第二个
# （你习惯是连着开两个）。这时候只剩 1 个，如果严格不认，第二个箱子
# 就永远记不上、界面会一直显示“已满”。所以给一个 12 秒的连开窗口，
# 只在“刚刚真的开掉过一个”之后才开这个口子，平时完全不生效。
$script:sessionUntil = [datetime]::MinValue   # 连开窗口的截止时间

function Test-ChestDue {
    if ($script:chests -ge $MaxChests) { return $true }
    if ($script:chests -ge 1 -and (Get-Date) -le $script:sessionUntil) { return $true }
    return $false
}

function Register-Open {
    # 记一次开箱。$when 就是“你按下去的那一刻”，默认取当前（精确到秒）。
    # 挑哪个槽位来重置：
    #   1) 手上有箱子 → 你开的必然是等得最久那个（先出现先被开）
    #   2) 没有已知的箱子、但有槽位还没对上表 → 就是你刚开的那个
    #   3) 都空着又都对上了 → 说明推算偏了，把最接近出箱的那个按现在重算
    param([datetime]$when)

    if ($null -eq $when -or $when.Year -lt 2000) { $when = Get-Date }

    $pick = $null
    foreach ($s in $script:slots) {
        if (-not $s.full) { continue }
        if ($null -eq $pick -or $s.start -lt $pick.start) { $pick = $s }
    }
    if ($null -eq $pick) {
        foreach ($s in $script:slots) { if ($s.unknown) { $pick = $s; break } }
    }
    if ($null -eq $pick) {
        foreach ($s in $script:slots) {
            if ($null -eq $pick -or $s.start -lt $pick.start) { $pick = $s }
        }
    }
    if ($null -eq $pick) { return $false }

    Save-Undo
    $pick.full    = $false
    $pick.unknown = $false
    $pick.start   = $when
    $script:chests      = Get-ChestCount
    $script:totalOpened = $script:totalOpened + 1
    $script:pending     = $false
    Save-State
    return $true
}

function Register-OpenTwo {
    # 日常情况：两个箱子差不多同时出、一起领，一次记录全重置。
    # 聪明一点：只重置“我们记着有箱子”的槽位（含还没对上表的）；
    # 万一两个槽位时间轴错开、你只领了一个，另一个的进度不受影响。
    # 要是程序以为一个箱子都没有、但你确实开了（说明推算偏了），那就信你的，全部重置。
    # 返回值 = 重置了几个槽位。
    param([datetime]$when)

    if ($null -eq $when -or $when.Year -lt 2000) { $when = Get-Date }

    $targets = @($script:slots | Where-Object { $_.full -or $_.unknown })
    if ($targets.Count -eq 0) { $targets = $script:slots }

    Save-Undo
    $n = 0
    foreach ($s in $targets) {
        $s.full    = $false
        $s.unknown = $false
        $s.start   = $when
        $n = $n + 1
    }
    $script:chests      = Get-ChestCount
    $script:totalOpened = $script:totalOpened + $n
    $script:pending     = $false
    Save-State
    return $n
}

# ---- 按“还剩几分钟”设定一个槽位（对表的核心公式）----
# m = 桌宠上显示的剩余分钟数；m = 0 表示这个槽位已经有箱子（停表等领）。
# 起点 = 现在 - (30 - m)，于是“起点 + 30 分钟 - 现在”正好等于 m 分钟。
function Set-SlotByRemain {
    param($slot, [int]$m, [datetime]$now)

    $slot.lastM = $m
    if ($m -le 0) {
        $slot.full = $true; $slot.unknown = $false; $slot.start = $now
    }
    else {
        $slot.full = $false; $slot.unknown = $false
        $slot.start = $now.AddMinutes(-($ChestIntervalMin - $m))
    }
}

# ---- 对表：直接照着桌宠显示的数字填。不管偏差是怎么来的，填完两边完全一致 ----
function Invoke-CalibNum {
    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text            = '对表 · 照桌宠的数字填'
    $dlg.ClientSize      = [System.Drawing.Size]::new(400, 240)
    $dlg.StartPosition   = 'CenterScreen'
    $dlg.FormBorderStyle = 'FixedDialog'
    $dlg.MaximizeBox     = $false
    $dlg.MinimizeBox     = $false
    $dlg.TopMost         = $true
    $dlg.BackColor       = [System.Drawing.Color]::FromArgb(32, 34, 40)
    $dlg.ForeColor       = [System.Drawing.Color]::FromArgb(230, 232, 238)
    $dlg.Font            = [System.Drawing.Font]::new('Microsoft YaHei UI', [float]9)

    $q = New-Object System.Windows.Forms.Label
    $q.Text      = '看一眼桌宠上的两个倒计时，各填“还剩几分钟”'
    $q.SetBounds(20, 16, 350, 24)
    $q.Font      = [System.Drawing.Font]::new('Microsoft YaHei UI', [float]10.5, [System.Drawing.FontStyle]::Bold)
    $q.ForeColor = [System.Drawing.Color]::FromArgb(232, 232, 238)
    $dlg.Controls.Add($q)

    $sub = New-Object System.Windows.Forms.Label
    $sub.Text      = '没有倒计时（箱子已满）的槽位填 0。'
    $sub.SetBounds(20, 44, 350, 20)
    $sub.ForeColor = [System.Drawing.Color]::FromArgb(150, 154, 164)
    $dlg.Controls.Add($sub)

    $boxes = @()
    for ($i = 0; $i -lt 2; $i++) {
        $lbl = New-Object System.Windows.Forms.Label
        $lbl.Text      = "槽位 $($i+1) 还剩"
        $lbl.SetBounds(28, 78 + $i * 48, 110, 26)
        $lbl.ForeColor = [System.Drawing.Color]::FromArgb(232, 232, 238)
        $dlg.Controls.Add($lbl)

        # 故意不放预填数字：预填会把我们自己的误差又喂回去
        $tb = New-Object System.Windows.Forms.TextBox
        $tb.SetBounds(140, 74 + $i * 48, 64, 30)
        $tb.TextAlign = 'Center'
        $tb.Font      = [System.Drawing.Font]::new('Microsoft YaHei UI', [float]11, [System.Drawing.FontStyle]::Bold)
        $tb.BackColor = [System.Drawing.Color]::FromArgb(52, 55, 63)
        $tb.ForeColor = [System.Drawing.Color]::FromArgb(232, 232, 238)
        $tb.BorderStyle = 'FixedSingle'
        $dlg.Controls.Add($tb)
        $boxes += $tb

        $u = New-Object System.Windows.Forms.Label
        $u.Text      = '分钟'
        $u.SetBounds(212, 78 + $i * 48, 60, 26)
        $u.ForeColor = [System.Drawing.Color]::FromArgb(150, 154, 164)
        $dlg.Controls.Add($u)
    }

    $lblErr = New-Object System.Windows.Forms.Label
    $lblErr.Text      = ''
    $lblErr.SetBounds(24, 178, 356, 20)
    $lblErr.ForeColor = [System.Drawing.Color]::FromArgb(232, 108, 108)
    $dlg.Controls.Add($lblErr)

    $ok = New-Object System.Windows.Forms.Button
    $ok.Text   = '对好表'
    $ok.SetBounds(132, 204, 96, 30)
    $ok.FlatStyle = 'Flat'
    $ok.BackColor = [System.Drawing.Color]::FromArgb(255, 200, 96)
    $ok.ForeColor = [System.Drawing.Color]::FromArgb(30, 30, 34)
    $ok.FlatAppearance.BorderSize = 0
    $ok.Cursor    = [System.Windows.Forms.Cursors]::Hand
    $ok.Add_Click({
        $vv = @()
        foreach ($tb in $boxes) {
            $txt = ($tb.Text -replace '[^\d]', '')
            if ($txt -eq '') { $lblErr.Text = '两个槽位都要填；没有箱子（已满）的填 0'; return }
            $v = [int]$txt
            if ($v -gt 30) { $lblErr.Text = '填 0 到 30 之间的分钟数'; return }
            $vv += $v
        }
        $script:calibVals = $vv
        $dlg.DialogResult = [System.Windows.Forms.DialogResult]::OK
    })
    $dlg.Controls.Add($ok)
    $dlg.AcceptButton = $ok

    $cancel = New-Object System.Windows.Forms.Button
    $cancel.Text   = '取消'
    $cancel.SetBounds(240, 204, 80, 30)
    $cancel.FlatStyle = 'Flat'
    $cancel.BackColor = [System.Drawing.Color]::FromArgb(48, 51, 58)
    $cancel.ForeColor = [System.Drawing.Color]::FromArgb(232, 232, 238)
    $cancel.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(74, 74, 84)
    $cancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $dlg.Controls.Add($cancel)
    $dlg.CancelButton = $cancel

    $script:calibVals = $null
    if ($dlg.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { $dlg.Dispose(); return }
    $vals = $script:calibVals
    $dlg.Dispose()
    if ($null -eq $vals -or @($vals).Count -lt 2) { return }

    $now = Get-Date
    for ($i = 0; $i -lt 2; $i++) {
        $m = $vals[$i]
        $s = $script:slots[$i]
        Set-SlotByRemain -slot $s -m $m -now $now
    }
    $script:chests  = Get-ChestCount
    $script:pending = $false
    Save-State
    if ($EnableSound) { try { [System.Media.SystemSounds]::Asterisk.Play() } catch { } }
    $t1 = if ($vals[0] -le 0) { '已满' } else { "$($vals[0]) 分" }
    $t2 = if ($vals[1] -le 0) { '已满' } else { "$($vals[1]) 分" }
    $notify.ShowBalloonTip(6000, '对表完成', "槽位1 = $t1，槽位2 = $t2。界面上现在应该显示同样的数字。", [System.Windows.Forms.ToolTipIcon]::Info)
}

function Start-Locate {
    # 定点识别的关键一步：接下来 15 秒内的下一次左键按下 = 宝箱位置。
    # 之后就不用任何手动操作了——点到宝箱位置附近，自动记时。
    $script:locateUntil = (Get-Date).AddSeconds(15)
    $notify.ShowBalloonTip(4000, '定位宝箱', '15 秒内，把鼠标移到宝箱上，点一下箱子本身。', [System.Windows.Forms.ToolTipIcon]::Info)
}

# ---- 提醒设置：把推送地址存进 push-url.txt，箱子满了推到微信 ----
function Invoke-PushSetup {
    $script:pushAction = ''

    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text            = '提醒设置 · 推送到微信'
    $dlg.ClientSize      = [System.Drawing.Size]::new(474, 258)
    $dlg.StartPosition   = 'CenterScreen'
    $dlg.FormBorderStyle = 'FixedDialog'
    $dlg.MaximizeBox     = $false
    $dlg.MinimizeBox     = $false
    $dlg.TopMost         = $true
    $dlg.BackColor       = [System.Drawing.Color]::FromArgb(32, 34, 40)
    $dlg.ForeColor       = [System.Drawing.Color]::FromArgb(230, 232, 238)
    $dlg.Font            = [System.Drawing.Font]::new('Microsoft YaHei UI', [float]9)

    # 说明文字每行单独一个 Label，高度给够（AutoSize=false + 明确高度），
    # 这样即使某行比预期长，也是自己折在自己的框里，不会压到下面的输入框上。
    $t1 = New-Object System.Windows.Forms.Label
    if (Test-Path $PushFile) {
        $t1.Text      = '两个槽位都满了的时候，把消息推送到你微信。　当前：已配置 ✔'
        $t1.ForeColor = [System.Drawing.Color]::FromArgb(120, 216, 150)
    }
    else {
        $t1.Text      = '两个槽位都满了的时候，把消息推送到你微信。　当前：还没配'
        $t1.ForeColor = [System.Drawing.Color]::FromArgb(232, 196, 120)
    }
    $t1.SetBounds(20, 14, 434, 22)
    $t1.TextAlign = 'MiddleLeft'
    $dlg.Controls.Add($t1)

    $t2 = New-Object System.Windows.Forms.Label
    $t2.Text      = '支持两种地址，粘一个到下面的输入框，点「测试」（成功会自动保存）：'
    $t2.SetBounds(20, 44, 434, 20)
    $dlg.Controls.Add($t2)

    $t3 = New-Object System.Windows.Forms.Label
    $t3.Text      = '① 企业微信群机器人 webhook：群设置 → 群机器人 → 添加，复制地址'
    $t3.SetBounds(20, 70, 434, 20)
    $dlg.Controls.Add($t3)

    $t4 = New-Object System.Windows.Forms.Label
    $t4.Text      = '② Server酱：sct.ftqq.com 扫码登录 → 生成 SendKey（SCT 开头）'
    $t4.SetBounds(20, 94, 434, 20)
    $dlg.Controls.Add($t4)

    $t5 = New-Object System.Windows.Forms.Label
    $t5.Text      = '　　拼成 https://sctapi.ftqq.com/SCTxxxx.send 再粘到下面'
    $t5.SetBounds(20, 116, 434, 20)
    $dlg.Controls.Add($t5)

    foreach ($t in @($t2, $t3, $t4, $t5)) {
        $t.ForeColor = [System.Drawing.Color]::FromArgb(150, 154, 164)
    }

    $tb = New-Object System.Windows.Forms.TextBox
    $tb.SetBounds(20, 148, 434, 28)
    $tb.Text      = $PushUrl
    $tb.BackColor = [System.Drawing.Color]::FromArgb(48, 51, 58)
    $tb.ForeColor = [System.Drawing.Color]::FromArgb(232, 232, 238)
    $tb.BorderStyle = 'FixedSingle'
    $dlg.Controls.Add($tb)

    $mk = {
        param($text, $x, $w, $tag)
        $b = New-Object System.Windows.Forms.Button
        $b.Text      = $text
        $b.SetBounds($x, 196, $w, 36)
        $b.FlatStyle = 'Flat'
        $b.BackColor = [System.Drawing.Color]::FromArgb(48, 51, 58)
        $b.ForeColor = [System.Drawing.Color]::FromArgb(232, 232, 238)
        $b.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(74, 74, 84)
        $b.Cursor    = [System.Windows.Forms.Cursors]::Hand
        $b.Tag       = $tag
        $b.Add_Click({
            $script:pushAction = [string]$this.Tag
            $script:pushDlg.DialogResult = [System.Windows.Forms.DialogResult]::OK
        })
        $script:pushDlg.Controls.Add($b)
    }
    $script:pushDlg = $dlg
    & $mk '测试' 20 104 'test'
    & $mk '保存' 130 104 'save'
    & $mk '清除' 240 104 'clear'
    & $mk '关闭' 350 104 'close'

    $res = $dlg.ShowDialog()
    $action = [string]$script:pushAction
    $txt = ''
    try { $txt = $tb.Text.Trim() } catch { }
    $dlg.Dispose()

    if ($res -ne [System.Windows.Forms.DialogResult]::OK -or -not $action -or $action -eq 'close') { return }

    switch ($action) {
        'test' {
            if (-not $txt) {
                [void][System.Windows.Forms.MessageBox]::Show('先粘贴一个地址再测试。', '提醒设置', 'OK', 'Information')
                return
            }
            $old = $PushUrl
            $script:PushUrl = $txt
            $r = Invoke-Push -title '测试推送' -body '能收到这条，说明提醒地址配好了。'
            if ($r.ok) {
                # 测通了就直接存下来 —— 免得“测完忘了点保存”，到时候以为配好了其实没配
                try {
                    Set-Content -Path $PushFile -Value $txt -Encoding UTF8
                    $script:PushUrl = $txt
                    [void][System.Windows.Forms.MessageBox]::Show('发出去成功了，并且已经顺手保存。去微信看一下收到没有。', '提醒设置', 'OK', 'Information')
                } catch {
                    $script:PushUrl = $old
                    [void][System.Windows.Forms.MessageBox]::Show(('消息发出去了，但保存失败：' + $_.Exception.Message), '提醒设置', 'OK', 'Warning')
                }
            } else {
                $script:PushUrl = $old
                [void][System.Windows.Forms.MessageBox]::Show(('没发出去。' + [Environment]::NewLine + [Environment]::NewLine + $r.msg + [Environment]::NewLine + [Environment]::NewLine + '常见原因：SendKey 少字或多了空格 / 没在微信里关注 Server酱 公众号 / 网络不通。'), '提醒设置', 'OK', 'Warning')
            }
        }
        'save' {
            if ($txt) {
                try {
                    Set-Content -Path $PushFile -Value $txt -Encoding UTF8
                    if (-not (Test-Path $PushFile)) { throw '文件没写成功' }
                    $script:PushUrl = $txt
                    $notify.ShowBalloonTip(3000, '已保存', '箱子满了会推送到这个地址。', [System.Windows.Forms.ToolTipIcon]::Info)
                } catch {
                    [void][System.Windows.Forms.MessageBox]::Show(('保存失败：' + $_.Exception.Message + [Environment]::NewLine + '看看这个文件夹是不是只读的。'), '提醒设置', 'OK', 'Warning')
                }
            } else {
                if (Test-Path $PushFile) { Remove-Item $PushFile -Force }
                $script:PushUrl = ''
                $notify.ShowBalloonTip(3000, '已清空', '输入框是空的，等于不推送。', [System.Windows.Forms.ToolTipIcon]::Info)
            }
        }
        'clear' {
            if (Test-Path $PushFile) { Remove-Item $PushFile -Force }
            $script:PushUrl = ''
            $notify.ShowBalloonTip(3000, '已清除', '以后只在电脑上提醒，不再推送。', [System.Windows.Forms.ToolTipIcon]::Info)
        }
    }
}

function Show-Window {
    $form.ShowInTaskbar = $true
    $form.Show()
    $form.WindowState = [System.Windows.Forms.FormWindowState]::Normal
    [void]$form.Activate()
}

function Hide-ToTray {
    $form.Hide()
    $notify.ShowBalloonTip(1500, '仍在后台盯着', '已缩到托盘，双击图标打开。', [System.Windows.Forms.ToolTipIcon]::Info)
}

function Exit-App {
    $script:reallyExit = $true
    Save-State
    $tickTimer.Stop()
    try { $notify.Visible = $false; $notify.Dispose() } catch { }
    [System.Windows.Forms.Application]::Exit()
}

# ---- 计时推进 ----
# 双槽独立：两个槽位各自跑自己的 30 分钟，互不干扰。
# 已实测确认：关掉桌宠、关机、睡眠，计时都照常走，
# 所以只需要存绝对时刻，程序没开的那段空白会自然被算进去。
function Update-Chest {
    $now = Get-Date
    $changed = $false

    foreach ($s in $script:slots) {
        if ($s.full) { continue }            # 有箱子 = 这个槽位停表
        if ($s.unknown) { continue }         # 还没对上表，不知道攒了多久，不瞎算
        $elapsed = ($now - $s.start).TotalMinutes
        if ($elapsed -le 0) { continue }     # 系统时间被往回调过，这一拍先忽略

        if ($elapsed -ge $ChestIntervalMin) {
            # 这个槽位攒够了：出 1 个箱子，起点推进到“出箱那一刻”，然后停表。
            # 一个槽位最多存 1 个，所以哪怕关机很久也只加 1。
            $s.start = $s.start.AddMinutes($ChestIntervalMin)
            $s.full  = $true
            $changed = $true
        }
    }

    if (-not $changed) { return }

    $script:chests = Get-ChestCount
    if ($script:chests -ge $MaxChests) { $script:pending = $true }
    Save-State
}

# ---- 把“还剩多久”格式化成 分:秒 ----
# 必须向下取整：只剩 0 分 59 秒就写 00:59。
# 之前用 [int]$span.TotalMinutes 是四舍五入，0.98 分会被抬成 1 分 → 显示成 01:59，
# 同理 29.98 分被抬成 30 分 → 30:59 看着像 31 分钟。这里改成按整秒截断。
function Format-Remain {
    param([TimeSpan]$span)
    $total = [int][math]::Floor($span.TotalSeconds)
    if ($total -lt 0) { $total = 0 }
    $m   = [int][math]::Floor($total / 60)
    $sec = $total - $m * 60
    return ('{0:00}:{1:00}' -f $m, $sec)
}

# ---- 这个屏幕坐标上盖着的是不是桌宠 ----
# 返回 'pet' / 'other:进程名' / 'unknown'
function Get-HitOwner {
    param([int]$x, [int]$y)
    if (-not $script:hitReady) { return 'unknown' }
    try {
        $hpid = [BoxHit]::PidAt($x, $y)
        if ($hpid -le 0) { return 'other:?' }
        $p = Get-Process -Id $hpid -ErrorAction Stop
        if ($p.ProcessName -eq 'WuwaTappo') { return 'pet' }
        return ('other:' + $p.ProcessName)
    } catch {
        return 'other:进程已退出'
    }
}

# ---- 点击诊断：只在“点在宝箱附近、却没落到桌宠身上”时写一行 ----
function Write-ClickDiag {
    param([string]$text)
    try {
        if ((Test-Path $ClickDiagFile) -and ((Get-Item $ClickDiagFile).Length -gt 200KB)) {
            Remove-Item $ClickDiagFile -Force -ErrorAction SilentlyContinue
        }
        Add-Content -Path $ClickDiagFile -Value ((Get-Date).ToString('MM-dd HH:mm:ss') + '  ' + $text) -Encoding UTF8
    } catch { }
}

# ---- 桌宠角色位置：读它自己存的 ratio ----
# 桌宠是 Tauri + WebView 做的，角色位置存在 EBWebView 的 Local Storage（leveldb）里。
# leveldb 是追加写：*.log 是最新写入，*.ldb 是压过的旧数据。
# 所以按修改时间从新到旧找，第一个能匹配的文件里取“最后一次出现”的那条 = 当前位置。
function Read-SharedText {
    param([string]$path)
    try {
        $fs = [System.IO.File]::Open($path, [System.IO.FileMode]::Open,
                                     [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        $sr = New-Object System.IO.StreamReader($fs, [System.Text.Encoding]::UTF8)
        $t = $sr.ReadToEnd()
        $sr.Close(); $fs.Close()
        return $t
    } catch { return $null }
}

$script:petRatioRx = [regex]'"x":\{"ratio":([0-9.]+),"minEdge":(true|false),"maxEdge":(true|false)\},"y":\{"ratio":([0-9.]+),"minEdge":(true|false),"maxEdge":(true|false)\}'

function Get-PetRatio {
    try {
        $dir = Join-Path $env:LOCALAPPDATA 'com.kuro.wuwatappo.cn\EBWebView\Default\Local Storage\leveldb'
        if (-not (Test-Path $dir)) { return $null }
        $files = @(Get-ChildItem $dir -File -ErrorAction SilentlyContinue |
                   Where-Object { $_.Extension -eq '.log' -or $_.Extension -eq '.ldb' } |
                   Sort-Object LastWriteTime -Descending)
        foreach ($f in $files) {
            if ($f.Length -gt 4MB) { continue }
            $txt = Read-SharedText $f.FullName
            if ([string]::IsNullOrEmpty($txt)) { continue }
            $ms = $script:petRatioRx.Matches($txt)
            if ($ms.Count -eq 0) { continue }
            $m = $ms[$ms.Count - 1]        # 最后一条 = 最近一次保存的位置
            $edge = 'free'
            if ($m.Groups[3].Value -eq 'true')      { $edge = 'right' }
            elseif ($m.Groups[2].Value -eq 'true')  { $edge = 'left' }
            $ci = [System.Globalization.CultureInfo]::InvariantCulture
            return [pscustomobject]@{
                x     = [double]::Parse($m.Groups[1].Value, $ci)
                y     = [double]::Parse($m.Groups[4].Value, $ci)
                xEdge = $edge
            }
        }
    } catch { }
    return $null
}

# ---- 桌宠被拖动了？宝箱点跟着挪 ----
# 定位宝箱时记下那一刻的角色位置（锚点）。之后每 3 秒比一次：
#   · 纵向：ratio 差 × 屏幕高 = 挪了多少像素，直接加到宝箱 Y 上。
#   · 横向：两边都贴右（或都贴左）= 横向没动；两边都自由 = 按比例算；
#           一边贴边一边自由 = 横向位移算不出来，只能提示你重新定位。
# 算完把锚点更新成当前位置，所以是“增量跟随”，拖动过程中反复读也不会累加错。
function Sync-PetMove {
    $cur = Get-PetRatio
    if ($null -eq $cur) { return }      # 读不到就先不动，下一轮再说

    # 还没有锚点（老存档刚升级上来）：只补记当前值，绝不动坐标
    if ($null -eq $script:petAX -or $null -eq $script:petAY) {
        if ($script:chestX -ge 0) {
            $script:petAX    = $cur.x
            $script:petAY    = $cur.y
            $script:petAEdge = $cur.xEdge
            Save-State
        }
        return
    }

    $vs = [System.Windows.Forms.SystemInformation]::VirtualScreen
    if ($vs.Width -le 0 -or $vs.Height -le 0) { return }

    $dy = [int][math]::Round(($cur.y - $script:petAY) * $vs.Height)

    # 横向位移：$null 表示“算不出来”
    $dx = $null
    if ($script:petAEdge -eq 'right') {
        if ($cur.xEdge -eq 'right') { $dx = 0 }
    }
    elseif ($script:petAEdge -eq 'left') {
        if ($cur.xEdge -eq 'left') { $dx = 0 }
    }
    elseif ($script:petAEdge -eq 'free' -and $cur.xEdge -eq 'free') {
        $dx = [int][math]::Round(($cur.x - $script:petAX) * $vs.Width)
    }

    $dyMoved = ([math]::Abs($dy) -ge $PetMoveTolPx)
    $dxMoved = $false
    $dxUnknown = $false
    if ($null -eq $dx) {
        # 贴边状态变了 = 横向确实动过，只是位移量没法算
        if ($script:petAEdge -ne $cur.xEdge) { $dxMoved = $true; $dxUnknown = $true }
    }
    elseif ([math]::Abs($dx) -ge $PetMoveTolPx) { $dxMoved = $true }

    if (-not $dyMoved -and -not $dxMoved) { return }

    # 真的挪了：平移宝箱点（锚点随后跟着更新，下次就从这个新位置继续比）
    $movedText = ''
    if ($dyMoved) {
        if ($dy -gt 0) { $movedText = "下移 $dy 像素" } else { $movedText = "上移 $([math]::Abs($dy)) 像素" }
    }
    if ($dxMoved -and -not $dxUnknown) {
        $t = if ($dx -gt 0) { "右移 $dx 像素" } else { "左移 $([math]::Abs($dx)) 像素" }
        if ($movedText) { $movedText = $movedText + '、' + $t } else { $movedText = $t }
    }

    if ($PetFollowOn -and $script:chestX -ge 0 -and -not $dxUnknown) {
        $nx = $script:chestX
        $ny = $script:chestY + $dy
        if ($null -ne $dx -and $dxMoved) { $nx = $script:chestX + $dx }
        if ($nx -ge $vs.Left -and $nx -lt $vs.Right -and $ny -ge $vs.Top -and $ny -lt $vs.Bottom) {
            $script:chestX = $nx
            $script:chestY = $ny
        }
        else {
            # 挪到屏幕外了：坐标作废，让你重新定位
            $script:chestX     = -1
            $script:chestY     = -1
            $script:coordReset = $true
            $dxUnknown         = $true
        }
    }

    # 锚点更新成当前值（不管有没有真的平移坐标，都要更新，否则每 3 秒重复判一次）
    $script:petAX    = $cur.x
    $script:petAY    = $cur.y
    $script:petAEdge = $cur.xEdge
    Save-State

    # 提示（限流：拖动过程中只会认真弹一次）
    if (((Get-Date) - $script:petMovedAt).TotalSeconds -lt $PetNoticeGapSec) { return }
    $script:petMovedAt = Get-Date
    if (-not $PetFollowOn) {
        $notify.ShowBalloonTip(4000, '桌宠挪了位置',
            ('角色' + $movedText + '。宝箱点没有跟着动，记得点一次「定位宝箱」。'),
            [System.Windows.Forms.ToolTipIcon]::Warning)
    }
    elseif ($dxUnknown -or $script:chestX -lt 0) {
        $notify.ShowBalloonTip(5000, '桌宠横向挪了位置',
            '宝箱点没法自动跟过去。请点一下「定位宝箱」，再去点一下箱子重新对一下位置。',
            [System.Windows.Forms.ToolTipIcon]::Warning)
    }
    elseif ($movedText) {
        $notify.ShowBalloonTip(4000, '桌宠挪了位置', ('角色' + $movedText + '，宝箱点已自动跟过去，不用重新定位。'),
            [System.Windows.Forms.ToolTipIcon]::Info)
    }
    Write-ClickDiag ('桌宠位置变了：' + $movedText + '，宝箱点 → (' + $script:chestX + ',' + $script:chestY + ')')
}

# ---- 主循环 ----
$tickTimer = New-Object System.Windows.Forms.Timer
$tickTimer.Interval = $TickMs
$tickTimer.Add_Tick({
    if ($script:reallyExit) { return }
    $script:tickNo = $script:tickNo + 1

    # --- 每 10 拍（约 1 秒）看一下桌宠在不在、前台是不是游戏 ---
    if (($script:tickNo % 10) -eq 0) {
        $proc = Get-Process -Name WuwaTappo -ErrorAction SilentlyContinue | Select-Object -First 1
        $script:tappoRun = ($null -ne $proc)

        # 前台是不是游戏（是的话，满箱提醒先攒着，等你退出来再弹）
        $fp = [BoxNative]::ForegroundPid()
        $script:gameFg = $false
        if ($fp -gt 0) {
            try {
                $script:fgName = (Get-Process -Id $fp -ErrorAction Stop).ProcessName
                foreach ($kw in $GameKeywords) {
                    if ($script:fgName -like "*$kw*") { $script:gameFg = $true; break }
                }
            } catch { $script:fgName = '' }
        }
    }

    # --- 每 30 拍（约 3 秒）看一眼桌宠角色有没有被拖动 ---
    # 拖了就按位移把宝箱点挪过去，你不需要重新定位。
    # 放在上面那段之后，保证这一拍 tappoRun 已经是最新的。
    if (($script:tickNo % $PetCheckEvery) -eq 0 -and $script:tappoRun) {
        Sync-PetMove
    }

    # --- 键鼠状态（只读，不注入任何东西）---
    # 同时抓“按下沿”和“松开沿”：按下那一刻 = 最准的时间戳；
    # 松开那一刻 = 判定是不是一次快速点击（排除拖桌宠）
    $down     = (([int][BoxNative]::GetAsyncKeyState(0x01)) -band 0x8000) -ne 0
    $downEdge = $down -and (-not $script:btnPrev)
    $upEdge   = ((-not $down)) -and $script:btnPrev
    $script:btnPrev = $down
    if ($downEdge) {
        $ptDown = New-Object BoxNative+POINT
        if ([BoxNative]::GetCursorPos([ref]$ptDown)) { $script:downX = $ptDown.X; $script:downY = $ptDown.Y }
        $script:downAt = Get-Date
    }
    $clicked = $downEdge

    # --- 定位宝箱：15 秒内的下一次左键按下 = 宝箱位置 ---
    if ($script:locateUntil -gt [datetime]::MinValue) {
        if ((Get-Date) -gt $script:locateUntil) {
            $script:locateUntil = [datetime]::MinValue
            $notify.ShowBalloonTip(3000, '定位超时', '没等到点击。再点一次「定位宝箱」试试。', [System.Windows.Forms.ToolTipIcon]::Warning)
        }
        elseif ($downEdge) {
            $script:chestX = $script:downX
            $script:chestY = $script:downY
            # 顺手记下这一刻桌宠角色的位置。以后角色被拖动时，
            # 宝箱点就按同样的位移跟过去（这就是“不用重新定位”的原理）。
            $pr = Get-PetRatio
            if ($null -ne $pr) {
                $script:petAX    = $pr.x
                $script:petAY    = $pr.y
                $script:petAEdge = $pr.xEdge
            }
            $script:locateUntil = [datetime]::MinValue
            Save-State
            if ($EnableSound) { try { [System.Media.SystemSounds]::Asterisk.Play() } catch { } }
            $notify.ShowBalloonTip(4000, '锁定成功', "宝箱位置 ($($script:chestX), $($script:chestY)) 已记住。以后点到这儿就自动记时。", [System.Windows.Forms.ToolTipIcon]::Info)
        }
    }

    # --- 定点自动记时：松开鼠标那一刻判定，不用你按任何热键 ---
    if ($AutoDetect -and $script:chestX -ge 0 -and $upEdge -and
        ($script:locateUntil -eq [datetime]::MinValue)) {
        $heldMs  = ((Get-Date) - $script:downAt).TotalMilliseconds
        $movedOk = $true
        $ptUp    = New-Object BoxNative+POINT
        if ([BoxNative]::GetCursorPos([ref]$ptUp)) {
            $mdx = [math]::Abs($ptUp.X - $script:downX)
            $mdy = [math]::Abs($ptUp.Y - $script:downY)
            if (($mdx -gt $ClickMaxMovePx) -or ($mdy -gt $ClickMaxMovePx)) { $movedOk = $false }
        }
        $ddx = $script:downX - $script:chestX
        $ddy = $script:downY - $script:chestY
        $atChest = ([math]::Sqrt($ddx * $ddx + $ddy * $ddy) -le $ChestRadiusPx)

        # 点在宝箱附近，但那一下没落到桌宠的窗口上 —— 说明被别的窗口挡住了，
        # 桌宠根本收不到这一下（你会觉得“点了没反应”）。只记日志，不弹窗打扰。
        if ($atChest -and $script:tappoRun) {
            $owner = Get-HitOwner $script:downX $script:downY
            if ($owner -ne 'pet' -and $owner -ne 'unknown') {
                Write-ClickDiag ('点在宝箱附近 ({0},{1})，但那一下落到 {2} 上，桌宠没收到' -f $script:downX, $script:downY, $owner)
            }
        }

        # 三个条件都满足才算开箱：点在宝箱附近 + 是快速点击（不是拖着桌宠跑）+ 桌宠开着，
        # 并且只在“两个槽位都满了”时才认 —— 那一刻才可能真的在开箱。
        # 计时走在半路上时点了不记、也不提示（安静，不打扰）。
        if ($atChest -and $movedOk -and ($heldMs -le $ClickMaxMs) -and $script:tappoRun) {
            # 点在我们自己窗口上的不算（比如点按钮）
            if ([BoxNative]::ForegroundPid() -ne $PID) {
                if (Test-ChestDue) {
                    $wasFull = ($script:chests -ge $MaxChests)
                    if (Register-Open -when $script:downAt) {
                        # 刚才还是“两个都满” → 开这 12 秒的连开窗口，
                        # 让你紧接着开第二个箱子时也能记上
                        if ($wasFull) { $script:sessionUntil = (Get-Date).AddSeconds(12) }
                    }
                }
            }
        }
    }

    # --- 热键：Ctrl+Alt+B = 记一次开箱；Ctrl+Alt+Z = 撤销上一次记时 ---
    if ($HotkeyEnabled) {
        $modDown = ((([int][BoxNative]::GetAsyncKeyState(0x11)) -band 0x8000) -ne 0) -and
                   ((([int][BoxNative]::GetAsyncKeyState(0x12)) -band 0x8000) -ne 0)
        $hk  = $modDown -and ((([int][BoxNative]::GetAsyncKeyState(0x42)) -band 0x8000) -ne 0)
        $hkZ = $modDown -and ((([int][BoxNative]::GetAsyncKeyState(0x5A)) -band 0x8000) -ne 0)
        if ($hk -and -not $script:hkPrev -and ((Get-Date) - $script:hkAt).TotalMilliseconds -gt 700) {
            $script:hkAt = Get-Date
            $nOpen = Register-OpenTwo -when (Get-Date)
            $notify.ShowBalloonTip(1200, "记下了：重置 $nOpen 个槽位", 'Ctrl+Alt+B · 误记了按 Ctrl+Alt+Z 撤销', [System.Windows.Forms.ToolTipIcon]::None)
        }
        if ($hkZ -and -not $script:hkZPrev -and ((Get-Date) - $script:hkZAt).TotalMilliseconds -gt 700) {
            $script:hkZAt = Get-Date
            Undo-Last
        }
        $script:hkPrev  = $hk
        $script:hkZPrev = $hkZ
    }

    # --- 计时推进 ---
    Update-Chest

    # --- 两个槽位都满了：提醒一次 ---
    # 只提醒一次（响一声 + 一条通知 + 手机推送），之后不再重复。
    # 人在游戏里时先攒着，等退出游戏回桌面再弹，免得打断你。
    if ($script:chests -ge $MaxChests) {
        if ($script:gameFg) {
            $script:pending = $true
        }
        elseif ($script:pending) {
            $script:pending = $false
            Show-Alert
        }
    }

    # --- 每 5 拍刷一次界面 ---
    if (($script:tickNo % 5) -ne 0) { return }

    $lblTotal.Text = "累计已开 $($script:totalOpened) 个"

    # 两个槽位各自算各自的倒计时
    $nowUi = Get-Date
    $rows  = @(
        @{ D = $lblS1; T = $lblT1; N = $lblN1; B = $bar1 },
        @{ D = $lblS2; T = $lblT2; N = $lblN2; B = $bar2 }
    )
    $nearest = $null

    for ($i = 0; $i -lt 2; $i++) {
        $s = $script:slots[$i]
        $r = $rows[$i]

        if ($s.full) {
            # 有箱子：停表，显示已经等了多久
            $span = $nowUi - $s.start
            if ($span.TotalDays -ge 2) {
                $stopText = '{0} 天 {1} 小时' -f [int][math]::Floor($span.TotalDays), $span.Hours
            }
            elseif ($span.TotalHours -ge 1) {
                $stopText = '{0} 小时 {1} 分' -f [int][math]::Floor($span.TotalHours), $span.Minutes
            }
            else {
                $stopText = '{0} 分钟' -f [int][math]::Floor([math]::Max([double]0, $span.TotalMinutes))
            }
            $r.D.ForeColor = $cAccent
            $r.T.Text      = '已满'
            $r.T.ForeColor = $cAccent
            $r.N.Text      = "槽位 $($i+1) · 有箱子 · 已停 $stopText"
            $r.N.ForeColor = $cRed
            $r.B.Value     = 100
        }
        elseif ($s.unknown) {
            # 还没对上表：不编数字，直接告诉你点一下
            $r.D.ForeColor = $cEmpty
            $r.T.Text      = '--:--'
            $r.T.ForeColor = $cDim
            $r.N.Text      = "槽位 $($i+1) · 待对表 · 点「对表」照桌宠数字填"
            $r.N.ForeColor = $cDim
            $r.B.Value     = 0
        }
        else {
            $remain = $s.start.AddMinutes($ChestIntervalMin) - $nowUi
            if ($remain.TotalSeconds -lt 0) { $remain = [TimeSpan]::Zero }
            $pct = 100 - [int](($remain.TotalSeconds / ($ChestIntervalMin * 60)) * 100)
            if ($pct -lt 0) { $pct = 0 }; if ($pct -gt 100) { $pct = 100 }

            $r.D.ForeColor = $cEmpty
            $r.T.Text      = Format-Remain $remain
            $r.T.ForeColor = $cGreen
            # 把上次对表填的分钟数显示出来，方便和桌宠核对
            $extra = ''
            if ($null -ne $s.lastM) { $extra = " · 对表 $($s.lastM) 分" }
            $r.N.Text      = "槽位 $($i+1) · 计时中$extra"
            $r.N.ForeColor = $cDim
            $r.B.Value     = $pct

            if ($null -eq $nearest -or $remain.TotalSeconds -lt $nearest.TotalSeconds) { $nearest = $remain }
        }
    }

    if ($script:chests -ge $MaxChests) {
        $notify.Text = '宝箱计时 · 两个都满了'
    }
    elseif ($null -ne $nearest) {
        $notify.Text = '宝箱计时 · 最近一个 ' + (Format-Remain $nearest)
    }
    else {
        $notify.Text = '宝箱计时'
    }

    # 托盘图标：满了换成感叹号，一眼能看出来（不弹窗、不挡手）
    $wantFull = ($script:chests -ge $MaxChests)
    if ($wantFull -ne $script:fullIcon) {
        $script:fullIcon = $wantFull
        try {
            if ($wantFull) { $notify.Icon = [System.Drawing.SystemIcons]::Exclamation }
            else           { $notify.Icon = [System.Drawing.SystemIcons]::Application }
        } catch { }
    }

    $anyUnknown = $false
    foreach ($s in $script:slots) { if ($s.unknown) { $anyUnknown = $true; break } }

    if ($script:locateUntil -gt [datetime]::MinValue) {
        $lblHint.Text = '定位中：15 秒内去点一下宝箱（点箱子本身）'
    }
    elseif ($script:chestX -lt 0) {
        if ($script:coordReset) {
            $lblHint.Text = '屏幕变了：老的宝箱坐标已作废，请重新点一次「定位宝箱」'
        }
        else {
            $lblHint.Text = '还没定位宝箱：点「定位宝箱」后去点一下箱子，以后自动记时'
        }
    }
    elseif ($anyUnknown) {
        $lblHint.Text = '有槽位待对表：点「对表」照桌宠的数字填一下'
    }
    elseif (-not $script:tappoRun) {
        $lblHint.Text = '桌宠没开 · 计时照常走 · 开箱按 Ctrl+Alt+B'
    }
    else {
        $lblHint.Text = '两个都满时点宝箱自动记时 · Ctrl+Alt+Z 撤销'
    }

    if ($script:chestX -ge 0) {
        # 后面这半句是给桌宠“挪位置自动跟随”用的：能看到开没开，排障时一眼就清楚
        $follow = ' · 跟随未建立'
        if (-not $PetFollowOn)              { $follow = ' · 跟随已关' }
        elseif ($null -ne $script:petAX)    { $follow = ' · 跟随开' }
        $lblLock.Text = "● 已锁定 ($($script:chestX), $($script:chestY)) · 半径 ${ChestRadiusPx}px$follow"
        $lblLock.ForeColor = $cGreen
    }
    else {
        $lblLock.Text = '○ 未定位 · 自动记时关闭'
        $lblLock.ForeColor = $cDim
    }
})

# ---- 事件 ----
$btnOpen2.Add_Click({ [void](Register-OpenTwo) })
$btnOpen1.Add_Click({ [void](Register-Open) })
$btnUndo.Add_Click({ Undo-Last })
$btnHide.Add_Click({ Hide-ToTray })
$btnExit.Add_Click({ Exit-App })
$btnPush.Add_Click({ Invoke-PushSetup })
$btnLocate.Add_Click({ Start-Locate })
$miShow.Add_Click({ Show-Window })
$miOpen2.Add_Click({ [void](Register-OpenTwo) })
$miOpen.Add_Click({ [void](Register-Open) })
$miUndo.Add_Click({ Undo-Last })
$miSync.Add_Click({ Invoke-CalibNum })
$miLocate.Add_Click({ Start-Locate })
$miPush.Add_Click({ Invoke-PushSetup })
$miExit.Add_Click({ Exit-App })
$notify.Add_DoubleClick({ Show-Window })

$btnCal.Add_Click({ Invoke-CalibNum })

$form.Add_Resize({
    if ($form.WindowState -ne [System.Windows.Forms.FormWindowState]::Minimized) { return }
    # 最小化 = 缩进托盘（托盘图标常驻，双击就能回来）
    $form.Hide()
})

$form.Add_FormClosing({
    param($s, $e)
    if (($e.CloseReason -eq [System.Windows.Forms.CloseReason]::UserClosing) -and (-not $script:reallyExit)) {
        $e.Cancel = $true
        Hide-ToTray
    }
})

# ---- 起飞 ----
$firstRun = -not (Test-Path $StateFile)   # 得在存盘之前判断，不然永远“不是第一次”
$script:calibPending = ((-not $Minimized) -and ($firstRun -or $script:needCalib))
$script:needCalib = $false
Save-State
$tickTimer.Start()
if ($Minimized) {
    # 开机自启：不弹窗挡你开机，直接待在托盘里
    $form.ShowInTaskbar = $false
    $form.Hide()
}
else {
    $form.Add_Shown({
        # 第一次用（或从老模型升上来）：弹对表窗口，照桌宠显示的数字填一下就好。
        if ($script:calibPending) { $script:calibPending = $false; Invoke-CalibNum }
    })
}
[void][System.Windows.Forms.Application]::Run($form)

}
catch {
    $msg = "启动失败：`r`n`r`n" + $_.Exception.Message + "`r`n`r`n" + $_.ScriptStackTrace
    [void][System.Windows.Forms.MessageBox]::Show($msg, 'Wuwa Tappo 宝箱计时', 'OK', 'Error')
}

# ============================================================
# 关于 $PushUrl（推送到手机）：
#   最省事的做法是在企业微信里建一个群 → 群设置 → 群机器人 → 添加，
#   复制那条 webhook 地址（形如
#   https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=xxxx）
#   填到本文件顶部的 $PushUrl = '...'，保存重启即可。
#   没有企业微信的话，Server酱（sctapi.ftqq.com）的地址也支持，
#   直接粘完整地址就行。留空则完全不联网。
# ============================================================
