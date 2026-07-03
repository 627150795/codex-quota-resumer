$ErrorActionPreference = "Stop"
$TaskName = "CodexQuotaResumerWatcher"
if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
  Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
  Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
}
$Shortcut = Join-Path ([Environment]::GetFolderPath("Startup")) "Codex Quota Resumer Watcher.lnk"
if (Test-Path -LiteralPath $Shortcut) {
  Remove-Item -LiteralPath $Shortcut -Force
}
Write-Output "uninstalled=$TaskName"
