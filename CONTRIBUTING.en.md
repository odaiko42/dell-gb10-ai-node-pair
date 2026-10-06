# Contributing

🌐 **Language / Langue:** English (current) · [Français](CONTRIBUTING.md)

Thanks for your interest in this repository.

## Proposing a change

1. Fork the repository and create a dedicated branch:
   - `feat/...` for a new feature
   - `fix/...` for a bug fix
   - `docs/...` for documentation-only changes
2. Keep scripts idempotent: re-running a script must never corrupt an existing configuration
   (check the current state before acting, plan a rollback path).
3. Never commit a real IP address, hostname, account identifier, or secret — use environment
   variables with example values (see the existing scripts under [scripts/](scripts)).
4. Document any new environment variable in the header of the relevant script.
5. Open a Pull Request describing the change, its context, and how it was tested.

## Expectations

- Shell scripts: `bash -n` must pass without error, `set -euo pipefail` at the top.
- Documentation: stay consistent with the existing style (short, actionable sections).

Pull Requests are reviewed before merging.
