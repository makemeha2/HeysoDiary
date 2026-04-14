param(
    [string]$Model
)

. "$PSScriptRoot\agent-common.ps1"

$config = Get-AgentPlanConfig
$leaderPromptText = Read-Utf8File -Path $config.Prompts.leader

$promptText = @"
$leaderPromptText

추가 지시:
현재 작업은 monitoring_event 관리자 화면 및 API 구현이다.
작업 루트는 $($config.Root) 이다.
리더 보고서를 작성하고 개발자 AI에게 넘길 작업 지시를 구체화하라.
결과는 $($config.Reports.leader) 에 저장할 수 있도록 markdown 형식으로 출력하라.
"@

Invoke-AgentPrompt -Role leader -Cli claude -Model $Model -PromptText $promptText -OutputPath $config.Reports.leader
