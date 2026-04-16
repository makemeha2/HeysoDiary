$ErrorActionPreference = "Stop"

$script:Utf8NoBom = [System.Text.UTF8Encoding]::new($false)
$script:Utf8Bom = [System.Text.UTF8Encoding]::new($true)
$script:Root = Split-Path -Parent $PSScriptRoot

function New-AgentRunId {
    return "{0}_{1}" -f (Get-Date -Format "yyyyMMdd_HHmmss"), ([guid]::NewGuid().ToString("N").Substring(0, 8))
}

function Ensure-Directory {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
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

    $commandInfo = Get-Command $CommandName -ErrorAction SilentlyContinue
    if (-not $commandInfo) {
        return $null
    }

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
    param([Parameter(Mandatory)][pscustomobject]$Config)

    [Console]::InputEncoding = $script:Utf8NoBom
    [Console]::OutputEncoding = $script:Utf8NoBom
    $global:OutputEncoding = $script:Utf8NoBom

    foreach ($path in @(
        $Config.PlanDir,
        $Config.ReportsDir,
        $Config.RuntimeDir,
        $Config.StatusDir,
        $Config.LogsDir,
        $Config.GitDir,
        $Config.DashboardDir,
        $Config.RunsDir
    )) {
        Ensure-Directory -Path $path
    }
}

function Write-Utf8File {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Content
    )

    $parent = Split-Path -Parent $Path
    if ($parent) {
        Ensure-Directory -Path $parent
    }

    [System.IO.File]::WriteAllText($Path, $Content, $script:Utf8Bom)
}

function Read-Utf8File {
    param([Parameter(Mandatory)][string]$Path)

    return [System.IO.File]::ReadAllText($Path, $script:Utf8NoBom)
}

function Write-JsonFile {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]$Data
    )

    $json = $Data | ConvertTo-Json -Depth 10
    Write-Utf8File -Path $Path -Content $json
}

function Get-JsonObjectFromFile {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return $null
    }

    $raw = Get-Content -Raw -LiteralPath $Path -ErrorAction SilentlyContinue
    if ([string]::IsNullOrWhiteSpace($raw)) {
        return $null
    }

    try {
        return ($raw | ConvertFrom-Json)
    }
    catch {
        return $null
    }
}

function Read-JsonFile {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return $null
    }

    $raw = Get-Content -Raw -LiteralPath $Path
    if ([string]::IsNullOrWhiteSpace($raw)) {
        return $null
    }

    return ($raw | ConvertFrom-Json)
}

function Resolve-ProviderFromModel {
    param([Parameter(Mandatory)][string]$Model)

    if ($Model -match '^gpt-') {
        return "openai"
    }

    if ($Model -in @("opus", "sonnet", "haiku")) {
        return "anthropic"
    }

    if ($Model -match '^(claude-)?(opus|sonnet|haiku)(-|$)') {
        return "anthropic"
    }

    throw "지원하지 않는 모델입니다: $Model. 현재는 gpt-* / claude-* / opus / sonnet / haiku 만 지원합니다. 모델명을 확인하거나 Get-AgentPlanConfig 기본값을 수정하세요."
}

function Resolve-CliFromProvider {
    param([Parameter(Mandatory)][ValidateSet("openai", "anthropic")][string]$Provider)

    switch ($Provider) {
        "openai" { return "codex" }
        "anthropic" { return "claude" }
    }
}

function Normalize-AgentCli {
    param([AllowEmptyString()][string]$Cli)

    if ([string]::IsNullOrWhiteSpace($Cli)) {
        return $null
    }

    $normalized = $Cli.Trim().ToLowerInvariant()
    if ($normalized -notin @("claude", "codex")) {
        throw "지원하지 않는 CLI 입니다: $Cli. 허용값: claude, codex"
    }

    return $normalized
}

function Get-DefaultRoleDefinitions {
    param([Parameter(Mandatory)][hashtable]$Paths)

    return [ordered]@{
        leader = [ordered]@{
            Role = "leader"
            DefaultModel = "claude-opus-4-6"
            WorkingDirectory = $Paths.Root
            PromptCandidates = @("prompt_leader.md", "prompt_master.md")
            AddendumAliases = @("leader", "master")
            ReportFileName = "leader_report.md"
            NeedsGitArtifacts = $false
        }
        be_dev = [ordered]@{
            Role = "be_dev"
            DefaultModel = "gpt-5.4"
            WorkingDirectory = $Paths.BackEnd
            PromptCandidates = @("prompt_backend.md", "prompt_developer.md")
            AddendumAliases = @("backend", "be_dev", "developer", "dev")
            ReportFileName = "be_dev_report.md"
            NeedsGitArtifacts = $true
            DiffFileName = "be_dev_diff.patch"
            ChangedFilesFileName = "be_dev_changed_files.txt"
        }
        fe_dev = [ordered]@{
            Role = "fe_dev"
            DefaultModel = "gpt-5.4"
            WorkingDirectory = $Paths.FrontEnd
            PromptCandidates = @("prompt_frontend.md", "prompt_developer.md")
            AddendumAliases = @("frontend", "fe_dev", "developer", "dev")
            ReportFileName = "fe_dev_report.md"
            NeedsGitArtifacts = $true
            DiffFileName = "fe_dev_diff.patch"
            ChangedFilesFileName = "fe_dev_changed_files.txt"
        }
        reviewer = [ordered]@{
            Role = "reviewer"
            DefaultModel = "claude-sonnet-4-6"
            WorkingDirectory = $Paths.Root
            PromptCandidates = @("prompt_reviewer.md")
            AddendumAliases = @("reviewer", "review")
            ReportFileName = "reviewer_report.md"
            NeedsGitArtifacts = $false
        }
        qa = [ordered]@{
            Role = "qa"
            DefaultModel = "claude-haiku-4-5"
            WorkingDirectory = $Paths.Root
            PromptCandidates = @("prompt_qa.md")
            AddendumAliases = @("qa")
            ReportFileName = "qa_report.md"
            NeedsGitArtifacts = $false
        }
        leader_final = [ordered]@{
            Role = "leader_final"
            DefaultModel = "gpt-5.4"
            WorkingDirectory = $Paths.Root
            PromptCandidates = @("prompt_leader.md", "prompt_master.md")
            AddendumAliases = @("leader", "leader_final", "master")
            ReportFileName = "leader_final_report.md"
            NeedsGitArtifacts = $false
        }
    }
}

function Copy-Hashtable {
    param([Parameter(Mandatory)][hashtable]$Source)

    $copy = [ordered]@{}
    foreach ($key in $Source.Keys) {
        $value = $Source[$key]
        if ($value -is [hashtable]) {
            $copy[$key] = Copy-Hashtable -Source $value
        }
        elseif ($value -is [System.Collections.IDictionary]) {
            $nested = [ordered]@{}
            foreach ($nestedKey in $value.Keys) {
                $nested[$nestedKey] = $value[$nestedKey]
            }
            $copy[$key] = $nested
        }
        elseif ($value -is [System.Collections.IEnumerable] -and $value -isnot [string]) {
            $copy[$key] = @($value)
        }
        else {
            $copy[$key] = $value
        }
    }

    return $copy
}

function Apply-HashtableOverrides {
    param(
        [Parameter(Mandatory)][hashtable]$Target,
        [Parameter(Mandatory)][hashtable]$Overrides
    )

    foreach ($key in $Overrides.Keys) {
        if ($Target.Contains($key) -and $Target[$key] -is [hashtable] -and $Overrides[$key] -is [hashtable]) {
            Apply-HashtableOverrides -Target $Target[$key] -Overrides $Overrides[$key]
            continue
        }

        $Target[$key] = $Overrides[$key]
    }
}

