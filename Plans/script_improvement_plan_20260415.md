# 멀티 에이전트 오케스트레이터 전환 계획서

## 문서 목적

기존 `Scripts` 기반 PowerShell 스크립트 꾸러미를 단일 에이전트 실행기에서 **멀티 에이전트 오케스트레이터**로 확장한다.  
목표는 다음과 같다.

- `leader / be_dev / fe_dev / reviewer / qa` 역할 분리
- 모델 선택만으로 CLI가 자동 결정되는 구조 도입
- `PlanName` 기반으로 작업 디렉토리 및 문서 경로를 유연하게 전환
- `leader > be_dev > fe_dev > reviewer > qa > leader_final` 1사이클 자동화
- BE/FE 분리 저장소 환경에서의 git 충돌·권한 혼선 최소화
- 상태 모니터링 및 실패 지점 추적성 개선
- Cycle 종료 후 사람이 leader 보고서를 확인하고 다음 실행 여부를 결정하는 구조 확립

---

## 확정된 의사결정

### 1. 저장소 루트 경로 확정

기준 루트는 아래와 같다.

```text
C:\Projects\HeysoDiary  [https://github.com/makemeha2/HeysoDiary.git: main]
├─ .claude
├─ .git
├─ .vscode
├─ HeysoDiaryBackEnd      [https://github.com/makemeha2/HeysoDiaryBackEnd.git: dev]
├─ heysoDiaryDeploy       [https://github.com/makemeha2/heysoDiaryDeploy.git: dev]
├─ HeysoDiaryDocs         [https://github.com/makemeha2/HeysoDiaryDocs.git: main]
├─ HeysoDiaryFrontEnd     [https://github.com/makemeha2/HeysoDiaryFrontEnd.git: dev]
├─ Scripts
│  ├─ agent-common.ps1
│  ├─ run-dev.ps1
│  ├─ run-leader.ps1
│  ├─ run-qa.ps1
│  ├─ run-review.ps1
│  └─ show-agent-status.ps1
├─ .gitignore
└─ CLAUDE.md
```

작업 루트는 역할별로 다음과 같이 확정한다.

- 문서/오케스트레이션 루트: `C:\Projects\HeysoDiary`
- BE 저장소: `C:\Projects\HeysoDiary\HeysoDiaryBackEnd`
- FE 저장소: `C:\Projects\HeysoDiary\HeysoDiaryFrontEnd`
- Deploy 저장소: `C:\Projects\HeysoDiary\heysoDiaryDeploy`
- Docs 저장소: `C:\Projects\HeysoDiary\HeysoDiaryDocs`

### 2. 역할별 기본 모델 확정

모든 plan에 공통 기본값으로 아래를 사용한다.

- leader = `gpt-5.4`
- be_dev = `opus`
- fe_dev = `opus`
- reviewer = `gpt-5.4`
- qa = `sonnet`

### 3. Provider/CLI 자동 매핑 규칙 확정

우선 아래 기본 규칙만 고려한다.

- `gpt-*` 계열 → OpenAI provider → `codex`
- `opus`, `sonnet` → Anthropic provider → `claude`

예외 규칙, 별도 override 체계, 복수 CLI는 1차 범위에서 제외한다.

### 4. Dev 실행 정책 확정

1차 구현에서는 **반드시 `be_dev` 선행 후 `fe_dev`** 로 간다.  
병렬 실행은 1차 범위에서 제외한다.

단, 아래는 반드시 지원한다.

- `be_dev`만 수행하고 `fe_dev`는 pass
- `fe_dev`만 수행하고 `be_dev`는 pass
- 둘 다 작업이 필요 없으면 dev 단계를 skip

즉, “순차 실행”은 고정하되, 각 dev 역할은 leader 판단에 따라 **실행 / pass / skip** 될 수 있어야 한다.

### 5. 1사이클 종료 후 재실행 방식 확정

