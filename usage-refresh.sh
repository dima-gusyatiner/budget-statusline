#!/bin/sh
# Fetches live spend figures for the status line and caches them.
#
# Why this exists: on an enterprise usage-based seat Claude Code sends no
# `rate_limits` in the status line payload at all (the status line docs list
# them only for Pro and Max, and behind a gateway with a spend limit), and the
# copy it keeps in `~/.claude.json` went 6 days without refreshing. The
# payload's `cost.total_cost_usd` is no substitute: it is one session's
# list-price estimate, measured larger than the account's real all-session total
# at the same moment, and it carries neither the limit nor the reset date.
#
# Called detached from `statusline.sh`, which decides when. `$1` is the local
# observed-spend total at call time, stored so the caller can tell how much
# spend has happened since.
#
# With `credits` as the third argument it serves a Claude.ai subscription
# instead: once a 5-hour or 7-day window is full, Claude Code spends usage
# credits, and the payload says nothing about them. Then `$1` is this session's
# cost and `$4` its id, it keeps the `extra_usage` part of the reply in
# `.credits-cache.json`, and it records failures in `.credits-unavailable`. Both
# are files of their own: `.usage-cache.json` marks a machine as an enterprise
# seat, and a failure on one path must not hold back the other.
#
# Every file lives in the login's config folder, `CLAUDE_CONFIG_DIR` when set,
# else `~/.claude`, and the login is the one Claude Code keeps for that folder.
#
# On failure this writes no snapshot, only a reason into `.usage-unavailable`
# (`.credits-unavailable` in credits mode), and on a second line its time:
#   nologin | login [expiresAt] | expired | nocurl | offline <curl exit>
#   tls <curl exit> | http <code> | api | nofigure
#   throttled <until-epoch> <429s-in-a-row>
# The caller renders that reason and picks its retry backoff from it, so an old
# figure is never drawn as current and the cause is never guessed at.
# Everything written here, the temporary files included, is for this account
# alone: the figures, the reasons, the lock.
umask 077
CLAUDE=${CLAUDE_CONFIG_DIR:-$HOME/.claude}
cache="$CLAUDE/.usage-cache.json"
lock="$CLAUDE/.usage-cache.lock"
dead="$CLAUDE/.usage-unavailable"
tmp="$cache.$$"
mode=${3:-} sess=${4:--}
[ "$mode" = credits ] && dead="$CLAUDE/.credits-unavailable"

# fail <reason>: record why, and on a second line when, through a temporary
# file so the status line never reads it half written, and stop. The time is
# written rather than read from the file's date, which a clock moved back would
# leave in the future.
fail() {
  printf '%s\n%s\n' "$1" "$(date +%s)" 2>/dev/null > "$dead.$$" && mv -f "$dead.$$" "$dead" 2>/dev/null ||
    rm -f "$dead.$$" 2>/dev/null
  exit 0
}

seen=${1:-0}
case "$seen" in ''|*[!0-9.]*) seen=0 ;; esac

# Client version for the `User-Agent` header. Callers without it get throttled
# into a punitive 429 bucket (reported upstream: anthropics/claude-code#31021
# and anthropics/claude-code#31637). Passed by `statusline.sh` from the
# payload; falls back to `claude --version`, then to a known-good pin.
ver=${2:-}
case "$ver" in ''|*[!0-9.]*) ver=$(claude --version 2>/dev/null | awk '{print $1; exit}') ;; esac
case "$ver" in ''|*[!0-9.]*) ver=2.1.252 ;; esac

