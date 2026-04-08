#!/usr/bin/env bash
# =============================================================================
# 04_agent_loop.sh
# Core agent loop. Picks the next auto_attempt issue from the backlog,
# hands it to Claude Code, runs tests, and opens a PR.
#
# Requirements: claude CLI (Claude Code), gh CLI, jq, git
# Usage:
#   Single run:   ./04_agent_loop.sh
#   Pick specific: ISSUE_NUMBER=42 ./04_agent_loop.sh
#   Batch N:      BATCH=5 ./04_agent_loop.sh
# =============================================================================

set -euo pipefail

BACKLOG="./data/backlog.json"
FORK="${FORK:-$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || echo "")}"
MAX_FIX_ATTEMPTS=3
BATCH="${BATCH:-1}"

if [ -z "$FORK" ]; then
  echo "ERROR: Set FORK env var or run from inside the fork repo"
  exit 1
fi

if [ ! -f "$BACKLOG" ]; then
  echo "ERROR: $BACKLOG not found. Run 02_triage.js and 03_recreate_in_fork.sh first."
  exit 1
fi

# ── Helpers ───────────────────────────────────────────────────────────────────

log()  { echo "[$(date '+%H:%M:%S')] $*"; }
fail() { echo "[$(date '+%H:%M:%S')] ERROR: $*" >&2; }

pick_next_issue() {
  local specific="${ISSUE_NUMBER:-}"
  if [ -n "$specific" ]; then
    jq -r --argjson n "$specific" \
      'to_entries[] | select(.value.fork_issue_number == $n) | .key' \
      "$BACKLOG"
  else
    # Pick highest-priority auto_attempt issue that is still open and not in-progress
    jq -r 'to_entries[]
      | select(
          .value.triage.auto_attempt == true
          and .value.status == "open"
          and .value.attempts < '"$MAX_FIX_ATTEMPTS"'
        )
      | .key' \
      "$BACKLOG" | head -1
  fi
}

update_backlog() {
  local idx="$1"; shift
  local tmp
  tmp=$(mktemp)
  jq "$1" "$BACKLOG" > "$tmp" && mv "$tmp" "$BACKLOG"
}

set_status() {
  local idx="$1" status="$2"
  local tmp; tmp=$(mktemp)
  jq ".[$idx].status = \"$status\" | .[$idx].last_attempt = \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"" \
    "$BACKLOG" > "$tmp" && mv "$tmp" "$BACKLOG"
}

increment_attempts() {
  local idx="$1"
  local tmp; tmp=$(mktemp)
  jq ".[$idx].attempts += 1" "$BACKLOG" > "$tmp" && mv "$tmp" "$BACKLOG"
}

# ── Build the prompt for Claude Code ─────────────────────────────────────────

