param(
    [string]$Model
)

. "$PSScriptRoot\agent-common.ps1"

$config = Get-AgentPlanConfig
$reviewPromptText = Get-AgentPromptText -Role reviewer -BasePromptPath $config.Prompts.reviewer
$devReportText = Read-Utf8File -Path $config.Reports.dev
$diffText = Read-Utf8File -Path (Join-Path $config.Plan "dev_diff.patch")

$promptText = @"
$reviewPromptText

아래는 개발자 AI의 보고서다.

$devReportText

아래는 코드 변경 diff 다.

$diffText

해야 할 일:
- 요구사항 충족 여부 검토
- 문서 불일치 여부 검토
- 구조 위반 여부 검토
- 승인 가능 여부 판정
- 개발자 AI에게 전달할 수정 지시문 작성

출력은 markdown 형식으로 작성하라.
"@

Invoke-AgentPrompt -Role reviewer -Cli claude -Model $Model -PromptText $promptText -OutputPath $config.Reports.reviewer
