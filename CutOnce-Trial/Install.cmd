@echo off
rem Copyright (c) 2026 Stephen Walz. All rights reserved.
rem Installs the CutOnce Trial for the current user. Pass options through, e.g. Install.cmd -Scope AllUsers
rem To unlock the full version, reach out to stevewalz@hotmail.com
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install.ps1" %*
pause
