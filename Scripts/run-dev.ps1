param(
    [string]$Model
)

. "$PSScriptRoot\agent-common.ps1"

$config = Get-AgentPlanConfig

if (-not (Test-Path $config.Prompts.dev)) {
    throw "개발자 프롬프트 파일이 없습니다: $($config.Prompts.dev)"
}

if (-not (Test-Path $config.Reports.leader)) {
    throw "리더 보고서 파일이 없습니다: $($config.Reports.leader)"
}

$devPromptText = Get-AgentPromptText -Role dev -BasePromptPath $config.Prompts.dev
$leaderReportText = Read-Utf8File -Path $config.Reports.leader

$promptText = @"
$devPromptText

아래는 리더 AI의 최신 보고서 및 개발 지시다.

$leaderReportText

추가 지시:
- 현재 작업 루트는 $($config.Root) 이다.
- 리더 보고서의 지시사항을 기준으로 실제 구현 작업을 수행하라.
- 구현 범위 밖의 변경은 하지 마라.
- 작업이 끝나면 결과를 markdown 형식으로 정리하라.
- 결과는 아래 형식을 반드시 따른다.

### 1. 변경 개요
### 2. 변경 파일 목록
### 3. API 명세
### 4. 구현 세부
### 5. 테스트 방법
### 6. 남은 리스크 / 확인 필요 사항
"@

Invoke-AgentPrompt -Role dev -Cli codex -Model $Model -PromptText $promptText -OutputPath $config.Reports.dev

git diff -- . | Set-Content (Join-Path $config.Plan "dev_diff.patch") -Encoding utf8
git status --short | Set-Content (Join-Path $config.Plan "dev_changed_files.txt") -Encoding utf8
