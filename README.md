# Testingrepo

Informatica IDMC Cloud Data Integration assets, with CI/CD through GitHub Actions.

```
IDMC Dev org ──Check In──► develop ──Pull request──► main ──► QA org ──approval──► PROD org
```

- **CI** (`.github/workflows/idmc-ci.yml`): every pull request into `main` is
  checked, and the summary lists the IDMC check-ins it will deploy.
- **CD** (`.github/workflows/idmc-cd.yml`): after merge, those check-ins are
  deployed to QA and smoke-tested. After approval, they go to PROD.

Start here:
- [docs/SETUP.md](docs/SETUP.md): one-time setup and daily use
- [docs/FAQ-parallel-prs-and-dependencies.md](docs/FAQ-parallel-prs-and-dependencies.md): parallel PRs and asset dependencies
- [docs/IDMC_CICD_Proposal.docx](docs/IDMC_CICD_Proposal.docx): the proposal
