@echo off
rem Removes CutOnce. Add -RemoveLogs to delete logs and reports too.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Uninstall.ps1" %*
pause
