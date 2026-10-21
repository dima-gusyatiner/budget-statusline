# Windows

There is no separate Windows build. The scripts run in Git Bash, which Claude Code uses for status line commands when it is installed ([status line documentation](https://code.claude.com/docs/en/statusline)).

## Setting it up

1. Install [Git for Windows](https://gitforwindows.org), which brings Git Bash, and `jq`: `winget install jqlang.jq`.
2. Install from Git Bash, with the plugin or with `sh install.sh`. Both write the command with `bash` in front, as `bash ~/.claude/statusline.sh` in the default folder, because a bare `.sh` path does not run on Windows. Setting it up by hand, write it the same way, with forward slashes.
3. The refresher reads the login from `.credentials.json` in the [config folder](configuration.md#the-config-folder).

## What to expect

- In the classic Windows console the line switches to [ASCII](accounts.md#the-ascii-line) by itself. It takes Git Bash for that console when neither `WT_SESSION`, which Windows Terminal sets, nor `TERM_PROGRAM` is set. `CC_ASCII=0` keeps the symbols, `CC_ASCII=1` forces ASCII anywhere.
- Renders are slower than on macOS or Linux. Git Bash is slow to start a process, and every render starts several. Not measured.
- A `.gitattributes` rule keeps `*.sh` files on LF line endings, so a Git for Windows checkout does not break them.

## How well it is tested

Both test suites run in Git Bash on every pull request: `tests/run.sh` for the line and the refresher, and `tests/test-deploy.sh` for the plugin hook and `install.sh`, `bash` prefix included. The checks that need Unix file modes or real symbolic links print a skip line there.

The release has not been tried by hand on a Windows machine yet. Reports are welcome.
