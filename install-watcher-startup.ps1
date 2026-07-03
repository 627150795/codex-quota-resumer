param(
  [Parameter(Mandatory = $true)]
  [string]$ThreadId
)

$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$Startup = [Environment]::GetFolderPath("Startup")
$Shortcut = Join-Path $Startup "Codex Quota Resumer Watcher.lnk"
$PowerShell = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
$Script = Join-Path $Root "watch-codex.ps1"
$Args = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$Script`" -ThreadId `"$ThreadId`""

$Shell = New-Object -ComObject WScript.Shell
$Link = $Shell.CreateShortcut($Shortcut)
$Link.TargetPath = $PowerShell
$Link.Arguments = $Args
$Link.WorkingDirectory = $Root
$Link.WindowStyle = 7
$Link.Description = "Start Codex quota resumer when Codex Desktop is running"
$Link.Save()

Start-Process -FilePath $PowerShell -ArgumentList $Args -WorkingDirectory $Root -WindowStyle Hidden
Write-Output "installed=$Shortcut"
