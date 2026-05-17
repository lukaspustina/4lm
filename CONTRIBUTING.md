# Contributing to 4lm

4lm is a single-engineer personal-use tool that happens to be open source.
Issues and PRs are welcome but please read this first — the project has
strong opinions about scope and complexity.

## Scope

4lm targets **one operator, one Apple Silicon Mac, one login session**.
Pull requests that broaden the scope — multi-user support, Docker
packaging, Linux/Intel backends, cloud fallbacks, framework
abstractions — will be politely declined.

In scope: bugs, additional MLX/Apple Silicon backends, profile additions,
test coverage, docs improvements, security hardening, MCP/tool-calling
work tracked in `specs/sdd/webui-tools-and-mcp.md`.

Out of scope: anything that adds dependencies or branches "for
flexibility" without a current caller.

## Dev setup

```sh
git clone https://github.com/<repo>
cd 4lm
make bootstrap    # Brewfile + Brewfile-tui + pipx ensurepath
make check        # lint + syntax + plist-lint + yaml-lint + test
```

`make check` is what CI runs. Get it green locally before opening a PR.
For the matrix:

```sh
make ci           # runs ci-default + ci-backend-only locally
```

## Commit style

- Conventional-commit prefix required: `feat:`, `fix:`, `refactor:`,
  `chore:`, `docs:`, `test:`. Scope optional (e.g. `fix(parser):`).
- Subject line ≤ 72 characters.
- Formatting-only changes ship in their own commits.
- No `Co-Authored-By: Claude` lines.
- Sign your commits if you can (the maintainer signs via 1Password SSH).

## PR checklist

- [ ] `make check` passes.
- [ ] Tests added/updated for any behavior change.
- [ ] CLAUDE.md or README.md updated if you introduced a new convention,
      key decision, or non-obvious gotcha.
- [ ] CHANGELOG.md entry under `Unreleased` for user-facing changes.
- [ ] Profile YAML changes (if any) include a header rationale.

## Specs-driven changes

Non-trivial work follows the spec pipeline:

1. Brainstorm — open an issue or discuss in a PR description.
2. SDD — produce a Software Design Document in `specs/sdd/`.
3. Implement — phase by phase if multi-phase.
4. Verify — implementation matches the SDD.
5. Finish — archive the SDD to `specs/done/sdd/` with the completion date.

For a typo fix, a one-line bug, or a comment-only change: skip the
pipeline and just open the PR.

## Reporting bugs

Include:

- Mac model and macOS version
- Active profile (`4lm profile current`)
- `4lm doctor` output
- `4lm diag` output if relevant
- Last ~50 lines of `4lm logs backend`

## Security issues

Don't open a public issue. See [`SECURITY.md`](SECURITY.md).
