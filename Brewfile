# Everything superlinear shells out to, plus what the agent it launches needs
# once it is running. Install it all with `make init`.
#
# Not covered here: macOS 14+, and the Swift 6 toolchain that comes with Xcode.
#
# Two of these taps are third-party. Homebrew refuses to load formulae from
# untrusted taps, and `brew bundle` aborts on the first one it meets without
# installing anything at all — so `make init` trusts them before it runs.

# `make reset` kills leftover superlinear_* sessions
brew "tmux"

# the agent the daemon starts
cask "claude-code@latest"

# workr: `work start --headless` creates the worktree and pipes the prompt into
# `claude -p`. Ships as the `work` binary. Needs 1.2.0 or later, for
# `--session-id`, `--resume` and `work clean`; a cask cannot pin a minimum, so `brew upgrade`.
tap "armcknight/tools"
cask "armcknight/tools/work"

# the armcknight-claude plugin's commands shell out to these once the agent runs
tap "dorkitude/linctl"
brew "dorkitude/linctl/linctl" # read and update Linear issues
brew "direnv"                  # supplies the Linear token to every linctl call
brew "gh"                      # open PRs and read CI status
