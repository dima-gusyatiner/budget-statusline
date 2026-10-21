# Limits

## Known defects

- The branch link to VS Code does not URL-encode the folder path. A folder with a space in its name gives `vscode://file/.../my project`, which the editor may not open. The `vscode://` scheme is fixed, with no setting for another editor.

## Caveats

- The usage endpoint is undocumented. If it changes or goes away, the line shows a reason rather than a wrong number: `cap api moved` for a reply it does not know, `cap http 404` or `cap offline` for an endpoint that is gone, `cap no figure` for a reply without a figure. Only an update can follow the change. See [the usage endpoint](usage-endpoint.md).
- The Enterprise cap's reset date is the next UTC month boundary, not a figure the endpoint reports. [How it was checked](usage-endpoint.md#reset-dates).
- Usage credits are looked up only while a 5-hour or 7-day window is full. Credits spent before any window is full do not show.
- A gateway spend limit is drawn as a share. Claude Code 2.1.284 and newer also pass its dollars, which the line does not draw.
- The dollar estimate is this session's cost at list price, summed on your machine over the sessions whose status line ran. It is not your bill.
- The burn estimate is a smoothed recent pace: a hint, not a forecast. Trust the colour more than the minutes.
- A session left idle keeps the figure it heard last, and keeps the shared record of a window alive. So if the server ever lowers a figure inside a window, the lower one shows 30 minutes after the last session still on the old figure hears the new one or closes. The Enterprise and credits figures, which every session reads from one file, take a lower figure at once.
- The keychain item for a `CLAUDE_CONFIG_DIR` folder is named as observed on Claude Code 2.1.292, from the variable exactly as set. If a later version names it differently, that login shows `cap login` until the line follows. Without `CLAUDE_CONFIG_DIR` the plain name is used.
- Claude Code passes the plan windows only after the first reply from the server. Until then a new session shows the figures another session of the login has seen in the last 30 minutes, from the shared records. With none, say in the first session after a quiet half hour, it has no budget until its own figures arrive, at the next run of the line after that reply: the first message, or the next `refreshInterval` tick, at most a minute with the 60 seconds the plugin and `install.sh` set. On an Enterprise seat the first figure lands once the refresher has run.
- Every symbol counts as one column, and very long non-ASCII names are not always shortened: see [narrow terminals](narrow-terminals.md#limits).
