param(
    [string]$PlanName = "event_monitoring",
    [int]$MaxCycles = 1,
    [string]$LeaderModel,
    [string]$BeModel,
    [string]$FeModel,
    [string]$ReviewerModel,
    [string]$QaModel,
    [string]$LeaderFinalModel,
    [ValidateSet("claude", "codex")][string]$LeaderCli,
    [ValidateSet("claude", "codex")][string]$BeCli,
    [ValidateSet("claude", "codex")][string]$FeCli,
    [ValidateSet("claude", "codex")][string]$ReviewerCli,
    [ValidateSet("claude", "codex")][string]$QaCli,
    [ValidateSet("claude", "codex")][string]$LeaderFinalCli,
    [switch]$DryRun,
    [string]$MockOutputDir,
    [Nullable[bool]]$MockBeRequired = $null,
    [Nullable[bool]]$MockFeRequired = $null,
    [string]$MockFinalDecision,
    [int]$TimeoutSec = 2700,
    [int]$NoOutputTimeoutSec = 300
)

. "$PSScriptRoot\agent-common.ps1"

if ($MaxCycles -ne 1) {
    throw "현재 1차 구현에서는 MaxCycles=1 만 지원합니다. 반복 실행이 필요하면 leader_final_report 를 확인한 뒤 run-cycle.ps1 을 다시 실행하세요."
}

function Get-RoleMockPath {
    param(
        [string]$BaseDir,
        [string]$Role
    )

    if (-not $BaseDir) {
        return $null
    }

    $path = Join-Path $BaseDir ("{0}.md" -f $Role)
    if (Test-Path -LiteralPath $path) {
        return $path
    }

    return $null
}

$config = Get-AgentPlanConfig -PlanName $PlanName
$cycleRunId = New-AgentRunId
$finalDecision = "BLOCKED"
$hadError = $false

Write-Host ("[CYCLE] plan={0} runId={1}" -f $PlanName, $cycleRunId)
Write-Host ("[CYCLE] reports={0}" -f $config.ReportsDir)
Write-Host ("[CYCLE] runtime={0}" -f $config.RuntimeDir)

