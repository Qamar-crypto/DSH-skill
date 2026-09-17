@echo off
chcp 65001 >nul
title MiMo live progress
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0MimoProgress.ps1" %*
echo.
pause
