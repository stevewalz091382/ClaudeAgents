@echo off
rem Installs ByLayerCheck for the current user. Pass options through, e.g. Install.cmd -Scope AllUsers
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install.ps1" %*
pause
