#!/usr/bin/env bash
# Git cleanup script with interactive menus (requires gum).
#
# Modes:
#   1. Stash cleanup — review stashes one by one (show diff, drop or keep)
#   2. Branch cleanup — delete empty and merged branches

set -euo pipefail

if ! command -v gum &> /dev/null; then
  echo "This script requires gum. Install with: brew install gum"
  exit 1
fi

MAIN_BRANCH=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's|refs/remotes/origin/||')
MAIN_BRANCH="${MAIN_BRANCH:-master}"
current_branch=$(git symbolic-ref --short HEAD)

while true; do
  # ─── Mode Selection ───────────────────────────────────────────────────

  stash_count=$(git stash list | wc -l | tr -d ' ')
  branch_count=$(git branch --format='%(refname:short)' | grep -v "^${MAIN_BRANCH}$" | grep -v "^${current_branch}$" | wc -l | tr -d ' ')

  echo ""
  mode=$(gum choose \
    "Stash cleanup ($stash_count stashes)" \
    "Branch cleanup ($branch_count branches)" \
    "Exit" \
    --header "What do you want to clean up?")

  # ─── Exit ─────────────────────────────────────────────────────────────

  if [[ "$mode" == Exit ]]; then
    break
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

      action=$(gum choose "Keep" "Drop" "Check conflicts with $MAIN_BRANCH" "Quit" --header "What to do with this stash?")

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
    # Collect all branches
    branches=()
    while IFS= read -r branch; do
      branches+=("$branch")
    done < <(git branch --format='%(refname:short)' | grep -v "^${MAIN_BRANCH}$" | grep -v "^${current_branch}$" | while read -r b; do
      echo "$(git log -1 --format='%ct' "$b") $b"
    done | sort -rn | cut -d' ' -f2-)

    total=${#branches[@]}
    if [ "$total" -eq 0 ]; then
      gum style --foreground 2 "No branches to review."
      continue
    fi

    # Choose: review all or pick a specific branch
    branch_mode=$(gum choose \
      "Review all branches" \
      "Pick a specific branch" \
      --header "How do you want to review?")

    review_branches=("${branches[@]}")

    if [[ "$branch_mode" == Pick* ]]; then
      # Build list with dates for display
      branch_list=""
      for b in "${branches[@]}"; do
        b_date=$(git log -1 --format="%ar" "$b" 2>/dev/null || echo "unknown")
        branch_list+="$b ($b_date)"$'\n'
      done
      selected=$(echo "$branch_list" | sed '/^$/d' | fzf --no-sort --header "Select a branch")
      selected=$(echo "$selected" | sed 's/ (.*//')
      if [ -z "$selected" ]; then
        continue
      fi
      review_branches=("$selected")
    fi

    total=${#review_branches[@]}
    deleted=0
    kept=0

    for i in "${!review_branches[@]}"; do
      branch="${review_branches[$i]}"
      idx=$((i + 1))

      # ── Gather info ──

      branch_date=$(git log -1 --format="%ad" --date=short "$branch")
      branch_age=$(git log -1 --format="%ar" "$branch")

      merge_base=$(git merge-base "$MAIN_BRANCH" "$branch" 2>/dev/null || echo "")
      if [ -z "$merge_base" ]; then
        continue
      fi

      # Status
      commit_count=$(git log --oneline "$merge_base".."$branch" | wc -l | tr -d ' ')
      is_merged=false
      if git merge-base --is-ancestor "$branch" "$MAIN_BRANCH" 2>/dev/null; then
        is_merged=true
      fi

      if [ "$commit_count" -eq 0 ]; then
        status="EMPTY"
        status_color=3
      elif [ "$is_merged" = true ]; then
        status="MERGED"
        status_color=3
      else
        # Check for squash merge: are the branch's file changes already in master?
        changed_files=$(git diff --name-only "$merge_base".."$branch" 2>/dev/null)
        if [ -n "$changed_files" ] && git diff --quiet "$branch" "$MAIN_BRANCH" -- $changed_files 2>/dev/null; then
          status="MERGED (squash)"
          status_color=3
        elif command -v gh &>/dev/null; then
          # Ask GitHub if this branch has a merged PR
          pr_info=$(gh pr list --head "$branch" --state merged --limit 1 --json number,title 2>/dev/null || echo "[]")
          if [ "$pr_info" != "[]" ]; then
            pr_number=$(echo "$pr_info" | sed -n 's/.*"number":\([0-9]*\).*/\1/p')
            pr_title=$(echo "$pr_info" | sed -n 's/.*"title":"\([^"]*\)".*/\1/p')
            status="MERGED via PR #${pr_number}: ${pr_title}"
            status_color=3
          else
            status="ACTIVE ($commit_count commits)"
            status_color=2
          fi
        else
          status="ACTIVE ($commit_count commits)"
          status_color=2
        fi
      fi

      # Remote
      remote_ref=$(git config "branch.${branch}.remote" 2>/dev/null || true)
      if [ -n "$remote_ref" ]; then
        if git rev-parse --verify "refs/remotes/${remote_ref}/${branch}" &>/dev/null; then
          remote_status="pushed to $remote_ref"
        else
          remote_status="remote deleted"
        fi
      else
        remote_status="local only"
      fi

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

      action=$(gum choose "Keep" "Delete" "Checkout" "Show full diff" "Quit" --header "What to do with this branch?")

      case "$action" in
        Delete)
          git branch -D "$branch" > /dev/null
          gum style --foreground 1 "Deleted."
          deleted=$((deleted + 1))
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
          action2=$(gum choose "Keep" "Delete" "Checkout" "Quit" --header "What to do with this branch?")
          case "$action2" in
            Delete)
              git branch -D "$branch" > /dev/null
              gum style --foreground 1 "Deleted."
              deleted=$((deleted + 1))
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
              gum style --foreground 3 "Skipping remaining branches."
              break
              ;;
          esac
          ;;
        Quit)
          gum style --foreground 3 "Skipping remaining branches."
          break
          ;;
      esac
    done

    echo ""
    gum style --bold "Branch review done: $deleted deleted, $kept kept."
  fi
done