# The traps come first, so no signal can land between taking the lock and
# being ready to give it back; `own` says whether this run took it. The lock is
# given back only while it still holds this run's pid: a run that lost it to a
# takeover must not delete the one that took it.
own=
trap '[ -n "$own" ] && [ "$(cat "$lock/pid" 2>/dev/null)" = "$$" ] && rm -rf "$lock" 2>/dev/null; rm -f "$tmp" "$tmp.o" "$tmp.h" 2>/dev/null' EXIT
# Exit on a signal, so the `EXIT` trap cleans up. A trap that only cleaned up
# would carry on and record the killed `curl` as "offline". `statusline.sh`
# starts this in a session of its own, but without `setsid` or `perl` it stays
# in the process group Claude Code signals when it cancels a run.
trap 'exit 1' HUP INT TERM
# running <pid>: the lock's holder is a refresher still at work. A refresher
# killed with no chance to clean up (`SIGKILL`) leaves its pid to be reused, so
# where `ps` can show the command, it must still be a refresher; where `ps`
# cannot tell, the pid alone counts.
running() {
  kill -0 "$1" 2>/dev/null || return 1
  rn_c=$(ps -o command= -p "$1" 2>/dev/null) || return 0
  case "$rn_c" in *usage-refresh*) return 0 ;; esac
  return 1
}
if ! mkdir "$lock" 2>/dev/null; then
  # A refresh in flight keeps its lock however long it takes: a Mac asleep
  # mid-`curl` finishes it on waking. One whose holder is gone is taken over at
  # once, and one with no pid (a holder killed before writing it) after five
  # minutes.
  holder=; [ -r "$lock/pid" ] && read -r holder < "$lock/pid"
  case "$holder" in *[!0-9]*) holder= ;; esac
  if [ -n "$holder" ]; then running "$holder" && exit 0
  else [ -n "$(find "$lock" -maxdepth 0 -mmin +5 2>/dev/null)" ] || exit 0; fi
  # Take it over atomically: rename it away first. Of two runs that found it
  # stale only one renames it, and the other then finds the new lock. A lock
  # that turns out to be someone's new one gets its pid back.
  [ -e "$lock.$$" ] && rm -rf "$lock.$$" 2>/dev/null
  mv "$lock" "$lock.$$" 2>/dev/null || exit 0
  if [ "$(cat "$lock.$$/pid" 2>/dev/null)" != "$holder" ]; then
    mkdir "$lock" 2>/dev/null && mv -f "$lock.$$/pid" "$lock/pid" 2>/dev/null
    rm -rf "$lock.$$" 2>/dev/null; exit 0
  fi
  mkdir "$lock" 2>/dev/null || { rm -rf "$lock.$$" 2>/dev/null; exit 0; }
  own=1; printf '%s\n' "$$" > "$lock/pid" 2>/dev/null
  rm -rf "$lock.$$" 2>/dev/null
fi
own=1
printf '%s\n' "$$" > "$lock/pid" 2>/dev/null

# service: the keychain item Claude Code keeps this folder's login in, in
# `$svc`, or empty when it cannot be named. Claude Code keeps one login per
# config folder (its "Credential management" docs). Observed on 2.1.292, the
# item is "Claude Code-credentials", and with `CLAUDE_CONFIG_DIR` set it adds
# "-" and the first 8 hex digits of the SHA-256 of that value exactly as set,
# NFC-normalized and with no path cleaning. Reading the plain name for another
# folder would read another login's token, so a name that cannot be worked out
# reads nothing.
service() {
  svc="Claude Code-credentials" sv_in=${CLAUDE_CONFIG_DIR:-}
  [ -n "$sv_in" ] || return 0
  sv_n=$(perl -CSA -MUnicode::Normalize -e 'print NFC($ARGV[0])' -- "$sv_in" 2>/dev/null) && sv_in=$sv_n
  if command -v sha256sum >/dev/null 2>&1; then sv_h=$(printf '%s' "$sv_in" | sha256sum 2>/dev/null)
  elif command -v shasum >/dev/null 2>&1; then sv_h=$(printf '%s' "$sv_in" | shasum -a 256 2>/dev/null)
  else sv_h=$(printf '%s' "$sv_in" | openssl dgst -sha256 -r 2>/dev/null); fi
  sv_h=${sv_h%"${sv_h#????????}"}
  case "$sv_h" in
    [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]) svc="$svc-$sv_h" ;;
    *) svc= ;;
  esac
}

# On macOS the login is in the keychain, filed under an account name: Claude
# Code uses `$USER`, else the login name, or `claude-code-user` for a name with
# anything but letters, digits, dot, dash and underscore (observed on 2.1.292).
# If that account has nothing, the same item under any account, in case a later
# Claude Code picks the account differently; the item name already picks the
# login. Elsewhere, or when the keychain has nothing, `.credentials.json` in the
# config folder: Claude Code's docs name that file as the store on Linux and the
# fallback on macOS. One `jq` call keeps the token and its expiry and drops the
# rest. The `eol=1` at the end is a field nobody reads: a native Windows `jq`
# ends its output with a carriage return, and in `exp` it would fail the digit
# check below, so an expired token would be sent.
# Each field is kept only when it is a string or a number, as in `statusline.sh`:
# an array would come out of `@sh` as several words and run as a command.
creds='def s: if type == "string" or type == "number" then . else empty end; def v(f; d): [f? | s][0] // d; @sh "tok=\(v(.claudeAiOauth.accessToken; "")) exp=\(v(.claudeAiOauth.expiresAt; "")) eol=1"'
tok= exp=
if command -v security >/dev/null 2>&1; then
  service
  acct=${USER:-}; [ -n "$acct" ] || acct=$(id -un 2>/dev/null)
  case "$acct" in ''|*[!A-Za-z0-9._-]*) acct=claude-code-user ;; esac
  if [ -n "$svc" ]; then
    eval "$(security find-generic-password -a "$acct" -w -s "$svc" 2>/dev/null | jq -r "$creds" 2>/dev/null)"
    [ -n "$tok" ] || eval "$(security find-generic-password -w -s "$svc" 2>/dev/null | jq -r "$creds" 2>/dev/null)"
  fi
