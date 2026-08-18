# 4lm developer + runtime dependencies.
# Install with: just bootstrap (or: brew bundle --file=Brewfile)

# The verb contract itself (pdt-adlc ADR 0008). Listed first because every
# other verb in this file is reached through it — a machine without `just`
# cannot run `just bootstrap` to get the rest.
brew "just"

# Lint / format / test
brew "shellcheck"
brew "shfmt"
brew "bats-core"
brew "jq"

# Python tooling. mlx-openai-server requires Python >=3.11,<3.13, so we pin
# python@3.12 even when the system default is newer.
brew "python@3.12"
brew "pipx"

# Hardware-fit scoring and model recommendations (used by `4lm recommend`).
brew "llmfit"

# Ollama — needed for profiles with backend: ollama (e.g. ollama-gemma4).
brew "ollama"
