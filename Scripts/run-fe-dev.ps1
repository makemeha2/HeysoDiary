param(
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$PlanName,
    [string]$Model,
    [ValidateSet("claude", "codex")][string]$Cli,
    [switch]$DryRun,
    [string]$MockOutputPath,
    [int]$TimeoutSec = 2700,
    [int]$NoOutputTimeoutSec = 300
)

. "$PSScriptRoot\agent-common.ps1"

Invoke-AgentRole `
    -Role fe_dev `
    -PlanName $PlanName `
    -Model $Model `
    -Cli $Cli `
    -DryRun:$DryRun `
    -MockOutputPath $MockOutputPath `
    -TimeoutSec $TimeoutSec `
    -NoOutputTimeoutSec $NoOutputTimeoutSec | Out-Null