- Cycle 실행 후 무조건 종료
- 다음 Cycle은 사람이 leader 보고서를 확인 후 다시 실행
- 추후 “최대 N회 반복” 옵션을 넣을 수 있도록 구조를 열어둔다
- 최종 판정 상태 문자열은 아래로 표준화한다
  - `COMPLETED`
  - `REWORK_REQUIRED`
  - `BLOCKED`

### 6. 상태 모니터링 표시 수준 확정

- 콘솔 중심으로 구현한다
- 별도 요약 대시보드 `md/json`은 복잡하지 않은 선에서 허용한다
- 요약 대시보드가 있다면 **토큰 사용량 정보**를 반드시 포함한다

---

## 1차 범위에서의 핵심 해석

위 결정에 따라, 1차 구현의 방향은 아래로 정리된다.

1. 병렬 오케스트레이션보다 **역할 분리 + 순차 흐름 안정화**가 우선이다.
2. `run-dev.ps1` 단일 구조는 더 이상 유지하지 않고 `be_dev`, `fe_dev` 단위로 분리한다.
3. 상태 모니터링은 “예쁘게”보다 “현재 어디서 멈췄는지 보이는 것”이 중요하다.
4. leader가 각 dev 역할에 대해 **실행 필요 여부**를 판정할 수 있어야 한다.
5. 추후 N회 반복 옵션을 고려하되, 현재는 반드시 **1 Cycle 후 종료**한다.

---

## 제안 아키텍처

### 역할 구성
- `leader`
- `be_dev`
- `fe_dev`
- `reviewer`
- `qa`
- `leader_final`

권장:
- `leader_after`를 별도 스크립트로 유지하기보다 `run-leader.ps1 -Mode Final` 형태로 통합
- 중간 호환용 스크립트는 별도 유지하지 않고 `run-cycle.ps1` 또는 `run-leader.ps1` 경로로 통합

### 핵심 원칙
1. **역할별 설정 분리**
2. **역할별 working directory 분리**
3. **역할별 report/diff/status/log 파일 분리**
4. **모델 지정 중심, CLI는 자동 해석**
5. **1 Cycle 오케스트레이션 지원**
6. **dev 단계는 순차 실행 + 역할별 pass 가능**
7. **병렬 확장은 차후 옵션으로 열어둠**

---

## 목표 디렉토리 구조 제안

```text
Scripts/
  agent-common.ps1
  run-cycle.ps1
  run-leader.ps1
  run-be-dev.ps1
  run-fe-dev.ps1
  run-review.ps1
  run-qa.ps1
  show-agent-status.ps1
  helpers/
    process-stream.ps1
    config-loader.ps1

HeysoDiaryDocs/docs/plans/<PlanName>/
  prompt_leader.md
  prompt_backend.md
  prompt_frontend.md
  prompt_reviewer.md
  prompt_qa.md
  reports/
    leader_report.md
    be_dev_report.md
    fe_dev_report.md
    reviewer_report.md
    qa_report.md
    leader_final_report.md
    cycle_summary.md
  .runtime/
    status/
      leader.json
      be_dev.json
      fe_dev.json
      reviewer.json
      qa.json
      leader_final.json
    logs/
      leader.out.log
      leader.err.log
      be_dev.out.log
      be_dev.err.log
      fe_dev.out.log
      fe_dev.err.log
      reviewer.out.log
      reviewer.err.log
      qa.out.log
      qa.err.log
      leader_final.out.log
      leader_final.err.log
    git/
      be_dev_diff.patch
      be_dev_changed_files.txt
      fe_dev_diff.patch
      fe_dev_changed_files.txt
    dashboard/
      cycle_summary.json
    runs/
      <runId>.json
```

---

## 설정 구조 개편안

기존의 하드코딩된 전역 변수 대신, **단일 설정 객체**를 통해 전체 흐름을 제어한다.

