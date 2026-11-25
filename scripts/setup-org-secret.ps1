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
    [string]$InstanceUrl,

    # Log in again in the browser even if this alias is already connected.
    [switch]$ForceLogin
)

$ErrorActionPreference = 'Stop'

if (-not $InstanceUrl) {
    if ($Environment -eq 'PROD') { $InstanceUrl = 'https://login.salesforce.com' }
    else { $InstanceUrl = 'https://test.salesforce.com' }
}

$alias = "cicd-$Environment"

function Invoke-SfJson {
    # Runs an sf command with --json and returns the parsed result, or $null if it failed.
    param([string[]]$SfArgs)
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $text = (& sf @SfArgs --json 2>$null) -join "`n"
        if ($LASTEXITCODE -ne 0 -or -not $text) { return $null }
        return ($text | ConvertFrom-Json)
    }
    catch { return $null }
    finally { $ErrorActionPreference = $prev }
}

$alreadyConnected = $false
if (-not $ForceLogin) {
    $alreadyConnected = ($null -ne (Invoke-SfJson -SfArgs @('org', 'display', '--target-org', $alias)))
}

if ($alreadyConnected) {
    Write-Host "1/3  '$alias' is already logged in - skipping browser login (use -ForceLogin to log in again)." -ForegroundColor Cyan
}
else {
    Write-Host "1/3  Opening browser to log in to $Environment ($InstanceUrl) as alias '$alias'..." -ForegroundColor Cyan
    Write-Host "     Tip: log in as a dedicated integration/deployment user, not your personal user."
    sf org login web --alias $alias --instance-url $InstanceUrl
    if ($LASTEXITCODE -ne 0) { throw "Salesforce login failed." }
}

Write-Host "2/3  Reading the auth URL for '$alias'..." -ForegroundColor Cyan
$org = Invoke-SfJson -SfArgs @('org', 'display', '--target-org', $alias)
if (-not $org) { throw "Org '$alias' is not logged in. Re-run with -ForceLogin." }

# Newer Salesforce CLI versions redact the auth URL in 'org display'; this command returns the real value.
$authUrl = $null
$shown = Invoke-SfJson -SfArgs @('org', 'auth', 'show-sfdx-auth-url', '--target-org', $alias)
if ($shown) { $authUrl = $shown.result.sfdxAuthUrl }
if (-not $authUrl) {
    # Older CLI versions: fall back to 'org display --verbose'
    $verbose = Invoke-SfJson -SfArgs @('org', 'display', '--target-org', $alias, '--verbose')
    if ($verbose) { $authUrl = $verbose.result.sfdxAuthUrl }
}
if (-not $authUrl -or -not ([string]$authUrl).StartsWith('force://')) {
    throw "Could not read a valid auth URL (must start with force://). Log in with 'sf org login web' (not JWT/access token) and try again."
}

Write-Host "3/3  Saving secret SFDX_AUTH_URL_$Environment in $Repo..." -ForegroundColor Cyan
gh secret set "SFDX_AUTH_URL_$Environment" --repo $Repo --body $authUrl
if ($LASTEXITCODE -ne 0) { throw "gh secret set failed. Run 'gh auth login' and check the repo name." }

$authUrl = $null
Write-Host "Done. $Environment ($($org.result.username)) is connected to the pipeline." -ForegroundColor Green
