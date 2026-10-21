# Security

## Supported versions

| Version | Gets fixes |
|---|---|
| 1.0.x | yes |
| anything older | no |

## Reporting a vulnerability

Report it privately: on the repository's **Security** tab, choose **Report a vulnerability** ([direct link](https://github.com/dima-gusyatiner/budget-statusline/security/advisories/new)). Please do not open a public issue, and never paste a real token, a `.credentials.json` or a keychain entry into a report.

This is a one-person project, so the response is best effort, with no fixed reply time and no bug bounty. A confirmed problem gets a fix release and a line in the [changelog](CHANGELOG.md), with credit if you want it.

## What the tool reads, writes and sends

The tool handles your Claude sign-in token, so here is all of it.

### Every render

`statusline.sh` reads the JSON Claude Code pipes in, runs `git` in your working folder for the branch and the dirty mark, and checks Claude Code's `.claude.json` for two strings: `enterprise_usage_based`, which marks an Enterprise usage-based seat, and, while a window is full, `cachedExtraUsageDisabledReason`. It writes small state files in the [config folder](docs/configuration.md#state-files): figures, times and session ids, never a credential. It makes no network call.

For a repository owned by another account on the machine, `git` keeps its own guard: the line shows a plain folder name, and none of that repository's settings run. `git` also runs without optional locks, so a render never writes the index.

The folder, model and effort names lose any control characters before they are printed, so a crafted name cannot send escape sequences to your terminal. Branch names need no such step: `git` refuses a control character in one.

### The sign-in token

Only `usage-refresh.sh` touches your login, and it runs in two cases only: an Enterprise usage-based seat, and a Pro or Max window at 100%, for usage credits. Behind a Claude apps gateway it never runs. With an API key it runs only if `CC_ENTERPRISE=1` forces the Enterprise path, or if the machine still looks like an Enterprise seat from an earlier login: Claude Code's `.claude.json` names one, or a fetch left a snapshot in the last 8 days ([how a seat is spotted](docs/how-it-works.md#spotting-an-enterprise-seat)). `CC_ENTERPRISE=0` and `CC_CREDITS=0` together switch it off.

When it runs:

- It reads the token Claude Code stored for this config folder: on macOS from the keychain with `security find-generic-password`, elsewhere from `.credentials.json`. `jq` keeps the access token and its expiry and drops the rest of the record, refresh token included.
- An expired token is not sent. Nor is a token the endpoint has refused: the refresher keeps its expiry time as a fingerprint and sends only a new one.
- The token goes to `curl` on standard input, never on the command line, so other accounts cannot read it from the process list.
- It is never written to disk and never logged.

### The network

One request, to one host: `GET https://api.anthropic.com/api/oauth/usage`, over HTTPS. `curl` runs with `-q`, so a `~/.curlrc` cannot add a proxy, redirects or a trace file to this call; it follows no redirects, takes at most 1 MiB of reply and gives up after 10 seconds. The request carries the token, `anthropic-beta: oauth-2025-04-20` and `User-Agent: claude-code/<version>`. At most one call every 5 minutes, detached from the render. The reply is kept in a temporary file that is deleted when the refresher exits; only a few figures from it are kept. Everything the refresher writes is readable by your account only. Nothing else in the tool opens a connection: no telemetry, no update check of its own.

The endpoint is undocumented, and Anthropic's [legal and compliance page](https://code.claude.com/docs/en/legal-and-compliance) restricts third-party use of Claude.ai credentials. [The usage endpoint](docs/usage-endpoint.md) has the details.

### Installing and updating

- The plugin's `SessionStart` hook copies `statusline.sh` and `usage-refresh.sh` into the config folder each time a session starts or resumes, and `install.sh` does the same once. Both take a lock while they work, keep a manifest with checksums, never overwrite a file they did not write or one you edited, update the two scripts together or not at all, so an edited one never runs beside a newer partner, refuse to write through a symbolic link, and add a `statusLine` to `settings.json` only when it has none. `install.sh --uninstall` removes only what they placed.
- The hook never fails a session and puts nothing into Claude's context. When it could not do its job, such as wire `settings.json` or update an edited script, it prints one JSON object with a `systemMessage`, which Claude Code's hooks documentation says is shown to you, and says it again only when the message changes.
- A plugin update brings new code that runs on your machine, so trust rests on this repository. An update arrives only when the version number changes. With auto-update off, which is Claude Code's default for a marketplace added from GitHub, nothing changes until you update by hand, so you can read the change first.

## Out of scope

- The usage endpoint changing, throttling or going away. The line then says why instead of showing a figure.
- Problems in Claude Code, `jq`, `curl`, `git` or your terminal. Report those to their projects.
- Anything that needs an attacker who can already edit your `settings.json` or the scripts in your config folder.
