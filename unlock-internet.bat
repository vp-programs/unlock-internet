@echo off
chcp 65001 >nul
setlocal
rem ---- window title (no extra powershell call) ----
title UNLOCK INTERNET
set "SCRIPT_DIR=%~dp0"
rem -NoProfile = fast start, -File = direct script launch
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%unlock-internet.ps1" %*
endlocal
