#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Deploy IDMC check-in commits into an IDMC org (QA or PROD), oldest first,
# then (optionally) run a smoke-test task to prove the deployment works.
#
# Used by .github/workflows/idmc-cd.yml, but you can also run it from your
# own machine to try things out:
#
#   export IDMC_POD_URL=https://dm-us.informaticacloud.com
#   export IDMC_USERNAME=svc_cicd
#   export IDMC_PASSWORD='...'
#   scripts/idmc-deploy.sh <commit-hash> [<commit-hash> ...]
#
# Required environment variables:
#   IDMC_POD_URL           Login URL for your IDMC region (POD)
#   IDMC_USERNAME          IDMC service user (native login, not SSO)
#   IDMC_PASSWORD          Password of the service user
#
# Optional environment variables:
#   IDMC_SMOKE_TASK_ID     Federated ID of a task to run after the deploy
#   IDMC_SMOKE_TASK_TYPE   Type of that task (default MTT = mapping task)
#   IDMC_PULL_TIMEOUT      Seconds to wait for the deploy   (default 900)
#   IDMC_SMOKE_TIMEOUT     Seconds to wait for the smoke test (default 1800)
#   IDMC_POLL_INTERVAL     Seconds between status checks    (default 10)
#
# Requires: bash, curl, jq
# -----------------------------------------------------------------------------
set -euo pipefail

COMMITS=("$@")
SMOKE_TASK_ID="${IDMC_SMOKE_TASK_ID:-}"
SMOKE_TASK_TYPE="${IDMC_SMOKE_TASK_TYPE:-MTT}"
PULL_TIMEOUT="${IDMC_PULL_TIMEOUT:-900}"
SMOKE_TIMEOUT="${IDMC_SMOKE_TIMEOUT:-1800}"
POLL_INTERVAL="${IDMC_POLL_INTERVAL:-10}"

SESSION=""
BASE=""

# --- Output helpers (GitHub annotations when running inside GitHub Actions) ---
in_actions() { [ -n "${GITHUB_ACTIONS:-}" ]; }
info()  { echo "$*"; }
warn()  { if in_actions; then echo "::warning::$*"; else echo "WARNING: $*" >&2; fi; }
die()   { if in_actions; then echo "::error::$*"; else echo "ERROR: $*" >&2; fi; exit 1; }
summary() { if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then echo "$*" >> "$GITHUB_STEP_SUMMARY"; fi; }

# --- Checks before we start ---
for tool in curl jq; do
  command -v "$tool" >/dev/null 2>&1 || die "'$tool' is required but not installed."
done
for var in IDMC_POD_URL IDMC_USERNAME IDMC_PASSWORD; do
  [ -n "${!var:-}" ] || die "Environment variable $var is not set."
done
[ "${#COMMITS[@]}" -gt 0 ] || die "Usage: $0 <commit-hash> [<commit-hash> ...]"
for c in "${COMMITS[@]}"; do
  [[ "$c" =~ ^[0-9a-f]{40}$ ]] || die "Commit hash must be the full 40-character hash, got: $c"
done

