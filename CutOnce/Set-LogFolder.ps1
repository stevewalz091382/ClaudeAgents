<#
.SYNOPSIS
    Points CutOnce's logs at a folder, such as one shared team folder.

.DESCRIPTION
    Run with no options for step-by-step prompts. Sets the CUTONCE_LOGDIR
    (and optionally CUTONCE_LOGSUBFOLDER) environment variables for this
    user, or for every user with -Scope AllUsers (run as administrator).
    Civil 3D picks the change up the next time it starts.

.PARAMETER LogDir
    The log folder, e.g. "\\server\cad\CutOnce\Logs".

.PARAMETER LogSubfolder
    none, user, computer or user-computer. With a shared folder, each person
    (or PC) then writes to its own subfolder. user-computer is recommended.

.PARAMETER Clear
    Removes the setting, so the config file's LogDir (or the default
    %LOCALAPPDATA%\CutOnce\Logs) applies again.

.EXAMPLE
    .\Set-LogFolder.ps1
.EXAMPLE
    .\Set-LogFolder.ps1 -LogDir "\\server\cad\CutOnce\Logs" -LogSubfolder user-computer
#>
[CmdletBinding()]
param(
    [string]$LogDir,
    [ValidateSet('none', 'user', 'computer', 'user-computer')]
    [string]$LogSubfolder,
    [ValidateSet('User', 'AllUsers')]
    [string]$Scope = 'User',
    [switch]$Clear
)

$ErrorActionPreference = 'Stop'
$target = if ($Scope -eq 'AllUsers') { 'Machine' } else { 'User' }

if ($Scope -eq 'AllUsers') {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    if (-not (New-Object Security.Principal.WindowsPrincipal $id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Scope AllUsers needs an elevated (Run as administrator) PowerShell.'
    }
}

if ($Clear) {
    foreach ($name in 'CUTONCE_LOGDIR', 'CUTONCE_LOGSUBFOLDER') {
        [Environment]::SetEnvironmentVariable($name, $null, $target)
    }
    Write-Host 'Log folder setting removed. Restart Civil 3D to use the default again.'
    return
}

Write-Host ''
Write-Host 'CutOnce - choose where logs are written'
Write-Host '---------------------------------------'

# Step 1: the folder
if (-not $LogDir) {
    Write-Host 'Step 1 of 3: pick the log folder (for a team, one shared folder every office can reach).'
    try {
        Add-Type -AssemblyName System.Windows.Forms
        $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
        $dlg.Description = 'Choose the CutOnce log folder'
        $dlg.ShowNewFolderButton = $true
        if ($dlg.ShowDialog() -eq 'OK') { $LogDir = $dlg.SelectedPath }
    } catch { }
    if (-not $LogDir) { $LogDir = Read-Host 'Type the folder path (e.g. \\server\cad\CutOnce\Logs)' }
}
if (-not $LogDir) { throw 'No folder chosen - nothing changed.' }
$LogDir = $LogDir.TrimEnd('\', '/')

# Step 2: check it can be written
Write-Host ''
Write-Host "Step 2 of 3: checking that $LogDir can be written to..."
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
$probe = Join-Path $LogDir ("cutonce-write-test-{0}.tmp" -f [guid]::NewGuid())
Set-Content -Path $probe -Value 'test'
Remove-Item $probe -Force
Write-Host '  OK.'

# Step 3: one subfolder per person?
if (-not $LogSubfolder) {
    Write-Host ''
    Write-Host 'Step 3 of 3: should each person write to their own subfolder?'
    Write-Host '  1  Yes, one per person per computer (recommended for a shared or synced folder)'
    Write-Host '  2  Yes, one per person'
    Write-Host '  3  Yes, one per computer'
    Write-Host '  4  No, everyone writes the same files (one user, or a local folder)'
    switch (Read-Host 'Choose 1-4 [1]') {
        '2' { $LogSubfolder = 'user' }
        '3' { $LogSubfolder = 'computer' }
        '4' { $LogSubfolder = 'none' }
        default { $LogSubfolder = 'user-computer' }
    }
}

[Environment]::SetEnvironmentVariable('CUTONCE_LOGDIR', $LogDir, $target)
if ($LogSubfolder -eq 'none') {
    [Environment]::SetEnvironmentVariable('CUTONCE_LOGSUBFOLDER', $null, $target)
    $example = $LogDir
} else {
    [Environment]::SetEnvironmentVariable('CUTONCE_LOGSUBFOLDER', $LogSubfolder, $target)
    $sub = switch ($LogSubfolder) {
        'user'     { $env:USERNAME }
        'computer' { $env:COMPUTERNAME }
        default    { "$env:USERNAME-$env:COMPUTERNAME" }
    }
    $example = Join-Path $LogDir $sub
}

Write-Host ''
Write-Host 'Done.'
Write-Host "  Your logs will be written to: $example"
Write-Host '  Restart Civil 3D, then type CUTONCE-STATUS to confirm the log folder.'
