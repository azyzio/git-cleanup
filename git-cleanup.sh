#!/usr/bin/env bash
# Git cleanup script with interactive menus (requires gum).
#
# Modes:
#   1. Delete merged branches — find every branch already in main, delete in bulk
#   2. Branch cleanup — review branches one by one
#   3. Stash cleanup — review stashes one by one (show diff, drop or keep)

set -euo pipefail

if ! command -v gum &> /dev/null; then
  echo "This script requires gum. Install with: brew install gum"
  exit 1
fi

# Shorten git's relative date into the variable named $1: "2 years, 3 months ago"
# becomes "2y 3mo". Pure bash — it runs once per branch.
short_age() {
  local s="${2% ago}"
  s="${s//, / }"
  s="${s// years/y}";     s="${s// year/y}"
  s="${s// months/mo}";   s="${s// month/mo}"
  s="${s// weeks/w}";     s="${s// week/w}"
  s="${s// days/d}";      s="${s// day/d}"
  s="${s// hours/h}";     s="${s// hour/h}"
  s="${s// minutes/min}"; s="${s// minute/min}"
  s="${s// seconds/s}";   s="${s// second/s}"
  printf -v "$1" '%s' "$s"
}

# Path of the worktree a branch is checked out in, or empty if none.
worktree_path_for() {
  git worktree list --porcelain 2>/dev/null \
    | awk -v b="refs/heads/$1" '/^worktree / { wt = substr($0, 10) } $0 == "branch " b { print wt; exit }' \
    || true
}

# Delete a branch, first removing its worktree if it has one. A branch checked
# out in a worktree cannot be deleted with `git branch -D` — that error would
# otherwise kill the whole script via `set -e`. Returns non-zero on failure
# instead of exiting; never forces (a dirty/locked worktree is left untouched).
delete_branch() {
  local b="$1" wt
  wt=$(worktree_path_for "$b")
  if [ -n "$wt" ]; then
    if ! git worktree remove "$wt" 2>/dev/null; then
      gum style --foreground 1 "Worktree has uncommitted changes or is locked — nothing deleted."
      gum style --faint "  To force: git worktree remove --force '$wt' && git branch -D '$b'"
      return 1
    fi
  fi
  if git branch -D "$b" >/dev/null 2>&1; then
    gum style --foreground 1 "Deleted."
    return 0
  fi
  gum style --foreground 1 "Could not delete $b."
  return 1
}

# Branches never offered for automatic deletion (besides main and the current branch).
PROTECTED_BRANCHES="main master develop"

# Fetch, then set what "merged" is checked against: MERGE_TARGETS (local main
# and origin/main, whichever exist) and MAIN_REF (the freshest of them).
# Returns non-zero if neither main ref exists.
prepare_merge_checks() {
  local ref
  if git remote get-url origin &>/dev/null; then
    if ! gum spin --title "Fetching origin..." -- git fetch --prune --quiet origin; then
      gum style --foreground 3 "Fetch failed — checking against local refs only."
    fi
  fi

  MERGE_TARGETS=()
  MAIN_REF=""
  for ref in "refs/heads/$MAIN_BRANCH" "refs/remotes/origin/$MAIN_BRANCH"; do
    if git show-ref --verify --quiet "$ref"; then
      MERGE_TARGETS+=("$ref")
      MAIN_REF="$ref"
    fi
  done
  if [ -z "$MAIN_REF" ]; then
    gum style --foreground 1 "Neither $MAIN_BRANCH nor origin/$MAIN_BRANCH exists."
    return 1
  fi
}

