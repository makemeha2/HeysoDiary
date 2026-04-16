param(
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$PlanName,
    [switch]$IncludeLogs
)

. "$PSScriptRoot\agent-common.ps1"

$config = Get-AgentPlanConfig -PlanName $PlanName
$statuses = Get-AllAgentStatuses -Config $config

if (-not $statuses -or $statuses.Count -eq 0) {
    Write-Host "상태 파일이 없습니다: $($config.StatusDir)"
    Write-Host "먼저 run-cycle.ps1 또는 개별 run-*.ps1 스크립트를 실행하세요."
    exit 0
}

$statuses |
    Sort-Object Role |
    Select-Object `
        Role,
        Status,
        Model,
        Provider,
        Cli,
        Pid,
        StartedAt,
        LastOutputAt,
        ExitCode,
        PromptTokens,
        CompletionTokens,
        TotalTokens |
    Format-Table -AutoSize

if ($IncludeLogs) {
    foreach ($status in ($statuses | Sort-Object Role)) {
        Write-Host ""
        Write-Host ("[{0}] recent={1}" -f $status.Role.ToUpperInvariant(), $status.RecentOutput)
        if ($status.OutLogPath -and (Test-Path -LiteralPath $status.OutLogPath)) {
            Write-Host ("  out: {0}" -f $status.OutLogPath)
        }
        if ($status.ErrLogPath -and (Test-Path -LiteralPath $status.ErrLogPath)) {
            Write-Host ("  err: {0}" -f $status.ErrLogPath)
        }
        if ($status.ReportPath -and (Test-Path -LiteralPath $status.ReportPath)) {
            Write-Host ("  report: {0}" -f $status.ReportPath)
        }
    }
}

$summaryPath = Join-Path $config.DashboardDir "cycle_summary.json"
if (Test-Path -LiteralPath $summaryPath) {
    Write-Host ""
    Write-Host ("cycle summary: {0}" -f $summaryPath)
}
