## Summary

<!-- One paragraph: what changed and why. -->

## Checklist

- [ ] `make check` passes locally
- [ ] Tests added/updated for any behavior change
- [ ] `CLAUDE.md` / `README.md` updated if a new convention or non-obvious gotcha was introduced
- [ ] `CHANGELOG.md` entry under `[Unreleased]` for user-facing changes
- [ ] Profile YAML changes (if any) include a header rationale comment
- [ ] Conventional-commit subject ≤ 72 characters
- [ ] Formatting-only changes ship in a separate commit

## Scope check

4lm targets **one operator, one Apple Silicon Mac, one login session**.
PRs broadening scope (multi-user, Docker, Linux/Intel, cloud fallback)
will be politely declined. See [`CONTRIBUTING.md`](../CONTRIBUTING.md)
for the full scope rules.
