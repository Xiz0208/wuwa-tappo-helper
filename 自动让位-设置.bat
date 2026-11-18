@echo off
chcp 65001 >nul
title Wuwa Auto-Hide - Settings

net session >nul 2>&1
if errorlevel 1 (
  echo.
  echo  Requesting administrator rights...
  powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
  exit /b
)

cd /d "%~dp0"

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0AutoHideSetup.ps1"
exit /b
