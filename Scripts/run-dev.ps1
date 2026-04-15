param(
    [string]$PlanName = "event_monitoring",
    [string]$BeModel,
    [string]$FeModel,
    [ValidateSet("claude", "codex")][string]$BeCli,
    [ValidateSet("claude", "codex")][string]$FeCli,
    [switch]$SkipBackend,
    [switch]$SkipFrontend,
    [switch]$DryRun,
    [int]$TimeoutSec = 2700,
    [int]$NoOutputTimeoutSec = 300
)

. "$PSScriptRoot\agent-common.ps1"

if ($SkipBackend -and $SkipFrontend) {
    throw "be_dev 와 fe_dev 를 모두 건너뛸 수는 없습니다. 둘 다 실행하지 않을 경우 run-cycle.ps1 을 사용하세요."
}

if (-not $SkipBackend) {
    Invoke-AgentRole `
        -Role be_dev `
        -PlanName $PlanName `
        -Model $BeModel `
        -Cli $BeCli `
        -DryRun:$DryRun `
        -TimeoutSec $TimeoutSec `
        -NoOutputTimeoutSec $NoOutputTimeoutSec | Out-Null
}

if (-not $SkipFrontend) {
    Invoke-AgentRole `
        -Role fe_dev `
        -PlanName $PlanName `
        -Model $FeModel `
        -Cli $FeCli `
        -DryRun:$DryRun `
        -TimeoutSec $TimeoutSec `
        -NoOutputTimeoutSec $NoOutputTimeoutSec | Out-Null
}
