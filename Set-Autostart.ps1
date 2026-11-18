<#
  ============================================================
  开机自启 安装 / 取消
  ------------------------------------------------------------
  做法很直白：往「启动」文件夹里放一个小 bat，里面有绝对路径。
  不放注册表、不装服务、不碰系统设置，你随时能在启动文件夹里
  看到它、删掉它。

  用法：
    安装开机自启.bat   → 调用本脚本（不带参数）
    取消开机自启.bat   → 调用本脚本 -Remove
  ============================================================
#>

param(
    [switch]$Remove
)

$ErrorActionPreference = 'Stop'

$target  = Join-Path $PSScriptRoot 'WuwaBoxTimer.ps1'
$startup = [Environment]::GetFolderPath('Startup')
$dst     = Join-Path $startup 'WuwaBoxTimer.bat'

Write-Host ''

if ($Remove) {
    if (Test-Path $dst) {
        Remove-Item $dst -Force
        Write-Host ' 已取消开机自启。' -ForegroundColor Green
        Write-Host " 删掉的文件：$dst" -ForegroundColor DarkGray
    } else {
        Write-Host ' 本来就没有设置开机自启，不用取消。' -ForegroundColor Yellow
    }
    Write-Host ''
    exit 0
}

if (-not (Test-Path $target)) {
    Write-Host ' 找不到 WuwaBoxTimer.ps1。' -ForegroundColor Red
    Write-Host ' 它需要和本脚本待在同一个文件夹里。' -ForegroundColor Red
    Write-Host ''
    exit 1
}

$line = '@echo off' + "`r`n" +
        'start "" powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' +
        $target + '" -Minimized' + "`r`n"

Set-Content -Path $dst -Value $line -Encoding Default

Write-Host ' 已安装开机自启。' -ForegroundColor Green
Write-Host " 启动文件：$dst" -ForegroundColor DarkGray
Write-Host ''
Write-Host ' 开机会自动在托盘里待着，不弹窗、不挡你。' -ForegroundColor Gray
Write-Host ' 想取消：运行「取消开机自启.bat」，或直接删掉上面那个文件。' -ForegroundColor Gray
Write-Host ''
