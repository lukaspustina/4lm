# 4lm developer + runtime dependencies.
# Install with: make bootstrap (or: brew bundle --file=Brewfile)

# Lint / format / test
brew "shellcheck"
brew "shfmt"
brew "bats-core"

# Python tooling. mlx-openai-server requires Python >=3.11,<3.13, so we pin
# python@3.12 even when the system default is newer.
brew "python@3.12"
brew "pipx"

# OpenCode TUI — talks to the local backend over OpenAI-compatible /v1.
# homebrew/core's opencode formula pulls anomalyco's opencode-ai npm package;
# the older 'sst/opencode' fork no longer exists upstream.
brew "opencode"
