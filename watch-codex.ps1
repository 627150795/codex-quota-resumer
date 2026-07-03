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

$MutexName = "Global\CodexQuotaResumerWatcher_$($ThreadId -replace '[^A-Za-z0-9_.-]', '_')"
$CreatedMutex = $false
$WatcherMutex = New-Object System.Threading.Mutex($true, $MutexName, [ref]$CreatedMutex)
if (-not $CreatedMutex) {
  "$(Get-Date -Format o) watcher-already-running thread=$ThreadId" | Add-Content -LiteralPath $LogPath -Encoding UTF8
  return
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

function Write-WatcherLog($Message) {
  "$(Get-Date -Format o) $Message" | Add-Content -LiteralPath $LogPath -Encoding UTF8
}

function Read-State {
  if (-not (Test-Path -LiteralPath $StatePath)) { return $null }
  try {
    Get-Content -LiteralPath $StatePath -Raw -Encoding UTF8 | ConvertFrom-Json
  } catch {
    Write-WatcherLog "state-read-error $($_.Exception.Message)"
    $null
  }
}

function Write-State($State) {
  try {
    $json = $State | ConvertTo-Json -Depth 20
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($StatePath, $json, $utf8NoBom)
  } catch {
    Write-WatcherLog "state-write-error $($_.Exception.Message)"
  }
}

function New-TrayIcon {
  $bitmap = New-Object System.Drawing.Bitmap 16, 16
  $g = [System.Drawing.Graphics]::FromImage($bitmap)
  $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::None
  $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::Half
  $g.Clear([System.Drawing.Color]::FromArgb(37, 99, 235))
  $white = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::White)
  $status = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(134, 239, 172))
  $g.FillRectangle($white, 3, 4, 3, 9)
  $g.FillRectangle($white, 5, 3, 6, 3)
  $g.FillRectangle($white, 5, 11, 6, 3)
  $g.FillRectangle($status, 11, 1, 4, 4)
  $g.FillRectangle($status, 10, 2, 6, 2)
  $status.Dispose()
  $white.Dispose()
  $g.Dispose()
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

function Stop-ProcessTree($ProcessIdToStop) {
  Get-CimInstance Win32_Process | Where-Object { $_.ParentProcessId -eq $ProcessIdToStop } | ForEach-Object {
    Stop-ProcessTree $_.ProcessId
  }
  Stop-Process -Id $ProcessIdToStop -Force -ErrorAction SilentlyContinue
}

function Stop-Resumers {
  foreach ($p in @(Get-ResumerProcess)) {
    Write-WatcherLog "resumer-stopping pid=$($p.ProcessId)"
    Stop-ProcessTree $p.ProcessId
  }
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
  $state = Read-State
  if ($null -eq $state) { return @() }
  @($state.backups | Where-Object {
    $_.threadId -eq $ThreadId -and
    $_.status -in @("captured", "scheduled", "retry_scheduled")
  })
}

function Show-QueuedNotifications {
  $state = Read-State
  if ($null -eq $state -or $null -eq $state.notificationEvents) { return }

  $pending = @($state.notificationEvents | Where-Object {
    $_.type -in @("backup-saved", "replay-scheduled") -and
    $_.threadId -eq $ThreadId -and
    -not $_.shownAt -and
    -not $ShownNotificationIds.Contains([string]$_.id)
  })
  if ($pending.Count -eq 0) { return }

  if ($pending.Count -eq 1) {
    $tray.BalloonTipTitle = [string]$pending[0].title
    $tray.BalloonTipText = [string]$pending[0].body
  } else {
    $tray.BalloonTipTitle = "Codex Quota Resumer"
    $tray.BalloonTipText = (($pending | ForEach-Object { "$($_.title): $($_.body)" }) -join "`n")
  }
  $tray.ShowBalloonTip(8000)

  foreach ($notification in $pending) {
    $ShownNotificationIds.Add([string]$notification.id) | Out-Null
    $notification.shownAt = (Get-Date -Format o)
    Write-WatcherLog "notification-shown id=$($notification.id) type=$($notification.type)"
  }
  Write-State $state
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
      Stop-Resumers
    }

    Show-QueuedNotifications
  } catch {
    Write-WatcherLog "sync-error $($_.Exception.Message)"
  }
}

$tray = New-Object System.Windows.Forms.NotifyIcon
$tray.Icon = New-TrayIcon
$tray.Text = "Codex Quota Resumer"
$tray.Visible = $true
$ShownNotificationIds = [System.Collections.Generic.HashSet[string]]::new()

$menu = New-Object System.Windows.Forms.ContextMenuStrip
$showItem = $menu.Items.Add("Show waiting tasks")
$openLogItem = $menu.Items.Add("Open log")
$exitItem = $menu.Items.Add("Exit")
$tray.ContextMenuStrip = $menu

$showItem.Add_Click({ Show-WaitingBackups })
$openLogItem.Add_Click({ Start-Process notepad.exe $LogPath })
$exitItem.Add_Click({
  $timer.Stop()
  Stop-Resumers
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
try {
  [System.Windows.Forms.Application]::Run()
} finally {
  $tray.Dispose()
  $WatcherMutex.ReleaseMutex()
  $WatcherMutex.Dispose()
}