function Get-AgentPlanConfig {
    param(
        [string]$PlanName = "",
        [hashtable]$Overrides = @{}
    )

    if ([string]::IsNullOrWhiteSpace($PlanName)) {
        throw "-PlanName 값은 필수입니다. HeysoDiaryDocs/docs/plans 아래의 plan 디렉토리 이름을 전달하세요."
    }

    $paths = [ordered]@{
        Root = $script:Root
        Docs = Join-Path $script:Root "HeysoDiaryDocs"
        Plans = Join-Path $script:Root "HeysoDiaryDocs\docs\plans"
        PlanDir = Join-Path $script:Root ("HeysoDiaryDocs\docs\plans\{0}" -f $PlanName)
        ReportsDir = Join-Path $script:Root ("HeysoDiaryDocs\docs\plans\{0}\reports" -f $PlanName)
        RuntimeDir = Join-Path $script:Root ("HeysoDiaryDocs\docs\plans\{0}\.runtime" -f $PlanName)
        StatusDir = Join-Path $script:Root ("HeysoDiaryDocs\docs\plans\{0}\.runtime\status" -f $PlanName)
        LogsDir = Join-Path $script:Root ("HeysoDiaryDocs\docs\plans\{0}\.runtime\logs" -f $PlanName)
        GitDir = Join-Path $script:Root ("HeysoDiaryDocs\docs\plans\{0}\.runtime\git" -f $PlanName)
        DashboardDir = Join-Path $script:Root ("HeysoDiaryDocs\docs\plans\{0}\.runtime\dashboard" -f $PlanName)
        RunsDir = Join-Path $script:Root ("HeysoDiaryDocs\docs\plans\{0}\.runtime\runs" -f $PlanName)
        BackEnd = Join-Path $script:Root "HeysoDiaryBackEnd"
        FrontEnd = Join-Path $script:Root "HeysoDiaryFrontEnd"
        Deploy = Join-Path $script:Root "heysoDiaryDeploy"
        DocsRepo = Join-Path $script:Root "HeysoDiaryDocs"
    }

    $roleDefinitions = Get-DefaultRoleDefinitions -Paths $paths
    if ($Overrides.Count -gt 0) {
        Apply-HashtableOverrides -Target $roleDefinitions -Overrides $Overrides
    }

    $roles = [ordered]@{}
    foreach ($roleName in $roleDefinitions.Keys) {
        $definition = Copy-Hashtable -Source $roleDefinitions[$roleName]
        $model = $definition.DefaultModel
        $provider = Resolve-ProviderFromModel -Model $model
        $cli = Resolve-CliFromProvider -Provider $provider
        $promptCandidates = @()
        foreach ($candidate in $definition.PromptCandidates) {
            $promptCandidates += (Join-Path $paths.PlanDir $candidate)
        }

        $promptPath = $null
        foreach ($candidatePath in $promptCandidates) {
            if (Test-Path -LiteralPath $candidatePath) {
                $promptPath = $candidatePath
                break
            }
        }
        if (-not $promptPath) {
            $promptPath = $promptCandidates[0]
        }

        $roleObject = [pscustomobject]@{
            Role = $roleName
            Model = $model
            Provider = $provider
            Cli = $cli
            WorkingDirectory = $definition.WorkingDirectory
            PromptCandidates = $promptCandidates
            PromptPath = $promptPath
            AddendumAliases = @($definition.AddendumAliases)
            ReportPath = Join-Path $paths.ReportsDir $definition.ReportFileName
            StatusPath = Join-Path $paths.StatusDir ("{0}.json" -f $roleName)
            OutLogPath = Join-Path $paths.LogsDir ("{0}.out.log" -f $roleName)
            ErrLogPath = Join-Path $paths.LogsDir ("{0}.err.log" -f $roleName)
            NeedsGitArtifacts = [bool]$definition.NeedsGitArtifacts
            DiffPath = if ($definition.Contains("DiffFileName")) { Join-Path $paths.GitDir $definition.DiffFileName } else { $null }
            ChangedFilesPath = if ($definition.Contains("ChangedFilesFileName")) { Join-Path $paths.GitDir $definition.ChangedFilesFileName } else { $null }
        }

        $roles[$roleName] = $roleObject
    }

    $config = [pscustomobject]@{
        Root = $paths.Root
        DocsRoot = $paths.Docs
        PlansRoot = $paths.Plans
        PlanName = $PlanName
        PlanDir = $paths.PlanDir
        ReportsDir = $paths.ReportsDir
        RuntimeDir = $paths.RuntimeDir
        StatusDir = $paths.StatusDir
        LogsDir = $paths.LogsDir
        GitDir = $paths.GitDir
        DashboardDir = $paths.DashboardDir
        RunsDir = $paths.RunsDir
        Repositories = [pscustomobject]@{
            Root = $paths.Root
            BackEnd = $paths.BackEnd
            FrontEnd = $paths.FrontEnd
            Deploy = $paths.Deploy
            Docs = $paths.DocsRepo
        }
        Roles = $roles
        FinalDecisionValues = @("COMPLETED", "REWORK_REQUIRED", "BLOCKED")
    }

    Initialize-AgentEnvironment -Config $config
    return $config
}

function Copy-RoleConfig {
    param([Parameter(Mandatory)][pscustomobject]$RoleConfig)

    $copy = [ordered]@{}
    foreach ($property in $RoleConfig.PSObject.Properties) {
        $value = $property.Value
        if ($value -is [System.Collections.IEnumerable] -and $value -isnot [string]) {
            $copy[$property.Name] = @($value)
        }
        else {
            $copy[$property.Name] = $value
        }
    }

    return [pscustomobject]$copy
}

function Get-ResolvedRoleConfig {
    param(
        [Parameter(Mandatory)][pscustomobject]$Config,
        [Parameter(Mandatory)][ValidateSet("leader", "be_dev", "fe_dev", "reviewer", "qa", "leader_final")][string]$Role,
        [string]$Model,
        [AllowEmptyString()][string]$Cli
    )

    $roleConfig = Copy-RoleConfig -RoleConfig $Config.Roles[$Role]
    if ($Model) {
        $roleConfig.Model = $Model
        $roleConfig.Provider = Resolve-ProviderFromModel -Model $Model
    }

    $resolvedCli = Normalize-AgentCli -Cli $Cli
    if ($resolvedCli) {
        $roleConfig.Cli = $resolvedCli
        $roleConfig.Provider = if ($resolvedCli -eq "claude") { "anthropic" } else { "openai" }
    }
    else {
        $roleConfig.Cli = Resolve-CliFromProvider -Provider $roleConfig.Provider
    }

    return $roleConfig
}

function Get-PlanAddendumFiles {
    param(
        [Parameter(Mandatory)][pscustomobject]$Config,
        [Parameter(Mandatory)][pscustomobject]$RoleConfig
    )

    $files = [System.Collections.Generic.List[System.IO.FileInfo]]::new()
    $commonPattern = Join-Path $Config.PlanDir "prompt_addendum_*.md"
    foreach ($file in Get-ChildItem -Path $commonPattern -File -ErrorAction SilentlyContinue | Sort-Object Name) {
        $files.Add($file)
    }

    foreach ($alias in $RoleConfig.AddendumAliases) {
        $rolePattern = Join-Path $Config.PlanDir ("prompt_{0}_addendum_*.md" -f $alias)
        foreach ($file in Get-ChildItem -Path $rolePattern -File -ErrorAction SilentlyContinue | Sort-Object Name) {
            if (-not ($files | Where-Object FullName -eq $file.FullName)) {
                $files.Add($file)
            }
        }
    }

    return @($files)
}

function Get-AgentPromptText {
    param(
        [Parameter(Mandatory)][pscustomobject]$Config,
        [Parameter(Mandatory)][pscustomobject]$RoleConfig
    )

    $sections = [System.Collections.Generic.List[string]]::new()
    $sections.Add((Read-Utf8File -Path $RoleConfig.PromptPath))

    $addendumFiles = Get-PlanAddendumFiles -Config $Config -RoleConfig $RoleConfig
    if ($addendumFiles.Count -gt 0) {
        $sections.Add("`n---`n## 추가 요구사항 문서`n아래 문서를 기존 프롬프트와 함께 반드시 반영하라.")

        foreach ($file in $addendumFiles) {
            $content = Read-Utf8File -Path $file.FullName
            $sections.Add(("`n### {0}`n{1}" -f $file.Name, $content))
        }
    }

    if (Test-Path -LiteralPath (Join-Path $Config.PlanDir "plan.md")) {
        $sections.Add("`n---`n## 실행 우선순위`n- plan.md 에 확정 의사결정이 있으면 그 내용을 최우선 기준으로 따른다.")
    }

    return ($sections -join "`n")
}

function Get-FileSection {
    param(
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][string]$Path,
        [string]$WhenMissing = "(없음)"
    )

    $content = if (Test-Path -LiteralPath $Path) { Read-Utf8File -Path $Path } else { $WhenMissing }
    return @"
## $Title
$content
"@
}

function New-PlanSnapshotContent {
    param(
        [Parameter(Mandatory)][string]$SourcePath,
        [Parameter(Mandatory)][string]$Content,
        [Parameter(Mandatory)][string]$Role
    )

    return @"
# Local Plan Snapshot ($Role)

- Source: $SourcePath
- GeneratedAt: $((Get-Date).ToString("o"))

---

$Content
"@
}

