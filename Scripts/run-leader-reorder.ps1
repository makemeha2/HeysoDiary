param(
    [string]$Model
)

. "$PSScriptRoot\agent-common.ps1"

$config = Get-AgentPlanConfig
$leaderPromptText = Read-Utf8File -Path $config.Prompts.leader
$leaderReportText = if (Test-Path $config.Reports.leader) { Read-Utf8File -Path $config.Reports.leader } else { "" }
$devReportText = if (Test-Path $config.Reports.dev) { Read-Utf8File -Path $config.Reports.dev } else { "" }
$reviewReportText = if (Test-Path $config.Reports.reviewer) { Read-Utf8File -Path $config.Reports.reviewer } else { "" }
$qaReportText = if (Test-Path $config.Reports.qa) { Read-Utf8File -Path $config.Reports.qa } else { "" }

$promptText = @"
$leaderPromptText

아래는 기존 리더 보고서다.

$leaderReportText

아래는 개발자 AI의 최신 보고서다.

$devReportText

아래는 리뷰어 AI의 최신 보고서다.

$reviewReportText

아래는 QA AI의 최신 보고서다.

$qaReportText

해야 할 일:
- 리뷰어/QA 보고서의 지적사항을 기준으로 현재 상태를 다시 판정하라.
- 재작업이 필요하면 개발자 AI에게 전달할 수정 지시를 통합된 작업지시 형태로 다시 작성하라.
- 리더의 역할은 구현이 아니라 조정/판정이다. 직접 코드를 고치려 하지 마라.
- 개발자 AI가 바로 실행할 수 있게 누락 수정사항, 우선순위, 금지사항, 확인 항목을 명확히 정리하라.
- 기존에 이미 충족된 항목은 재지시에서 제외하거나 "유지"로 명시하라.
- 결과는 $($config.Reports.leader) 에 저장할 수 있도록 markdown 형식으로 작성하라.

출력 형식:
### 1. 현재 단계
### 2. 현재 판정
### 3. 근거
### 4. 개발자 AI 재작업 지시
### 5. 체크리스트
"@

Invoke-AgentPrompt -Role leader -Cli claude -Model $Model -PromptText $promptText -OutputPath $config.Reports.leader
