param(
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$PlanName,
    [string]$Model,
    [AllowEmptyString()][string]$Cli,
    [switch]$DryRun,
    [string]$MockOutputPath,
    [int]$TimeoutSec = 2700,
    [int]$NoOutputTimeoutSec = 300
)

. "$PSScriptRoot\agent-common.ps1"

Write-Host "[DEPRECATED] run-leader_after.ps1 는 leader_final 단계로 통합되었습니다. run-leader_after.ps1 는 계속 동작하지만, 새 스크립트는 run-cycle.ps1 또는 leader_final 역할을 사용하세요."

Invoke-AgentRole `
    -Role leader_final `
    -PlanName $PlanName `
    -Model $Model `
    -Cli $Cli `
    -DryRun:$DryRun `
    -MockOutputPath $MockOutputPath `
    -TimeoutSec $TimeoutSec `
    -NoOutputTimeoutSec $NoOutputTimeoutSec | Out-Null
