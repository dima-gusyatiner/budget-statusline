# What the line shows

The line has four groups, left to right: where you are, the model, the context window and the budget. The budget group depends on your account and picks itself, so there is nothing to set per machine.

```text
git:(main) ✗ · Opus 5 (1M) ◊high · ctx 182k 18% · 5h 06:16 64% ↯1.2h · 7d Wed 62%
```

## Every part

| Part | Example | Means |
|---|---|---|
| Branch | `git:(main) ✗` | The git branch. `✗` means uncommitted changes, `✓` a clean tree. In a terminal that supports links, the branch opens the folder in VS Code |
| Folder | `⌂home` | Outside a repository, the name of the folder, here one called `home`. It also shows on a detached HEAD, where there is no branch to name, and in a repository owned by another account on the machine, which git refuses to read |
| Model | `Opus 5 (1M)` | The model, with `(1M)` for a one-million-token context window |
| Effort | `◊high` | The effort level |
| Context | `ctx 182k 18%` | Tokens in the context window, and the share of the window they fill |
| 5-hour window | `5h 06:16 64%` | Pro or Max: the 5-hour usage window, the time it resets and the share used |
| 7-day window | `7d Wed 62%` | Pro or Max: the weekly window and the day it resets |
| Burn estimate | `↯1.2h` | At the recent pace, this window is full in 1.2 hours. Under an hour it counts minutes, `↯25m`; from 10 hours, whole hours, `↯36h`; from 2 days, whole days, `↯2d`. See [the burn estimate](how-it-works.md#the-burn-estimate) |
| Usage credits | `¤$12.40` | Spent on usage credits this month. Shown only while a window is full |
| Monthly cap | `cap 01/Nov 80%` | Enterprise usage-based seat: the monthly spend cap and the day it resets |
| Gateway cap | `cap 23/Oct 78%` | Behind a Claude apps gateway: its spend limit, and when it resets: a time when that is less than a day away, such as `cap 14:30 78%`, else a date written like the monthly cap's |
| Dollars | `$2.50` | API key, Amazon Bedrock or Google Vertex AI: dollars spent this month, summed on your machine |
| Dollars against a cap | `$42.60/50 85%` | The same, against a cap you name with `CC_SPEND_CAP` |
| Stale figure | `cap 2h-stale` | The last figure is 2 hours old, too old to draw. See [old and missing figures](#old-and-missing-figures) |
| Window over | `5h reset` | The window's reset time has passed and no reply has brought the new window yet. Also `7d reset` and `cap reset` |
| Reason | `cap login`, `cap 01/Nov 42% login` | Why there is no figure, or why the figure shown could not be refreshed. See [old and missing figures](#old-and-missing-figures) |

Day and month names follow your locale: in German the same windows read `7d Mi. 62%` and `cap 01/Nov. 80%` on macOS, and `7d Mi 62%` and `cap 01/Nov 80%` on Linux, whose names have no full stop. Numbers always use a decimal point.

A percentage is drawn at 0% too. Colour carries the severity, so the number is the only thing to read:

| Share used | Colour |
|---|---|
| under 50% | green |
| 50% to 79% | yellow |
| 80% and over | red |

The rule holds wherever a share is drawn: the context, the windows, the caps, usage credits against their monthly limit, and the dollar estimate against `CC_SPEND_CAP`. The burn estimate is dim, and red when the window would fill before it resets. A word in place of a figure is dim, yellow or red by [who has to act](usage-endpoint.md#when-it-cannot-get-a-number).

## Per account

| Account | The budget part | Where the figure comes from |
|---|---|---|
| Claude Pro or Max | `5h 06:16 64% · 7d Wed 62%` | `rate_limits.five_hour` and `rate_limits.seven_day` in the JSON Claude Code passes the status line |
| Pro or Max with a window full | adds `¤$12.40` | the usage endpoint, see [usage credits](#usage-credits) |
| Enterprise usage-based seat | `cap 01/Nov 80%` | the usage endpoint, see [the usage endpoint](usage-endpoint.md) |
| Claude apps gateway with a spend limit | `cap 23/Oct 78%` | `rate_limits.spend_limit` in the JSON, Claude Code 2.1.251 or newer |
| API key, Bedrock, Vertex AI, or any other login with no limits in the JSON | `$2.50`, or `$42.60/50 85%` with `CC_SPEND_CAP=50` | `cost.total_cost_usd`, this session's estimated cost, summed on your machine. See [the dollar estimate](how-it-works.md#the-dollar-estimate) |

Until its first reply, a new session that has spent nothing draws the figures another session of the login has seen in the last 30 minutes, from the shared records, without usage credits: see [the first render of a new chat](how-it-works.md#the-first-render-of-a-new-chat).

One line per account type:

```text
git:(main) ✗ · Opus 5 (1M) ◊high · ctx 182k 18% · 5h 06:16 64% ↯1.2h · 7d Wed 62%
git:(main) ✗ · Opus 5 (1M) ◊high · ctx 182k 18% · 5h 06:16 100% · 7d Wed 62% · ¤$12.40
git:(main) ✗ · Opus 5 · ctx 12.0k · cap 01/Nov 80%
git:(main) ✗ · Sonnet 5 · ctx 80.6k 40% · cap 23/Oct 78%
git:(main) ✗ · Opus 5 · ctx 880 · $2.50
```

With `CC_SPEND_DOLLARS=1` the monthly cap also shows the dollars: `cap 01/Nov $160.40/200 80%`. With `CC_SPEND_CAP=50` the dollar estimate reads `$42.60/50 85%`. Outside a repository the line starts with the folder: `⌂home · Opus 5 ◊high · ctx 880`.

## Usage credits

When a 5-hour or 7-day window is full, Claude Code goes on with usage credits if the account has them on. The JSON it passes the status line says nothing about credits, so while a window stays full the line asks the [usage endpoint](usage-endpoint.md) for them.

- `¤$12.40`: spent on credits this month. Dollars rather than a share, because once a window is full the money is what hurts. With a monthly limit, the colour says how close it is and `↯` says when the limit runs out at this pace. Another currency reads `¤12.40 EUR`.
- `¤credits`, dim: a window is full, and the first figure is on its way. Nothing to do.
- `¤login`, `¤tls`, `¤no refresher`, `¤offline` and the other reasons: no figure from the last hour, and why. `¤$12.50 login`: a refresh failed after this figure was fetched. They mean what the `cap` forms mean in [when it cannot get a number](usage-endpoint.md#when-it-cannot-get-a-number).
- Nothing: no window is full, the account has credits off, or the session has had no reply yet. With credits off nothing is being spent, and the red `100%` says enough.

A window counts as full when the line draws it at 100%, which is the freshest figure any session on the machine has seen. A session left idle on 97% shows the credits once another session has seen 100%. Behind a Claude apps gateway the line never looks credits up, even with a full window: the gateway sets the budget there. A new session looks credits up only after its first reply.

`CC_CREDITS=0` turns the lookup off.

## Old and missing figures

The Enterprise cap and usage credits come from the usage endpoint, so their figure can be old, or missing. A figure shows no age: it is the last one fetched, drawn until it is too old to trust.

| Shown | Means |
|---|---|
| `cap 01/Nov 42%`, `¤$12.50` | The last figure fetched. It is drawn until it is three times the refresh floor old, 90 minutes by default and less as the cap nears, or an hour for usage credits |
| `cap 01/Nov 42% login` | The last refresh failed after this figure was fetched, and the word says why. After a 429 the figure stays for at least an hour: `cap 01/Nov 91% throttled` |
| `cap login`, `cap tls`, `cap 6d-stale` | No figure the line can vouch for: only the reason, or how old the last one is, here 6 days |
| `cap …`, `¤credits` | The first figure is on its way. Both are dim: nothing to do |

Every reason, its colour and when the line tries again: [when it cannot get a number](usage-endpoint.md#when-it-cannot-get-a-number).

## The ASCII line

Some fonts lack a symbol, and some terminals cannot show anything outside ASCII. `CC_ASCII=1` draws the line in plain ASCII, and it turns on by itself where the symbols are likely to break: [`CC_ASCII`](configuration.md#cc_ascii).

| Part | Default | ASCII |
|---|---|---|
| Separator | ` · ` | ` \| ` |
| A name over 13 characters, cut short | `a-long-branc…` | `a-long-bran..` |
| Uncommitted changes | `✗` | `*` |
| Clean tree | `✓` | nothing |
| Folder | `⌂home` | `home` |
| Effort | `◊high` | `high`, or `effort high` with no model before it |
| Usage credits | `¤$12.40`, `¤login`, `¤credits` | `+$12.40`, `+login`, `+credits` |
| Burn estimate | `↯1.2h` | `~1.2h` |
| First fetch on its way | `cap …` | `cap ..` |

```text
git:(main) * | Opus 5 (1M) high | ctx 182k 18% | 5h 06:16 64% ~1.2h | 7d Wed 62%
```

## The context figure

`ctx 182k 18%` is the share of the context window in use. Claude Code's own context warning counts down to auto-compaction instead, a different number, so the two will not match.
