# Changelog

Notable changes to `budget-statusline`. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.0.1] - 2026-10-21

### Fixed

- A new session no longer starts without a budget. Until its first reply brings its own figures, it draws the 5-hour and 7-day windows, or a gateway's cap, that another session of the login has seen in the last 30 minutes, from the shared records, burn estimate included.

## [1.0.0] - 2026-10-21

The first public release.

### Added

- One status line for every account type: the 5-hour and 7-day windows on Pro and Max; usage credits in dollars once a window is full; the monthly spend cap of an Enterprise usage-based seat; a Claude apps gateway's spend limit; and for an API key, Amazon Bedrock or Google Vertex AI, the dollars spent this month, with an optional cap (`CC_SPEND_CAP`).
- The burn estimate, `↯1.2h`: when a window reaches 100% at the recent pace, red when that comes before the window resets.
- Colour by share used: green under 50%, yellow from 50%, red from 80%.
- One shared record per window, so several sessions on one machine show the same figure, an idle one neither lags behind nor raises a false alarm, and a window past its reset reads `5h reset` until the new one arrives.
- A background refresher for the figures Claude Code does not pass a status line: one call at most every 5 minutes per login, back-off after a refusal, never an expired or refused token, the age of an old figure on the line, and a word for why a figure is missing or could not be refreshed, such as `cap login` or `cap 01/Nov 42% login`.
- Fitting to the terminal width in steps, with the budget kept to the end (`CC_WIDTH`).
- Symbols that common terminal fonts draw inside one cell, and a pure ASCII line with `CC_ASCII=1`, on by itself on the Linux text console, in a locale that is not UTF-8 and in the classic Windows console.
- One config folder per login, so several logins on one machine keep apart.
- Install as a Claude Code plugin, or with `install.sh` on a machine without plugins. Neither overwrites a file it did not write or one you edited, and `install.sh --uninstall` removes only what they placed.
- Runs on POSIX `sh`: macOS `/bin/sh`, `dash`, `bash`, and Git Bash on Windows. Needs `jq`, and `curl` for the usage endpoint only. Both test suites run on Linux, macOS and Windows.

[Unreleased]: https://github.com/dima-gusyatiner/budget-statusline/compare/v1.0.1...HEAD
[1.0.1]: https://github.com/dima-gusyatiner/budget-statusline/releases/tag/v1.0.1
[1.0.0]: https://github.com/dima-gusyatiner/budget-statusline/releases/tag/v1.0.0
