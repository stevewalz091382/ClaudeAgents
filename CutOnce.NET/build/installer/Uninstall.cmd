@echo off
rem Removes CutOnce. Add -RemoveLogs to delete logs too.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Uninstall.ps1" %*
pause
