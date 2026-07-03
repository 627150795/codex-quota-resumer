param(
  [Parameter(Mandatory = $true)]
  [string]$ThreadId,

  [int]$IntervalSeconds = 10
)

$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$LogDir = Join-Path $Root ".codex-quota-resumer"
$LogPath = Join-Path $LogDir "watcher.log"
$StatePath = Join-Path $LogDir "state.json"
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

function Write-WatcherLog($Message) {
  "$(Get-Date -Format o) $Message" | Add-Content -LiteralPath $LogPath -Encoding UTF8
}

function New-TrayIcon {
  $bitmap = New-Object System.Drawing.Bitmap 16, 16
  $g = [System.Drawing.Graphics]::FromImage($bitmap)
  $g.Clear([System.Drawing.Color]::FromArgb(35, 92, 180))
  $font = New-Object System.Drawing.Font "Segoe UI", 9, ([System.Drawing.FontStyle]::Bold)
  $brush = [System.Drawing.Brushes]::White
  $g.DrawString("C", $font, $brush, 3, 0)
  $g.Dispose()
  $font.Dispose()
  [System.Drawing.Icon]::FromHandle($bitmap.GetHicon())
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
    "--data-dir", $LogDir,
    "--high-risk-percent", "95"
  )
  $p = Start-Process -FilePath $Node -ArgumentList $Args -WorkingDirectory $Root -WindowStyle Hidden -PassThru
  Write-WatcherLog "resumer-started pid=$($p.Id)"
}

function Get-WaitingBackups {
  if (-not (Test-Path -LiteralPath $StatePath)) { return @() }
  try {
    $state = Get-Content -LiteralPath $StatePath -Raw -Encoding UTF8 | ConvertFrom-Json
    @($state.backups | Where-Object {
      $_.threadId -eq $ThreadId -and
      $_.status -in @("captured", "scheduled", "retry_scheduled")
    })
  } catch {
    Write-WatcherLog "state-read-error $($_.Exception.Message)"
    @()
  }
}

function Show-WaitingBackups {
  $items = @(Get-WaitingBackups)
  if ($items.Count -eq 0) {
    $tray.BalloonTipTitle = "Codex Quota Resumer"
    $tray.BalloonTipText = "No waiting tasks."
    $tray.ShowBalloonTip(4000)
    return
  }

  $lines = $items | Select-Object -First 5 | ForEach-Object {
    $time = if ($_.scheduledFor) { $_.scheduledFor } else { $_.capturedAt }
    "- $($_.status) $time $($_.textPreview)"
  }
  if ($items.Count -gt 5) { $lines += "... plus $($items.Count - 5) more" }
  $tray.BalloonTipTitle = "Waiting Codex tasks: $($items.Count)"
  $tray.BalloonTipText = ($lines -join "`n")
  $tray.ShowBalloonTip(8000)
}

function Sync-Resumer {
  try {
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
  } catch {
    Write-WatcherLog "sync-error $($_.Exception.Message)"
  }
}

$tray = New-Object System.Windows.Forms.NotifyIcon
$tray.Icon = New-TrayIcon
$tray.Text = "Codex Quota Resumer"
$tray.Visible = $true

$menu = New-Object System.Windows.Forms.ContextMenuStrip
$showItem = $menu.Items.Add("Show waiting tasks")
$openLogItem = $menu.Items.Add("Open log")
$exitItem = $menu.Items.Add("Exit")
$tray.ContextMenuStrip = $menu

$showItem.Add_Click({ Show-WaitingBackups })
$openLogItem.Add_Click({ Start-Process notepad.exe $LogPath })
$exitItem.Add_Click({
  $timer.Stop()
  $tray.Visible = $false
  [System.Windows.Forms.Application]::Exit()
})
$tray.Add_DoubleClick({ Show-WaitingBackups })

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = [Math]::Max(1, $IntervalSeconds) * 1000
$timer.Add_Tick({ Sync-Resumer })
$timer.Start()

Write-WatcherLog "watcher-started thread=$ThreadId interval=${IntervalSeconds}s tray=true"
Sync-Resumer
[System.Windows.Forms.Application]::Run()
