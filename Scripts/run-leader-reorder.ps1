param(
    [string]$PlanName = "event_monitoring",
    [string]$Model,
    [ValidateSet("claude", "codex")][string]$Cli,
    [switch]$DryRun,
    [string]$MockOutputPath,
    [int]$TimeoutSec = 2700,
    [int]$NoOutputTimeoutSec = 300
)

. "$PSScriptRoot\agent-common.ps1"

Write-Host "[DEPRECATED] run-leader-reorder.ps1 는 run-leader.ps1 / run-cycle.ps1 구조로 대체되었습니다. 기존 호출은 leader_final 단계로 매핑합니다."

Invoke-AgentRole `
    -Role leader_final `
    -PlanName $PlanName `
    -Model $Model `
    -Cli $Cli `
    -DryRun:$DryRun `
    -MockOutputPath $MockOutputPath `
    -TimeoutSec $TimeoutSec `
    -NoOutputTimeoutSec $NoOutputTimeoutSec | Out-Null
