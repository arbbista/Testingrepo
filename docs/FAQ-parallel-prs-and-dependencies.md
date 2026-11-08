# FAQ: parallel pull requests and asset dependencies

This page answers two common questions about the IDMC CI/CD pipeline:

1. [What happens when there's already an open PR and someone opens a second one?](#1-what-happens-when-theres-already-an-open-pr-and-someone-opens-a-second-one)
2. [How do we handle dependencies between assets and taskflows?](#2-how-do-we-handle-dependencies-between-assets-and-taskflows)

See [SETUP.md](SETUP.md) for how the pipeline is set up.

---

## 1. What happens when there's already an open PR and someone opens a second one?

There's only one Dev org, and it is linked to one branch, `develop`. So everyone's
check-ins land on `develop`. GitHub allows only one open PR per branch pair, so
**a second `develop` → `main` PR can't be opened.** Instead, the second developer's
check-in is **added automatically to the PR that's already open**.

```
develop:  A1 (Ana's mapping) ── B1 (Ben's taskflow) ──►  open PR #1 now contains A1 + B1
```

**If the changes are independent:** they ship together, like a release train. If
Ana's part isn't approved, Ben's part waits too.

**If Ben's taskflow depends on Ana's mapping:** this is the safe case. Both are in
the same PR, and the pipeline deploys the oldest commit first. So Ana's mapping is
in QA before Ben's taskflow arrives.

**Workarounds that don't work:**

- **Ben creates his own branch from `develop`.** That branch also contains Ana's
  commits, because they aren't on `main` yet. Merging it releases Ana's unapproved
  work anyway.
- **Someone deploys only Ben's commit by hand.** If it depends on Ana's mapping,
  IDMC refuses to pull it into QA and lists the missing objects. The pipeline stops
  there, and PROD isn't touched.

### The rule that makes this work: "Check In = ready for release"

- Developers save their work in Dev but don't check it in until it's ready for QA.
- If something unready gets checked in anyway, fix or back it out in Dev and check
  in again.

If the release train gets too slow as the team grows, the next step is to split the
work. Give each team or stream its own Dev sub-org and branch. Newer IDMC releases
may also let you link individual projects to their own repository; check whether
your release supports that.

### Summary

| Situation | What happens |
|---|---|
| A PR is open and someone else checks in | Their commit joins the open PR. Both are released together. |
| The second change depends on the first | Same PR, deployed oldest first, so it works. |
| One change in the PR isn't approved | Nothing in the PR is released until it's fixed or backed out. |
| Someone deploys a dependent commit on its own | The QA deploy fails and lists the missing objects. PROD isn't touched. |
| A PROD approval is rejected, then another PR is merged | ⚠ Known gap, see below |
| Several merges happen close together | ⚠ Known gap, see below |

### ⚠ Known gap: commits can be skipped

Each pipeline run deploys only the commits from **its own** merge. In two cases,
commits are silently skipped:

- **A PROD approval is rejected, and then another PR is merged.** The second run
  deploys only its own commits, so the first PR's changes reach QA but never reach
  PROD.
- **Three merges happen close together.** GitHub keeps only one waiting run per
  deploy queue. The third run cancels the second, waiting one, so the second
  merge's commits are never deployed. Setting `cancel-in-progress: false` doesn't
  prevent this; it only protects the run that's already executing.

**Planned fix:** the pipeline records the last commit it deployed to each
environment, using a Git tag such as `deployed/qa` and `deployed/prod`. Each run
then deploys everything from that tag up to now, so a rejected or cancelled run is
caught up by the next one. This should be done before going live.

---

## 2. How do we handle dependencies between assets and taskflows?

A typical dependency chain:

```
Taskflow ─► Mapping task ─► Mapping ─► Mapplets / user-defined functions
                  │              └──► Connections, runtime environment
                  └──► Schedule, parameter file
```

These fall into two groups:

| Deployed by the pipeline (through Git) | Set up once per environment, with the **same name** |
|---|---|
| Taskflows, mapping tasks, mappings, mapplets, other design assets | Connections, runtime environments (Secure Agent groups), schedules, parameter files on the agent |

### How IDMC behaves

- **Check In does not include dependent objects automatically.** You have to select
  them yourself.
- **A pull fails if a dependent object is missing in the target org**, and the
  error lists the missing objects.
- **Dependencies in other projects are not included in a pull.**
- **Connections, runtime environments and schedules are reused** if an object with
  the same name already exists in the target org.

### Rules

1. **Check in related objects together.** If you change a taskflow, its mapping
   task and its mapping, select all three in one Check In. That gives one commit
   with a consistent set, which is also Informatica's own recommendation.
2. **New dependencies go first, or in the same check-in.** The pipeline deploys
   oldest first, so mapping-then-taskflow works. Taskflow first, with its new
   mapping in a later commit, fails at the first deploy.
3. **Put shared building blocks in their own project**, e.g. a `Shared` project for
   mapplets and functions used everywhere. Change them in a separate PR that's
   released first. A pull won't bring in dependencies from other projects, so they
   must already be in QA and PROD.
4. **Create the per-environment objects before the first deploy**, with identical
   names in Dev, QA and PROD. The PR template has a checklist item for this.
5. **Organize projects by data flow**, so that checking in a folder naturally
   captures everything that flow needs.

### If a dependency is missed anyway

The QA deploy fails at that commit and shows IDMC's list of missing objects. PROD
stays untouched. Check in the missing object from Dev, open a new PR, and the next
deploy picks it up.

---

## Planned improvements

1. **Track the last deployed commit per environment** (fixes the known gap above).
2. **Dependency check in CI:** read each taskflow and mapping task in a PR and flag
   references to assets that aren't in the repository. This needs a sample of how
   IDMC lays out its files in GitHub first.

---

## Sources

- [Informatica: source control pulls](https://docs.informatica.com/integration-cloud/data-integration/current-version/asset-management/source-control/source-control-pulls.html)
- [Informatica: source control best practices](https://onlinehelp.informatica.com/IICS/prod/CAI/en/bc-asset-management/Source_control_best_practices.html)
- [Informatica: runtime environments and connections as dependent objects](https://docs.informatica.com/integration-cloud/data-integration/current-version/asset-management/asset-migration/dependent-objects/runtime-environments-and-connections.html)
- [GitHub Docs: control workflow concurrency](https://docs.github.com/en/enterprise-server@3.14/actions/how-tos/write-workflows/choose-when-workflows-run/control-workflow-concurrency)
- [DEV Community: cancel-in-progress false still drops queued runs](https://dev.to/kanta13jp1/github-actions-concurrency-trap-cancel-in-progress-false-still-drops-queued-runs-5hg3)
