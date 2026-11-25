<#
.SYNOPSIS
  One-time GitHub setup for the Salesforce CI/CD pipeline.

.DESCRIPTION
  - Creates the develop and uat branches from main (if missing)
  - Creates the SIT, UAT and PROD GitHub Environments
  - Sets the Apex test level per org (repo variables)
  - Optionally restricts allowed Jira project keys
  - Optionally adds a required reviewer to PROD (approval gate)
  - Optionally protects develop/uat/main so merges need a PR with green checks

  Run from the repo root after the first push to GitHub.
  Requires: git, GitHub CLI (gh) logged in with `gh auth login`.

.EXAMPLE
  .\scripts\bootstrap-github.ps1 -Repo your-user/salesforce-cicd-poc -JiraKeys PROJ -ProdReviewer your-github-user -ProtectBranches
#>
param(
    [Parameter(Mandatory = $true)]
    [string]$Repo,

    # Comma-separated Jira project keys, e.g. "PROJ,SFDC". Empty = any key format.
    [string]$JiraKeys,

    # GitHub username who must approve PROD deployments.
    [string]$ProdReviewer,

    # Require a PR + green checks on develop/uat/main.
    [switch]$ProtectBranches,

    # Approvals needed on PRs when -ProtectBranches is used (0 for a solo POC).
    [int]$RequiredApprovals = 0
)

$ErrorActionPreference = 'Stop'

function Invoke-Gh {
    param([string[]]$GhArgs, [string]$InputJson)
    if ($InputJson) { $out = $InputJson | gh @GhArgs }
    else { $out = gh @GhArgs }
    if ($LASTEXITCODE -ne 0) { throw "gh $($GhArgs -join ' ') failed" }
    return $out
}

# --- 1. Long-lived branches -------------------------------------------------
Write-Host "Creating long-lived branches..." -ForegroundColor Cyan
git fetch origin --quiet
foreach ($branch in 'develop', 'uat') {
    git ls-remote --exit-code --heads origin $branch | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Write-Host "  $branch already exists"
    }
    else {
        git push origin "refs/remotes/origin/main:refs/heads/$branch"
        if ($LASTEXITCODE -ne 0) { throw "Could not create branch $branch" }
        Write-Host "  created $branch from main"
    }
}

# --- 2. Environments --------------------------------------------------------
Write-Host "Creating GitHub Environments SIT, UAT, PROD..." -ForegroundColor Cyan
foreach ($envName in 'SIT', 'UAT', 'PROD') {
    Invoke-Gh -GhArgs @('api', '--method', 'PUT', "repos/$Repo/environments/$envName", '--silent') | Out-Null
    Write-Host "  $envName ok"
}

# --- 3. Test levels ---------------------------------------------------------
# NoTestRun is allowed in sandboxes only; production always needs tests.
Write-Host "Setting test levels..." -ForegroundColor Cyan
Invoke-Gh -GhArgs @('variable', 'set', 'TEST_LEVEL_SIT', '--repo', $Repo, '--body', 'NoTestRun') | Out-Null
Invoke-Gh -GhArgs @('variable', 'set', 'TEST_LEVEL_UAT', '--repo', $Repo, '--body', 'RunLocalTests') | Out-Null
Invoke-Gh -GhArgs @('variable', 'set', 'TEST_LEVEL_PROD', '--repo', $Repo, '--body', 'RunLocalTests') | Out-Null
Write-Host "  SIT=NoTestRun, UAT=RunLocalTests, PROD=RunLocalTests"

# --- 4. Jira keys -----------------------------------------------------------
if ($JiraKeys) {
    Invoke-Gh -GhArgs @('variable', 'set', 'JIRA_PROJECT_KEYS', '--repo', $Repo, '--body', $JiraKeys) | Out-Null
    Write-Host "Allowed Jira keys: $JiraKeys" -ForegroundColor Cyan
}

# --- 5. PROD approval gate --------------------------------------------------
if ($ProdReviewer) {
    Write-Host "Adding $ProdReviewer as required reviewer on PROD..." -ForegroundColor Cyan
    $userId = Invoke-Gh -GhArgs @('api', "users/$ProdReviewer", '--jq', '.id')
    $body = @{ reviewers = @(@{ type = 'User'; id = [int64]$userId }) } | ConvertTo-Json -Depth 5 -Compress
    try {
        Invoke-Gh -GhArgs @('api', '--method', 'PUT', "repos/$Repo/environments/PROD", '--input', '-', '--silent') -InputJson $body | Out-Null
        Write-Host "  PROD deployments now wait for approval"
    }
    catch {
        Write-Warning "Could not add a reviewer. Required reviewers on PRIVATE repos need a paid GitHub plan (see README). Continuing."
    }
}

# --- 6. Branch protection ---------------------------------------------------
if ($ProtectBranches) {
    Write-Host "Protecting develop, uat, main..." -ForegroundColor Cyan
    $protection = @{
        required_status_checks        = @{
            strict   = $true
            contexts = @('Validate against target org', 'Jira key present')
        }
        enforce_admins                = $false
        required_pull_request_reviews = @{ required_approving_review_count = $RequiredApprovals }
        restrictions                  = $null
    } | ConvertTo-Json -Depth 5 -Compress

    foreach ($branch in 'develop', 'uat', 'main') {
        try {
            Invoke-Gh -GhArgs @('api', '--method', 'PUT', "repos/$Repo/branches/$branch/protection", '--input', '-', '--silent') -InputJson $protection | Out-Null
            Write-Host "  $branch protected"
        }
        catch {
            Write-Warning "Could not protect $branch. Branch protection on PRIVATE repos needs GitHub Pro/Team (see README)."
        }
    }
}

Write-Host ""
Write-Host "GitHub setup complete. Next: run scripts\setup-org-secret.ps1 for SIT, UAT and PROD." -ForegroundColor Green
