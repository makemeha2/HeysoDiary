$ErrorActionPreference = "Stop"

$script:Utf8NoBom = [System.Text.UTF8Encoding]::new($false)
$script:Utf8Bom = [System.Text.UTF8Encoding]::new($true)
$script:Root = Split-Path -Parent $PSScriptRoot
$script:Plan = Join-Path $script:Root "HeysoDiaryDocs\docs\plans\event_monitoring"
$script:ReportsDir = Join-Path $script:Plan "reports"
$script:RuntimeDir = Join-Path $script:Plan ".runtime"
$script:StatusPath = Join-Path $script:RuntimeDir "agent_status.json"

function New-AgentRunId {
    return "{0}_{1}" -f (Get-Date -Format "yyyyMMdd_HHmmss"), ([guid]::NewGuid().ToString("N").Substring(0, 8))
}

function Resolve-PowerShellHost {
    $pwsh = Get-Command pwsh -ErrorAction SilentlyContinue
    if ($pwsh) {
        return $pwsh.Source
    }

    return (Join-Path $PSHOME "powershell.exe")
}

function Resolve-AgentExecutable {
    param([Parameter(Mandatory)][string]$CommandName)

    $commandInfo = Get-Command $CommandName -ErrorAction Stop
    if ($commandInfo.CommandType -eq [System.Management.Automation.CommandTypes]::Application) {
        return [pscustomobject]@{
            FilePath = $commandInfo.Source
            PrefixArguments = @()
        }
    }

    if ($commandInfo.CommandType -eq [System.Management.Automation.CommandTypes]::ExternalScript) {
        return [pscustomobject]@{
            FilePath = Resolve-PowerShellHost
            PrefixArguments = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $commandInfo.Source)
        }
    }

    throw "지원하지 않는 명령 형식입니다: $CommandName ($($commandInfo.CommandType))"
}

function Initialize-AgentEnvironment {
    [Console]::InputEncoding = $script:Utf8NoBom
    [Console]::OutputEncoding = $script:Utf8NoBom
    $global:OutputEncoding = $script:Utf8NoBom

    foreach ($path in @($script:ReportsDir, $script:RuntimeDir)) {
        if (-not (Test-Path $path)) {
            New-Item -ItemType Directory -Path $path | Out-Null
        }
    }
}

function Get-AgentPlanConfig {
    Initialize-AgentEnvironment

    $prompts = [ordered]@{
        leader = Join-Path $script:Plan "prompt_leader.md"
        dev = Join-Path $script:Plan "prompt_developer.md"
        reviewer = Join-Path $script:Plan "prompt_reviewer.md"
        qa = Join-Path $script:Plan "prompt_qa.md"
    }

    $reports = [ordered]@{
        leader = Join-Path $script:ReportsDir "leader_report.md"
        dev = Join-Path $script:ReportsDir "dev_report.md"
        reviewer = Join-Path $script:ReportsDir "review_report.md"
        qa = Join-Path $script:ReportsDir "qa_report.md"
    }

    $models = [ordered]@{
        leader = "opus"
        dev = "gpt-5.4"
        reviewer = "sonnet"
        qa = "gpt-5.4"
    }

    [pscustomobject]@{
        Root = $script:Root
        Plan = $script:Plan
        Prompts = $prompts
        Reports = $reports
        Models = $models
        RuntimeDir = $script:RuntimeDir
        StatusPath = $script:StatusPath
    }
}

function Set-AgentStatus {
    param(
        [string]$Role,
        [string]$State,
        [string]$Model,
        [int]$ProcessId = 0,
        [string]$OutputPath,
        [string]$RunId,
        [string]$InputPath,
        [string]$StdoutPath,
        [string]$StderrPath
    )

    $status = [ordered]@{
        role = $Role
        state = $State
        model = $Model
        pid = $ProcessId
        runId = $RunId
        outputPath = $OutputPath
        inputPath = $InputPath
        stdoutPath = $StdoutPath
        stderrPath = $StderrPath
        updatedAt = (Get-Date).ToString("o")
    }

    $json = $status | ConvertTo-Json
    [System.IO.File]::WriteAllText($script:StatusPath, $json, $script:Utf8Bom)
}