### 권장 설정 형태
```powershell
$agents = [ordered]@{
    leader = @{
        Provider = "openai"
        Model = "gpt-5.4"
        WorkingDirectory = "C:\Projects\HeysoDiary"
        PromptFile = "prompt_leader.md"
        ReportFile = "leader_report.md"
    }
    be_dev = @{
        Provider = "anthropic"
        Model = "opus"
        WorkingDirectory = "C:\Projects\HeysoDiary\HeysoDiaryBackEnd"
        PromptFile = "prompt_backend.md"
        ReportFile = "be_dev_report.md"
        DiffFile = "be_dev_diff.patch"
        ChangedFilesFile = "be_dev_changed_files.txt"
    }
    fe_dev = @{
        Provider = "anthropic"
        Model = "opus"
        WorkingDirectory = "C:\Projects\HeysoDiary\HeysoDiaryFrontEnd"
        PromptFile = "prompt_frontend.md"
        ReportFile = "fe_dev_report.md"
        DiffFile = "fe_dev_diff.patch"
        ChangedFilesFile = "fe_dev_changed_files.txt"
    }
    reviewer = @{
        Provider = "openai"
        Model = "gpt-5.4"
        WorkingDirectory = "C:\Projects\HeysoDiary"
        PromptFile = "prompt_reviewer.md"
        ReportFile = "reviewer_report.md"
    }
    qa = @{
        Provider = "anthropic"
        Model = "sonnet"
        WorkingDirectory = "C:\Projects\HeysoDiary"
        PromptFile = "prompt_qa.md"
        ReportFile = "qa_report.md"
    }
    leader_final = @{
        Provider = "openai"
        Model = "gpt-5.4"
        WorkingDirectory = "C:\Projects\HeysoDiary"
        PromptFile = "prompt_leader.md"
        ReportFile = "leader_final_report.md"
    }
}
```

---

## 역할별 실행 정책

### leader
역할:
- 현재 task 해석
- 이번 cycle에서 `be_dev`, `fe_dev` 수행 필요 여부 판정
- reviewer/qa가 볼 핵심 포인트 정리

산출물 권장 항목:
- 작업 요약
- 범위
- BE 필요 여부
- FE 필요 여부
- 선행순서
- 위험요소
- 완료 기준

### be_dev
역할:
- BE 저장소 기준 구현
- 보고서 및 git diff/changed files 생성

### fe_dev
역할:
- FE 저장소 기준 구현
- 보고서 및 git diff/changed files 생성

### reviewer
역할:
- leader 지시와 BE/FE 결과를 교차 검토
- 누락, 과도 구현, 인터페이스 불일치, 리스크 지적

### qa
역할:
- 테스트 관점에서 확인
- 수동 테스트 포인트 정리
- 실제 미검증 영역과 추정 영역 구분

### leader_final
역할:
- 이번 cycle 최종 판정
- 결과를 `COMPLETED / REWORK_REQUIRED / BLOCKED` 중 하나로 귀결
- 다음 cycle 필요 여부를 사람이 판단할 수 있게 요약

---

## Leader 보고서 표준화 권장안

1차부터 너무 복잡한 YAML parser를 넣지 않더라도, 최소한 아래 헤더 형식은 권장한다.

```md
Decision: REWORK_REQUIRED
BE_REQUIRED: true
FE_REQUIRED: false
NEXT_ORDER: be_dev -> reviewer -> qa -> leader_final
```

권장 이유:
- 스크립트가 정규식으로 쉽게 판독 가능
- 사람이 보고도 이해하기 쉬움

---

## 단계별 구현 계획

## Phase 1. 설정 외부화 및 PlanName 파라미터화

### 목표
- `event_monitoring` 하드코딩 제거
- `PlanName` 기반 경로 계산
- 모델/역할 설정을 한 곳에서 관리

### 작업
1. `Get-AgentPlanConfig` 함수 시그니처 변경
   - `param([string]$PlanName, [hashtable]$Overrides)`
2. `$script:Plan = Join-Path ... event_monitoring` 제거
3. `reports`, `.runtime`, `logs`, `status`, `git`, `dashboard` 하위 경로 자동 생성
4. 기본 모델값을 설정 객체에 모음
5. `run-*.ps1` 스크립트에 `-PlanName` 파라미터 추가

