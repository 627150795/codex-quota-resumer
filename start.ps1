param(
  [Parameter(Mandatory = $true)]
  [string]$ThreadId
)

$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $Root

node .\codex-quota-resumer.mjs `
  --thread-id $ThreadId `
  --data-dir .\.codex-quota-resumer `
  --high-risk-percent 95