fi
[ -n "$tok" ] || eval "$(jq -r "$creds" 2>/dev/null < "$CLAUDE/.credentials.json")"
[ -n "$tok" ] || fail nologin       # not an OAuth seat, or never logged in here
# Without `curl` the call below fails like a dropped network, and "offline"
# says it will clear itself. It will not: `curl` has to be installed.
command -v curl >/dev/null 2>&1 || fail nocurl
# An expired token is never sent. The endpoint has been seen to answer one with
# a 429 and a `Retry-After` near an hour, which would read as an hour of
# throttling, and Claude Code renews the token itself on its next request. The
# expiry is in milliseconds; a figure too small for that is taken as seconds.
fp=$exp
case "$exp" in
  ''|*[!0-9]*) fp= ;;
  *) [ "$exp" -ge 100000000000 ] && exp=$((exp / 1000))
     [ "$exp" -gt "$(date +%s)" ] || fail expired ;;
esac
# A token the server rejected is not sent again. Its expiry stands in for it in
# the reason ("login <expiresAt>"), and a new `/login` brings a new one: until
# then, nothing goes out, and the status line looks again after the 5-minute
# gap rather than an hour later.
if [ -n "$fp" ] && [ -r "$dead" ]; then
  read -r w0 fp0 _ < "$dead" 2>/dev/null
  [ "$w0" = login ] && [ "$fp0" = "$fp" ] && fail "login $fp"
fi

# The token goes to `curl` on stdin (`-H @-`, `curl` 7.55 or newer), never in
# an argument: every local account can read other users' argument lists with
# `ps`. `printf` is a shell builtin, so no extra process carries the token
# either. `-q` keeps the user's `~/.curlrc` out of this call, which could turn on
# redirects, a proxy, or a trace file that writes the token to disk; `curl`
# honours it only as the very first argument. A usage reply is a few hundred
# bytes, so `curl` stops (exit 63) at 1 MiB rather than fill the disk with
# something else. It runs in the config folder and writes its two files there
# by name: Git Bash hands a native `curl.exe` a path it may not be able to open
# (one with an apostrophe in it), but never touches a name without a slash.
code=$(CDPATH= cd -- "$CLAUDE" && printf 'Authorization: Bearer %s\n' "$tok" | curl -q -sS -m 10 --max-filesize 1048576 -o "${tmp##*/}" -D "${tmp##*/}.h" -w '%{http_code}' \
  https://api.anthropic.com/api/oauth/usage \
  -H @- \
  -H "anthropic-beta: oauth-2025-04-20" \
  -H "User-Agent: claude-code/$ver" \
  -H "Content-Type: application/json" 2>/dev/null)
rc=$?
# `curl`'s exit code is kept for whoever reads the file. A refused certificate
# or handshake is not a dropped network: a proxy that re-signs HTTPS (its CA can
# reach Claude Code through `NODE_EXTRA_CA_CERTS` and still not `curl`), or a CA
# file `curl` cannot read. Waiting will not fix it, so it is "tls", not
# "offline".
case "$rc" in
  0)  ;;
  63) fail api ;;                    # far too big to be a usage reply
  35|51|53|54|58|59|60|64|66|77|80|82|83|90|91) fail "tls $rc" ;;
  *)  fail "offline $rc" ;;
esac
# throttled: HTTP 429, too many requests. Keep away for the longer of what the
# server asks (`Retry-After` in seconds; a date there is ignored) and 5 minutes,
# doubled for each further 429 in a row, at most an hour. Asking again while
# refused seems to stretch the refusal (claude-hud issue 275).
throttled() {
  ra=$(awk 'tolower($1) == "retry-after:" { v = $2; gsub(/[^0-9]/, "", v); print v; exit }' "$tmp.h" 2>/dev/null)
  case "$ra" in ''|*[!0-9]*) ra=0 ;; esac
  streak=0
  [ -r "$dead" ] && read -r w0 u0 n0 < "$dead" && [ "$w0" = throttled ] && streak=$n0
  case "$streak" in ''|*[!0-9]*) streak=0 ;; esac
  streak=$((streak + 1))
  secs=300 i=1
  while [ "$i" -lt "$streak" ] && [ "$secs" -lt 3600 ]; do secs=$((secs * 2)) i=$((i + 1)); done
  [ "$ra" -gt "$secs" ] 2>/dev/null && secs=$ra
  [ "$secs" -gt 3600 ] && secs=3600
  fail "throttled $(( $(date +%s) + secs )) $streak"
}

