param(
  [string]$ThreadId
)

$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path

function Stop-ProcessTree($ProcessIdToStop) {
  Get-CimInstance Win32_Process | Where-Object { $_.ParentProcessId -eq $ProcessIdToStop } | ForEach-Object {
    Stop-ProcessTree $_.ProcessId
  }
  if ($ProcessIdToStop -ne $PID) {
    Stop-Process -Id $ProcessIdToStop -Force -ErrorAction SilentlyContinue
  }
}

function Matches-Thread($Process) {
  if (-not $ThreadId) { return $true }
  return $Process.CommandLine -like "*--thread-id*$ThreadId*" -or $Process.CommandLine -like "*-ThreadId*$ThreadId*"
}

$TaskName = "CodexQuotaResumerWatcher"
if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
  Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
  Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
}
$Shortcut = Join-Path ([Environment]::GetFolderPath("Startup")) "Codex Quota Resumer Watcher.lnk"
if (Test-Path -LiteralPath $Shortcut) {
  Remove-Item -LiteralPath $Shortcut -Force
}

$escapedRoot = [WildcardPattern]::Escape($Root)
$watchers = @(Get-CimInstance Win32_Process | Where-Object {
  $_.ProcessId -ne $PID -and
  $_.CommandLine -like '*watch-codex.ps1*' -and
  $_.CommandLine -like "*$escapedRoot*" -and
  (Matches-Thread $_)
})
foreach ($p in $watchers) {
  Stop-ProcessTree $p.ProcessId
}

$resumers = @(Get-CimInstance Win32_Process -Filter "name = 'node.exe'" | Where-Object {
  $_.CommandLine -like '*codex-quota-resumer.mjs*' -and
  $_.CommandLine -like "*$escapedRoot*" -and
  (Matches-Thread $_)
})
foreach ($p in $resumers) {
  Stop-ProcessTree $p.ProcessId
}

Write-Output "uninstalled=$TaskName"