try {
    $leaderMock = @{}
    if ($null -ne $MockBeRequired) {
        $leaderMock["BeRequired"] = $MockBeRequired
    }
    if ($null -ne $MockFeRequired) {
        $leaderMock["FeRequired"] = $MockFeRequired
    }

    Write-Host "[CYCLE] step=leader"
    Invoke-AgentRole `
        -Role leader `
        -PlanName $PlanName `
        -Model $LeaderModel `
        -Cli $LeaderCli `
        -DryRun:$DryRun `
        -MockOutputPath (Get-RoleMockPath -BaseDir $MockOutputDir -Role "leader") `
        -MockMetadata $leaderMock `
        -TimeoutSec $TimeoutSec `
        -NoOutputTimeoutSec $NoOutputTimeoutSec `
        -RunId $cycleRunId `
        -CycleRunId $cycleRunId | Out-Null

    $leaderDirectives = Get-ReportDirectives -Path $config.Roles["leader"].ReportPath
    if ($null -eq $leaderDirectives.BeRequired -or $null -eq $leaderDirectives.FeRequired) {
        throw "leader_report.md 에서 BE_REQUIRED 또는 FE_REQUIRED 헤더를 읽지 못했습니다. leader 프롬프트가 헤더를 출력했는지 확인하거나 DryRun mock 값을 사용하세요."
    }

    $beRoleConfig = Get-ResolvedRoleConfig -Config $config -Role "be_dev" -Model $BeModel -Cli $BeCli
    if ($leaderDirectives.BeRequired) {
        Write-Host "[CYCLE] step=be_dev action=run"
        Invoke-AgentRole `
            -Role be_dev `
            -PlanName $PlanName `
            -Model $BeModel `
            -Cli $BeCli `
            -DryRun:$DryRun `
            -MockOutputPath (Get-RoleMockPath -BaseDir $MockOutputDir -Role "be_dev") `
            -TimeoutSec $TimeoutSec `
            -NoOutputTimeoutSec $NoOutputTimeoutSec `
            -RunId $cycleRunId `
            -CycleRunId $cycleRunId | Out-Null
    }
    else {
        Write-Host "[CYCLE] step=be_dev action=pass"
        Write-PassRoleArtifacts -RoleConfig $beRoleConfig -Status "PASSED" -Reason "leader 가 BE_REQUIRED=false 로 판정했습니다." -RunId $cycleRunId -CycleRunId $cycleRunId
    }

    $feRoleConfig = Get-ResolvedRoleConfig -Config $config -Role "fe_dev" -Model $FeModel -Cli $FeCli
    if ($leaderDirectives.FeRequired) {
        Write-Host "[CYCLE] step=fe_dev action=run"
        Invoke-AgentRole `
            -Role fe_dev `
            -PlanName $PlanName `
            -Model $FeModel `
            -Cli $FeCli `
            -DryRun:$DryRun `
            -MockOutputPath (Get-RoleMockPath -BaseDir $MockOutputDir -Role "fe_dev") `
            -TimeoutSec $TimeoutSec `
            -NoOutputTimeoutSec $NoOutputTimeoutSec `
            -RunId $cycleRunId `
            -CycleRunId $cycleRunId | Out-Null
    }
    else {
        Write-Host "[CYCLE] step=fe_dev action=pass"
        Write-PassRoleArtifacts -RoleConfig $feRoleConfig -Status "PASSED" -Reason "leader 가 FE_REQUIRED=false 로 판정했습니다." -RunId $cycleRunId -CycleRunId $cycleRunId
    }

    Write-Host "[CYCLE] step=reviewer"
    Invoke-AgentRole `
        -Role reviewer `
        -PlanName $PlanName `
        -Model $ReviewerModel `
        -Cli $ReviewerCli `
        -DryRun:$DryRun `
        -MockOutputPath (Get-RoleMockPath -BaseDir $MockOutputDir -Role "reviewer") `
        -TimeoutSec $TimeoutSec `
        -NoOutputTimeoutSec $NoOutputTimeoutSec `
        -RunId $cycleRunId `
        -CycleRunId $cycleRunId | Out-Null

    Write-Host "[CYCLE] step=qa"
    Invoke-AgentRole `
        -Role qa `
        -PlanName $PlanName `
        -Model $QaModel `
        -Cli $QaCli `
        -DryRun:$DryRun `
        -MockOutputPath (Get-RoleMockPath -BaseDir $MockOutputDir -Role "qa") `
        -TimeoutSec $TimeoutSec `
        -NoOutputTimeoutSec $NoOutputTimeoutSec `
        -RunId $cycleRunId `
        -CycleRunId $cycleRunId | Out-Null

    $leaderFinalMock = @{}
    if ($MockFinalDecision) {
        $leaderFinalMock["Decision"] = $MockFinalDecision
    }

    Write-Host "[CYCLE] step=leader_final"
    Invoke-AgentRole `
        -Role leader_final `
        -PlanName $PlanName `
        -Model $LeaderFinalModel `
        -Cli $LeaderFinalCli `
        -DryRun:$DryRun `
        -MockOutputPath (Get-RoleMockPath -BaseDir $MockOutputDir -Role "leader_final") `
        -MockMetadata $leaderFinalMock `
        -TimeoutSec $TimeoutSec `
        -NoOutputTimeoutSec $NoOutputTimeoutSec `
        -RunId $cycleRunId `
        -CycleRunId $cycleRunId | Out-Null

    $finalDirectives = Get-ReportDirectives -Path $config.Roles["leader_final"].ReportPath
    if (-not $finalDirectives.Decision) {
        throw "leader_final_report.md 에서 Decision 헤더를 읽지 못했습니다. leader_final 출력 형식을 확인하세요."
    }

    if ($config.FinalDecisionValues -notcontains $finalDirectives.Decision) {
        throw "leader_final Decision 값이 유효하지 않습니다: $($finalDirectives.Decision). 허용값: $($config.FinalDecisionValues -join ', ')"
    }

    $finalDecision = $finalDirectives.Decision
}
catch {
    $hadError = $true
    Write-Warning $_.Exception.Message
}
finally {
    $summaryFiles = Write-CycleSummaryFiles -Config $config -RunId $cycleRunId -FinalDecision $finalDecision
    Write-Host ("[CYCLE] summary.md={0}" -f $summaryFiles.MarkdownPath)
    Write-Host ("[CYCLE] summary.json={0}" -f $summaryFiles.JsonPath)
    Write-Host ("[CYCLE] finalDecision={0}" -f $finalDecision)
}

if ($hadError) {
    throw "Cycle 실행이 중단되었습니다. leader/reviewer/qa 보고서와 cycle summary 를 확인한 뒤 수정 후 다시 실행하세요."
}
