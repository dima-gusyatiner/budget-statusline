# Configuration

## Set it up by hand

Copy `statusline.sh` and `usage-refresh.sh` into the [config folder](#the-config-folder), make both executable (`chmod +x`), and add this to the `settings.json` there. This is the default folder; with `CLAUDE_CONFIG_DIR` set, name the script by its full path in that folder instead:

```json
{
  "statusLine": { "type": "command", "command": "~/.claude/statusline.sh", "refreshInterval": 60 }
}
```

`refreshInterval` re-runs the command every 60 seconds while the session sits idle, so the clock and the burn estimate stay current. Without it the line changes only when something happens in the session.

On Windows the command starts with `bash`, as in `bash ~/.claude/statusline.sh`. See [Windows](windows.md).

`statusline.sh` looks for `usage-refresh.sh` next to itself first, so the two are always one version, then in the config folder.

## The config folder

Everything lives in the login's config folder: `CLAUDE_CONFIG_DIR` when it is set, else `~/.claude`. The two scripts go there, so does the `settings.json` that runs them, and so do the state files below and the plugin's manifest and log.

Claude Code keeps one login per config folder. Two logins on one machine, each with its own `CLAUDE_CONFIG_DIR`, keep their own figures, their own keychain item and their own account type, and never share a file. With `CLAUDE_CONFIG_DIR` set, the `statusLine` command names the script by its full path. The plugin and `install.sh` write it that way.

## Settings

Put them in front of the `command` already in your `settings.json`, so they apply on every run, and keep the path that command has. In the default folder that reads:

```json
"command": "CC_ASCII=1 CC_SPEND_CAP=200 ~/.claude/statusline.sh"
```

Under `CLAUDE_CONFIG_DIR` the path is the full one the plugin or `install.sh` wrote; pasting the line above there would point at a script that is not there, and the status line would go blank.

| Variable | Values | When unset | Effect |
|---|---|---|---|
| `CC_ASCII` | `1`, `0` | detected | `1` draws a pure ASCII line, `0` never does. See [below](#cc_ascii) |
| `CC_WIDTH` | a whole number | `COLUMNS` minus 4 | The width the line is fitted to. A positive number is the width itself. A negative one is taken off `COLUMNS` instead of the 4: `-8` for a `statusLine` `padding` of 2. `0` turns the fitting off. See [narrow terminals](narrow-terminals.md#the-width) |
| `CC_CREDITS` | `0` | on | `0` turns off the usage credits lookup: a full window is drawn as it is, and nothing is fetched |
| `CC_ENTERPRISE` | `1`, `0` | detected | `1` forces the Enterprise monthly cap on, `0` forces it off. Unset, it is on for an Enterprise usage-based seat: [how one is spotted](how-it-works.md#spotting-an-enterprise-seat) |
| `CC_SPEND_DOLLARS` | `1`, `0` | off | `1` adds the dollars to the Enterprise cap: `cap 01/Nov $160.40/200 80%`. `0` or unset leaves them off, since the share and the reset date are the useful parts; any other value counts as `1` |
| `CC_USAGE_FLOOR` | whole seconds | `1800` | The base wait between Enterprise refreshes, used below 50% of the cap. A value under 300 is raised to 300, the gap between calls. Anything that is not a whole number gives 1800. From 50% of the cap the wait is 600 seconds and from 80% it is 300, whatever this says |
| `CC_SPEND_CAP` | dollars, such as `50` | no cap | Turns the local dollar estimate into a share of a cap you name: `CC_SPEND_CAP=50` draws `$42.60/50 85%`. Pay-per-token accounts only, and ignored wherever the server reports a real figure. A value that is not a number above zero is ignored, and the plain `$2.50` shows |
| `CC_SPEND_PERIOD` | `day`, `week`, `month` | `month` | The period the local dollar estimate covers. Match how the account is billed, or the total starts over on the wrong day |

### `CC_ASCII`

The default line uses a few symbols outside ASCII, `· … ✗ ✓ ⌂ ◊ ↯ ¤`, picked to stay inside their cell with common terminal fonts. Where they still break, `CC_ASCII=1` draws [the ASCII line](accounts.md#the-ascii-line).

Unset, ASCII turns on by itself where the symbols are likely to break:

- the Linux text console, `TERM=linux`;
- a locale that is not UTF-8: none of `LC_ALL`, `LC_CTYPE` and `LANG` names `UTF-8` or `utf8`, as Claude Code passed them;
- the classic Windows console: Git Bash with neither `WT_SESSION`, which Windows Terminal sets, nor `TERM_PROGRAM` set.

A wrong guess costs a plainer line, never a broken one. `CC_ASCII=0` keeps the symbols in all three cases.

## Read from the environment

The scripts also read these. You do not normally set them for the line.

| Variable | Read by | For |
|---|---|---|
| `CLAUDE_CONFIG_DIR` | all | The [config folder](#the-config-folder). Set it per login, as you would for Claude Code |
| `COLUMNS` | `statusline.sh` | The terminal width, which Claude Code passes to the command |
| `TERM`, `LC_ALL`, `LC_CTYPE`, `LANG`, `WT_SESSION`, `TERM_PROGRAM` | `statusline.sh` | Whether to [draw ASCII](#cc_ascii) when `CC_ASCII` is unset |
| `OS` | `statusline.sh` | `Windows_NT` on Windows, the only place the line asks `uname` whether it runs in Git Bash |
| `HOME` | all | The default config folder, `~/.claude` |
| `PWD` | `statusline.sh`, `install.sh` | The folder to show when the JSON names none; the base of a relative `--config-dir` |
| `USER` | `usage-refresh.sh` | The keychain account the login is filed under |
| `CLAUDE_PLUGIN_ROOT` | the plugin hook | Where the plugin's own copy of the scripts is |

## No script at all

If you only need a Pro or Max window or a gateway cap, one `jq` command in `settings.json` is enough. It needs no files:

```json
{
  "statusLine": {
    "type": "command", "command": "jq -r '\"\\(.model.display_name // \"?\") · \\(.context_window.used_percentage // 0 | floor)% ctx · \" + (if .rate_limits.five_hour then \"5h \\(.rate_limits.five_hour.used_percentage | round)%\" + (if .rate_limits.seven_day then \" · 7d \\(.rate_limits.seven_day.used_percentage | round)%\" else \"\" end) elif .rate_limits.spend_limit then \"cap \\(.rate_limits.spend_limit.used_percentage | round)%\" else \"$\\((.cost.total_cost_usd // 0) * 100 | round / 100)\" end)'"
  }
}
```

It renders, depending on the account:

```text
Opus 5 · 12% ctx · 5h 24% · 7d 62%     Pro or Max
Sonnet 5 · 40% ctx · cap 78%           gateway spend limit
Opus 5 · 3% ctx · $1.23                Enterprise seat, or pay per token
```

`jq` drops trailing zeros, so $2.50 reads `$2.5`. On an Enterprise seat it falls back to this session's estimated cost, because that seat type sends no limits to a status line. See [the usage endpoint](usage-endpoint.md).

## State files

All in the config folder, all disposable: delete any of them and the line rebuilds it.

| File | Holds |
|---|---|
| `.rl-<key>-state` | One record per window (`5h`, `7d`, `gateway`, `spend` for the Enterprise cap, `credits`, `ledger`), shared by every session: the reset time, the highest figure a session has shown and when, and the burn rate. One line, under 80 bytes |
| `.usage-cache.json` | The last Enterprise snapshot, about 120 bytes. While under 8 days old it also marks the machine as an Enterprise seat: [the latch](how-it-works.md#spotting-an-enterprise-seat) |
| `.usage-activity` | The cost each session has seen, and a running local total |
| `.usage-attempt` | The time of the last call, for the 5-minute gap between calls |
| `.usage-unavailable` | Why the last Enterprise call failed and when, and after a 429 until when to wait. Absent when healthy |
| `.usage-cache.lock/` | A folder that exists only while a refresh runs |
| `.credits-cache.json` | The last usage credits figures |
| `.credits-unavailable` | Why the last credits call failed, and when. Absent when healthy |
| `.spend-ledger` | The local dollar total, pay-per-token accounts only |

The files the refresher writes, the snapshots, the reasons and the lock, are readable by your account only.

Four more belong to the installers. Leave these alone:

| File | Holds |
|---|---|
| `.budget-statusline-manifest` | What the plugin and `install.sh` installed, with checksums, so neither overwrites a file it did not write or one you edited |
| `.budget-statusline.log` | What the plugin did at session start, and the line to add when it could not wire `settings.json`. Trimmed to the last 200 lines once it passes 400. `install.sh` prints instead of logging |
| `.budget-statusline-notice` | The message the plugin last showed in Claude Code, so that it is shown once. It goes once there is nothing to say |
| `.budget-statusline.lock/` | A folder that exists only while the plugin or `install.sh` is changing the config folder, so two session starts cannot get in each other's way |
