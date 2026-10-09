@echo off
rem Points CutOnce's logs at a folder, step by step. Options pass through, e.g.
rem   Set-LogFolder.cmd -LogDir "\\server\cad\CutOnce\Logs" -LogSubfolder user-computer
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Set-LogFolder.ps1" %*
pause
