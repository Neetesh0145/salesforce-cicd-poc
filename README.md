# Salesforce CI/CD POC: GitHub Actions + Salesforce CLI + Jira

A GitHub-backed pipeline for Salesforce that replaces per-user Copado licences:

- **PR validation:** every pull request is validated against the org it will deploy to (dry run + Apex tests). Only the changed metadata is checked, using `sfdx-git-delta`. Salesforce Code Analyzer also runs on the source.
- **Automatic deployment** when a PR is merged: `develop` deploys to SIT, `uat` deploys to UAT and `main` deploys to PROD (PROD can require approval).
- **Jira integration:** branches, commits, PRs, builds and deployments appear on the Jira ticket through the free *GitHub for Jira* app. A check makes sure each PR carries a Jira key.

```
 Dev sandbox ──retrieve──► feature/PROJ-123-xyz ──PR──► develop ──PR──► uat ──PR──► main
                                                  │         │         │      │       │
                                          validate SIT  deploy SIT  validate deploy  validate ─► deploy PROD
                                                                     UAT     UAT     PROD        (approval)
```

## Repository contents

| Path | Purpose |
|---|---|
| `.github/workflows/pr-validation.yml` | Validates PR delta against the target org and runs Code Analyzer |
| `.github/workflows/deploy.yml` | Deploys the delta when a PR is merged into `develop`, `uat` or `main` |
| `.github/workflows/jira-key-check.yml` | Fails a PR that has no Jira key in its branch name or title |
| `.github/actions/sf-setup/action.yml` | Installs the Salesforce CLI and sfdx-git-delta, then logs in |
| `scripts/ci/sf-delta-deploy.sh` | Works out the delta and runs the validation or deployment (used by both workflows) |
| `scripts/bootstrap-github.ps1` | One-time GitHub setup: branches, environments, variables, protection |
| `scripts/setup-org-secret.ps1` | Connects an org to the pipeline by storing its auth URL as a secret |
| `.jira/config.yml` | Maps the SIT, UAT and PROD environments to Jira's environment types |
| `manifest/package.xml` | Used only to retrieve the existing metadata baseline from a sandbox |
| `force-app/` | Salesforce source (contains a sample class and test for the POC) |

---

## 1. Prerequisites (one time, on your machine)

```powershell
winget install --id Git.Git -e
```
```powershell
winget install --id GitHub.cli -e
```
```powershell
winget install --id OpenJS.NodeJS.LTS -e
```
```powershell
npm install --global @salesforce/cli
```
```powershell
gh auth login
```