build_prompt() {
  local item="$1"
  local fork_issue="$2"

  local title category complexity affected summary test_hint orig_body upstream_num upstream_type
  title=$(echo "$item"         | jq -r '.title')
  category=$(echo "$item"     | jq -r '.triage.category')
  complexity=$(echo "$item"   | jq -r '.triage.complexity')
  affected=$(echo "$item"     | jq -r '.triage.affected_area')
  summary=$(echo "$item"      | jq -r '.triage.summary')
  test_hint=$(echo "$item"    | jq -r '.triage.test_hint // ""')
  orig_body=$(echo "$item"    | jq -r '.body // ""' | head -c 3000)
  upstream_num=$(echo "$item" | jq -r '.number')
  upstream_type=$(echo "$item" | jq -r '.type')

  # Load diff if this was a PR
  local diff_section=""
  if [ "$upstream_type" = "pr" ] && [ -f "./data/diffs/pr_${upstream_num}.diff" ]; then
    local diff_content
    diff_content=$(head -c 6000 "./data/diffs/pr_${upstream_num}.diff")
    diff_section="

The original patch from upstream PR #${upstream_num} is shown below for reference.
You should re-implement the intent of this patch cleanly against the current codebase:

\`\`\`diff
${diff_content}
\`\`\`"
  fi

  cat <<EOF
You are working on the Focalboard codebase. Read CLAUDE.md in the repo root before starting.

## Your task
Fix fork issue #${fork_issue} (originally upstream ${upstream_type} #${upstream_num}).

**Category:** ${category}
**Complexity:** ${complexity}
**Affected area:** ${affected}
**Summary:** ${summary}

## Issue description
${orig_body}
${diff_section}

## Instructions
1. Read CLAUDE.md to understand the codebase structure and conventions.
2. Understand the issue fully before writing any code.
3. Implement the fix. Follow existing code style exactly.
4. Run the appropriate tests:
$([ -n "$test_hint" ] && echo "   - Specifically: \`${test_hint}\`")
   - Backend: \`cd server && go test ./... 2>&1 | tail -30\`
   - Frontend: \`cd webapp && npm test -- --watchAll=false 2>&1 | tail -30\`
   - Lint: \`cd server && golangci-lint run ./... 2>&1 | tail -20\`
5. If tests fail, fix the failures. Try up to 3 times.
6. If you cannot make tests pass after 3 attempts, stop and explain what's blocking you.
7. Do NOT open a PR yourself — the script will do that.
8. When complete, output exactly this on the last line:
   AGENT_SUCCESS: <one-sentence description of what you changed>
   Or on failure:
   AGENT_FAILURE: <one-sentence description of what blocked you>
EOF
}

# ── Run one issue ─────────────────────────────────────────────────────────────

run_issue() {
  local idx="$1"
  local item fork_issue branch_name title commit_msg

  item=$(jq ".[$idx]" "$BACKLOG")
  fork_issue=$(echo "$item" | jq -r '.fork_issue_number')
  title=$(echo "$item" | jq -r '.title' | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g' | cut -c1-40)
  category=$(echo "$item" | jq -r '.triage.category')
  upstream_num=$(echo "$item" | jq -r '.number')

  branch_name="fix/issue-${fork_issue}-${title}"
  [ "$category" = "feature" ] || [ "$category" = "enhancement" ] && branch_name="feat/issue-${fork_issue}-${title}"

  log "Starting issue #${fork_issue}: $(echo "$item" | jq -r '.title')"
  log "Branch: $branch_name"

  # Mark in-progress
  set_status "$idx" "in-progress"
  increment_attempts "$idx"

  # Ensure we're on main and up to date
  git checkout main --quiet
  git pull origin main --quiet 2>/dev/null || true

  # Create branch (or reset if it already exists)
  git checkout -B "$branch_name" --quiet

  # Build prompt
  PROMPT=$(build_prompt "$item" "$fork_issue")

  # Run Claude Code
  log "Handing to Claude Code..."
  CLAUDE_OUTPUT_FILE=$(mktemp)

  claude -p \
    --dangerously-skip-permissions \
    --tools "Bash,Edit,Read,Write" \
    --max-turns 50 \
    "$PROMPT" 2>&1 | tee "$CLAUDE_OUTPUT_FILE" || true

  # Parse outcome from last meaningful line
  LAST_LINE=$(grep -E "^AGENT_(SUCCESS|FAILURE):" "$CLAUDE_OUTPUT_FILE" | tail -1 || echo "")

  if [[ "$LAST_LINE" == AGENT_SUCCESS:* ]]; then
    DESCRIPTION="${LAST_LINE#AGENT_SUCCESS: }"
    log "Claude Code succeeded: $DESCRIPTION"

    # Commit everything
    git add -A
    commit_msg="$([ "$category" = "feature" ] || [ "$category" = "enhancement" ] && echo "feat" || echo "fix")(${category}): ${DESCRIPTION} (#${fork_issue})"
    git commit -m "$commit_msg" --quiet || { log "Nothing to commit"; set_status "$idx" "open"; return 0; }

    # Push
    git push origin "$branch_name" --quiet --force-with-lease

    # Open PR
    PR_BODY="Closes #${fork_issue}

## What changed
${DESCRIPTION}

## Test plan
Automated tests pass. See CI for full results.

---
*Generated by Claude Code agent | Upstream reference: #${upstream_num}*"

    PR_URL=$(gh pr create \
      --repo "$FORK" \
      --base main \
      --head "$branch_name" \
      --title "$(echo "$item" | jq -r '.title')" \
      --body "$PR_BODY")

    log "PR created: $PR_URL"

    # Update backlog
    local tmp; tmp=$(mktemp)
    jq ".[$idx].status = \"done\" | .[$idx].pr_url = \"$PR_URL\"" "$BACKLOG" > "$tmp" && mv "$tmp" "$BACKLOG"

    # Update fork issue with PR link
    gh issue comment "$fork_issue" \
      --repo "$FORK" \
      --body "🤖 Claude Code opened PR: $PR_URL" 2>/dev/null || true

  else
    REASON="${LAST_LINE#AGENT_FAILURE: }"
    [ -z "$REASON" ] && REASON="Agent did not produce a clear success/failure signal"
    fail "Claude Code did not succeed: $REASON"

    # Roll back any partial changes
    git checkout main --quiet
    git branch -D "$branch_name" 2>/dev/null || true

    ATTEMPTS=$(jq ".[$idx].attempts" "$BACKLOG")
    if [ "$ATTEMPTS" -ge "$MAX_FIX_ATTEMPTS" ]; then
      log "Max attempts ($MAX_FIX_ATTEMPTS) reached — marking as failed"
      set_status "$idx" "failed"

      gh issue comment "$fork_issue" \
        --repo "$FORK" \
        --body "🤖 Auto-fix failed after $MAX_FIX_ATTEMPTS attempts. Last failure: ${REASON}. Needs human review." 2>/dev/null || true

      gh issue edit "$fork_issue" \
        --repo "$FORK" \
        --add-label "human-review" \
        --remove-label "auto-attempt" 2>/dev/null || true
    else
      log "Attempt $ATTEMPTS/$MAX_FIX_ATTEMPTS failed — will retry next run"
      set_status "$idx" "open"
    fi
  fi

  rm -f "$CLAUDE_OUTPUT_FILE"
}

# ── Main ──────────────────────────────────────────────────────────────────────

log "Starting agent loop (batch=$BATCH, fork=$FORK)"

for batch_i in $(seq 1 "$BATCH"); do
  IDX=$(pick_next_issue)

  if [ -z "$IDX" ]; then
    log "No more eligible issues in backlog"
    break
  fi

  log "--- Batch item $batch_i/$BATCH ---"
  run_issue "$IDX"
  echo ""
done

log "Agent loop complete"

# Print remaining counts
OPEN_COUNT=$(jq '[.[] | select(.status == "open" and .triage.auto_attempt == true)] | length' "$BACKLOG")
DONE_COUNT=$(jq '[.[] | select(.status == "done")] | length' "$BACKLOG")
FAIL_COUNT=$(jq '[.[] | select(.status == "failed")] | length' "$BACKLOG")
log "Backlog: $OPEN_COUNT open | $DONE_COUNT done | $FAIL_COUNT failed"
