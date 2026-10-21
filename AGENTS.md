# Notes for coding agents

Read [CONTRIBUTING.md](CONTRIBUTING.md) first. It has the shell rules, the tests and what a pull request needs.

- Run `sh tests/run.sh` and `sh tests/test-deploy.sh`, each also with `SL_SHELL=dash` and `SL_SHELL=bash`, before you propose a change.
- Never run the scripts against a real `~/.claude`, a real keychain or the network. The suites use scratch folders and stand-ins for `curl` and `security`; any check you add does the same.
- Keep the docs in step with the line: the readme legend, `docs/accounts.md` and `docs/configuration.md`.