# --- IDMC API call: api METHOD PATH [JSON_BODY] -> prints the response body ---
api() {
  local method=$1 path=$2 body=${3:-}
  local header="INFA-SESSION-ID"           # v3 resources
  [[ "$path" == /api/v2/* ]] && header="icSessionId"   # v2 resources
  local args=(-sS --fail-with-body -X "$method" "$BASE$path"
              -H "Accept: application/json" -H "$header: $SESSION")
  if [ -n "$body" ]; then
    args+=(-H "Content-Type: application/json" -d "$body")
  fi
  curl "${args[@]}"
}

login() {
  local body resp
  body=$(jq -n --arg u "$IDMC_USERNAME" --arg p "$IDMC_PASSWORD" '{username: $u, password: $p}')
  resp=$(curl -sS --fail-with-body -X POST "${IDMC_POD_URL%/}/saas/public/core/v3/login" \
           -H "Content-Type: application/json" -H "Accept: application/json" -d "$body") \
    || die "Login to $IDMC_POD_URL failed: $resp"
  SESSION=$(jq -r '.userInfo.sessionId // empty' <<<"$resp")
  BASE=$(jq -r '.products[0].baseApiUrl // empty' <<<"$resp")
  [ -n "$SESSION" ] && [ -n "$BASE" ] || die "Login response did not contain a session. Response: $resp"
  if in_actions; then echo "::add-mask::$SESSION"; fi
  info "Logged in to IDMC as $IDMC_USERNAME"
}

logout() {
  if [ -n "$SESSION" ]; then
    api POST /public/core/v3/logout >/dev/null 2>&1 || true
  fi
}

# --- Step 1: pull one commit into the target org and wait for it to finish ---
deploy_commit() {
  local commit=$1 resp action_id state deadline
  info "Deploying commit $commit ..."
  resp=$(api POST /public/core/v3/pullByCommitHash "{\"commitHash\": \"$commit\"}") \
    || die "IDMC did not accept the deploy request: $resp"
  action_id=$(jq -r '.pullActionId // empty' <<<"$resp")
  [ -n "$action_id" ] || die "No pullActionId in response: $resp"
  info "Deploy started (action $action_id)"

  deadline=$((SECONDS + PULL_TIMEOUT))
  while :; do
    resp=$(api GET "/public/core/v3/sourceControlAction/$action_id") \
      || die "Could not read deploy status: $resp"
    state=$(jq -r '.status.state // empty' <<<"$resp")
    info "  status: ${state:-unknown}"
    case "$state" in
      SUCCESSFUL)
        summary "| Deploy \`${commit:0:8}\` | :white_check_mark: Successful |"
        return 0 ;;
      WARNING)
        warn "Deploy finished with warnings. See Monitor > Source Control Logs in IDMC."
        summary "| Deploy \`${commit:0:8}\` | :warning: Finished with warnings |"
        return 0 ;;
      FAILED)
        info "Details:"
        api GET "/public/core/v3/sourceControlAction/$action_id?expand=objects" 2>/dev/null \
          | jq '{status, objects}' 2>/dev/null || true
        summary "| Deploy \`${commit:0:8}\` | :x: Failed |"
        die "Deploy of $commit failed. See the details above and Monitor > Source Control Logs in IDMC." ;;
    esac
    if [ "$SECONDS" -ge "$deadline" ]; then
      summary "| Deploy \`${commit:0:8}\` | :x: Timed out |"
      die "Timed out after ${PULL_TIMEOUT}s waiting for the deploy of $commit to finish."
    fi
    sleep "$POLL_INTERVAL"
  done
}

# --- Step 2 (optional): run a smoke-test task and check that it succeeds ---
smoke_test() {
  local body resp task_id run_id state deadline
  info "Running smoke test task $SMOKE_TASK_ID ($SMOKE_TASK_TYPE) ..."
  body=$(jq -n --arg id "$SMOKE_TASK_ID" --arg t "$SMOKE_TASK_TYPE" \
           '{"@type": "job", taskFederatedId: $id, taskType: $t}')
  resp=$(api POST /api/v2/job "$body") || die "Could not start smoke test task: $resp"
  task_id=$(jq -r '.taskId // empty' <<<"$resp")
  run_id=$(jq -r '.runId // empty' <<<"$resp")
  [ -n "$task_id" ] && [ -n "$run_id" ] || die "Unexpected response when starting smoke test: $resp"
  info "Smoke test started (run $run_id)"

  deadline=$((SECONDS + SMOKE_TIMEOUT))
  while :; do
    resp=$(api GET "/api/v2/activity/activityLog?taskId=$task_id&runId=$run_id") \
      || die "Could not read smoke test status: $resp"
    if [ "$(jq 'length' <<<"$resp")" -gt 0 ]; then
      state=$(jq -r '.[0].state' <<<"$resp")   # 1 = success, 2 = warning, 3 = failed
      jq -r '.[0] | "  rows ok: \(.successTargetRows // 0), rows failed: \(.failedTargetRows // 0)"' <<<"$resp"
      case "$state" in
        1) summary "| Smoke test | :white_check_mark: Successful |"; return 0 ;;
        2) warn "Smoke test finished with warnings."
           summary "| Smoke test | :warning: Finished with warnings |"; return 0 ;;
        *) info "  error: $(jq -r '.[0].errorMsg // "n/a"' <<<"$resp")"
           summary "| Smoke test | :x: Failed |"
           die "Smoke test failed. See Monitor > All Jobs in IDMC." ;;
      esac
    fi
    if [ "$SECONDS" -ge "$deadline" ]; then
      summary "| Smoke test | :x: Timed out |"
      die "Timed out after ${SMOKE_TIMEOUT}s waiting for the smoke test."
    fi
    sleep "$POLL_INTERVAL"
  done
}

# --- Main ---
summary "### IDMC deployment (${#COMMITS[@]} commit(s))"
summary ""
summary "| Step | Result |"
summary "|---|---|"

login
trap logout EXIT
for c in "${COMMITS[@]}"; do
  deploy_commit "$c"
done
if [ -n "$SMOKE_TASK_ID" ]; then
  smoke_test
else
  info "No smoke test configured (IDMC_SMOKE_TASK_ID is empty). Skipping."
  summary "| Smoke test | Skipped (not configured) |"
fi
info "Done."
