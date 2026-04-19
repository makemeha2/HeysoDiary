param(
    [string]$PlanName = "user_management",
    [int]$MaxCycles = 1,
    [int]$MaxReviewReworkPasses = 1,
    [ValidateSet("leader", "reviewer", "leader_review", "qa", "leader_final")][string]$StartAt = "leader",
    [string]$LeaderModel,
    [string]$BeModel,
    [string]$FeModel,
    [string]$ReviewerModel,
    [string]$LeaderReviewModel,
    [string]$QaModel,
    [string]$LeaderFinalModel,
    [AllowEmptyString()][string]$LeaderCli,
    [AllowEmptyString()][string]$BeCli,
    [AllowEmptyString()][string]$FeCli,
    [AllowEmptyString()][string]$ReviewerCli,
    [AllowEmptyString()][string]$LeaderReviewCli,
    [AllowEmptyString()][string]$QaCli,
    [AllowEmptyString()][string]$LeaderFinalCli,
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

if ($MaxReviewReworkPasses -lt 0) {
    throw "MaxReviewReworkPasses 는 0 이상이어야 합니다."
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

function Invoke-DirectedDevRoles {
    param(
        [Parameter(Mandatory)][pscustomobject]$Directives,
        [Parameter(Mandatory)][string]$DecisionSource,
        [switch]$PreserveExistingOnSkip
    )

    $beRoleConfig = Get-ResolvedRoleConfig -Config $config -Role "be_dev" -Model $BeModel -Cli $BeCli
    if ($Directives.BeRequired) {
        Write-Host ("[CYCLE] step=be_dev action=run source={0}" -f $DecisionSource)
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
    elseif ($PreserveExistingOnSkip -and (Test-Path -LiteralPath $beRoleConfig.ReportPath)) {
        Write-Host ("[CYCLE] step=be_dev action=preserve source={0}" -f $DecisionSource)
    }
    else {
        Write-Host ("[CYCLE] step=be_dev action=pass source={0}" -f $DecisionSource)
        Write-PassRoleArtifacts -RoleConfig $beRoleConfig -Status "PASSED" -Reason "$DecisionSource 가 BE_REQUIRED=false 로 판정했습니다." -RunId $cycleRunId -CycleRunId $cycleRunId
    }

    $feRoleConfig = Get-ResolvedRoleConfig -Config $config -Role "fe_dev" -Model $FeModel -Cli $FeCli
    if ($Directives.FeRequired) {
        Write-Host ("[CYCLE] step=fe_dev action=run source={0}" -f $DecisionSource)
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
    elseif ($PreserveExistingOnSkip -and (Test-Path -LiteralPath $feRoleConfig.ReportPath)) {
        Write-Host ("[CYCLE] step=fe_dev action=preserve source={0}" -f $DecisionSource)
    }
    else {
        Write-Host ("[CYCLE] step=fe_dev action=pass source={0}" -f $DecisionSource)
        Write-PassRoleArtifacts -RoleConfig $feRoleConfig -Status "PASSED" -Reason "$DecisionSource 가 FE_REQUIRED=false 로 판정했습니다." -RunId $cycleRunId -CycleRunId $cycleRunId
    }
}

function Assert-CycleResumePrerequisites {
    param(
        [Parameter(Mandatory)][string]$ResumePoint
    )

    switch ($ResumePoint) {
        "leader" {
            return
        }
        "reviewer" {
            if (-not (Test-Path -LiteralPath $config.Roles["leader"].ReportPath)) {
                throw "-StartAt reviewer 는 leader_report.md 가 필요합니다."
            }

            if (-not (Test-AnyPathExists -Paths @($config.Roles["be_dev"].ReportPath, $config.Roles["fe_dev"].ReportPath))) {
                throw "-StartAt reviewer 는 be_dev_report.md 또는 fe_dev_report.md 가 필요합니다."
            }
        }
        "leader_review" {
            if (-not (Test-Path -LiteralPath $config.Roles["leader"].ReportPath)) {
                throw "-StartAt leader_review 는 leader_report.md 가 필요합니다."
            }

            if (-not (Test-AnyPathExists -Paths @($config.Roles["be_dev"].ReportPath, $config.Roles["fe_dev"].ReportPath))) {
                throw "-StartAt leader_review 는 be_dev_report.md 또는 fe_dev_report.md 가 필요합니다."
            }

            if (-not (Test-Path -LiteralPath $config.Roles["reviewer"].ReportPath)) {
                throw "-StartAt leader_review 는 reviewer_report.md 가 필요합니다."
            }
        }
        "qa" {
            if (-not (Test-Path -LiteralPath $config.Roles["reviewer"].ReportPath)) {
                throw "-StartAt qa 는 reviewer_report.md 가 필요합니다."
            }
        }
        "leader_final" {
            if (-not (Test-Path -LiteralPath $config.Roles["reviewer"].ReportPath)) {
                throw "-StartAt leader_final 는 reviewer_report.md 가 필요합니다."
            }

            if (-not (Test-Path -LiteralPath $config.Roles["qa"].ReportPath)) {
                throw "-StartAt leader_final 는 qa_report.md 가 필요합니다."
            }
        }
    }
}

$config = Get-AgentPlanConfig -PlanName $PlanName
$cycleRunId = New-AgentRunId
$finalDecision = "BLOCKED"
$hadError = $false

Write-Host ("[CYCLE] plan={0} runId={1}" -f $PlanName, $cycleRunId)
Write-Host ("[CYCLE] reports={0}" -f $config.ReportsDir)
Write-Host ("[CYCLE] runtime={0}" -f $config.RuntimeDir)
Write-Host ("[CYCLE] startAt={0}" -f $StartAt)

try {
    Assert-CycleResumePrerequisites -ResumePoint $StartAt

    if ($StartAt -eq "leader") {
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

        Invoke-DirectedDevRoles -Directives $leaderDirectives -DecisionSource "leader"

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
    }
    elseif ($StartAt -eq "reviewer") {
        Write-Host "[CYCLE] step=reviewer action=resume"
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
    }

    $reworkPassesUsed = 0
    $qaExecuted = $false
    $qaSkipReason = $null

    if ($StartAt -eq "qa" -or $StartAt -eq "leader_final") {
        $reworkPassesUsed = $MaxReviewReworkPasses
    }

    while ($StartAt -ne "qa" -and $StartAt -ne "leader_final") {
        Write-Host "[CYCLE] step=leader_review"
        Invoke-AgentRole `
            -Role leader_review `
            -PlanName $PlanName `
            -Model $LeaderReviewModel `
            -Cli $LeaderReviewCli `
            -DryRun:$DryRun `
            -MockOutputPath (Get-RoleMockPath -BaseDir $MockOutputDir -Role "leader_review") `
            -TimeoutSec $TimeoutSec `
            -NoOutputTimeoutSec $NoOutputTimeoutSec `
            -RunId $cycleRunId `
            -CycleRunId $cycleRunId | Out-Null

        $leaderReviewDirectives = Get-ReportDirectives -Path $config.Roles["leader_review"].ReportPath
        if ($null -eq $leaderReviewDirectives.BeRequired -or $null -eq $leaderReviewDirectives.FeRequired) {
            throw "leader_review_report.md 에서 BE_REQUIRED 또는 FE_REQUIRED 헤더를 읽지 못했습니다. leader_review 출력 형식을 확인하세요."
        }

        $needsReviewerDrivenRework = $leaderReviewDirectives.BeRequired -or $leaderReviewDirectives.FeRequired
        if (-not $needsReviewerDrivenRework) {
            Write-Host "[CYCLE] step=qa action=run"
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
            $qaExecuted = $true
            break
        }

        if ($reworkPassesUsed -ge $MaxReviewReworkPasses) {
            $qaSkipReason = "leader_review 가 reviewer 지적에 따른 재개발이 필요하다고 판정했지만, 허용된 재작업 횟수($MaxReviewReworkPasses)를 모두 사용해 qa 를 생략했습니다."
            Write-Warning $qaSkipReason
            break
        }

        $reworkPassesUsed += 1
        Invoke-DirectedDevRoles -Directives $leaderReviewDirectives -DecisionSource "leader_review" -PreserveExistingOnSkip

        Write-Host ("[CYCLE] step=reviewer action=rerun pass={0}" -f $reworkPassesUsed)
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
    }

    if ($StartAt -eq "qa") {
        Write-Host "[CYCLE] step=qa action=resume"
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
        $qaExecuted = $true
    }

    if (-not $qaExecuted -and $StartAt -ne "leader_final") {
        $qaRoleConfig = Get-ResolvedRoleConfig -Config $config -Role "qa" -Model $QaModel -Cli $QaCli
        if (-not $qaSkipReason) {
            $qaSkipReason = "leader_review 판정에 따라 qa 실행이 필요하지 않았습니다."
        }
        Write-Host "[CYCLE] step=qa action=skip"
        Write-PassRoleArtifacts -RoleConfig $qaRoleConfig -Status "SKIPPED" -Reason $qaSkipReason -RunId $cycleRunId -CycleRunId $cycleRunId
    }

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