### 완료 기준
- 어떤 plan 디렉토리명이라도 `-PlanName xxx`로 실행 가능
- 모델 기본값이 한 곳에서 수정 가능

---

## Phase 2. 역할 분리: dev → be_dev / fe_dev

### 목표
- BE/FE repo 분리 대응
- 역할별 report/diff/status 분리

### 작업
1. `run-dev.ps1`를 `run-be-dev.ps1`, `run-fe-dev.ps1`로 분리
2. prompt 파일도 분리
   - `prompt_backend.md`
   - `prompt_frontend.md`
3. report 파일 분리
   - `be_dev_report.md`
   - `fe_dev_report.md`
4. git 결과 파일 분리
   - `be_dev_diff.patch`
   - `fe_dev_diff.patch`
5. 역할별 WorkingDirectory 사용

### 완료 기준
- BE와 FE가 서로 다른 repo에서 독립적으로 실행 가능
- git diff, git status가 각 repo 기준으로 따로 저장됨

---

## Phase 3. Model → Provider → CLI 자동 해석

### 목표
- 호출부에서 `-Cli` 제거 또는 선택화
- 모델명만 넘겨도 올바른 CLI 선택

### 작업
1. `Resolve-ProviderFromModel` 함수 추가
2. `Resolve-CliFromProvider` 함수 추가
3. `Invoke-AgentPrompt`가 `Cli` 없이도 실행되도록 수정
4. 필요 시 `-Cli`는 override 용도로만 유지

### 예시 규칙
- `gpt-*` → `openai` → `codex`
- `opus` → `anthropic` → `claude`
- `sonnet` → `anthropic` → `claude`

### 완료 기준
- 호출부에서 `-Model`만 지정해도 정상 동작
- 잘못된 모델 입력 시 명확한 예외 메시지 출력

---

## Phase 4. 상태 모니터링 개선

### 목표
- 단일 `agent_status.json` 구조 제거
- 역할별 상태 추적
- 멈춤 여부 파악 가능
- 콘솔 중심 가시성 강화

### 작업
1. 상태파일을 역할별로 분리
   - `status/leader.json`
   - `status/be_dev.json`
   - `status/fe_dev.json`
   - ...
2. 상태 정보에 아래 필드 추가
   - `Role`
   - `Model`
   - `Provider`
   - `Cli`
   - `Pid`
   - `StartedAt`
   - `LastOutputAt`
   - `LastHeartbeatAt`
   - `Status`
   - `ExitCode`
   - `OutputPath`
   - `OutLogPath`
   - `ErrLogPath`
   - `PromptTokens`
   - `CompletionTokens`
   - `TotalTokens`
3. stdout/stderr 로그 저장 분리
4. 최근 출력 일부를 콘솔에 주기적으로 표시
5. timeout / no-output-timeout 판정 추가
6. cycle 종료 시 요약 파일 생성
   - `reports/cycle_summary.md`
   - `.runtime/dashboard/cycle_summary.json`

### 완료 기준
- 실행 중 현재 역할과 최근 출력이 보임
- 병렬로 바꿔도 상태가 충돌하지 않는 구조임
- cycle summary에 토큰 사용량 집계가 기록됨

---

## Phase 5. 1 Cycle 오케스트레이터 도입

### 목표
- 수동 단계 실행 대신 한 사이클 자동 실행
- 무한 루프 없이 1회전 후 종료
- dev 순차 실행 + pass 지원

### 확정 흐름
1. leader
2. be_dev 필요 시 실행, 아니면 pass
3. fe_dev 필요 시 실행, 아니면 pass
4. reviewer
5. qa
6. leader_final
7. 종료

### 작업
1. `run-cycle.ps1` 추가
2. 내부에서 단계별 실행 순서 제어
3. leader 결과에서 `BE_REQUIRED`, `FE_REQUIRED` 판정 읽기
4. pass 시 더미 상태/요약 기록
5. 마지막에 cycle summary md/json 생성
6. 다음 cycle 자동 반복은 하지 않음

