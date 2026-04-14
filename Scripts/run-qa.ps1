param(
    [string]$Model
)

. "$PSScriptRoot\agent-common.ps1"

$config = Get-AgentPlanConfig
$qaPromptText = Read-Utf8File -Path $config.Prompts.qa
$devReportText = Read-Utf8File -Path $config.Reports.dev
$reviewReportText = Read-Utf8File -Path $config.Reports.reviewer

$promptText = @"
$qaPromptText

아래는 개발자 AI 보고서다.

$devReportText

아래는 리뷰어 AI 보고서다.

$reviewReportText

해야 할 일:
- 정상/예외/경계/회귀 테스트 케이스 작성
- 발견 이슈 정리
- QA 통과 여부 판정
- 개발자에게 전달할 수정 요청 정리

출력은 markdown 형식으로 작성하라.
"@

Invoke-AgentPrompt -Role qa -Cli claude -Model $Model -PromptText $promptText -OutputPath $config.Reports.qa