function Get-UserManagementBackendSnapshot {
    return @"
Use this snapshot instead of reading the full external plan.

Goal
- Build phase-1 admin user management backend for local and social users.

In scope
- Admin APIs under /api/admin/users/**
- List/detail/create/update/status/password/delete
- Self-protection and last-active-admin protection
- LOCAL-only password reset and delete
- Duplicate checks for email and LOCAL loginId
- Block updates for WITHDRAWN users

Out of scope
- DB schema changes
- Admin creation for GOOGLE/NAVER users
- loginId change
- Forced session invalidation after password reset
- Cleanup of orphan rows after hard delete

Reference patterns inside backend repo
- monitoringMng for pagination/filter patterns
- aiTemplate for admin CRUD endpoint style
- user for existing domain and mapper reuse
- auth/service/AdminAuthorizationService.java for requireAdminUser()

Required endpoints
- GET /api/admin/users
- GET /api/admin/users/{userId}
- POST /api/admin/users
- POST /api/admin/users/{userId}/update
- POST /api/admin/users/{userId}/status
- POST /api/admin/users/{userId}/password
- POST /api/admin/users/{userId}/delete

Request/response rules
- Base path: /api/admin/users
- Require admin scope and admin role
- Use ResponseEntity<T>
- Return machine-readable errorCode for 409 responses

Required 409 errorCode values
- EMAIL_DUPLICATED
- LOGIN_ID_DUPLICATED
- CANNOT_DEMOTE_SELF
- CANNOT_DEACTIVATE_SELF
- CANNOT_DELETE_SELF
- LAST_ADMIN_PROTECTED
- ONLY_LOCAL_ALLOWED
- WITHDRAWN_USER_IMMUTABLE

Data/query rules
- Query uses tb_user u LEFT JOIN tb_user_auth ua ON u.user_id = ua.user_id
- keyword matches email, nickname, login_id
- Filters: role, status, authProvider
- Pagination: page, size, offset

Create rules
- LOCAL only
- providerUserId = loginId
- status = ACTIVE
- password stored as BCrypt hash

Update/status/delete rules
- Cannot demote self
- Cannot deactivate self
- Cannot delete self
- Protect the last ACTIVE ADMIN
- WITHDRAWN user is immutable
- Password reset and delete are LOCAL only

Expected new backend module
- userMng/controller/AdminUserController.java
- userMng/service/AdminUserService.java
- userMng/dto/*
- userMng/mapper/AdminUserMapper.java
- userMng/security/UserMngEndpointSecurity.java
- src/main/resources/mapper/biz/userMng/AdminUserMapper.xml

Reuse guidance
- Reuse existing user/UserMapper where possible
- Do not modify the existing user domain unless unavoidable
- Follow the repo's MapStruct conventions for row-to-response mapping

Validation checklist
- list/detail/create/update/status/password/delete all wired
- duplicate checks implemented
- self-protection implemented
- last active admin protection implemented
- LOCAL-only restrictions implemented
- tests or verification steps included in the final report
"@
}

function Get-UserManagementFrontendSnapshot {
    return @"
Use this snapshot instead of reading the full external plan.

Goal
- Build phase-1 admin user management frontend page.

In scope
- /admin/user-mng page
- List/detail/create/update/status/password/delete flows
- Filters, pagination, detail modal, dialogs, forms
- UI hints for self-protection rules
- Error handling for backend 409 errorCode responses

Out of scope
- DB changes
- OAuth user creation flows
- loginId change
- Forced session invalidation after password reset

Reference patterns inside frontend repo
- monitoringMng for page structure, filters, table, modal, pagination
- AdminPageProvider / useAdminPageContext
- adminFetch in src/admin/lib/api.ts
- common components: AdminDataTable, AdminAlertDialog, AdminConfirmDialog, StatusFilterSelect

Required route and integration
- Add /admin/user-mng route
- Add sidebar/menu entry
- Add src/admin/lib/userApi.ts

Expected new frontend structure
- src/admin/pages/userMng/

UI responsibilities
- User list with keyword/role/status/authProvider filters
- Detail view
- LOCAL user create form
- Update form for nickname and role
- Status change dialog
- LOCAL-only password reset dialog
- LOCAL-only delete dialog

Backend contract dependency
- Base path: /api/admin/users
- Use be_dev report/contracts first if available
- Respect all backend restrictions and errorCode values

Important UX rules
- Hide or disable invalid actions when possible, but keep server as source of truth
- Show clear feedback for self-demotion, self-deactivation, self-delete, last-admin protection
- Handle WITHDRAWN users as read-only / immutable

Required errorCode handling
- EMAIL_DUPLICATED
- LOGIN_ID_DUPLICATED
- CANNOT_DEMOTE_SELF
- CANNOT_DEACTIVATE_SELF
- CANNOT_DELETE_SELF
- LAST_ADMIN_PROTECTED
- ONLY_LOCAL_ALLOWED
- WITHDRAWN_USER_IMMUTABLE

Validation checklist
- route/menu connected
- list/detail/filter/pagination working
- create/update/status/password/delete flows covered
- backend errorCode messages mapped
- final report includes changed files, test steps, remaining risks
"@
}

function Get-RolePlanSnapshotBody {
    param(
        [Parameter(Mandatory)][string]$PlanName,
        [Parameter(Mandatory)][string]$Role,
        [Parameter(Mandatory)][string]$RawPlanContent
    )

    if ($PlanName -eq "user_management") {
        switch ($Role) {
            "be_dev" { return (Get-UserManagementBackendSnapshot) }
            "fe_dev" { return (Get-UserManagementFrontendSnapshot) }
        }
    }

    $trimmed = $RawPlanContent.Trim()
    if ($trimmed.Length -gt 6000) {
        $trimmed = $trimmed.Substring(0, 6000).TrimEnd() + "`n`n[truncated]"
    }

    return @"
Use this snapshot instead of reading the full external plan.

Priority
- Treat the source plan as the single source of truth.
- Follow only the requirements relevant to the current role: $Role.

Plan excerpt
$trimmed
"@
}

function Ensure-RolePlanSnapshot {
    param(
        [Parameter(Mandatory)][pscustomobject]$Config,
        [Parameter(Mandatory)][pscustomobject]$RoleConfig
    )

    $sourcePath = Join-Path $Config.PlanDir "plan.md"
    if (-not (Test-Path -LiteralPath $sourcePath)) {
        return ""
    }

    $contextDir = Join-Path $RoleConfig.WorkingDirectory ".agent-context\$($Config.PlanName)"
    Ensure-Directory -Path $contextDir

    # Mirror the plan into the role worktree so Claude can stay inside its allowed working directory.
    $snapshotPath = Join-Path $contextDir "plan_snapshot.md"
    $rawPlanContent = Read-Utf8File -Path $sourcePath
    $summaryContent = Get-RolePlanSnapshotBody -PlanName $Config.PlanName -Role $RoleConfig.Role -RawPlanContent $rawPlanContent
    Write-Utf8File -Path $snapshotPath -Content (New-PlanSnapshotContent -SourcePath $sourcePath -Content $summaryContent -Role $RoleConfig.Role)
    return $snapshotPath
}

function Get-ClaudeProjectsRoot {
    return (Join-Path $env:USERPROFILE ".claude\projects")
}

function Get-ClaudeSessionsRoot {
    return (Join-Path $env:USERPROFILE ".claude\sessions")
}

function Get-ClaudeSessionInfo {
    param([Parameter(Mandatory)][int]$ProcessId)

    $sessionPath = Join-Path (Get-ClaudeSessionsRoot) ("{0}.json" -f $ProcessId)
    $session = Get-JsonObjectFromFile -Path $sessionPath
    if (-not $session -or [string]::IsNullOrWhiteSpace($session.sessionId)) {
        return $null
    }

    # Claude writes progress into its own session jsonl, not necessarily to redirected stdout/stderr.
    $logPath = Get-ChildItem -Path (Get-ClaudeProjectsRoot) -Filter ("{0}.jsonl" -f $session.sessionId) -Recurse -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1 -ExpandProperty FullName

    return [pscustomobject]@{
        SessionId = $session.sessionId
        SessionPath = $sessionPath
        LogPath = $logPath
    }
}

function Get-CompactText {
    param(
        [AllowEmptyString()][string]$Text,
        [int]$MaxLength = 140
    )

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return ""
    }

    $compact = ($Text -replace '\s+', ' ').Trim()
    if ($compact.Length -le $MaxLength) {
        return $compact
    }

    return ($compact.Substring(0, $MaxLength) + "...")
}

function Get-ClaudeLogExcerpt {
    param([string]$Path)

    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) {
        return ""
    }

    $lines = Get-Content -LiteralPath $Path -Tail 12 -ErrorAction SilentlyContinue
    if (-not $lines) {
        return ""
    }

    for ($index = $lines.Count - 1; $index -ge 0; $index--) {
        $line = $lines[$index]
        if ([string]::IsNullOrWhiteSpace($line)) {
            continue
        }

        try {
            $entry = $line | ConvertFrom-Json -ErrorAction Stop
        }
        catch {
            $text = Get-CompactText -Text $line
            if ($text) {
                return $text
            }

            continue
        }

        if ($entry.PSObject.Properties.Name -contains "toolUseResult") {
            $toolResult = $entry.toolUseResult
            if ($toolResult -is [string]) {
                $text = Get-CompactText -Text $toolResult
                if ($text) {
                    return $text
                }
            }
            elseif ($toolResult -and $toolResult.PSObject.Properties.Name -contains "content") {
                foreach ($item in $toolResult.content) {
                    if ($item.text) {
                        $text = Get-CompactText -Text $item.text
                        if ($text) {
                            return $text
                        }
                    }
                }
            }
        }

        if ($entry.type -eq "queue-operation" -and $entry.operation) {
            return ("Claude queue {0}" -f $entry.operation)
        }

        if ($entry.message) {
            if ($entry.message.content -is [string]) {
                $text = Get-CompactText -Text $entry.message.content
                if ($text) {
                    return $text
                }
            }

            foreach ($item in @($entry.message.content)) {
                if ($item.text) {
                    $text = Get-CompactText -Text $item.text
                    if ($text) {
                        return $text
                    }
                }

                if ($item.content) {
                    $text = Get-CompactText -Text $item.content
                    if ($text) {
                        return $text
                    }
                }

                if ($item.name) {
                    return ("Claude tool: {0}" -f $item.name)
                }
            }
        }
    }

    return ""
}

function Assert-CommandAvailable {
    param(
        [Parameter(Mandatory)][string]$CommandName,
        [Parameter(Mandatory)][string]$ErrorMessage
    )

    $resolved = Resolve-AgentExecutable -CommandName $CommandName
    if (-not $resolved) {
        throw $ErrorMessage
    }
}

function Assert-GitRepository {
    param(
        [Parameter(Mandatory)][string]$WorkingDirectory,
        [Parameter(Mandatory)][string]$Role
    )

    $git = Get-Command git -ErrorAction SilentlyContinue
    if (-not $git) {
        throw "git 명령을 찾을 수 없습니다. git 설치 또는 PATH 를 확인한 뒤 다시 실행하세요."
    }

    $null = & git -C $WorkingDirectory rev-parse --is-inside-work-tree 2>$null
    if ($LASTEXITCODE -ne 0) {
        throw "$Role 역할의 WorkingDirectory 가 git 저장소가 아닙니다: $WorkingDirectory. 경로를 확인하거나 저장소를 초기화한 뒤 다시 실행하세요."
    }
}

function Test-AnyPathExists {
    param([Parameter(Mandatory)][string[]]$Paths)

    foreach ($path in $Paths) {
        if ($path -and (Test-Path -LiteralPath $path)) {
            return $true
        }
    }

    return $false
}

function Assert-RolePrerequisites {
    param(
        [Parameter(Mandatory)][pscustomobject]$Config,
        [Parameter(Mandatory)][pscustomobject]$RoleConfig,
        [switch]$DryRun
    )

    if (-not (Test-Path -LiteralPath $Config.PlanDir)) {
        throw "Plan 디렉토리가 없습니다: $($Config.PlanDir). -PlanName 값을 확인하거나 HeysoDiaryDocs/docs/plans 아래에 plan 디렉토리를 먼저 준비하세요."
    }

    if (-not (Test-Path -LiteralPath $RoleConfig.WorkingDirectory)) {
        throw "WorkingDirectory 가 존재하지 않습니다: $($RoleConfig.WorkingDirectory). 경로를 확인하거나 Get-AgentPlanConfig 기본 경로를 수정하세요."
    }

    if (-not (Test-Path -LiteralPath $RoleConfig.PromptPath)) {
        $candidateList = $RoleConfig.PromptCandidates -join ", "
        throw "$($RoleConfig.Role) 프롬프트 파일을 찾지 못했습니다. 다음 파일 중 하나를 plan 디렉토리에 추가하세요: $candidateList"
    }

    switch ($RoleConfig.Role) {
        "be_dev" {
            if (-not (Test-Path -LiteralPath $Config.Roles["leader"].ReportPath)) {
                throw "leader_report.md 가 없습니다. 먼저 run-leader.ps1 또는 run-cycle.ps1 을 실행하세요."
            }
        }
        "fe_dev" {
            if (-not (Test-Path -LiteralPath $Config.Roles["leader"].ReportPath)) {
                throw "leader_report.md 가 없습니다. 먼저 run-leader.ps1 또는 run-cycle.ps1 을 실행하세요."
            }
        }
        "reviewer" {
            if (-not (Test-Path -LiteralPath $Config.Roles["leader"].ReportPath)) {
                throw "leader_report.md 가 없습니다. 먼저 run-leader.ps1 또는 run-cycle.ps1 을 실행하세요."
            }

            if (-not (Test-AnyPathExists -Paths @($Config.Roles["be_dev"].ReportPath, $Config.Roles["fe_dev"].ReportPath))) {
                throw "검토할 개발 보고서가 없습니다. 먼저 run-be-dev.ps1, run-fe-dev.ps1 또는 run-cycle.ps1 을 실행하세요."
            }
        }
        "qa" {
            if (-not (Test-Path -LiteralPath $Config.Roles["reviewer"].ReportPath)) {
                throw "reviewer_report.md 가 없습니다. 먼저 run-review.ps1 또는 run-cycle.ps1 을 실행하세요."
            }

            if (-not (Test-AnyPathExists -Paths @($Config.Roles["be_dev"].ReportPath, $Config.Roles["fe_dev"].ReportPath))) {
                throw "검증할 개발 보고서가 없습니다. 먼저 run-be-dev.ps1, run-fe-dev.ps1 또는 run-cycle.ps1 을 실행하세요."
            }
        }
        "leader_final" {
            if (-not (Test-Path -LiteralPath $Config.Roles["reviewer"].ReportPath)) {
                throw "reviewer_report.md 가 없습니다. 먼저 run-review.ps1 또는 run-cycle.ps1 을 실행하세요."
            }

            if (-not (Test-Path -LiteralPath $Config.Roles["qa"].ReportPath)) {
                throw "qa_report.md 가 없습니다. 먼저 run-qa.ps1 또는 run-cycle.ps1 을 실행하세요."
            }
        }
    }

    if (-not $DryRun) {
        Assert-CommandAvailable -CommandName $RoleConfig.Cli -ErrorMessage "$($RoleConfig.Cli) CLI 를 찾을 수 없습니다. PATH 또는 설치 상태를 확인한 뒤 다시 실행하세요."
    }

    if ($RoleConfig.NeedsGitArtifacts) {
        Assert-GitRepository -WorkingDirectory $RoleConfig.WorkingDirectory -Role $RoleConfig.Role
    }
}

function Get-RolePromptPayload {
    param(
        [Parameter(Mandatory)][pscustomobject]$Config,
        [Parameter(Mandatory)][pscustomobject]$RoleConfig
    )

    $basePrompt = Get-AgentPromptText -Config $Config -RoleConfig $RoleConfig
    $leaderReportPath = $Config.Roles["leader"].ReportPath
    $beReportPath = $Config.Roles["be_dev"].ReportPath
    $feReportPath = $Config.Roles["fe_dev"].ReportPath
    $reviewerReportPath = $Config.Roles["reviewer"].ReportPath
    $qaReportPath = $Config.Roles["qa"].ReportPath
    $beDiffPath = $Config.Roles["be_dev"].DiffPath
    $feDiffPath = $Config.Roles["fe_dev"].DiffPath
    $planSnapshotPath = ""

    # be_dev / fe_dev are the roles most affected by cross-repo doc access, so prepare a local snapshot for them.
    if ($RoleConfig.Role -in @("be_dev", "fe_dev")) {
        $planSnapshotPath = Ensure-RolePlanSnapshot -Config $Config -RoleConfig $RoleConfig
    }

    switch ($RoleConfig.Role) {
        "leader" {
            return @"
$basePrompt

추가 런타임 지시:
- 현재 PlanName 은 $($Config.PlanName) 이다.
- 문서/오케스트레이션 루트는 $($Config.Root) 이다.
- BE 저장소는 $($Config.Repositories.BackEnd), FE 저장소는 $($Config.Repositories.FrontEnd) 이다.
- 이번 단계는 leader 초기 판단 단계다.
- 1차 구현에서는 be_dev -> fe_dev 순차 실행만 허용된다.
- 이번 cycle 에서 be_dev / fe_dev 수행 필요 여부를 반드시 판정하라.
- 결과 맨 앞에 아래 헤더를 정확히 작성하라.

Decision: REWORK_REQUIRED
BE_REQUIRED: true
FE_REQUIRED: true
NEXT_ORDER: be_dev -> fe_dev -> reviewer -> qa -> leader_final

본문에는 아래 항목을 포함하라.
### 1. 현재 단계
### 2. 현재 판정
### 3. 근거
### 4. 다음 액션
### 5. 체크리스트
"@
        }
        "be_dev" {
            return @"
$basePrompt

$(Get-FileSection -Title "로컬 Plan 스냅샷" -Path $planSnapshotPath -WhenMissing "(plan 스냅샷 없음)")

$(Get-FileSection -Title "Leader 보고서" -Path $leaderReportPath -WhenMissing "(leader 보고서 없음)")

추가 지시:
- 현재 역할은 be_dev 다.
- 실제 작업 루트는 $($RoleConfig.WorkingDirectory) 이다.
- 작업 루트 바깥의 docs 경로를 직접 읽으려 하지 말고, 작업 루트 안에 생성된 로컬 plan 스냅샷을 우선 참고하라: $planSnapshotPath
- plan.md 의 확정 의사결정이 있으면 로컬 plan 스냅샷 기준으로 최우선 반영하라.
- 프론트 작업은 직접 구현하지 말고, BE 관점에서 필요한 계약과 산출물만 정리하라.
- 결과는 markdown 형식으로 작성하고, 변경 파일 목록 / API 명세 / 테스트 방법 / 남은 리스크를 포함하라.
"@
        }
        "fe_dev" {
            return @"
$basePrompt

$(Get-FileSection -Title "로컬 Plan 스냅샷" -Path $planSnapshotPath -WhenMissing "(plan 스냅샷 없음)")

$(Get-FileSection -Title "Leader 보고서" -Path $leaderReportPath -WhenMissing "(leader 보고서 없음)")

$(Get-FileSection -Title "be_dev 보고서" -Path $beReportPath -WhenMissing "(be_dev 보고서 없음)")

$(Get-FileSection -Title "be_dev diff" -Path $beDiffPath -WhenMissing "(be_dev diff 없음)")

추가 지시:
- 현재 역할은 fe_dev 다.
- 실제 작업 루트는 $($RoleConfig.WorkingDirectory) 이다.
- be_dev 산출물이 있으면 그 계약을 우선 참고하라.
- 작업 루트 바깥의 docs 경로를 직접 읽으려 하지 말고, 작업 루트 안에 생성된 로컬 plan 스냅샷을 우선 참고하라: $planSnapshotPath
- plan.md 의 확정 의사결정이 있으면 로컬 plan 스냅샷 기준으로 최우선 반영하라.
- 결과는 markdown 형식으로 작성하고, 변경 파일 목록 / 테스트 방법 / 남은 리스크를 포함하라.
"@
        }
        "reviewer" {
            return @"
$basePrompt

$(Get-FileSection -Title "Leader 보고서" -Path $leaderReportPath -WhenMissing "(leader 보고서 없음)")

$(Get-FileSection -Title "be_dev 보고서" -Path $beReportPath -WhenMissing "(be_dev 보고서 없음)")

$(Get-FileSection -Title "fe_dev 보고서" -Path $feReportPath -WhenMissing "(fe_dev 보고서 없음)")

$(Get-FileSection -Title "be_dev diff" -Path $beDiffPath -WhenMissing "(be_dev diff 없음)")

$(Get-FileSection -Title "fe_dev diff" -Path $feDiffPath -WhenMissing "(fe_dev diff 없음)")

추가 지시:
- 현재 역할은 reviewer 다.
- 문서 기준과 role 산출물을 교차 검토하라.
- 치명적 문제 / 수정 권장 / 문서 불일치 / 승인 가능 여부를 분리해서 작성하라.
"@
        }
        "qa" {
            return @"
$basePrompt

$(Get-FileSection -Title "Leader 보고서" -Path $leaderReportPath -WhenMissing "(leader 보고서 없음)")

$(Get-FileSection -Title "be_dev 보고서" -Path $beReportPath -WhenMissing "(be_dev 보고서 없음)")

$(Get-FileSection -Title "fe_dev 보고서" -Path $feReportPath -WhenMissing "(fe_dev 보고서 없음)")

$(Get-FileSection -Title "Reviewer 보고서" -Path $reviewerReportPath -WhenMissing "(reviewer 보고서 없음)")

추가 지시:
- 현재 역할은 qa 다.
- 실제 테스트를 모두 수행하지 못한 경우, 미검증 영역과 추정 영역을 구분해서 적어라.
- 정상/예외/경계/회귀 테스트 케이스를 반드시 포함하라.
"@
        }
        "leader_final" {
            return @"
$basePrompt

$(Get-FileSection -Title "초기 Leader 보고서" -Path $leaderReportPath -WhenMissing "(leader 보고서 없음)")

$(Get-FileSection -Title "be_dev 보고서" -Path $beReportPath -WhenMissing "(be_dev 보고서 없음)")

$(Get-FileSection -Title "fe_dev 보고서" -Path $feReportPath -WhenMissing "(fe_dev 보고서 없음)")

$(Get-FileSection -Title "Reviewer 보고서" -Path $reviewerReportPath -WhenMissing "(reviewer 보고서 없음)")

$(Get-FileSection -Title "QA 보고서" -Path $qaReportPath -WhenMissing "(qa 보고서 없음)")

추가 지시:
- 현재 단계는 leader_final 이다.
- 이번 cycle 의 최종 판정을 아래 세 값 중 하나로만 결정하라: COMPLETED / REWORK_REQUIRED / BLOCKED
- 결과 맨 앞에 아래 헤더를 정확히 작성하라.

Decision: REWORK_REQUIRED
BE_REQUIRED: false
FE_REQUIRED: false
NEXT_ORDER: stop

본문에는 아래 항목을 포함하라.
### 1. 현재 단계
### 2. 현재 판정
### 3. 근거
### 4. 다음 액션
### 5. 체크리스트
"@
        }
    }
}

function Get-MockTokenUsage {
    param([Parameter(Mandatory)][string]$Role)

    switch ($Role) {
        "leader" { return [pscustomobject]@{ PromptTokens = 1200; CompletionTokens = 800; TotalTokens = 2000 } }
        "be_dev" { return [pscustomobject]@{ PromptTokens = 5000; CompletionTokens = 2200; TotalTokens = 7200 } }
        "fe_dev" { return [pscustomobject]@{ PromptTokens = 4800; CompletionTokens = 2100; TotalTokens = 6900 } }
        "reviewer" { return [pscustomobject]@{ PromptTokens = 1400; CompletionTokens = 900; TotalTokens = 2300 } }
        "qa" { return [pscustomobject]@{ PromptTokens = 2100; CompletionTokens = 1100; TotalTokens = 3200 } }
        "leader_final" { return [pscustomobject]@{ PromptTokens = 800; CompletionTokens = 500; TotalTokens = 1300 } }
    }
}

function Get-MockOutputContent {
    param(
        [Parameter(Mandatory)][string]$Role,
        [hashtable]$MockMetadata = @{},
        [string]$MockOutputPath
    )

    if ($MockOutputPath) {
        if (-not (Test-Path -LiteralPath $MockOutputPath)) {
            throw "Mock 출력 파일을 찾지 못했습니다: $MockOutputPath. 경로를 확인하거나 -MockOutputPath 값을 제거하세요."
        }

        return (Read-Utf8File -Path $MockOutputPath)
    }

    switch ($Role) {
        "leader" {
            $decision = if ($MockMetadata.ContainsKey("Decision")) { $MockMetadata["Decision"] } else { "REWORK_REQUIRED" }
            $beRequired = if ($MockMetadata.ContainsKey("BeRequired")) { [string]$MockMetadata["BeRequired"] } else { "true" }
            $feRequired = if ($MockMetadata.ContainsKey("FeRequired")) { [string]$MockMetadata["FeRequired"] } else { "true" }
            return @"
Decision: $decision
BE_REQUIRED: $beRequired
FE_REQUIRED: $feRequired
NEXT_ORDER: be_dev -> fe_dev -> reviewer -> qa -> leader_final

### 1. 현재 단계
- DEV 요청

### 2. 현재 판정
- 진행 가능

### 3. 근거
- DryRun mock 결과다.

### 4. 다음 액션
- be_dev 후 fe_dev 를 순차 실행한다.

### 5. 체크리스트
- PlanName 기반 경로 계산 확인
- be_dev / fe_dev pass 가능 여부 확인
"@
        }
        "be_dev" {
            return @"
### 1. 변경 개요
- DryRun 용 be_dev mock 보고서

### 2. 변경 파일 목록
- (mock) backend file

### 3. API 명세
- (mock) backend api

### 4. 구현 세부
- BE 작업 요약

### 5. 테스트 방법
- DryRun 이므로 미실행

### 6. 남은 리스크 / 확인 필요 사항
- 실제 백엔드 CLI 실행 전 검증 필요
"@
        }
        "fe_dev" {
            return @"
### 1. 변경 개요
- DryRun 용 fe_dev mock 보고서

### 2. 변경 파일 목록
- (mock) frontend file

### 3. API 명세
- (mock) frontend contract usage

### 4. 구현 세부
- FE 작업 요약

### 5. 테스트 방법
- DryRun 이므로 미실행

### 6. 남은 리스크 / 확인 필요 사항
- 실제 프론트 CLI 실행 전 검증 필요
"@
        }
        "reviewer" {
            return @"
### 1. 총평
DryRun mock 기준으로 구조가 맞다.

### 2. 치명적 문제
없음

### 3. 수정 권장 사항
- 실제 실행 시 diff 내용을 재검토할 것

### 4. 문서 불일치 / 요구사항 누락
없음

### 5. 과잉 구현 / 범위 이탈
없음

### 6. 승인 가능 여부
- 승인 가능

### 7. 개발자 AI에게 전달할 수정 지시문
- 실제 구현 결과를 기준으로 재검토하라.
"@
        }
        "qa" {
            return @"
### 1. QA 총평
DryRun mock 기준으로 재검증 필요 영역만 남아 있다.

### 2. 테스트 케이스
- 구분: 정상
- 테스트명: 기본 조회
- 사전조건: mock 데이터 존재
- 절차: 페이지 진입 후 조회
- 기대 결과: 목록이 표시된다.

### 3. 발견 이슈
없음

### 4. 최종 판정
- QA 통과

### 5. 개발자 AI에게 전달할 수정 요청
- 실제 환경에서 수동 테스트를 재실행하라.
"@
        }
        "leader_final" {
            $decision = if ($MockMetadata.ContainsKey("Decision")) { $MockMetadata["Decision"] } else { "REWORK_REQUIRED" }
            return @"
Decision: $decision
BE_REQUIRED: false
FE_REQUIRED: false
NEXT_ORDER: stop

### 1. 현재 단계
- DONE

### 2. 현재 판정
- $decision

### 3. 근거
- DryRun mock 결과다.

### 4. 다음 액션
- 사람이 leader_final_report 를 확인한 뒤 다음 cycle 여부를 결정한다.

### 5. 체크리스트
- cycle summary 생성 여부 확인
- 역할별 status/log/report/diff 분리 여부 확인
"@
        }
    }
}

function Get-TokenUsageFromText {
    param([string[]]$Texts)

    $promptTokens = $null
    $completionTokens = $null
    $totalTokens = $null

    $regexOptions = [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
    $patterns = @(
        @{ Prompt = 'prompt_tokens"\s*:\s*(\d+)'; Completion = 'completion_tokens"\s*:\s*(\d+)'; Total = 'total_tokens"\s*:\s*(\d+)' },
        @{ Prompt = 'input_tokens"\s*:\s*(\d+)'; Completion = 'output_tokens"\s*:\s*(\d+)'; Total = 'total_tokens"\s*:\s*(\d+)' },
        @{ Prompt = 'PromptTokens\s*[:=]\s*(\d+)'; Completion = 'CompletionTokens\s*[:=]\s*(\d+)'; Total = 'TotalTokens\s*[:=]\s*(\d+)' },
        @{ Prompt = 'prompt tokens?\s*[:=]\s*(\d+)'; Completion = 'completion tokens?\s*[:=]\s*(\d+)'; Total = 'total tokens?\s*[:=]\s*(\d+)' }
    )

    foreach ($text in $Texts) {
        if ([string]::IsNullOrWhiteSpace($text)) {
            continue
        }

        foreach ($pattern in $patterns) {
            if ($null -eq $promptTokens) {
                $match = [regex]::Match($text, $pattern.Prompt, $regexOptions)
                if ($match.Success) {
                    $promptTokens = [int]$match.Groups[1].Value
                }
            }

            if ($null -eq $completionTokens) {
                $match = [regex]::Match($text, $pattern.Completion, $regexOptions)
                if ($match.Success) {
                    $completionTokens = [int]$match.Groups[1].Value
                }
            }

            if ($null -eq $totalTokens) {
                $match = [regex]::Match($text, $pattern.Total, $regexOptions)
                if ($match.Success) {
                    $totalTokens = [int]$match.Groups[1].Value
                }
            }
        }
    }

    if ($null -eq $promptTokens) { $promptTokens = 0 }
    if ($null -eq $completionTokens) { $completionTokens = 0 }
    if ($null -eq $totalTokens) { $totalTokens = $promptTokens + $completionTokens }

    return [pscustomobject]@{
        PromptTokens = $promptTokens
        CompletionTokens = $completionTokens
        TotalTokens = $totalTokens
    }
}

function Get-DefaultStatusRecord {
    param(
        [Parameter(Mandatory)][pscustomobject]$RoleConfig,
        [string]$RunId,
        [string]$CycleRunId
    )

    return [ordered]@{
        Role = $RoleConfig.Role
        Model = $RoleConfig.Model
        Provider = $RoleConfig.Provider
        Cli = $RoleConfig.Cli
        WorkingDirectory = $RoleConfig.WorkingDirectory
        RunId = $RunId
        CycleRunId = $CycleRunId
        Pid = 0
        StartedAt = $null
        LastOutputAt = $null
        LastHeartbeatAt = $null
        CompletedAt = $null
        Status = "PENDING"
        ExitCode = $null
        PromptPath = $RoleConfig.PromptPath
        ReportPath = $RoleConfig.ReportPath
        OutputPath = $RoleConfig.ReportPath
        OutLogPath = $RoleConfig.OutLogPath
        ErrLogPath = $RoleConfig.ErrLogPath
        PromptTokens = 0
        CompletionTokens = 0
        TotalTokens = 0
        RecentOutput = ""
        Note = ""
        SessionId = ""
        SessionLogPath = ""
        UpdatedAt = (Get-Date).ToString("o")
    }
}

function Set-AgentStatus {
    param(
        [Parameter(Mandatory)][pscustomobject]$RoleConfig,
        [hashtable]$Values,
        [string]$RunId,
        [string]$CycleRunId
    )

    $status = Get-DefaultStatusRecord -RoleConfig $RoleConfig -RunId $RunId -CycleRunId $CycleRunId
    $existing = Read-JsonFile -Path $RoleConfig.StatusPath
    if ($existing) {
        foreach ($property in $existing.PSObject.Properties) {
            $status[$property.Name] = $property.Value
        }
    }

    if ($Values) {
        foreach ($key in $Values.Keys) {
            $status[$key] = $Values[$key]
        }
    }

    $status["UpdatedAt"] = (Get-Date).ToString("o")
    Write-JsonFile -Path $RoleConfig.StatusPath -Data $status
    return [pscustomobject]$status
}

function Get-AgentStatus {
    param(
        [Parameter(Mandatory)][pscustomobject]$Config,
        [Parameter(Mandatory)][string]$Role
    )

    return (Read-JsonFile -Path $Config.Roles[$Role].StatusPath)
}

function Get-AllAgentStatuses {
    param([Parameter(Mandatory)][pscustomobject]$Config)

    $statuses = @()
    foreach ($roleName in @("leader", "be_dev", "fe_dev", "reviewer", "qa", "leader_final")) {
        $status = Get-AgentStatus -Config $Config -Role $roleName
        if ($status) {
            $statuses += $status
        }
    }

    return $statuses
}

function Get-RecentLogExcerpt {
    param([string]$Path)

    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) {
        return ""
    }

    try {
        $lines = Get-Content -LiteralPath $Path -Tail 3 -ErrorAction Stop
        return (($lines -join " ").Trim())
    }
    catch {
        return ""
    }
}

function Invoke-GitArtifactCapture {
    param([Parameter(Mandatory)][pscustomobject]$RoleConfig)

    if (-not $RoleConfig.NeedsGitArtifacts) {
        return
    }

    $diffText = (& git -C $RoleConfig.WorkingDirectory diff -- . | Out-String)
    $changedFilesText = (& git -C $RoleConfig.WorkingDirectory status --short | Out-String)
    Write-Utf8File -Path $RoleConfig.DiffPath -Content $diffText.TrimEnd()
    Write-Utf8File -Path $RoleConfig.ChangedFilesPath -Content $changedFilesText.TrimEnd()
}

function Write-PassRoleArtifacts {
    param(
        [Parameter(Mandatory)][pscustomobject]$RoleConfig,
        [Parameter(Mandatory)][string]$Status,
        [Parameter(Mandatory)][string]$Reason,
        [string]$RunId,
        [string]$CycleRunId
    )

    $timestamp = (Get-Date).ToString("o")
    $report = @"
# $($RoleConfig.Role)

- Status: $Status
- Reason: $Reason
- WorkingDirectory: $($RoleConfig.WorkingDirectory)
"@
    Write-Utf8File -Path $RoleConfig.ReportPath -Content $report
    Write-Utf8File -Path $RoleConfig.OutLogPath -Content "[$($RoleConfig.Role)] $Status - $Reason"
    Write-Utf8File -Path $RoleConfig.ErrLogPath -Content ""

    if ($RoleConfig.NeedsGitArtifacts) {
        Write-Utf8File -Path $RoleConfig.DiffPath -Content ""
        Write-Utf8File -Path $RoleConfig.ChangedFilesPath -Content ""
    }

    Set-AgentStatus -RoleConfig $RoleConfig -RunId $RunId -CycleRunId $CycleRunId -Values @{
        Status = $Status
        ExitCode = 0
        StartedAt = $timestamp
        LastOutputAt = $timestamp
        LastHeartbeatAt = $timestamp
        CompletedAt = $timestamp
        OutLogPath = $RoleConfig.OutLogPath
        ErrLogPath = $RoleConfig.ErrLogPath
        OutputPath = $RoleConfig.ReportPath
        PromptTokens = 0
        CompletionTokens = 0
        TotalTokens = 0
        RecentOutput = $Reason
        Note = $Reason
    } | Out-Null
}

function Invoke-AgentPrompt {
    param(
        [Parameter(Mandatory)][pscustomobject]$RoleConfig,
        [Parameter(Mandatory)][AllowEmptyString()][string]$PromptText,
        [switch]$DryRun,
        [string]$MockOutputPath,
        [hashtable]$MockMetadata = @{},
        [int]$TimeoutSec = 2700,
        [int]$NoOutputTimeoutSec = 300,
        [string]$RunId,
        [string]$CycleRunId
    )

    if (-not $RunId) {
        $RunId = New-AgentRunId
    }

    Write-Utf8File -Path $RoleConfig.OutLogPath -Content ""
    Write-Utf8File -Path $RoleConfig.ErrLogPath -Content ""

    if ($DryRun) {
        $mockOutput = Get-MockOutputContent -Role $RoleConfig.Role -MockMetadata $MockMetadata -MockOutputPath $MockOutputPath
        $mockTokens = Get-MockTokenUsage -Role $RoleConfig.Role
        $timestamp = (Get-Date).ToString("o")
        Write-Utf8File -Path $RoleConfig.ReportPath -Content $mockOutput
        Write-Utf8File -Path $RoleConfig.OutLogPath -Content ("[{0}] DryRun mock executed." -f $RoleConfig.Role)
        Set-AgentStatus -RoleConfig $RoleConfig -RunId $RunId -CycleRunId $CycleRunId -Values @{
            Status = "COMPLETED"
            ExitCode = 0
            StartedAt = $timestamp
            LastOutputAt = $timestamp
            LastHeartbeatAt = $timestamp
            CompletedAt = $timestamp
            OutLogPath = $RoleConfig.OutLogPath
            ErrLogPath = $RoleConfig.ErrLogPath
            OutputPath = $RoleConfig.ReportPath
            PromptTokens = $mockTokens.PromptTokens
            CompletionTokens = $mockTokens.CompletionTokens
            TotalTokens = $mockTokens.TotalTokens
            RecentOutput = "DryRun mock completed."
            Note = "DryRun"
        } | Out-Null

        return [pscustomobject]@{
            Status = "COMPLETED"
            ExitCode = 0
            PromptTokens = $mockTokens.PromptTokens
            CompletionTokens = $mockTokens.CompletionTokens
            TotalTokens = $mockTokens.TotalTokens
            RunId = $RunId
        }
    }

    $resolved = Resolve-AgentExecutable -CommandName $RoleConfig.Cli
    $logDir = Split-Path -Parent $RoleConfig.OutLogPath
    $inputPath = Join-Path $logDir ("{0}.{1}.stdin.txt" -f $RoleConfig.Role, $RunId)
    $stdoutPath = $RoleConfig.OutLogPath
    $stderrPath = $RoleConfig.ErrLogPath
    $resultPath = Join-Path $logDir ("{0}.{1}.result.txt" -f $RoleConfig.Role, $RunId)
    $effectiveNoOutputTimeoutSec = $NoOutputTimeoutSec
    # Claude can spend long periods updating only its internal session log, so keep the no-output threshold looser.
    if ($RoleConfig.Cli -eq "claude" -and $effectiveNoOutputTimeoutSec -lt 1200) {
        $effectiveNoOutputTimeoutSec = 1200
    }
    Write-Utf8File -Path $inputPath -Content $PromptText

    $arguments = @($resolved.PrefixArguments)
    if ($RoleConfig.Cli -eq "claude") {
        $arguments += @("-p", "--model", $RoleConfig.Model)
    }
    else {
        $arguments += @("exec", "--model", $RoleConfig.Model, "-o", $resultPath, "-")
    }

    $startedAt = Get-Date
    Write-Host ("[{0}] start model={1} provider={2} cli={3}" -f $RoleConfig.Role.ToUpperInvariant(), $RoleConfig.Model, $RoleConfig.Provider, $RoleConfig.Cli)
    $process = Start-Process `
        -FilePath $resolved.FilePath `
        -ArgumentList $arguments `
        -WorkingDirectory $RoleConfig.WorkingDirectory `
        -RedirectStandardInput $inputPath `
        -RedirectStandardOutput $stdoutPath `
        -RedirectStandardError $stderrPath `
        -NoNewWindow `
        -PassThru

    $lastOutFileLength = 0L
    $lastErrFileLength = 0L
    $lastOutputAt = $startedAt
    $lastStatusPrintAt = [datetime]::MinValue
    $claudeSessionInfo = $null
    $lastClaudeLogLength = 0L

    Set-AgentStatus -RoleConfig $RoleConfig -RunId $RunId -CycleRunId $CycleRunId -Values @{
        Status = "RUNNING"
        Pid = $process.Id
        StartedAt = $startedAt.ToString("o")
        LastHeartbeatAt = $startedAt.ToString("o")
        LastOutputAt = $startedAt.ToString("o")
        OutLogPath = $stdoutPath
        ErrLogPath = $stderrPath
        OutputPath = $RoleConfig.ReportPath
    } | Out-Null

    while (-not $process.HasExited) {
        $now = Get-Date
        $recentOutput = ""

        if (Test-Path -LiteralPath $stdoutPath) {
            $stdoutItem = Get-Item -LiteralPath $stdoutPath
            if ($stdoutItem.Length -gt $lastOutFileLength) {
                $lastOutFileLength = $stdoutItem.Length
                $lastOutputAt = $now
                $recentOutput = Get-RecentLogExcerpt -Path $stdoutPath
            }
        }

        if (Test-Path -LiteralPath $stderrPath) {
            $stderrItem = Get-Item -LiteralPath $stderrPath
            if ($stderrItem.Length -gt $lastErrFileLength) {
                $lastErrFileLength = $stderrItem.Length
                $lastOutputAt = $now
                if (-not $recentOutput) {
                    $recentOutput = Get-RecentLogExcerpt -Path $stderrPath
                }
            }
        }

        if ($RoleConfig.Cli -eq "claude") {
            if (-not $claudeSessionInfo) {
                # Session metadata appears asynchronously after process start, so keep retrying until it is available.
                $claudeSessionInfo = Get-ClaudeSessionInfo -ProcessId $process.Id
                if ($claudeSessionInfo) {
                    Set-AgentStatus -RoleConfig $RoleConfig -RunId $RunId -CycleRunId $CycleRunId -Values @{
                        SessionId = $claudeSessionInfo.SessionId
                        SessionLogPath = $claudeSessionInfo.LogPath
                    } | Out-Null
                }
            }
            elseif (-not $claudeSessionInfo.LogPath) {
                $refreshedClaudeSessionInfo = Get-ClaudeSessionInfo -ProcessId $process.Id
                if ($refreshedClaudeSessionInfo -and $refreshedClaudeSessionInfo.LogPath) {
                    $claudeSessionInfo = $refreshedClaudeSessionInfo
                    Set-AgentStatus -RoleConfig $RoleConfig -RunId $RunId -CycleRunId $CycleRunId -Values @{
                        SessionId = $claudeSessionInfo.SessionId
                        SessionLogPath = $claudeSessionInfo.LogPath
                    } | Out-Null
                }
            }

            if ($claudeSessionInfo -and $claudeSessionInfo.LogPath -and (Test-Path -LiteralPath $claudeSessionInfo.LogPath)) {
                # Treat Claude's internal session jsonl as heartbeat output when stdout/stderr stay silent.
                $claudeLogItem = Get-Item -LiteralPath $claudeSessionInfo.LogPath
                if ($claudeLogItem.Length -gt $lastClaudeLogLength) {
                    $lastClaudeLogLength = $claudeLogItem.Length
                    $lastOutputAt = $now
                    if (-not $recentOutput) {
                        $recentOutput = Get-ClaudeLogExcerpt -Path $claudeSessionInfo.LogPath
                    }
                }
            }
        }

        if (($now - $startedAt).TotalSeconds -gt $TimeoutSec) {
            Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
            Set-AgentStatus -RoleConfig $RoleConfig -RunId $RunId -CycleRunId $CycleRunId -Values @{
                Status = "TIMEOUT"
                ExitCode = -1
                CompletedAt = (Get-Date).ToString("o")
                LastHeartbeatAt = $now.ToString("o")
                LastOutputAt = $lastOutputAt.ToString("o")
                RecentOutput = "전체 실행 시간이 제한($TimeoutSec 초)을 초과했습니다."
                Note = "Timeout"
            } | Out-Null
            throw "$($RoleConfig.Role) 실행이 $TimeoutSec 초를 초과했습니다. 프롬프트를 줄이거나 CLI 상태를 확인한 뒤 다시 실행하세요."
        }

        if (($now - $lastOutputAt).TotalSeconds -gt $effectiveNoOutputTimeoutSec) {
            Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
            Set-AgentStatus -RoleConfig $RoleConfig -RunId $RunId -CycleRunId $CycleRunId -Values @{
                Status = "NO_OUTPUT_TIMEOUT"
                ExitCode = -1
                CompletedAt = (Get-Date).ToString("o")
                LastHeartbeatAt = $now.ToString("o")
                LastOutputAt = $lastOutputAt.ToString("o")
                RecentOutput = "최근 출력이 없어 중단했습니다."
                Note = "No output timeout"
            } | Out-Null
            throw "$($RoleConfig.Role) 실행 중 $effectiveNoOutputTimeoutSec 초 동안 새 출력이 없었습니다. CLI 가 멈췄는지 확인하고 로그를 점검한 뒤 다시 실행하세요."
        }

        Set-AgentStatus -RoleConfig $RoleConfig -RunId $RunId -CycleRunId $CycleRunId -Values @{
            Status = "RUNNING"
            Pid = $process.Id
            LastHeartbeatAt = $now.ToString("o")
            LastOutputAt = $lastOutputAt.ToString("o")
            RecentOutput = $recentOutput
        } | Out-Null

        if (($now - $lastStatusPrintAt).TotalSeconds -ge 5) {
            $elapsed = $now - $startedAt
            $display = if ($recentOutput) { $recentOutput } else { "출력 대기 중" }
            Write-Host ("[{0}] elapsed={1} last={2}" -f $RoleConfig.Role.ToUpperInvariant(), $elapsed.ToString("hh\:mm\:ss"), $display)
            $lastStatusPrintAt = $now
        }

        Start-Sleep -Seconds 1
    }

    $stderr = if (Test-Path -LiteralPath $stderrPath) { Read-Utf8File -Path $stderrPath } else { "" }
    $stdoutPrimary = if (Test-Path -LiteralPath $stdoutPath) { Read-Utf8File -Path $stdoutPath } else { "" }
    $stdoutResult = if (Test-Path -LiteralPath $resultPath) { Read-Utf8File -Path $resultPath } else { "" }
    $finalOutput = if (-not [string]::IsNullOrWhiteSpace($stdoutResult)) { $stdoutResult } else { $stdoutPrimary }
    $tokenUsage = Get-TokenUsageFromText -Texts @($stdoutPrimary, $stderr, $stdoutResult)

    if ($process.ExitCode -ne 0) {
        Set-AgentStatus -RoleConfig $RoleConfig -RunId $RunId -CycleRunId $CycleRunId -Values @{
            Status = "FAILED"
            ExitCode = $process.ExitCode
            CompletedAt = (Get-Date).ToString("o")
            LastHeartbeatAt = (Get-Date).ToString("o")
            LastOutputAt = $lastOutputAt.ToString("o")
            PromptTokens = $tokenUsage.PromptTokens
            CompletionTokens = $tokenUsage.CompletionTokens
            TotalTokens = $tokenUsage.TotalTokens
            RecentOutput = (Get-RecentLogExcerpt -Path $stderrPath)
            Note = "ExitCode=$($process.ExitCode)"
        } | Out-Null
        throw "[${($RoleConfig.Role)}] exit code $($process.ExitCode) 로 실패했습니다. stderr 로그를 확인하고 프롬프트/CLI 설정을 점검한 뒤 다시 실행하세요.`n$stderr"
    }

    Write-Utf8File -Path $RoleConfig.ReportPath -Content $finalOutput
    Set-AgentStatus -RoleConfig $RoleConfig -RunId $RunId -CycleRunId $CycleRunId -Values @{
        Status = "COMPLETED"
        ExitCode = 0
        CompletedAt = (Get-Date).ToString("o")
        LastHeartbeatAt = (Get-Date).ToString("o")
        LastOutputAt = $lastOutputAt.ToString("o")
        PromptTokens = $tokenUsage.PromptTokens
        CompletionTokens = $tokenUsage.CompletionTokens
        TotalTokens = $tokenUsage.TotalTokens
        RecentOutput = (Get-RecentLogExcerpt -Path $stdoutPath)
    } | Out-Null

    $elapsed = (Get-Date) - $startedAt
    Write-Host ("[{0}] done in {1}" -f $RoleConfig.Role.ToUpperInvariant(), $elapsed.ToString("hh\:mm\:ss"))

    return [pscustomobject]@{
        Status = "COMPLETED"
        ExitCode = 0
        PromptTokens = $tokenUsage.PromptTokens
        CompletionTokens = $tokenUsage.CompletionTokens
        TotalTokens = $tokenUsage.TotalTokens
        RunId = $RunId
    }
}

function Invoke-AgentRole {
    param(
        [Parameter(Mandatory)][ValidateSet("leader", "be_dev", "fe_dev", "reviewer", "qa", "leader_final")][string]$Role,
        [string]$PlanName = "",
        [string]$Model,
        [AllowEmptyString()][string]$Cli,
        [switch]$DryRun,
        [string]$MockOutputPath,
        [hashtable]$MockMetadata = @{},
        [int]$TimeoutSec = 2700,
        [int]$NoOutputTimeoutSec = 300,
        [string]$RunId,
        [string]$CycleRunId
    )

    $config = Get-AgentPlanConfig -PlanName $PlanName
    $roleConfig = Get-ResolvedRoleConfig -Config $config -Role $Role -Model $Model -Cli $Cli
    Assert-RolePrerequisites -Config $config -RoleConfig $roleConfig -DryRun:$DryRun

    $promptText = Get-RolePromptPayload -Config $config -RoleConfig $roleConfig
    $result = Invoke-AgentPrompt `
        -RoleConfig $roleConfig `
        -PromptText $promptText `
        -DryRun:$DryRun `
        -MockOutputPath $MockOutputPath `
        -MockMetadata $MockMetadata `
        -TimeoutSec $TimeoutSec `
        -NoOutputTimeoutSec $NoOutputTimeoutSec `
        -RunId $RunId `
        -CycleRunId $CycleRunId

    if ($roleConfig.NeedsGitArtifacts) {
        if ($DryRun) {
            Write-Utf8File -Path $roleConfig.DiffPath -Content "# DryRun - no git diff"
            Write-Utf8File -Path $roleConfig.ChangedFilesPath -Content "# DryRun - no changed files"
        }
        else {
            Invoke-GitArtifactCapture -RoleConfig $roleConfig
        }
    }

    return [pscustomobject]@{
        Config = $config
        RoleConfig = $roleConfig
        Result = $result
        Status = Get-AgentStatus -Config $config -Role $Role
    }
}

function Get-ReportDirectives {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "보고서 파일을 찾지 못했습니다: $Path. 먼저 해당 역할 스크립트를 실행해 보고서를 생성하세요."
    }

    $text = Read-Utf8File -Path $Path
    $directives = [ordered]@{
        Decision = $null
        BeRequired = $null
        FeRequired = $null
        NextOrder = $null
    }

    foreach ($line in ($text -split "`r?`n")) {
        if ($line -match '^\s*Decision\s*:\s*(\S.*?)\s*$') {
            $directives.Decision = $Matches[1].Trim().ToUpperInvariant()
        }
        elseif ($line -match '^\s*BE_REQUIRED\s*:\s*(\S.*?)\s*$') {
            $directives.BeRequired = $Matches[1].Trim().ToLowerInvariant() -eq "true"
        }
        elseif ($line -match '^\s*FE_REQUIRED\s*:\s*(\S.*?)\s*$') {
            $directives.FeRequired = $Matches[1].Trim().ToLowerInvariant() -eq "true"
        }
        elseif ($line -match '^\s*NEXT_ORDER\s*:\s*(\S.*?)\s*$') {
            $directives.NextOrder = $Matches[1].Trim()
        }
    }

    return [pscustomobject]$directives
}

function Get-CycleSummaryObject {
    param(
        [Parameter(Mandatory)][pscustomobject]$Config,
        [Parameter(Mandatory)][string]$RunId,
        [string]$FinalDecision = "BLOCKED"
    )

    $roles = @("leader", "be_dev", "fe_dev", "reviewer", "qa", "leader_final")
    $agents = @()
    $promptTotal = 0
    $completionTotal = 0
    $tokenTotal = 0

    foreach ($role in $roles) {
        $status = Get-AgentStatus -Config $Config -Role $role
        if (-not $status) {
            continue
        }

        $prompt = [int]$status.PromptTokens
        $completion = [int]$status.CompletionTokens
        $total = [int]$status.TotalTokens
        $promptTotal += $prompt
        $completionTotal += $completion
        $tokenTotal += $total

        $agents += [pscustomobject]@{
            role = $role
            model = $status.Model
            provider = $status.Provider
            cli = $status.Cli
            status = $status.Status
            promptTokens = $prompt
            completionTokens = $completion
            totalTokens = $total
            reportPath = $status.ReportPath
            outLogPath = $status.OutLogPath
            errLogPath = $status.ErrLogPath
        }
    }

    return [pscustomobject]@{
        planName = $Config.PlanName
        runId = $RunId
        finalDecision = $FinalDecision
        generatedAt = (Get-Date).ToString("o")
        agents = $agents
        totals = [pscustomobject]@{
            promptTokens = $promptTotal
            completionTokens = $completionTotal
            totalTokens = $tokenTotal
        }
    }
}

function Convert-CycleSummaryToMarkdown {
    param([Parameter(Mandatory)][pscustomobject]$Summary)

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add("# Cycle Summary")
    $lines.Add("")
    $lines.Add("- PlanName: $($Summary.planName)")
    $lines.Add("- RunId: $($Summary.runId)")
    $lines.Add("- FinalDecision: $($Summary.finalDecision)")
    $lines.Add("")
    $lines.Add("## Agents")
    $lines.Add("| Role | Model | Status | PromptTokens | CompletionTokens | TotalTokens |")
    $lines.Add("|------|-------|--------|--------------|------------------|-------------|")

    foreach ($agent in $Summary.agents) {
        $lines.Add("| $($agent.role) | $($agent.model) | $($agent.status) | $($agent.promptTokens) | $($agent.completionTokens) | $($agent.totalTokens) |")
    }

    $lines.Add("")
    $lines.Add("## Totals")
    $lines.Add("- PromptTokens: $($Summary.totals.promptTokens)")
    $lines.Add("- CompletionTokens: $($Summary.totals.completionTokens)")
    $lines.Add("- TotalTokens: $($Summary.totals.totalTokens)")

    return ($lines -join "`n")
}

function Write-CycleSummaryFiles {
    param(
        [Parameter(Mandatory)][pscustomobject]$Config,
        [Parameter(Mandatory)][string]$RunId,
        [string]$FinalDecision = "BLOCKED"
    )

    $summary = Get-CycleSummaryObject -Config $Config -RunId $RunId -FinalDecision $FinalDecision
    $markdown = Convert-CycleSummaryToMarkdown -Summary $summary
    $markdownPath = Join-Path $Config.ReportsDir "cycle_summary.md"
    $jsonPath = Join-Path $Config.DashboardDir "cycle_summary.json"
    $runPath = Join-Path $Config.RunsDir ("{0}.json" -f $RunId)

    Write-Utf8File -Path $markdownPath -Content $markdown
    Write-JsonFile -Path $jsonPath -Data $summary
    Write-JsonFile -Path $runPath -Data $summary

    return [pscustomobject]@{
        MarkdownPath = $markdownPath
        JsonPath = $jsonPath
        RunPath = $runPath
        Summary = $summary
    }
}