### 완료 기준
- 단일 명령으로 1사이클 수행 가능
- dev 역할 pass가 정상 반영됨
- 종료 시 결과 요약 확인 가능

---

## Phase 6. 입력/출력 검증 및 오류 처리 강화

### 목표
- 선행 산출물 부재 시 친절한 에러
- 실패 원인 파악 시간 단축

### 작업
1. Prompt 파일 존재 검증
2. 선행 보고서 존재 검증
3. WorkingDirectory 존재 검증
4. git 사용 가능 여부 검증
5. CLI 실행 가능 여부 검증
6. 실패 메시지 표준화

### 예시 메시지
- `be_dev_report.md 가 없습니다. 먼저 run-be-dev.ps1 또는 run-cycle.ps1 을 실행하세요.`
- `WorkingDirectory 가 존재하지 않습니다: C:\Projects\HeysoDiary\HeysoDiaryFrontEnd`
- `claude CLI 를 찾을 수 없습니다. PATH 또는 설치 상태를 확인하세요.`

### 완료 기준
- 실패 시 다음 조치가 무엇인지 메시지로 안내됨

---

## Phase 7. 차후 확장을 고려한 구조 열어두기

### 목표
추후 아래를 자연스럽게 추가할 수 있는 구조를 유지한다.

- 최대 N회 반복
- 병렬 dev
- reviewer 세분화
- deploy 역할 추가
- dashboard 고도화

### 1차에서는 구현하지 않지만 고려할 인터페이스
예:
```powershell
param(
    [string]$PlanName,
    [int]$MaxCycles = 1
)
```

현재는 `MaxCycles=1`만 허용하는 형태로 두고, 이후 확장 가능하게만 설계한다.

---

## 권장 구현 순서

1. Phase 1
2. Phase 2
3. Phase 3
4. Phase 6
5. Phase 4
6. Phase 5
7. Phase 7

이 순서를 권장하는 이유:
- 먼저 설정 구조와 역할 분리가 되어야 나머지가 쉬워진다.
- 오케스트레이터는 마지막에 올리는 편이 안전하다.

---

## 테스트 전략

테스트는 **기능 검증 + 통합 시나리오 검증**으로 나눈다.

---

## 테스트 준비

### 샘플 Plan 디렉토리 준비
예:
`HeysoDiaryDocs/docs/plans/test_plan`

필수 파일:
- `prompt_leader.md`
- `prompt_backend.md`
- `prompt_frontend.md`
- `prompt_reviewer.md`
- `prompt_qa.md`

### 테스트용 저장소 준비
- BE/FE repo는 실제 repo 또는 안전한 샘플 repo 사용
- 테스트 중에는 `dev/main` 보호 브랜치에 직접 쓰기보다 테스트 브랜치 사용 권장

### 테스트용 더미 CLI 전략
실제 codex/claude를 매번 호출하지 않도록, 초기에는 더미 실행 모드가 있으면 좋다.

권장:
- `-DryRun`
- `-MockAgentOutput`

예:
- mock 모드에서 지정된 markdown 보고서를 자동 생성
- stdout/stderr도 샘플 로그 출력
- 토큰 사용량도 mock 값으로 기록

---

## 테스트 케이스

## TC01. PlanName 파라미터 경로 계산
### 목적
`-PlanName`에 따라 올바른 경로가 계산되는지 확인

### 절차
1. `run-leader.ps1 -PlanName test_plan -DryRun`
2. 생성된 reports/.runtime 경로 확인

### 기대 결과
- `HeysoDiaryDocs/docs/plans/test_plan` 기준으로 모든 경로 생성
- `event_monitoring` 문자열이 코드에 남아 있지 않음

---

## TC02. 모델 자동 매핑
### 목적
모델명만으로 provider/cli가 정상 선택되는지 확인

### 절차
1. `leader = gpt-5.4`, `be_dev = opus`, `qa = sonnet`으로 설정
2. 각 역할 1회씩 DryRun 실행
3. 상태파일의 `Provider`, `Cli`, `Model` 확인

