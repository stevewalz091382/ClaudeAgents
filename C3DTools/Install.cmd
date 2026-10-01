@echo off
rem Installs C3DTools for the current user. Pass options through, e.g. Install.cmd -LogDir "D:\CAD\Logs"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install.ps1" %*
pause
