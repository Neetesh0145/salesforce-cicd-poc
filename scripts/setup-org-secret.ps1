<#
.SYNOPSIS
  Logs in to a Salesforce org in your browser and stores its SFDX auth URL as a
  GitHub Actions secret (SFDX_AUTH_URL_<ENV>) so the pipeline can deploy to it.

.DESCRIPTION
  Run once per environment (SIT, UAT, PROD), and again after every sandbox refresh
  (a refresh invalidates the stored auth URL).
  Requires: Salesforce CLI (sf) and GitHub CLI (gh, logged in with `gh auth login`).

.EXAMPLE
  .\scripts\setup-org-secret.ps1 -Environment SIT -Repo your-user/salesforce-cicd-poc

.EXAMPLE
  # POC with a Developer Edition org standing in for production
  .\scripts\setup-org-secret.ps1 -Environment PROD -Repo your-user/salesforce-cicd-poc -InstanceUrl https://login.salesforce.com
#>
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('SIT', 'UAT', 'PROD')]
    [string]$Environment,

    [Parameter(Mandatory = $true)]
    [string]$Repo,

    # Defaults: test.salesforce.com for sandboxes, login.salesforce.com for PROD.
    # A My Domain URL (https://yourco--sit.sandbox.my.salesforce.com) also works.
    [string]$InstanceUrl
)

$ErrorActionPreference = 'Stop'

if (-not $InstanceUrl) {
    if ($Environment -eq 'PROD') { $InstanceUrl = 'https://login.salesforce.com' }
    else { $InstanceUrl = 'https://test.salesforce.com' }
}

$alias = "cicd-$Environment"

Write-Host "1/3  Opening browser to log in to $Environment ($InstanceUrl) as alias '$alias'..." -ForegroundColor Cyan
Write-Host "     Tip: log in as a dedicated integration/deployment user, not your personal user."
sf org login web --alias $alias --instance-url $InstanceUrl
if ($LASTEXITCODE -ne 0) { throw "Salesforce login failed." }

Write-Host "2/3  Reading the auth URL for '$alias'..." -ForegroundColor Cyan
$raw = (sf org display --target-org $alias --verbose --json) -join "`n"
if ($LASTEXITCODE -ne 0) { throw "sf org display failed." }
$org = $raw | ConvertFrom-Json
$authUrl = $org.result.sfdxAuthUrl
if (-not $authUrl) {
    throw "No sfdxAuthUrl returned. Log in with 'sf org login web' (not JWT/access token) and try again."
}

Write-Host "3/3  Saving secret SFDX_AUTH_URL_$Environment in $Repo..." -ForegroundColor Cyan
gh secret set "SFDX_AUTH_URL_$Environment" --repo $Repo --body $authUrl
if ($LASTEXITCODE -ne 0) { throw "gh secret set failed. Run 'gh auth login' and check the repo name." }

$authUrl = $null
Write-Host "Done. $Environment ($($org.result.username)) is connected to the pipeline." -ForegroundColor Green