case "$code" in
  200)     ;;
  000|'')  fail offline ;;          # never reached the host
  401|403) fail "login${fp:+ $fp}" ;;   # token rejected: `/login`
  429)     throttled ;;             # too many requests: wait, and say so calmly
  *)       fail "http $code" ;;
esac

# nextmonth: the epoch of the 1st of next month, local time: when usage credits
# start over, as Claude Code's `/usage` dates it. The reply has no reset date
# for them. `tests/run.sh` runs it for all twelve months.
nextmonth() {
  y=$(date +%Y) m=$(date +%m)
  m=${m#0}; m=$((m + 1)); [ "$m" -gt 12 ] && { m=1; y=$((y + 1)); }
  d=$(printf '%04d-%02d-01' "$y" "$m")
  date -j -f '%Y-%m-%d %H:%M:%S' "$d 00:00:00" +%s 2>/dev/null ||
    date -d "$d 00:00:00" +%s 2>/dev/null
}

if [ "$mode" = credits ]; then
  # The credits part of the reply, money in whole minor units (cents for USD),
  # the percentage 0 to 100, kept only when it is a number, and the currency
  # only when it is a string. A usage reply with no credits block means the
  # account has none: kept as "off", so the line stops asking every 5 minutes.
  # A reply with none of the usage keys at all means the shape moved.
  rs=$(nextmonth); case "$rs" in ''|*[!0-9]*) rs=null ;; esac
  jq -ce --argjson t "$(date +%s)" --arg s "$seen" --arg i "$sess" --argjson r "$rs" '
    select(type == "object" and (has("five_hour") or has("seven_day") or has("extra_usage") or has("limits"))) |
    (.extra_usage // {is_enabled: false}) as $x |
    {fetched_at:  $t,
     spend_seen:  $s,
     session:     $i,
     resets_at:   $r,
     enabled:     ($x.is_enabled == true),
     used_minor:  (if $x.used_credits == null then null else ($x.used_credits | floor) end),
     limit_minor: (if $x.monthly_limit == null then null else ($x.monthly_limit | floor) end),
     percent:     ($x.utilization | if type == "number" then . else null end),
     currency:    ($x.currency | if type == "string" then . else "USD" end)}' 2>/dev/null < "$tmp" > "$tmp.o" \
    || fail api                      # 200, but the response shape moved
  mv -f "$tmp.o" "$CLAUDE/.credits-cache.json" && rm -f "$dead"
  exit 0
fi

# Keep the figures the status line uses; `severity` rides along, unread. The
# share is the amount spent divided by the limit when the reply has both,
# because `spend.percent` comes rounded to a whole number (1 for 297 of 20000);
# else `spend.percent`. Some organisations get null in every one of these
# fields: that is "nofigure", a reason of its own. A reply with none of the
# usage keys at all means the shape moved.
snap=$(jq -c --argjson t "$(date +%s)" --argjson s "$seen" '
  def num: if type == "number" then . else null end;
  def obj: if type == "object" then . else {} end;
  if type != "object" then empty
  elif [has("spend"), has("five_hour"), has("seven_day"), has("extra_usage"), has("limits")] | any | not then empty
  else
    (.spend | obj) as $sp |
    ($sp.used | obj | .amount_minor | num) as $u |
    ($sp.limit | obj | .amount_minor | num) as $l |
    (if $u != null and $l != null and $l > 0 then (($u / $l * 100000 + 0.5) | floor) / 1000
     else ($sp.percent | num) end) as $pc |
    if $pc == null then "nofigure"
    else {fetched_at:  $t,
          spend_seen:  $s,
          percent:     $pc,
          used_minor:  (if $u == null then null else ($u | floor) end),
          limit_minor: (if $l == null then null else ($l | floor) end),
          severity:    $sp.severity}
    end
  end' 2>/dev/null < "$tmp")
# A native Windows `jq` ends its output with a carriage return, which would make
# "nofigure" read as a shape that moved.
cr=$(printf '\r'); snap=${snap%"$cr"}
case "$snap" in
  '{'*) ;;
  '"nofigure"') fail nofigure ;;     # 200, a usage reply, but no figure for this seat
  *) fail api ;;                     # 200, but the response shape moved
esac
printf '%s\n' "$snap" > "$tmp.o" 2>/dev/null && mv -f "$tmp.o" "$cache" && rm -f "$dead"
exit 0