# Print merged GitHub PRs whose head branch is one of the given names, as
# "<head sha> <number> <branch> <title>" lines. Asks GitHub for exactly these
# branches — one GraphQL query per 100, run in parallel — rather than paging
# through every merged PR. Prints nothing without gh or a GitHub remote.
fetch_merged_prs() {
  local dir q="" n=0 b
  if [ $# -eq 0 ] || ! command -v gh &>/dev/null; then
    return 0
  fi
  dir=$(mktemp -d)
  for b in "$@"; do
    q+="b$n:pullRequests(headRefName:\"${b//\"/\\\"}\",states:MERGED,first:20,orderBy:{field:CREATED_AT,direction:DESC}){nodes{headRefOid number headRefName title}} "
    n=$((n + 1))
    if (( n % 100 == 0 || n == $# )); then
      gh api graphql -F owner='{owner}' -F name='{repo}' \
        -f query="query(\$owner:String!,\$name:String!){repository(owner:\$owner,name:\$name){$q}}" \
        --jq '.data.repository[].nodes[] | "\(.headRefOid) \(.number) \(.headRefName) \(.title)"' \
        > "$dir/$n" 2>/dev/null &
      q=""
    fi
  done
  wait
  cat "$dir"/* 2>/dev/null || true
  rm -rf "$dir"
}

# Scan every local branch except main and the current one, newest first, into
# the parallel SCAN_* arrays. A single for-each-ref call covers age, upstream,
# worktree and commits ahead of main for all branches; only branches not plainly
# contained in main get the PR and squash checks, run in parallel. Sets
# MERGED_PRS (see fetch_merged_prs). Needs prepare_merge_checks.
scan_branches() {
  local fmt target b sha age short wt remote track ab1 ab2 i reason
  local cand_names=() cand_args=()
  fmt='%(refname:lstrip=2)%1f%(objectname)%1f%(committerdate:relative)%1f%(worktreepath)%1f%(upstream:remotename)%1f%(upstream:track)'
  for target in "${MERGE_TARGETS[@]}"; do
    fmt="$fmt%1f%(ahead-behind:$target)"
  done

  SCAN_NAMES=()
  SCAN_AGES=()
  SCAN_AHEAD=()
  SCAN_REASONS=()
  SCAN_REMOTES=()
  SCAN_WORKTREES=()
  while IFS=$'\x1f' read -r b sha age wt remote track ab1 ab2; do
    if [[ "$b" == "$MAIN_BRANCH" || "$b" == "$current_branch" ]]; then
      continue
    fi
    # ab1/ab2 are "<ahead> <behind>" per merge target; nothing ahead = contained in it
    reason=""
    if [[ "${ab1%% *}" == 0 || "${ab2%% *}" == 0 ]]; then
      reason="merged"
    else
      cand_names+=("$b")
      cand_args+=("${#SCAN_NAMES[@]}" "$b" "$sha")
    fi
    if [ -z "$remote" ]; then
      remote="local"
    elif [ "$track" = "[gone]" ]; then
      remote="remote gone"
    fi
    ab2="${ab2:-$ab1}"
    short_age short "$age"
    SCAN_NAMES+=("$b")
    SCAN_AGES+=("$short")
    SCAN_AHEAD+=("${ab2%% *}")
    SCAN_REASONS+=("$reason")
    SCAN_REMOTES+=("$remote")
    SCAN_WORKTREES+=("$wt")
  done < <(git for-each-ref --sort=-committerdate --format="$fmt" refs/heads)

  MERGED_PRS=""
  if [ ${#cand_names[@]} -gt 0 ]; then
    printf '\r\033[KFetching merged PRs from GitHub...' >&2
    MERGED_PRS=$(fetch_merged_prs "${cand_names[@]}")

    # merged_reason spawns several git processes per branch — spread them over all cores
    printf '\r\033[KChecking %d branches for PR and squash merges...' "${#cand_names[@]}" >&2
    export -f merged_reason
    export MAIN_REF MERGED_PRS
    while IFS=$'\t' read -r i reason; do
      if [ -n "$i" ]; then
        SCAN_REASONS[$i]="$reason"
      fi
    done < <(printf '%s\0' "${cand_args[@]}" \
      | xargs -0 -n 3 -P "$(getconf _NPROCESSORS_ONLN)" "$BASH" -c \
        'if r=$(merged_reason "$2" "$3"); then printf "%s\t%s\n" "$1" "$r"; fi' _)
    printf '\r\033[K' >&2
  fi
}

# Drop a deleted branch from the scan results (indices of the rest stay valid).
forget_scanned() {
  unset "SCAN_NAMES[$1]" "SCAN_AGES[$1]" "SCAN_AHEAD[$1]" "SCAN_REASONS[$1]" "SCAN_REMOTES[$1]" "SCAN_WORKTREES[$1]"
}

# Print why a branch not contained in main still counts as merged — "PR #N" or
# "squash-merged" — or return non-zero if it doesn't. Cheapest checks first.
# Runs in parallel child shells, so it only reads the exported MAIN_REF and
# MERGED_PRS (see prepare_merge_checks and fetch_merged_prs).
merged_reason() {
  local b="$1" sha="$2" pr_sha pr_number mb f tmp files=()

  # A merged GitHub PR whose head is (or contains) the branch tip. Matching on
  # the sha, not just the name, keeps branches with commits added after the merge.
  while read -r pr_sha pr_number; do
    if [ "$pr_sha" = "$sha" ] || git merge-base --is-ancestor "$sha" "$pr_sha" 2>/dev/null; then
      echo "PR #$pr_number"
      return 0
    fi
  done < <(printf '%s\n' "$MERGED_PRS" | awk -v b="$b" '$3 == b { print $1, $2 }')

  mb=$(git merge-base "$MAIN_REF" "$b" 2>/dev/null) || return 1

  # Squash merge: every file the branch changed is identical in main
  while IFS= read -r -d '' f; do
    files+=("$f")
  done < <(git diff --name-only -z "$mb" "$b" 2>/dev/null)
  [ ${#files[@]} -eq 0 ] && return 1
  if git --literal-pathspecs diff --quiet "$b" "$MAIN_REF" -- "${files[@]}" 2>/dev/null; then
    echo "squash-merged"
    return 0
  fi

  # Squash merge that main has changed since: the branch's combined diff
  # matches a commit on main (patch-id comparison via a throwaway commit)
  tmp=$(git commit-tree "$b^{tree}" -p "$mb" -m "git-cleanup squash check" 2>/dev/null) || return 1
  if [[ "$(git cherry "$MAIN_REF" "$tmp" 2>/dev/null)" == -* ]]; then
    echo "squash-merged"
    return 0
  fi
  return 1
}

# Main branch: what origin/HEAD points to, else a local main, else master
MAIN_BRANCH=$(git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null || true)
MAIN_BRANCH="${MAIN_BRANCH#origin/}"
if [ -z "$MAIN_BRANCH" ]; then
  if git show-ref --verify --quiet refs/heads/main; then
    MAIN_BRANCH=main
  else
    MAIN_BRANCH=master
  fi
fi
current_branch=$(git symbolic-ref --short HEAD)

while true; do
  # ─── Mode Selection ───────────────────────────────────────────────────

  stash_count=$(git stash list | wc -l | tr -d ' ')
  branch_count=$(git branch --format='%(refname:short)' | grep -v "^${MAIN_BRANCH}$" | grep -v "^${current_branch}$" | wc -l | tr -d ' ')

  echo ""
  mode=$(gum choose \
    "Delete merged branches" \
    "Branch cleanup ($branch_count branches)" \
    "Stash cleanup ($stash_count stashes)" \
    "Exit" \
    --header "What do you want to clean up?" || true)

  # ─── Exit ─────────────────────────────────────────────────────────────

  if [[ -z "$mode" || "$mode" == Exit ]]; then
    break
  fi

  # ─── Delete Merged Branches ───────────────────────────────────────────

  if [[ "$mode" == "Delete merged"* ]]; then
    prepare_merge_checks || continue
    scan_branches

    # Merged branches, minus protected ones and those checked out in a worktree
    merged_idx=()
    worktree_merged=()
    max_len=0
    for i in "${!SCAN_NAMES[@]}"; do
      b="${SCAN_NAMES[$i]}"
      if [ -z "${SCAN_REASONS[$i]}" ] || [[ " $PROTECTED_BRANCHES " == *" $b "* ]]; then
        continue
      fi
      # Worktrees may be in active use — leave them to the one-by-one review
      if [ -n "${SCAN_WORKTREES[$i]}" ]; then
        worktree_merged+=("$b")
        continue
      fi
      merged_idx+=("$i")
      (( ${#b} > max_len )) && max_len=${#b}
    done

    if [ ${#worktree_merged[@]} -gt 0 ]; then
      gum style --foreground 3 "Skipped merged branches checked out in a worktree (use Branch cleanup to remove them):"
      printf '  %s\n' "${worktree_merged[@]}"
    fi
    if [ ${#merged_idx[@]} -eq 0 ]; then
      gum style --foreground 2 "No merged branches to delete."
      continue
    fi

    # All preselected: Enter deletes everything, deselect branches to keep
    header=$(printf "%d merged branches — deselect any to keep, enter deletes the selected\n\n    %-${max_len}s  %-10s  %s" \
      "${#merged_idx[@]}" "Branch" "Age" "Reason")
    selected=$(for i in "${merged_idx[@]}"; do
        printf "%-${max_len}s  %-10s  %s\t%s\n" "${SCAN_NAMES[$i]}" "${SCAN_AGES[$i]}" "${SCAN_REASONS[$i]}" "${SCAN_NAMES[$i]}"
      done | gum choose --no-limit --selected='*' --label-delimiter=$'\t' --height 20 --header "$header" || true)
    if [ -z "$selected" ]; then
      gum style --foreground 3 "Nothing deleted."
      continue
    fi

    deleted=0
    failed=0
    while IFS= read -r b; do
      # Prints "Deleted branch <name> (was <sha>)." — the sha is enough to restore it
      if git branch -D "$b"; then
        deleted=$((deleted + 1))
      else
        failed=$((failed + 1))
      fi
    done <<< "$selected"

    echo ""
    gum style --bold "Deleted $deleted merged branches."
    if [ "$failed" -gt 0 ]; then
      gum style --foreground 1 "$failed could not be deleted (see errors above)."
    fi
    gum style --faint "To restore one: git branch <name> <sha>"
  fi

  # ─── Stash Cleanup ────────────────────────────────────────────────────

  if [[ "$mode" == Stash* ]]; then
    if [ "$stash_count" -eq 0 ]; then
      gum style --foreground 2 "No stashes found."
      continue
    fi

    idx=0
    remaining=$(git stash list | wc -l | tr -d ' ')

    while [ "$idx" -lt "$remaining" ]; do
      stash_ref="stash@{${idx}}"
      stash_info=$(git stash list | sed -n "$((idx + 1))p")
      stash_branch=$(echo "$stash_info" | sed 's/.*on \([^:]*\):.*/\1/')
      stash_date=$(git log -1 --format="%ar" "$stash_ref" 2>/dev/null || echo "unknown")

      echo ""
      gum style --bold --foreground 6 "[$((idx + 1))/$remaining] $stash_info"
      echo "Branch: $stash_branch  |  Created: $stash_date"
      echo ""

      # Show diff
      git stash show -p --color=always "$stash_ref" 2>/dev/null | head -100 || true
      stash_total=$(git stash show -p "$stash_ref" 2>/dev/null | wc -l | tr -d ' ' || true)
      if [ "$stash_total" -gt 100 ]; then
        gum style --foreground 3 "... ($((stash_total - 100)) more lines, showing first 100)"
      fi
      echo ""

      action=$(gum choose "Keep" "Drop" "Check conflicts with $MAIN_BRANCH" "Quit" --header "What to do with this stash?" || true)
      [[ -z "$action" ]] && break

      case "$action" in
        Drop)
          git stash drop "$stash_ref" > /dev/null
          gum style --foreground 1 "Dropped."
          remaining=$((remaining - 1))
          ;;
        Keep)
          gum style --foreground 2 "Kept."
          idx=$((idx + 1))
          ;;
        Check*)
          if git stash show -p "$stash_ref" 2>/dev/null | git apply --check 2>/dev/null; then
            gum style --foreground 2 "Clean — applies without conflicts."
          else
            gum style --foreground 1 "Conflicts detected:"
            git stash show -p "$stash_ref" 2>/dev/null | git apply --check 2>&1 | sed 's/^/  /'
          fi
          echo ""
          # loop back — re-show the action menu
          continue
          ;;
        Quit)
          gum style --foreground 3 "Skipping remaining stashes."
          break
          ;;
      esac
    done

    kept=$(git stash list | wc -l | tr -d ' ')
    dropped=$((stash_count - kept))
    echo ""
    gum style --bold "Stash review done: $dropped dropped, $kept kept."
  fi

  # ─── Branch Cleanup ───────────────────────────────────────────────────

  if [[ "$mode" == Branch* ]]; then
    prepare_merge_checks || continue
    # Scanned once; deletions below drop entries instead of re-scanning
    scan_branches
    deleted=0
    kept=0
    last_selected=""
    quit_branches=false

    while true; do
      if [ ${#SCAN_NAMES[@]} -eq 0 ]; then
        gum style --foreground 2 "No branches to review."
        break
      fi

      max_len=0
      for b in "${SCAN_NAMES[@]}"; do
        (( ${#b} > max_len )) && max_len=${#b}
      done

      # One "<row>\t<scan index>" line per branch, last-selected branch first
      rows=""
      for i in "${!SCAN_NAMES[@]}"; do
        if [ -n "${SCAN_WORKTREES[$i]}" ]; then
          b_status="WORKTREE"
        elif [ -n "${SCAN_REASONS[$i]}" ]; then
          b_status="MERGED"
        else
          b_status="${SCAN_AHEAD[$i]} commits"
        fi
        printf -v line "%-${max_len}s  %-14s  %-12s  %s\t%s" \
          "${SCAN_NAMES[$i]}" "${SCAN_AGES[$i]}" "$b_status" "${SCAN_REMOTES[$i]}" "$i"
        if [[ "$i" == "$last_selected" ]]; then
          rows="$line"$'\n'"$rows"
        else
          rows="$rows$line"$'\n'
        fi
      done

      header=$(printf "  %-${max_len}s  %-14s  %-12s  %s" "Branch" "Age" "Status" "Remote")
      selected=$(printf 'Review all branches\tall\n%s' "$rows" \
        | gum choose --label-delimiter=$'\t' --header "$header" || true)
      [[ -z "$selected" ]] && break

      if [[ "$selected" == all ]]; then
        review_idx=("${!SCAN_NAMES[@]}")
      else
        review_idx=("$selected")
        last_selected="$selected"
      fi

      total=${#review_idx[@]}
      idx=0

      for i in "${review_idx[@]}"; do
        branch="${SCAN_NAMES[$i]}"
        idx=$((idx + 1))

        # ── Gather info ──

        branch_date=$(git log -1 --format="%ad" --date=short "$branch")
        branch_age=$(git log -1 --format="%ar" "$branch")

        merge_base=$(git merge-base "$MAIN_REF" "$branch" 2>/dev/null || echo "")
        if [ -z "$merge_base" ]; then
          continue
        fi

        # Status (from the scan)
        commit_count="${SCAN_AHEAD[$i]}"
        status_color=3
        case "${SCAN_REASONS[$i]}" in
          merged)
            status="MERGED"
            ;;
          squash-merged)
            status="MERGED (squash)"
            ;;
          "PR #"*)
            pr_title=$(printf '%s\n' "$MERGED_PRS" \
              | awk -v n="${SCAN_REASONS[$i]#PR #}" '$2 == n { sub(/^[^ ]+ [^ ]+ [^ ]+ /, ""); print; exit }')
            status="MERGED via ${SCAN_REASONS[$i]}: $pr_title"
            ;;
          *)
            status="ACTIVE ($commit_count commits)"
            status_color=2
            ;;
        esac

        case "${SCAN_REMOTES[$i]}" in
          local) remote_status="local only" ;;
          "remote gone") remote_status="remote deleted" ;;
          *) remote_status="pushed to ${SCAN_REMOTES[$i]}" ;;
        esac

        branch_worktree="${SCAN_WORKTREES[$i]}"

        # Stashes
        stash_lines=$(git stash list | grep "on ${branch}:" || true)
        stash_count=0
        [ -n "$stash_lines" ] && stash_count=$(echo "$stash_lines" | grep -c ".")

        # ── Display ──

        echo ""
        gum style --bold --foreground 6 "[$idx/$total] $branch"
        echo ""
        gum style --foreground "$status_color" "  Status:      $status"
        echo "  Last commit: $branch_date ($branch_age)"
        echo "  Remote:      $remote_status"
        if [ -n "$branch_worktree" ]; then
          gum style --foreground 6 "  Worktree:    $branch_worktree"
        fi
        if [ "$stash_count" -gt 0 ]; then
          gum style --foreground 6 "  Stashes: $stash_count"
        fi

        # Commits
        if [ "$commit_count" -gt 0 ]; then
          echo ""
          gum style --faint "  Commits:"
          git log --oneline --format="    %h %s" "$merge_base".."$branch" | head -10 || true
          if [ "$commit_count" -gt 10 ]; then
            gum style --faint "    ... and $((commit_count - 10)) more"
          fi
        fi

        # Diff stat
        if [ "$commit_count" -gt 0 ]; then
          echo ""
          gum style --faint "  Changes:"
          git diff --stat --color=always "$merge_base".."$branch" | sed 's/^/    /' | tail -5 || true
        fi

        echo ""

        # ── Action ──

        if [ -n "$branch_worktree" ]; then
          action=$(gum choose "Keep" "Remove worktree + branch" "Show full diff" "Quit" --header "What to do with this branch?" || true)
        else
          action=$(gum choose "Keep" "Delete" "Checkout" "Show full diff" "Quit" --header "What to do with this branch?" || true)
        fi
        [[ -z "$action" ]] && break

        case "$action" in
          Delete | "Remove worktree + branch")
            if delete_branch "$branch"; then
              deleted=$((deleted + 1))
              last_selected=""
              forget_scanned "$i"
            fi
            ;;
          Keep)
            gum style --foreground 2 "Kept."
            kept=$((kept + 1))
            ;;
          Checkout)
            git checkout "$branch"
            gum style --foreground 2 "Switched to $branch."
            exit 0
            ;;
          "Show full diff")
            echo ""
            git diff --color=always "$merge_base".."$branch" | head -200 || true
            diff_total=$(git diff "$merge_base".."$branch" | wc -l | tr -d ' ' || true)
            if [ "$diff_total" -gt 200 ]; then
              gum style --foreground 3 "... ($((diff_total - 200)) more lines, showing first 200)"
            fi
            echo ""
            # Re-prompt after showing diff
            if [ -n "$branch_worktree" ]; then
              action2=$(gum choose "Keep" "Remove worktree + branch" "Quit" --header "What to do with this branch?" || true)
            else
              action2=$(gum choose "Keep" "Delete" "Checkout" "Quit" --header "What to do with this branch?" || true)
            fi
            [[ -z "$action2" ]] && break
            case "$action2" in
              Delete | "Remove worktree + branch")
                if delete_branch "$branch"; then
                  deleted=$((deleted + 1))
                  last_selected=""
                  forget_scanned "$i"
                fi
                ;;
              Keep)
                gum style --foreground 2 "Kept."
                kept=$((kept + 1))
                ;;
              Checkout)
                git checkout "$branch"
                gum style --foreground 2 "Switched to $branch."
                exit 0
                ;;
              Quit)
                quit_branches=true
                break
                ;;
            esac
            ;;
          Quit)
            quit_branches=true
            break
            ;;
        esac
      done

      [[ "$quit_branches" == true ]] && break
    done

    if [ "$deleted" -gt 0 ] || [ "$kept" -gt 0 ]; then
      echo ""
      gum style --bold "Branch review done: $deleted deleted, $kept kept."
    fi
  fi
done