Allow the PowerShell scripts in this repo to run in the current window:

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
```

**Orgs for the POC:** you need up to three orgs, one each for SIT, UAT and PROD. For the POC they can be any sandboxes or Developer Edition orgs you have. A single sandbox can also stand in for all three if that's all you have.

## 2. Create the GitHub repo and push

Run these from this folder. Replace `salesforce-cicd-poc` if you want a different name.

```powershell
git init -b main
```
```powershell
git add .
```
```powershell
git commit -m "Initial Salesforce CI/CD pipeline"
```
```powershell
gh repo create salesforce-cicd-poc --private --source . --push
```

> **Public or private?** On GitHub Free, *required reviewers* on environments and *branch protection* only work on **public** repos. The POC contains only sample code, so making it public is fine: use `--public` instead. Client repos need GitHub Team or Enterprise for these features (see section 8).

## 3. Configure GitHub (branches, environments, test levels)

Replace `your-user`, `PROJ` (your Jira project key) and the reviewer name:

```powershell
.\scripts\bootstrap-github.ps1 -Repo your-user/salesforce-cicd-poc -JiraKeys PROJ -ProdReviewer your-github-user -ProtectBranches
```

This creates the `develop` and `uat` branches and the `SIT`, `UAT` and `PROD` environments. It sets these repo variables:

| Variable | Value |
|---|---|
| `TEST_LEVEL_SIT` | NoTestRun |
| `TEST_LEVEL_UAT` | RunLocalTests |
| `TEST_LEVEL_PROD` | RunLocalTests |

It also adds a PROD approval gate and branch protection.

## 4. Connect each org to the pipeline

Each command opens a browser so you can log in. Use a deployment or integration user.

```powershell
.\scripts\setup-org-secret.ps1 -Environment SIT -Repo your-user/salesforce-cicd-poc
```
```powershell
.\scripts\setup-org-secret.ps1 -Environment UAT -Repo your-user/salesforce-cicd-poc
```
```powershell
.\scripts\setup-org-secret.ps1 -Environment PROD -Repo your-user/salesforce-cicd-poc -InstanceUrl https://login.salesforce.com
```

This stores the repo secrets `SFDX_AUTH_URL_SIT`, `SFDX_AUTH_URL_UAT` and `SFDX_AUTH_URL_PROD`. If PROD is a sandbox in your POC, leave out `-InstanceUrl`.

## 5. Connect Jira

1. In Jira, go to **Apps → Explore more apps**, search for **GitHub for Jira** (by Atlassian, free) and install it. You need Jira admin rights for this step.
2. Open the app, choose **Connect GitHub organization**, and select your account and this repo.
3. Use the Jira key everywhere:
   - **Branch:** `feature/PROJ-123-discount-field`
   - **Commit:** `PROJ-123 add discount field to Opportunity`
   - **PR title:** `PROJ-123: Add discount field`
4. Open the Jira ticket. The **Development** panel shows branches, commits, PRs and builds. The **Deployments** panel shows SIT, UAT and PROD deployments, typed as Testing, Staging and Production by `.jira/config.yml`.

## 6. Try it end to end

```powershell
git checkout develop
```
```powershell
git pull
```
```powershell
git checkout -b feature/PROJ-1-health-check-message
```

Edit `force-app/main/default/classes/CiCdHealthCheck.cls` and its test, changing the message in both. Then:

```powershell
git commit -am "PROJ-1 change health check message"
```
```powershell
git push -u origin feature/PROJ-1-health-check-message
```
```powershell
gh pr create --base develop --title "PROJ-1: Change health check message" --fill
```

What to check:

1. **PR checks:**
   - *Validate against target org* runs a dry run against SIT. The run summary shows the delta `package.xml`.
   - *Static code analysis* produces a report you can download from the run's artifacts.
   - *Jira key present* passes.
2. Merge the PR. **Deploy → Deploy to SIT** runs. Check that the class changed in SIT.
3. Promote by opening a PR from `develop` into `uat`, which validates against UAT, then merge it to deploy to UAT:
   ```powershell
   gh pr create --base uat --head develop --title "Release: develop to UAT" --fill
   ```
4. Open a PR from `uat` into `main`, which validates against PROD. Merging it starts **Deploy to PROD**, which waits for the approver. After approval it deploys with `RunLocalTests`.
5. Check the Jira ticket PROJ-1: you should see the branch, commits, PRs and three deployments.

### Bringing in existing metadata (baseline)

Retrieve the current state of a sandbox once, then commit it to `main` before the team starts working:

```powershell
sf project retrieve start --manifest manifest/package.xml --target-org cicd-SIT
```

---

## 7. Process

### Branching

| Branch | Deploys to | Comes from | Rules |
|---|---|---|---|
| `feature/PROJ-123-*`, `bugfix/PROJ-123-*` | Nothing (validation only) | `develop` | One Jira ticket per branch |
| `develop` | SIT | Feature PRs | PR, green checks |
| `uat` | UAT | PR from `develop` (release) | PR, green checks |
| `main` | PROD | PR from `uat` | PR, green checks, PROD approval |
| `hotfix/PROJ-123-*` | Nothing (validation only) | `main` | PR into `main`, then back-merge `main` into `uat` and `develop` |

### Sandbox process

1. **Developer sandboxes:** each developer builds in their own sandbox, then retrieves their changes into a feature branch:
   ```powershell
   sf project retrieve start --metadata ApexClass:MyClass --target-org my-dev
   ```
   You can also use VS Code's **SFDX: Retrieve Source from Org** command.
2. **SIT (Developer Pro or Partial Copy):** the integration org. Only the pipeline deploys here, never manual change sets.
3. **UAT (Partial or Full Copy):** business testing of a release candidate.
4. **PROD:** deployments come only from `main`, through the pipeline, with approval.
5. **After any sandbox refresh:**
   - Re-run `scripts/setup-org-secret.ps1` for that environment, because a refresh invalidates the stored auth URL.
   - Then re-sync the sandbox by running **Deploy** manually (*Actions → Deploy → Run workflow*) with `from_ref` set to the last commit that was in production.
6. **Developer sandbox refresh:** refresh from PROD regularly (for example each release) so dev sandboxes don't drift.

### Test levels

These are repo variables. Change them under *Settings → Secrets and variables → Actions → Variables*.

| Variable | Default | Notes |
|---|---|---|
| `TEST_LEVEL_SIT` | `NoTestRun` | Fast feedback. Not allowed for production. |
| `TEST_LEVEL_UAT` | `RunLocalTests` | Catches coverage problems before PROD |
| `TEST_LEVEL_PROD` | `RunLocalTests` | Salesforce requires 75% coverage |
| `SPECIFIED_TESTS_<ENV>` | (empty) | Set the test level to `RunSpecifiedTests` and list classes, e.g. `AccountServiceTest,OppTriggerTest` |
| `CODE_ANALYZER_BLOCKING` | (unset) | `true` makes High or Critical findings fail the PR |

---

## 8. Moving from POC to the client org

- **Authentication:** switch from auth URLs to the JWT bearer flow.
  - Create an **External Client App** (or a Connected App if the org still allows them) with *JWT* enabled and a certificate uploaded.
  - Pre-authorise a dedicated integration user.
  - Store these per environment:

    | Setting | Where |
    |---|---|
    | `SF_JWT_KEY_<ENV>` (private key text) | Secret |
    | `SF_CLIENT_ID_<ENV>` | Secret |
    | `SF_USERNAME_<ENV>` | Variable |
    | `SF_INSTANCE_URL_<ENV>` | Variable |

  - The setup action uses JWT automatically when `SF_JWT_KEY_<ENV>` is present.
- **Protect PROD credentials:** PR validation into `main` reads the PROD secret, so anyone who can push a PR branch could in theory change a workflow to expose it. For the client:
  - Validate PRs into `main` against a **staging** or **Full Copy** sandbox, or with a read-limited user.
  - Move the PROD deploy secret into the `PROD` *environment* secrets, so only the approved deploy job can read it.
- **GitHub plan:** private repos need **GitHub Team** (about $4/user/month) for branch protection. Required reviewers on environments may need **Enterprise** for private repos; check GitHub's current docs for your plan.
- **Copado's single license:** Copado can stay with one release manager during the transition, while this pipeline proves itself in SIT and UAT.

## 9. Troubleshooting

| Symptom | Fix |
|---|---|
| `No credentials for this org` | Secret `SFDX_AUTH_URL_<ENV>` is missing. Run `setup-org-secret.ps1`. |
| Login fails after a sandbox refresh | Auth URL is invalid. Re-run `setup-org-secret.ps1`. |
| `Nonexistent flag: --source-dir` or `--output-dir` from `sf sgd` | You're on an older sfdx-git-delta. In `sf-delta-deploy.sh`, use `--source` and `--output`. |
| `NoTestRun` rejected | Production requires tests. Use `RunLocalTests` for PROD. |
| Deployment fails on profiles or settings | They're excluded in `.forceignore` on purpose. Deploy them with permission sets instead. |
| `Average test coverage ... below 75%` | Add or extend Apex tests for the changed classes. |
| Code Analyzer step fails to start | Needs Java 11+ and Python 3.10+, which GitHub's `ubuntu-latest` runners already have. |
