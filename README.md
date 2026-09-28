# git-cleanup

Interactive tool for cleaning up git stashes and branches. Reviews items one by one with diffs and metadata so you can make informed keep/delete decisions.

## Install

```bash
brew install gum fzf
brew install gh  # optional, enables merged PR detection
ln -sf "$(pwd)/git-cleanup.sh" ~/.local/bin/git-cleanup
```

Requires git 2.41+ (for `for-each-ref`'s `ahead-behind`, which lets one call report every branch's status).

Make sure `~/.local/bin` is on your PATH (add to `~/.zshrc` if needed):

```bash
export PATH="$HOME/.local/bin:$PATH"
```

Then run `git-cleanup` from any git repo.

## Delete merged branches

The first menu option fetches `origin`, finds every local branch whose work is already in main, and deletes them in bulk after one confirmation (all preselected — deselect any to keep). A branch counts as merged when:

- it's an ancestor of `main`/`master` or `origin/main` (regular or fast-forward merge),
- a merged GitHub PR has its exact tip as head (needs `gh`; branches with commits added after the merge are kept),
- or it was squash-merged (its changes are already in main).

Main/master/develop, the current branch, and branches checked out in a worktree are never deleted. Only local branches are removed; each deletion prints the old sha so it can be restored with `git branch <name> <sha>`.
