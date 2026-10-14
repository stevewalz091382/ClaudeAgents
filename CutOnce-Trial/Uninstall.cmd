@echo off
rem Copyright (c) 2026 Stephen Walz. All rights reserved.
rem Removes CutOnce.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Uninstall.ps1" %*
pause
