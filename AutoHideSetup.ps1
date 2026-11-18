<#
  鸣潮桌宠 · 自动让位  设置菜单（中文）
  ------------------------------------------------------------
  这个文件由「自动让位.bat」「自动让位-设置.bat」调用，不用直接双击。
#>

param([string]$Action = '')

$ErrorActionPreference = 'Stop'
$Root = $PSScriptRoot
$Main = Join-Path $Root 'WuwaAutoHide.ps1'

function Wait-Key {
    Write-Host ''
    Write-Host '  按回车键返回菜单…' -ForegroundColor DarkGray
    [void](Read-Host)
}

function Test-PetRunning {
    return @(Get-Process -Name WuwaTappo -ErrorAction SilentlyContinue).Count -gt 0
}

function Start-AutoHide {
    if (-not (Test-PetRunning)) {
        Write-Host ''
        Write-Host '  [!] 桌宠（Wuwa Tappo）现在没有运行。' -ForegroundColor Yellow
        Write-Host '      请先打开桌宠，再回来点这个。' -ForegroundColor Yellow
        return
    }
    Start-Process -FilePath 'powershell.exe' -ArgumentList @(
        '-NoProfile', '-WindowStyle', 'Hidden', '-ExecutionPolicy', 'Bypass', '-File', $Main
    ) -WindowStyle Hidden
    Start-Sleep -Seconds 2
    Write-Host ''
    $s = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
           Where-Object { $_.CommandLine -like '*WuwaAutoHide*' })
    if ($s.Count -gt 0) {
        Write-Host '  已经在后台开始工作了（没有窗口，不会占托盘）。' -ForegroundColor Green
        Write-Host '  之后全屏会自动藏桌宠，回桌面自动回来。' -ForegroundColor Green
    } else {
        Write-Host '  启动似乎没成功，请看一下 autohide.log。' -ForegroundColor Red
    }
}

function Show-Menu {
    Clear-Host
    Write-Host ''
    Write-Host '  ==========================================================' -ForegroundColor Cyan
    Write-Host '              鸣潮桌宠 · 自动让位   设置' -ForegroundColor Cyan
    Write-Host '  ==========================================================' -ForegroundColor Cyan
    Write-Host ''
    Write-Host '    规则：全屏（游戏 / 视频）→ 桌宠藏起来'
    Write-Host '          回到桌面、或普通窗口（哪怕最大化）→ 桌宠回来'
    Write-Host ''
    Write-Host '    [1] 现在开始（后台运行）'
    Write-Host '    [2] 停止（并把桌宠放出来）'
    Write-Host '    [3] 设为开机自动运行（不弹管理员框）'
    Write-Host '    [4] 取消开机自动运行'
    Write-Host '    [5] 查看当前状态'
    Write-Host '    [6] 实时诊断（看它认为什么是全屏）'
    Write-Host '    [0] 退出'
    Write-Host ''
}

function Invoke-Action {
    param([string]$Name, [switch]$NoWait)

    switch ($Name) {
        'start' {
            Start-AutoHide
            if (-not $NoWait) { Wait-Key }
        }
        'stop' {
            Write-Host ''
            & $Main -Stop
            if (-not $NoWait) { Wait-Key }
        }
        'install' {
            Write-Host ''
            & $Main -Install
            if (-not $NoWait) { Wait-Key }
        }
        'uninstall' {
            Write-Host ''
            & $Main -Uninstall
            if (-not $NoWait) { Wait-Key }
        }
        'status' {
            Write-Host ''
            & $Main -Status
            if (-not $NoWait) { Wait-Key }
        }
        'diagnose' {
            Write-Host ''
            Write-Host '  接下来这一行会跟着你切换窗口实时变化。' -ForegroundColor Gray
            Write-Host '  请分别试：游戏全屏 / 视频全屏 / 浏览器最大化 / 文件夹最大化。' -ForegroundColor Gray
            Write-Host '  看完按 Ctrl+C 退出诊断。' -ForegroundColor Gray
            Write-Host ''
            & $Main -Diagnose
            if (-not $NoWait) { Wait-Key }
        }
    }
}

# ---------- 带参数直接执行（给 自动让位.bat 用） ----------
if ($Action) {
    Invoke-Action -Name $Action -NoWait
    exit 0
}

# ---------- 菜单 ----------
while ($true) {
    Show-Menu
    $c = Read-Host '  请输入数字后回车'

    switch ($c.Trim()) {
        '1' { Invoke-Action 'start' }
        '2' { Invoke-Action 'stop' }
        '3' { Invoke-Action 'install' }
        '4' { Invoke-Action 'uninstall' }
        '5' { Invoke-Action 'status' }
        '6' { Invoke-Action 'diagnose' }
        '0' { return }
        default { }
    }
}
