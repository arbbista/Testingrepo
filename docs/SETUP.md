# IDMC CI/CD — Setup guide

This guide sets up the pipeline in this repository for Informatica IDMC
Cloud Data Integration (CDI). Do it once. Menu names in IDMC can differ a
little between releases.

## How it works

```
IDMC Dev org ──Check In──► develop ──Pull request──► main ──► QA org ──approval──► PROD org
                                      (CI checks)           (auto)               (manual gate)
```

1. Developers build in the **Dev** org and click **Check In**. IDMC commits the
   change to the `develop` branch.
2. A pull request from `develop` into `main` runs the **IDMC CI** checks
   and shows which check-ins will be deployed. A teammate reviews it.
3. When the PR is merged, **IDMC CD** deploys those check-ins to the **QA** org,
   oldest first, and runs an optional smoke test.
4. After an approver clicks **Approve** in GitHub, the same check-ins are
   deployed to **PROD**.

| File | Purpose |
|---|---|
| `.github/workflows/idmc-ci.yml` | Checks that run on every pull request into `main` |
| `.github/workflows/idmc-cd.yml` | Deploys to QA, then PROD after approval |
| `scripts/idmc-deploy.sh` | Logs in to IDMC, deploys commits, runs the smoke test |
| `scripts/idmc-commits.sh` | Finds the IDMC check-in commits in a merge |
| `.github/pull_request_template.md` | Review checklist for each PR |

---

## 1. IDMC setup

1. **Three environments.** Have a Dev, QA and PROD org (or sub-orgs).
2. **Same names everywhere.** In each org, create the connections and runtime
   environments (Secure Agent groups) your assets use, with **exactly the same
   names**. The pipeline never moves connections, so each org keeps its own
   credentials.
3. **Service user in QA and PROD.** Create a user only for the pipeline:
   - a native IDMC login (not SSO/SAML), so it can log in with a password
   - a role that can pull from source control and run tasks
   - in that user's profile, save a GitHub personal access token with **read**
     access to this repository
4. **Link the orgs to this repository** (Administrator → Settings → Source Control):

   | Org | Branch |
   |---|---|
   | Dev | `develop` |
   | QA | `main` |
   | PROD | `main` |

5. **Developer access.** Each developer saves their own GitHub token (with write
   access) in their IDMC profile, so they can check in from the Dev org.
6. **Lock down QA and PROD.** Nobody edits or checks in from QA or PROD. Changes
   only arrive through the pipeline.

## 2. GitHub setup

1. **Create the `develop` branch** from `main`.
2. **Merge setting** (Settings → General → Pull Requests): allow **merge commits**
   only. Turn off *squash merging* and *rebase merging*, and turn off
   *automatically delete head branches*.
   > Why: the pipeline deploys the original commits that IDMC created.
   > Squash and rebase replace them with new commits that IDMC did not make.
3. **Protect `main`** (Settings → Branches → Add rule):
   - Require a pull request before merging, with at least 1 approval
   - Require the status check **Validate assets** to pass
4. **Create two environments** (Settings → Environments): `qa` and `prod`.
   For each one, add:

   | Type | Name | Value |
   |---|---|---|
   | Secret | `IDMC_USERNAME` | The service user of that org |
   | Secret | `IDMC_PASSWORD` | Its password |
   | Variable | `IDMC_POD_URL` | Login URL for your region, e.g. `https://dm-us.informaticacloud.com` |
   | Variable (optional) | `IDMC_SMOKE_TASK_ID` | ID of a small task to run after each deploy |
   | Variable (optional) | `IDMC_SMOKE_TASK_TYPE` | Its type: `MTT` (mapping task, default), `WORKFLOW` (taskflow), ... |

   On **`prod`** also set:
   - **Required reviewers**: the people who approve production releases
   - **Deployment branches**: `main` only

## 3. Test the setup

1. **From your laptop first.** Check in one simple mapping from Dev, copy the
   commit hash from GitHub, and deploy it to QA by hand:

   ```bash
   export IDMC_POD_URL=https://dm-us.informaticacloud.com
   export IDMC_USERNAME=<qa service user>
   export IDMC_PASSWORD=<password>
   scripts/idmc-deploy.sh <full commit hash>
   ```

2. **Then through GitHub.** Open a PR from `develop` into `main`, check the CI
   summary, merge it, and watch **Actions → IDMC CD**.

## Daily use

| I want to... | Do this |
|---|---|
| Ship a change | Check in from Dev → open PR `develop` → `main` → merge → approve PROD |
| See what will be deployed | Open the PR's **Validate assets** check → *Summary* |
| Redeploy or roll back | Actions → **IDMC CD** → *Run workflow* → enter the commit hash(es) of the good version |
| See why a deploy failed | The job log, then IDMC → Monitor → Source Control Logs in that org |

## Good to know

- Each pull request should contain everything it depends on. If a taskflow uses
  a mapping task that is not in QA yet, include it in the same PR.
- Pushes to `main` that only change `.github/`, `scripts/`, `docs/` or `*.md`
  files do not deploy anything.
- Parameter files on the Secure Agent machine and schedules are not deployed by
  this pipeline. Manage them per environment.
- If your IDMC org only allows logins from trusted IP addresses, GitHub-hosted
  runners may be blocked. Use a self-hosted runner in that case.