### 기대 결과
- `gpt-5.4` → `openai/codex`
- `opus`, `sonnet` → `anthropic/claude`

---

## TC03. 역할별 WorkingDirectory 분리
### 목적
BE/FE가 다른 repo를 정상 참조하는지 확인

### 절차
1. `be_dev`, `fe_dev`의 WorkingDirectory를 각기 다르게 설정
2. DryRun 또는 실제 실행
3. git diff / status 출력 파일 확인

### 기대 결과
- BE diff는 BE repo 기준
- FE diff는 FE repo 기준
- 서로의 저장소 파일이 섞이지 않음

---

## TC04. 역할별 상태파일 분리
### 목적
상태가 충돌하지 않는지 확인

### 절차
1. `run-cycle.ps1 -PlanName test_plan -DryRun`
2. `status/` 하위 json 생성 여부 확인

### 기대 결과
- `leader.json`, `be_dev.json`, `fe_dev.json`, `reviewer.json`, `qa.json`, `leader_final.json` 각각 생성
- 내용이 서로 덮어써지지 않음

---

## TC05. 순차 Dev 실행
### 목적
확정된 정책대로 `be_dev` 선행 후 `fe_dev`가 수행되는지 확인

### 절차
1. `run-cycle.ps1 -PlanName test_plan`
2. 실행 순서 기록 확인

### 기대 결과
- `leader -> be_dev -> fe_dev -> reviewer -> qa -> leader_final`
- 각 단계 완료 후 다음 단계 진행

---

## TC06. Dev pass 처리
### 목적
작업이 없는 역할이 pass 되는지 확인

### 절차
1. leader mock 결과를 아래처럼 생성
   - `BE_REQUIRED: true`
   - `FE_REQUIRED: false`
2. `run-cycle.ps1 -PlanName test_plan -DryRun`
3. 결과 파일과 상태파일 확인

### 기대 결과
- be_dev는 실행됨
- fe_dev는 `PASS` 또는 `SKIPPED` 상태로 기록됨
- cycle은 정상 ادامه됨

---

## TC07. 둘 다 skip 처리
### 목적
dev 작업이 전혀 없을 때 reviewer/qa/leader_final 흐름이 유지되는지 확인

### 절차
1. leader mock 결과를 아래처럼 생성
   - `BE_REQUIRED: false`
   - `FE_REQUIRED: false`
2. cycle 실행

### 기대 결과
- be_dev, fe_dev 모두 skip
- reviewer, qa, leader_final 단계는 정상 실행

---

## TC08. 선행 산출물 누락 처리
### 목적
필요 파일 누락 시 친절한 오류를 내는지 확인

### 절차
1. `prompt_backend.md` 삭제 또는 이름 변경
2. `run-be-dev.ps1 -PlanName test_plan`
3. 메시지 확인

### 기대 결과
- 실패 사유가 명확하게 출력됨
- 다음 조치가 안내됨

---

## TC09. 로그 무출력 timeout 처리
### 목적
에이전트 멈춤 감지 확인

### 절차
1. mock 프로세스를 생성하되 일정 시간 이후 출력 중단
2. no-output timeout을 짧게 설정
3. 상태 파일 확인

### 기대 결과
- `Status = hung` 또는 `timeout`
- 종료 또는 중단 처리 수행

---

## TC10. 1 Cycle 종료 판정
### 목적
무한 루프 없이 1회전 후 종료되는지 확인

### 절차
1. leader_final mock 결과를 `REWORK_REQUIRED` 로 반환
2. `run-cycle.ps1` 실행
3. 프로세스가 자동 재반복하는지 여부 확인

### 기대 결과
- 결과를 기록하고 종료
- 자동으로 다음 cycle은 실행하지 않음

---

## TC11. 토큰 사용량 집계
### 목적
대시보드와 요약 파일에 토큰 정보가 기록되는지 확인

