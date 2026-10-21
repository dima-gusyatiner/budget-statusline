# Contributing

Bug reports, fixes and small features are welcome. The line stays one line, and the scripts stay POSIX `sh` with `jq`, `git` and `curl`, so a feature request that needs more may be declined. For anything bigger than a fix, open an issue first and say what you have in mind.

Security problems go through [SECURITY.md](SECURITY.md), never a public issue.

## The tests

```sh
sh tests/run.sh
sh tests/test-deploy.sh
```

`tests/run.sh` covers `statusline.sh` and `usage-refresh.sh`. `tests/test-deploy.sh` covers the plugin hook, `hooks/deploy.sh`, and `install.sh`. Both work in scratch folders made with `mktemp`, with stand-ins for `curl` and `security`, so they never touch your `~/.claude`, your keychain or the network. Each prints `ok` or `FAIL` per check and exits with the number of failures. A check the system cannot run, such as a file mode check on Windows, prints an `ok` line that says it was skipped and why. `tests/run.sh` clears `LANG` and the `LC_*` variables, so a check runs in the C locale unless it sets another, and the Enterprise checks pin `TZ=UTC`; your own settings do not change what it sees.

Run both under each shell the scripts target. `SL_SHELL` picks the shell the scripts run under:

```sh
SL_SHELL=dash sh tests/run.sh
SL_SHELL=bash sh tests/run.sh
SL_SHELL=dash sh tests/test-deploy.sh
SL_SHELL=bash sh tests/test-deploy.sh
```

On macOS plain `sh` is the third shell: `/bin/sh` there is bash 3.2 in POSIX mode. macOS also has `/bin/dash`; on Linux, `dash` is the `sh` of Debian and Ubuntu.

## CI

`.github/workflows/tests.yml` runs on every pull request and every push to `main`:

| Runner | Shell | Suites |
|---|---|---|
| Linux | `dash` | both |
| Linux | `bash` | both |
| macOS | `sh`, bash 3.2 | both |
| Windows | Git Bash | both |

On Windows the checks that need Unix file modes or real symbolic links print a skip line each. The Linux rows also generate `de_DE.UTF-8`, so the comma-decimal check runs there. A pull request needs every job green.

## Shell rules

The scripts are POSIX `sh` and must run under macOS `/bin/sh`, `dash`, `bash` and Git Bash.

- **No `local`.** POSIX `sh` has none. A function's working variables carry a short prefix of their own (`ss_`, `r_`, `cr_`), so they cannot clobber the globals.
- **No bashisms.** No `[[ ]]`, arrays, `$'...'`, `==` inside `[ ]`, `function`, `source`, `${var//a/b}`, `10#$n`, process substitution or `echo -e`. Use `printf`. macOS `/bin/sh` forgives some of these and `dash` does not, so test under `dash`.
- **No leading zeros in arithmetic.** `$(( ))` reads `08` as bad octal, and under `dash` that ends the script. Strip leading zeros first, as the scripts already do.
- **BSD and GNU both.** `date -r` and `date -d @`, `stat -f` and `stat -c`: try one, fall back to the other.
- **Numbers in C notation.** Under a comma-decimal locale, macOS `printf` rejects `23.5` and `awk` prints `12,40`. `statusline.sh` sets `LC_NUMERIC=C` near the top and moves any `LC_ALL` into the other categories; keep new number handling below that, and test with `LC_ALL=de_DE.UTF-8`.
- **Count the processes.** The line runs several times a second while Claude is working. Every `$(...)`, pipe and external command starts a process, and Git Bash starts them slowly. Prefer parameter expansion, builtins, and one `awk` or `jq` call over several.
- **Never break the line.** A missing tool, an odd value or a failed write must end in a plainer line or a word like `cap offline`, never an error message, a blank line or a hang. Claude Code shows the output only when the script exits 0.
- **Values are data.** Pass values to `awk` and `jq` as variables (`-v`, `--arg`). Do not paste them into program text, even where older lines still do with numbers the script has checked.
- **Nothing raw reaches the terminal.** Pass any name taken from the JSON or the file system through `clean()` before it is printed, or a control character in it could forge an escape sequence.
- **The token stays out of sight.** It goes to `curl` on standard input, never as an argument, and is never written to a file or a log.
- **Docs describe the scripts and never paste them.** `tests/run.sh` fails when the readme or a page in `docs/` holds a shebang line or a script's longest line.

## Commits

[Conventional Commits](https://www.conventionalcommits.org/en/v1.0.0/): `feat:`, `fix:`, `docs:`, `test:`, `ci:`, `refactor:`, `chore:`. The subject is lowercase and imperative, under about 70 characters, with no full stop. The body says what changed and why, and how you checked it, one paragraph per line.

## Pull requests

- One change per pull request.
- Both suites pass under `dash` and `bash`.
- A change in behaviour comes with a test that fails without it.
- A change to what the line shows updates the readme legend and [`docs/accounts.md`](docs/accounts.md). A new setting goes in the readme table and [`docs/configuration.md`](docs/configuration.md).
- An entry in [`CHANGELOG.md`](CHANGELOG.md) under `Unreleased`.
- No new dependency, and no network call beyond the usage endpoint.

## Releases

The maintainer sets `version` in `.claude-plugin/plugin.json`, moves the `Unreleased` entries in the changelog under that version, and tags the release. Users with auto-update get a release when the version changes, not with every commit to `main`.
