# git-cleanup

Interactive tool for cleaning up git stashes and branches. Reviews items one by one with diffs and metadata so you can make informed keep/delete decisions.

## Install

```bash
brew install gum fzf
brew install gh  # optional, enables merged PR detection
ln -sf "$(pwd)/git-cleanup.sh" ~/.local/bin/git-cleanup
```

Make sure `~/.local/bin` is on your PATH (add to `~/.zshrc` if needed):

```bash
export PATH="$HOME/.local/bin:$PATH"
```

Then run `git-cleanup` from any git repo.
