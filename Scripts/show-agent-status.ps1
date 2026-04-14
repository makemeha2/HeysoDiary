. "$PSScriptRoot\agent-common.ps1"

$config = Get-AgentPlanConfig

if (-not (Test-Path $config.StatusPath)) {
    Write-Host "상태 파일이 없습니다: $($config.StatusPath)"
    exit 0
}

$status = Get-Content -Raw $config.StatusPath | ConvertFrom-Json
$isRunning = $false

if ($status.pid -gt 0) {
    $process = Get-Process -Id $status.pid -ErrorAction SilentlyContinue
    $isRunning = $null -ne $process
}

[pscustomobject]@{
    Role = $status.role
    State = $status.state
    Model = $status.model
    Pid = $status.pid
    RunId = $status.runId
    Running = $isRunning
    OutputPath = $status.outputPath
    InputPath = $status.inputPath
    StdoutPath = $status.stdoutPath
    StderrPath = $status.stderrPath
    UpdatedAt = $status.updatedAt
} | Format-List
