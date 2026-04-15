param(
    [string]$Model
)

. "$PSScriptRoot\agent-common.ps1"

$config = Get-AgentPlanConfig
$leaderPromptText = Get-AgentPromptText -Role leader -BasePromptPath $config.Prompts.leader
$reviewReportText = Read-Utf8File -Path $config.Reports.reviewer
$qaReportText = Read-Utf8File -Path $config.Reports.qa
$devReportText = Read-Utf8File -Path $config.Reports.dev

$promptText = @"
$leaderPromptText

아래는 개발자 AI 보고서다.

$devReportText

아래는 리뷰어 AI 보고서다.

$reviewReportText

아래는 QA AI 보고서다.

$qaReportText

해야 할 일:
- 현재 단계 판정
- 완료 / 재작업 필요 여부 판정
- 재작업이 필요하면 개발자 AI에게 전달할 통합 수정 지시 작성
- 완료라면 최종 완료 보고서 작성

출력은 markdown 형식으로 작성하라.
"@

Invoke-AgentPrompt -Role leader -Cli claude -Model $Model -PromptText $promptText -OutputPath $config.Reports.leader