function Read-Utf8File {
    param([Parameter(Mandatory)][string]$Path)

    return [System.IO.File]::ReadAllText($Path, $script:Utf8NoBom)
}

function Write-Utf8File {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Content
    )

    [System.IO.File]::WriteAllText($Path, $Content, $script:Utf8Bom)
}

function Invoke-AgentPrompt {
    param(
        [Parameter(Mandatory)][ValidateSet("leader", "dev", "reviewer", "qa")][string]$Role,
        [Parameter(Mandatory)][ValidateSet("claude", "codex")][string]$Cli,
        [Parameter(Mandatory)][string]$PromptText,
        [Parameter(Mandatory)][string]$OutputPath,
        [string]$Model
    )

    $config = Get-AgentPlanConfig
    if (-not $Model) {
        $Model = $config.Models[$Role]
    }

    $runId = New-AgentRunId
    $inputPath = Join-Path $config.RuntimeDir "$Role.$runId.stdin.txt"
    $stdoutPath = Join-Path $config.RuntimeDir "$Role.$runId.stdout.txt"
    $resultPath = Join-Path $config.RuntimeDir "$Role.$runId.result.txt"
    $stderrPath = Join-Path $config.RuntimeDir "$Role.$runId.stderr.txt"

    Write-Utf8File -Path $inputPath -Content $PromptText

    $commandName = if ($Cli -eq "claude") { "claude" } else { "codex" }
    $resolved = Resolve-AgentExecutable -CommandName $commandName
    $command = $resolved.FilePath
    $arguments = @($resolved.PrefixArguments) + $(if ($Cli -eq "claude") {
        @("-p", "--model", $Model)
    } else {
        @("exec", "--model", $Model, "-o", $resultPath, "-")
    })

    Write-Host ("[{0}] start model={1}" -f $Role.ToUpperInvariant(), $Model)

    $process = Start-Process `
        -FilePath $command `
        -ArgumentList $arguments `
        -WorkingDirectory $config.Root `
        -RedirectStandardInput $inputPath `
        -RedirectStandardOutput $stdoutPath `
        -RedirectStandardError $stderrPath `
        -NoNewWindow `
        -PassThru

    Set-AgentStatus -Role $Role -State "running" -Model $Model -ProcessId $process.Id -OutputPath $OutputPath -RunId $runId -InputPath $inputPath -StdoutPath $stdoutPath -StderrPath $stderrPath
    Write-Host ("[{0}] pid={1} status={2}" -f $Role.ToUpperInvariant(), $process.Id, $config.StatusPath)

    $startedAt = Get-Date
    while (-not $process.HasExited) {
        $elapsed = (Get-Date) - $startedAt
        $status = "PID $($process.Id) elapsed $($elapsed.ToString('hh\:mm\:ss'))"
        Write-Progress -Activity "Running $Role ($Model)" -Status $status -PercentComplete -1
        Start-Sleep -Seconds 1
    }

    Write-Progress -Activity "Running $Role ($Model)" -Completed

    $stderr = if (Test-Path $stderrPath) { Read-Utf8File -Path $stderrPath } else { "" }
    if ($process.ExitCode -ne 0) {
        Set-AgentStatus -Role $Role -State "failed" -Model $Model -ProcessId $process.Id -OutputPath $OutputPath -RunId $runId -InputPath $inputPath -StdoutPath $stdoutPath -StderrPath $stderrPath
        throw "[${Role}] failed with exit code $($process.ExitCode)`n$stderr"
    }

    $stdoutSource = if ($Cli -eq "claude") { $stdoutPath } else { $resultPath }
    $stdout = if (Test-Path $stdoutSource) { Read-Utf8File -Path $stdoutSource } else { "" }
    Write-Utf8File -Path $OutputPath -Content $stdout
    Set-AgentStatus -Role $Role -State "completed" -Model $Model -ProcessId $process.Id -OutputPath $OutputPath -RunId $runId -InputPath $inputPath -StdoutPath $stdoutPath -StderrPath $stderrPath

    $elapsed = (Get-Date) - $startedAt
    Write-Host ("[{0}] done in {1}" -f $Role.ToUpperInvariant(), $elapsed.ToString("hh\:mm\:ss"))
}
