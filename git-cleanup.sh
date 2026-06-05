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

short_age() {
  echo "$1" | sed -E -e 's/ years?/y/g' -e 's/ months?/mo/g' -e 's/ weeks?/w/g' -e 's/ days?/d/g' -e 's/ hours?/h/g' -e 's/ minutes?/min/g' -e 's/ seconds?/s/g' -e 's/ ago//' -e 's/, / /g'
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

MAIN_BRANCH=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's|refs/remotes/origin/||')
MAIN_BRANCH="${MAIN_BRANCH:-master}"
current_branch=$(git symbolic-ref --short HEAD)

while true; do
  # ─── Mode Selection ───────────────────────────────────────────────────

  stash_count=$(git stash list | wc -l | tr -d ' ')
  branch_count=$(git branch --format='%(refname:short)' | grep -v "^${MAIN_BRANCH}$" | grep -v "^${current_branch}$" | wc -l | tr -d ' ')

  echo ""
  mode=$(gum choose \
    "Branch cleanup ($branch_count branches)" \
    "Stash cleanup ($stash_count stashes)" \
    "Exit" \
    --header "What do you want to clean up?" || true)

  # ─── Exit ─────────────────────────────────────────────────────────────

  if [[ -z "$mode" || "$mode" == Exit ]]; then
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
    deleted=0
    kept=0
    last_selected=""
    quit_branches=false

    while true; do
      # Collect all branches (refresh each iteration to reflect deletions)
      branches=()
      while IFS= read -r branch; do
        branches+=("$branch")
      done < <(git branch --format='%(refname:short)' | grep -v "^${MAIN_BRANCH}$" | grep -v "^${current_branch}$" | while read -r b; do
        echo "$(git log -1 --format='%ct' "$b") $b"
      done | sort -rn | cut -d' ' -f2-)

      if [ ${#branches[@]} -eq 0 ]; then
        gum style --foreground 2 "No branches to review."
        break
      fi

      # Build branch list with summary info, last-selected branch first
      branch_display=()
      branch_names=()
      last_display=""
      last_name=""

      # Branches currently checked out in a worktree (can't be deleted normally)
      wt_branches=$(git worktree list --porcelain 2>/dev/null | sed -n 's|^branch refs/heads/||p' || true)

      # Find max branch name length for alignment
      max_len=0
      for b in "${branches[@]}"; do
        (( ${#b} > max_len )) && max_len=${#b}
      done

      for b in "${branches[@]}"; do
        b_age=$(short_age "$(git log -1 --format="%ar" "$b" 2>/dev/null || echo "unknown")")
        b_merge_base=$(git merge-base "$MAIN_BRANCH" "$b" 2>/dev/null || echo "")
        if [ -n "$b_merge_base" ]; then
          b_commits=$(git log --oneline "$b_merge_base".."$b" | wc -l | tr -d ' ')
          if git merge-base --is-ancestor "$b" "$MAIN_BRANCH" 2>/dev/null; then
            b_status="MERGED"
          elif [ "$b_commits" -eq 0 ]; then
            b_status="EMPTY"
          else
            # Check for squash merge: are the branch's file changes already in main?
            b_changed=$(git diff --name-only "$b_merge_base".."$b" 2>/dev/null)
            if [ -n "$b_changed" ] && git diff --quiet "$b" "$MAIN_BRANCH" -- $b_changed 2>/dev/null; then
              b_status="MERGED"
            else
              b_status="$b_commits commits"
            fi
          fi
        else
          b_commits=0
          b_status="—"
        fi
        b_remote=$(git config "branch.${b}.remote" 2>/dev/null || true)
        if [ -n "$b_remote" ]; then
          if git rev-parse --verify "refs/remotes/${b_remote}/${b}" &>/dev/null; then
            b_remote_status="origin"
          else
            b_remote_status="remote gone"
          fi
        else
          b_remote_status="local"
        fi

        if printf '%s\n' "$wt_branches" | grep -qxF "$b"; then
          b_status="WORKTREE"
        fi

        line=$(printf "%-${max_len}s  %-14s  %-12s  %s" "$b" "$b_age" "$b_status" "$b_remote_status")
        if [[ "$b" == "$last_selected" ]]; then
          last_display="$line"
          last_name="$b"
        else
          branch_display+=("$line")
          branch_names+=("$b")
        fi
      done
      if [[ -n "$last_display" ]]; then
        branch_display=("$last_display" "${branch_display[@]}")
        branch_names=("$last_name" "${branch_names[@]}")
      fi

      header=$(printf "  %-${max_len}s  %-14s  %-12s  %s" "Branch" "Age" "Status" "Remote")
      selected=$(printf '%s\n' "Review all branches" "${branch_display[@]}" \
        | gum choose --header "$header" || true)
      [[ -z "$selected" ]] && break

      if [[ "$selected" == "Review all branches" ]]; then
        review_branches=("${branches[@]}")
      else
        # Match selection back to branch name by index
        selected_branch=""
        for j in "${!branch_display[@]}"; do
          if [[ "${branch_display[$j]}" == "$selected" ]]; then
            selected_branch="${branch_names[$j]}"
            break
          fi
        done
        review_branches=("$selected_branch")
        last_selected="$selected_branch"
      fi

      total=${#review_branches[@]}

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

        # Worktree
        branch_worktree=$(worktree_path_for "$branch")

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