### 절차
1. mock 또는 실제 실행에서 각 역할별 토큰 수치 기록
2. cycle summary 파일 확인

### 기대 결과
- 역할별 토큰 사용량이 보임
- 총합 토큰 수가 집계됨

---

## TC12. 실제 저장소 대상 통합 검증
### 목적
실제 프로젝트 구조에서 동작하는지 확인

### 절차
1. test 브랜치 생성
2. 실제 BE/FE repo 경로 설정
3. 실제 CLI로 1회 cycle 실행
4. 보고서, diff, changed_files, status, logs 점검

### 기대 결과
- 각 역할 산출물이 정상 생성
- git 충돌 또는 저장소 혼선 없음
- 사람이 후속 판단 가능할 정도의 보고서 품질 확보

---

## Cycle Summary 제안 포맷

### Markdown 예시
```md
# Cycle Summary

- PlanName: event_monitoring
- RunId: 20260415-213000
- FinalDecision: REWORK_REQUIRED

## Agents
| Role | Model | Status | PromptTokens | CompletionTokens | TotalTokens |
|------|-------|--------|--------------|------------------|-------------|
| leader | gpt-5.4 | completed | 1200 | 800 | 2000 |
| be_dev | opus | completed | 5000 | 2200 | 7200 |
| fe_dev | opus | passed | 0 | 0 | 0 |
| reviewer | gpt-5.4 | completed | 1400 | 900 | 2300 |
| qa | sonnet | completed | 2100 | 1100 | 3200 |
| leader_final | gpt-5.4 | completed | 800 | 500 | 1300 |

## Totals
- PromptTokens: 10500
- CompletionTokens: 5500
- TotalTokens: 16000
```

### JSON 예시 필드
- `planName`
- `runId`
- `finalDecision`
- `agents[]`
  - `role`
  - `model`
  - `status`
  - `promptTokens`
  - `completionTokens`
  - `totalTokens`
- `totals`

---

## 구현 완료 정의 (Definition of Done)

아래를 모두 만족하면 본 전환 작업은 1차 완료로 본다.

1. `-PlanName` 으로 임의의 작업 계획 디렉토리를 지정할 수 있다.
2. `leader / be_dev / fe_dev / reviewer / qa / leader_final` 역할이 분리되어 있다.
3. BE/FE 각기 다른 repo에서 독립 실행된다.
4. 모델명만으로 CLI/provider가 자동 선택된다.
5. 역할별 상태파일·로그·diff·보고서가 분리되어 저장된다.
6. `run-cycle.ps1` 로 1회전 자동 실행이 가능하다.
7. `be_dev 선행 -> fe_dev` 순차 흐름과 역할별 pass/skip을 지원한다.
8. timeout / missing file / invalid path 에 대한 에러 메시지가 충분히 친절하다.
9. cycle summary에 토큰 사용량이 포함된다.
10. 최소 1회의 실제 프로젝트 통합 테스트를 통과했다.

---

## 권장 후속 개선 과제

1. Plan별 설정 파일 (`agent.config.psd1`) 지원
2. `MaxCycles > 1` 반복 지원
3. 병렬 dev 실행 옵션
4. leader 판정 결과를 더 구조적으로 표준화
5. `reviewer`를 `be_reviewer`, `fe_reviewer`로 추가 분리
6. QA 체크리스트 자동 생성
7. dashboard 고도화
8. deploy 역할 추가

---

## 최종 제안

우선은 아래 범위까지만 1차 구현하는 것이 가장 현실적이다.

- Phase 1 ~ Phase 6 중심
- 1 Cycle 자동화
- BE/FE 분리
- 모델 자동 매핑
- 상태파일 다중화
- dev 순차 실행 + pass/skip
- 토큰 사용량 포함 cycle summary
- 테스트용 DryRun/MockAgentOutput 지원

이 범위만 완성돼도 현재의 단일 스크립트 묶음에서 한 단계 높은 **실전형 멀티 에이전트 오케스트레이터**로 충분히 전환할 수 있다.
