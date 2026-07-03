param(
  [Parameter(Mandatory = $true)]
  [string]$ThreadId,

  [int]$IntervalSeconds = 10
)

$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$LogDir = Join-Path $Root ".codex-quota-resumer"
$LogPath = Join-Path $LogDir "watcher.log"
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null

function Write-WatcherLog($Message) {
  "$(Get-Date -Format o) $Message" | Add-Content -LiteralPath $LogPath -Encoding UTF8
}

function Get-CodexDesktopProcess {
  Get-CimInstance Win32_Process -Filter "name = 'Codex.exe'" |
    Where-Object { $_.CommandLine -like '*OpenAI.Codex_*' -or $_.ExecutablePath -like '*WindowsApps*OpenAI.Codex*' }
}

function Get-ResumerProcess {
  Get-CimInstance Win32_Process -Filter "name = 'node.exe'" |
    Where-Object { $_.CommandLine -like '*codex-quota-resumer.mjs*' -and $_.CommandLine -like "*--thread-id*$ThreadId*" }
}

function Stop-ProcessTree($Pid) {
  Get-CimInstance Win32_Process | Where-Object { $_.ParentProcessId -eq $Pid } | ForEach-Object {
    Stop-ProcessTree $_.ProcessId
  }
  Stop-Process -Id $Pid -Force -ErrorAction SilentlyContinue
}

function Start-Resumer {
  $Node = (Get-Command node -ErrorAction Stop).Source
  $Args = @(
    (Join-Path $Root "codex-quota-resumer.mjs"),
    "--thread-id", $ThreadId,
    "--data-dir", (Join-Path $Root ".codex-quota-resumer"),
    "--high-risk-percent", "95"
  )
  $p = Start-Process -FilePath $Node -ArgumentList $Args -WorkingDirectory $Root -WindowStyle Hidden -PassThru
  Write-WatcherLog "resumer-started pid=$($p.Id)"
}

Write-WatcherLog "watcher-started thread=$ThreadId interval=${IntervalSeconds}s"

while ($true) {
  $desktopRunning = [bool](Get-CodexDesktopProcess | Select-Object -First 1)
  $resumers = @(Get-ResumerProcess)

  if ($desktopRunning -and $resumers.Count -eq 0) {
    Start-Resumer
  }

  if (-not $desktopRunning -and $resumers.Count -gt 0) {
    foreach ($p in $resumers) {
      Write-WatcherLog "resumer-stopping pid=$($p.ProcessId)"
      Stop-ProcessTree $p.ProcessId
    }
  }

  Start-Sleep -Seconds $IntervalSeconds
}
