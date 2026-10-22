#!/bin/sh
# Tests for `statusline.sh` and `usage-refresh.sh`. POSIX sh, no framework. Each
# case pipes a payload through the script with `HOME` pointed at a scratch
# folder, then checks the output with the colour codes stripped. Every failure
# is counted, and the exit status is the number of failures.
set -u
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
sl="$here/../statusline.sh"
# `SL_SHELL=dash sh tests/run.sh` runs every case under another shell. macOS `sh` is
# `bash` in POSIX mode and forgives things that `dash`, the `sh` on Debian and
# Ubuntu, does not.
shell=${SL_SHELL:-sh}
fails=0
# Settings left in the shell that runs the suite would change what it sees. The
# config folder ones matter most: with `CLAUDE_CONFIG_DIR` set, the scripts would
# keep their state in the real folder it names, not in the scratch `HOME`.
unset CC_WIDTH CC_ENTERPRISE CC_SPEND_DOLLARS CC_SPEND_CAP CC_SPEND_PERIOD CC_USAGE_FLOOR CC_CREDITS CC_ASCII COLUMNS
unset CLAUDE_CONFIG_DIR
# The locale too: the suite reads numbers and dates in the C locale, and a check
# that wants another one sets it.
unset LANG LC_ALL LC_CTYPE LC_NUMERIC LC_TIME LC_COLLATE LC_MESSAGES LC_MONETARY
# Most checks read the symbols, so the plain ASCII line is off unless a check
# turns it on. Left to itself it would follow the locale and terminal of
# whoever runs the suite.
CC_ASCII=0; export CC_ASCII
E=$(printf '\033')

# What a terminal would show: colour codes and the hyperlink wrapper removed.
strip() { LC_ALL=C awk '{ gsub(/\033\]8;;[^\033]*\033\\/, ""); gsub(/\033\[[0-9;]*m/, ""); print }'; }
# vis <text>: the columns it takes, one per character whatever its bytes
vis() { printf '%s' "$1" | LC_ALL=C awk '{ gsub(/[\200-\277]/, ""); n += length($0) } END { print n + 0 }'; }

# run <payload> <extra-env...>  -> stripped output on stdout
# The script is COPIED into the scratch dir and run from there, so its
# `usage-refresh.sh` sibling is unresolvable: tests must never spawn the real
# refresher, which reads the real keychain and calls the real endpoint.
# `CC_WIDTH=0` pins the full line, whatever the width of the terminal running this.
run() { runraw "$@" | strip; }
runraw() {  # runraw <payload> <extra-env...>: the same, escape codes and all
  p=$1; shift
  H=$(mktemp -d) || exit 1
  mkdir -p "$H/.claude"
  cp "$sl" "$H/statusline.sh"
  now=$(date +%s)
  sed -e "s|__CWD__|$here|" -e "s|__T1__|$((now+7200))|" -e "s|__T2__|$((now+200000))|" \
    "$here/payloads/$p" | env HOME="$H" CC_WIDTH=0 "$@" "$shell" "$H/statusline.sh"
  rm -rf "$H"
}

check() {  # check <name> <output> <must-contain> [must-not-contain]
  name=$1 out=$2 want=$3 not=${4:-}
  case "$out" in *"$want"*) ;; *) echo "FAIL $name: missing '$want' in: $out"; fails=$((fails+1)); return;; esac
  if [ -n "$not" ]; then case "$out" in *"$not"*) echo "FAIL $name: unexpected '$not' in: $out"; fails=$((fails+1)); return;; esac; fi
  echo "ok   $name"
}

match() {  # match <name> <output> <glob>: like check, but the last argument is a pattern
  case "$2" in $3) echo "ok   $1" ;; *) echo "FAIL $1: no match for '$3' in: $2"; fails=$((fails+1)) ;; esac
}

# A check made of several cases: each case adds what went wrong to `$bad`.
verdict() { if [ -z "$2" ]; then echo "ok   $1"; else echo "FAIL $1:$2"; fails=$((fails+1)); fi; }
has() { case "$1" in *"$2"*) return 0 ;; esac; return 1; }    # has <text> <part>
like() { case "$1" in $2) return 0 ;; esac; return 1; }       # like <text> <glob>
# crlfjq <folder>: a `jq` there that ends every line with a carriage return, as a
# native Windows `jq` does
crlfjq() {
  mkdir -p "$1"
  printf '#!/bin/sh\n"%s" "$@" | awk '"'"'{ printf "%%s\\r\\n", $0 }'"'"'\n' "$(command -v jq)" > "$1/jq"; chmod +x "$1/jq"
}

# 23.5 rounds to 24 and 62.1 to 62, each with its reset stamp.
out=$(run subscription.json);           match subscription-5h   "$out" '* · 5h ??:?? 24% · 7d *'
                                        match subscription-7d   "$out" '* · 7d ??? 62%'
# The effort follows the model after one space; alone, it gets the dot before it.
                                        check model-then-effort "$out" "Opus 5 (1M) ◊high · ctx" "· ◊"
out=$(run effort-only.json);            check effort-alone      "$out" " · ◊high · ctx 880" "Opus"
# The colour bands, wherever a share is drawn: green under 50%, yellow from
# 50%, red from 80%. Each render gets a fresh `HOME`, so no record carries over.
bands() {  # bands <ctx %> <5h %> <7d %>: one render, escape codes and all
  H=$(mktemp -d); mkdir -p "$H/.claude"; cp "$sl" "$H/statusline.sh"
  printf '{"workspace":{"current_dir":"%s"},"context_window":{"total_input_tokens":5,"used_percentage":%s},"rate_limits":{"five_hour":{"used_percentage":%s,"resets_at":%s},"seven_day":{"used_percentage":%s,"resets_at":%s}}}' \
    "$H" "$1" "$2" "$(( $(date +%s) + 7200 ))" "$3" "$(( $(date +%s) + 200000 ))" | env HOME="$H" CC_WIDTH=0 "$shell" "$H/statusline.sh"
  rm -rf "$H"
}
raw=$(bands 12 49.4 80); bad=
has "$raw" "${E}[32m12%" || bad=" [ctx 12%]"
has "$raw" "${E}[32m5h " || bad="$bad [49%]"
has "$raw" "${E}[31m7d " || bad="$bad [80%]"
raw=$(bands 50 50 79)
has "$raw" "${E}[33m50%" || bad="$bad [ctx 50%]"
has "$raw" "${E}[33m5h " || bad="$bad [50%]"
has "$raw" "${E}[33m7d " || bad="$bad [79%]"
verdict colour-bands-green-yellow-red "$bad"
# The gateway cap's reset: a date in the Enterprise cap's style when it is more
# than a day away, the time of day when it is sooner.
out=$(run gateway.json);                match gateway-cap       "$out" '*· cap [0-3][0-9]/[A-Z][a-z][a-z] 78%'
H=$(mktemp -d); mkdir -p "$H/.claude"; cp "$sl" "$H/statusline.sh"
out=$(printf '{"workspace":{"current_dir":"%s"},"rate_limits":{"spend_limit":{"used_percentage":78.4,"resets_at":%s}}}' "$H" "$(( $(date +%s) + 3600 ))" \
      | env HOME="$H" CC_WIDTH=0 "$shell" "$H/statusline.sh" | strip); rm -rf "$H"
match gateway-cap-soon "$out" '*· cap [0-2][0-9]:[0-5][0-9] 78%'
# A gateway reset time that is not a whole epoch still draws the cap, with no
# stamp and nothing on stderr.
H=$(mktemp -d); mkdir -p "$H/.claude"; cp "$sl" "$H/statusline.sh"; bad=
for r in 1800000000.5 '"2026-11-01T00:00:00Z"'; do
  out=$(printf '{"workspace":{"current_dir":"%s"},"rate_limits":{"spend_limit":{"used_percentage":78.4,"resets_at":%s}}}' "$H" "$r" \
        | env HOME="$H" CC_WIDTH=0 "$shell" "$H/statusline.sh" 2>"$H/err" | strip)
  has "$out" '· cap 78%' || bad="$bad [$r: $out]"; [ -s "$H/err" ] && bad="$bad [$r, stderr: $(head -1 "$H/err")]"
done
rm -rf "$H"; verdict gateway-odd-reset-still-draws "$bad"
out=$(run apikey.json);                 check apikey-ledger     "$out" '$2.50' "· cap "
# With a cap of your own the dollars read as a share of it; the narrowest form
# keeps the share alone, under the word cap.
check apikey-ledger-cap "$(run apikey.json CC_SPEND_CAP=50)" '· $2.50/50 5%'
check apikey-ledger-cap-narrow "$(run apikey.json CC_SPEND_CAP=50 CC_WIDTH=8)" 'cap 5%' '$'
# `CC_SPEND_CAP` is a positive number or it is ignored, and it never runs as `awk`
# program text: 0 and abc draw the plain dollars, quietly, and a value written
# to run a command runs nothing.
X=$(mktemp -d); bad=
for c in 0 0.0 . abc '50;x' "1;system(\"touch $X/pwned\")"; do
  out=$(run apikey.json "CC_SPEND_CAP=$c" 2>"$X/err")
  { has "$out" '· $2.50' && ! has "$out" '%'; } || bad="$bad [$c: $out]"
  [ -s "$X/err" ] && bad="$bad [$c, stderr: $(head -1 "$X/err")]"
done
[ ! -e "$X/pwned" ] || bad="$bad [a command ran]"
has "$(run apikey.json CC_SPEND_CAP=0.5)" '· $2.50/0.5 500%' || bad="$bad [0.5: $(run apikey.json CC_SPEND_CAP=0.5)]"
rm -rf "$X"
verdict spend-cap-is-checked "$bad"
out=$(run enterprise.json);             check gate-off-default  "$out" '$0.80' "· cap "
# Forced on with no snapshot yet: the cap segment, and no dollars. This copy of
# the script has no refresher beside it, so it says so.
out=$(run enterprise.json CC_ENTERPRISE=1); check gate-on-nocache "$out" '· cap no refresher' '$0.80'

# Numbers in any locale. Under a comma-decimal locale the macOS shell's printf
# rejects 23.5 and `awk` prints 12,40. The figures must still read 24%, 42% and
# $2.50, through `LANG` and through `LC_ALL`, and the state files must keep a
# point: a pace saved as 0,0022 is rejected by the next render, which then
# starts the record over.
de=; for l in de_DE.UTF-8 de_DE.utf8; do [ "$(LC_ALL=$l locale charmap 2>/dev/null)" = UTF-8 ] && { de=$l; break; }; done
de_run() {  # de_run <payload> [VAR=value...]: one render with $v set to $de, in $L
  p=$1; shift
  sed -e "s|__CWD__|$here|" -e "s|__T1__|$((now+7200))|" -e "s|__T2__|$((now+200000))|" "$here/payloads/$p" \
    | env -u LC_ALL -u LC_NUMERIC -u LC_CTYPE -u LANG HOME="$L" CC_WIDTH=0 "$v=$de" "$@" "$shell" "$L/statusline.sh" 2>>"$L/err" | strip
}
if [ -z "$de" ]; then
  echo "ok   comma-locale-keeps-figures (skipped: no de_DE.UTF-8 locale here)"
else
  bad=
  for v in LANG LC_ALL; do
    L=$(mktemp -d); mkdir -p "$L/.claude"; cp "$sl" "$L/statusline.sh"; : > "$L/err"; now=$(date +%s)
    # a record 1000 s old at 20%, so this render's 24% is a rise with a pace to save
    printf '%s %s %s %s 20 0\n' $((now + 7200)) $((now - 1000)) $((now - 1000)) $((now - 1000)) > "$L/.claude/.rl-5h-state"
    out=$(de_run subscription.json)
    like "$out" '*ctx 36.4k · 5h ??:?? 24% · 7d * 62%' || bad="$bad [$v subscription: $out]"
    set -- $(cat "$L/.claude/.rl-5h-state"); born=${2:-}
    case "${6:-}" in ''|0|*,*) bad="$bad [$v pace: ${6:-}]" ;; esac
    de_run subscription.json >/dev/null
    set -- $(cat "$L/.claude/.rl-5h-state"); [ "${2:-}" = "$born" ] || bad="$bad [$v record started over]"
    printf '{"fetched_at":%s,"spend_seen":0,"percent":42.3,"used_minor":8460,"limit_minor":20000,"severity":"ok"}\n' "$now" > "$L/.claude/.usage-cache.json"
    has "$(de_run enterprise.json CC_ENTERPRISE=1)" '· cap ' || bad="$bad [$v enterprise: no cap]"
    has "$(de_run enterprise.json CC_ENTERPRISE=1)" ' 42%' || bad="$bad [$v enterprise: no 42%]"
    has "$(cat "$L/.claude/.usage-activity")" '#total 0.800000' || bad="$bad [$v activity: $(cat "$L/.claude/.usage-activity")]"
    rm -f "$L/.claude/.usage-cache.json" "$L/.claude"/.rl-*
    has "$(de_run apikey.json)" '· $2.50' || bad="$bad [$v ledger: $(de_run apikey.json)]"
    has "$(cat "$L/.claude/.spend-ledger")" ' 2.5000' || bad="$bad [$v ledger file]"
    [ -s "$L/err" ] && bad="$bad [$v stderr: $(head -2 "$L/err")]"
    rm -rf "$L"
  done
  verdict comma-locale-keeps-figures "$bad"
fi

# A field of the wrong type (an array, an object, a string where an object
# belongs) leaves that field empty and the rest of the line intact, quietly.
H=$(mktemp -d); mkdir -p "$H/.claude"; cp "$sl" "$H/statusline.sh"; bad=
for odd in '"model":{"display_name":["a","b"]}' '"model":{"display_name":{"x":1}}' '"model":"Opus","effort":[1]' '"workspace":"/x","cwd":7'; do
  out=$(printf '{%s,"context_window":{"total_input_tokens":5},"rate_limits":{"five_hour":{"used_percentage":24,"resets_at":%s}}}' "$odd" "$(( $(date +%s) + 7200 ))" \
        | env HOME="$H" CC_WIDTH=0 "$shell" "$H/statusline.sh" 2>"$H/err" | strip)
  like "$out" '* · ctx 5 · 5h ??:?? 24%' || bad="$bad [$odd: $out]"
  [ -s "$H/err" ] && bad="$bad [$odd, stderr: $(head -1 "$H/err")]"
done
rm -rf "$H"; verdict odd-payload-fields-keep-the-line "$bad"

# enterprise with a warm cache: seed the snapshot, expect the cap segment
H=$(mktemp -d); mkdir -p "$H/.claude"; now=$(date +%s)
printf '{"fetched_at":%s,"spend_seen":0,"percent":42.3,"used_minor":8460,"limit_minor":20000,"severity":"ok"}\n' "$now" > "$H/.claude/.usage-cache.json"
cp "$sl" "$H/statusline.sh"
out=$(sed -e "s|__CWD__|$here|" "$here/payloads/enterprise.json" | env HOME="$H" CC_WIDTH=0 CC_ENTERPRISE=1 "$shell" "$H/statusline.sh" | strip)
rm -rf "$H"
check enterprise-cached "$out" "cap "; check enterprise-pct "$out" "42%"

# same seeded cache, NO env var: the latch alone must keep the branch on
H=$(mktemp -d); mkdir -p "$H/.claude"; now=$(date +%s)
printf '{"fetched_at":%s,"spend_seen":0,"percent":42.3,"used_minor":8460,"limit_minor":20000,"severity":"ok"}\n' "$now" > "$H/.claude/.usage-cache.json"
cp "$sl" "$H/statusline.sh"
out=$(sed -e "s|__CWD__|$here|" "$here/payloads/enterprise.json" | env HOME="$H" CC_WIDTH=0 "$shell" "$H/statusline.sh" | strip)
rm -rf "$H"
check enterprise-latch "$out" "42%" '$0.80'

# The reset date comes out of `monthreset()`, which needs plain POSIX arithmetic:
# bash takes `10#$m` and dash rejects it, and the checks above would still pass
# under dash with the date gone. So this one wants the date and a silent
# stderr. CI runs the whole suite under dash and under bash.
H=$(mktemp -d); mkdir -p "$H/.claude"; now=$(date +%s)
printf '{"fetched_at":%s,"spend_seen":0,"percent":42.3,"used_minor":8460,"limit_minor":20000,"severity":"ok"}\n' "$now" > "$H/.claude/.usage-cache.json"
cp "$sl" "$H/statusline.sh"
out=$(sed -e "s|__CWD__|$here|" "$here/payloads/enterprise.json" | env HOME="$H" CC_WIDTH=0 CC_ENTERPRISE=1 "$shell" "$H/statusline.sh" 2>"$H/err" | strip)
err=$(cat "$H/err"); rm -rf "$H"
match enterprise-reset-date "$out" '*cap [0-3][0-9]/[A-Z][a-z][a-z] 42%*'
check enterprise-quiet-stderr "[$err]" "[]"

# The date above only exercises the month the suite happens to run in, and a
# wrong fix that skips the leading-zero strip passes in October and fails in
# August and September (08 and 09 are bad octal). So run the real `monthreset()`,
# and the refresher's `nextmonth()` for usage credits, for all twelve months. A
# `date` shim fakes only the clock reads, in UTC for the one and in local time
# for the other.
B=$(mktemp -d); real_date=$(command -v date)
cat > "$B/date" <<'EOF'
#!/bin/sh
case "$*" in
  "-u +%Y"|"+%Y") echo "$FAKE_Y" ;;
  "-u +%m"|"+%m") echo "$FAKE_M" ;;
  *) exec "$REAL_DATE" "$@" ;;
esac
EOF
chmod +x "$B/date"
# `monthreset()` leaves the next boundary in `$mr` and this month's start in `$ms`,
# worked out from the month's length, so leap years count too.
for fn in "monthreset:-u:$sl" "nextmonth::$here/../usage-refresh.sh"; do
  f=${fn%%:*} r=${fn#*:}; u=${r%%:*}; body=$(sed -n "/^$f()/,/^}/p" "${r#*:}")
  call=$f; [ "$f" = monthreset ] && call='monthreset; printf "%s %s" "$mr" "$ms"'
  bad=
  for row in 2026-01:2026-02 2026-02:2026-03 2026-03:2026-04 2026-04:2026-05 \
             2026-05:2026-06 2026-06:2026-07 2026-07:2026-08 2026-08:2026-09 \
             2026-09:2026-10 2026-10:2026-11 2026-11:2026-12 2026-12:2027-01 \
             2028-02:2028-03 2100-02:2100-03 2000-02:2000-03; do
    cur=${row%%:*}; want=${row##*:}
    out=$(env PATH="$B:$PATH" REAL_DATE="$real_date" FAKE_Y="${cur%-*}" FAKE_M="${cur#*-}" "$shell" -c "$body; $call" 2>&1); e=${out%% *}
    got=$(date $u -r "$e" +%Y-%m 2>/dev/null || date $u -d "@$e" +%Y-%m 2>/dev/null)
    [ "$got" = "$want" ] || bad="$bad $cur=>${got:-error}"
    if [ "$f" = monthreset ]; then
      st=${out#* }; gs=$(date -u -r "$st" '+%Y-%m-%d %H:%M' 2>/dev/null || date -u -d "@$st" '+%Y-%m-%d %H:%M' 2>/dev/null)
      [ "$gs" = "$cur-01 00:00" ] || bad="$bad $cur:start=>${gs:-error}"
    fi
  done
  verdict "$f-all-months" "$bad"
done
rm -rf "$B"

# --- enterprise seat: the refresh and its failures ---
# home: a scratch `HOME` with the script copied in and a stand-in `usage-refresh.sh`
# beside it, which notes its arguments in `$H/started`, so nothing real is called.
home() {
  H=$(mktemp -d); mkdir -p "$H/.claude"; cp "$sl" "$H/statusline.sh"
  printf '#!/bin/sh\necho "$*" >> "${0%%/*}/started"\n' > "$H/usage-refresh.sh"; chmod +x "$H/usage-refresh.sh"
}
snap() {  # snap <age> <percent> [spend seen]: an enterprise snapshot
  printf '{"fetched_at":%s,"spend_seen":%s,"percent":%s,"used_minor":8400,"limit_minor":20000,"severity":"ok"}\n' \
    "$(( $(date +%s) - $1 ))" "${3:-0}" "$2" > "$H/.claude/.usage-cache.json"
}
attempt() { printf '%s\n' "$1" > "$H/.claude/.usage-attempt"; }        # attempt <epoch>: the last call
why() { printf '%s\n%s\n' "$1" "${2:-$(date +%s)}" > "$H/.claude/.usage-unavailable"; }   # why <reason> [epoch]: the last failure, and when
ent() {  # ent [VAR=value...]: one enterprise render, keeping the attempt file as it was before
  cp "$H/.claude/.usage-attempt" "$H/before" 2>/dev/null || : > "$H/before"; rm -f "$H/started"
  sed -e "s|__CWD__|$here|" "$here/payloads/enterprise.json" | env HOME="$H" CC_WIDTH=0 CC_ENTERPRISE=1 TZ=UTC "$@" "$shell" "$H/statusline.sh" | strip
}
# A start always writes the attempt time first, so an unchanged attempt file
# proves no call without waiting for one that might come late.
nocall() { cmp -s "$H/before" "$H/.claude/.usage-attempt" || { [ ! -s "$H/before" ] && [ ! -e "$H/.claude/.usage-attempt" ]; }; }
calls() { i=0; while [ ! -s "$H/started" ] && [ "$i" -lt 10 ]; do sleep 1; i=$((i + 1)); done; [ -s "$H/started" ]; }

home; bad=                       # no snapshot: the first fetch failed, and the reason shows at once
for row in 'login:cap login' 'nocurl:cap no curl' 'api:cap api moved' 'http 500:cap http 500' 'nofigure:cap no figure' 'expired:cap login' 'tls 60:cap tls' 'offline 7:cap offline'; do
  why "${row%%:*}"; attempt "$(date +%s)"; has "$(ent)" "${row#*:}" || bad="$bad ${row%%:*}"
done
verdict enterprise-first-fetch-says-why "$bad"
# The names the Enterprise path uses start empty there, so figures exported in
# the environment cannot stand in for a snapshot: with none yet, the line shows
# the placeholder, not an exported, fresh-looking 50%.
rm -f "$H/.claude/.usage-unavailable" "$H/.claude/.usage-attempt" "$H/.claude/.usage-cache.json"
out=$(ent cp=50 cu=100 cl=20000 cts="$(date +%s)" ucx=1 2>/dev/null); bad=
{ has "$out" '· cap …' && ! has "$out" '50%'; } || bad=" [drew: $out]"
verdict environment-cannot-draw-a-figure "$bad"
rm -f "$H/.claude/.usage-attempt"
# An expired token is said calmly, in dim: Claude Code renews it on its next
# request. A reply with no figure for the seat is dim too: nobody here can act.
entraw() { sed -e "s|__CWD__|$here|" "$here/payloads/enterprise.json" | env HOME="$H" CC_WIDTH=0 CC_ENTERPRISE=1 TZ=UTC "$shell" "$H/statusline.sh"; }
bad=
why expired;  attempt "$(date +%s)"; has "$(entraw)" "${E}[2mcap login" || bad=" [expired not dim]"
why nofigure; attempt "$(date +%s)"; has "$(entraw)" "${E}[2mcap no figure" || bad="$bad [no figure not dim]"
why login;    attempt "$(date +%s)"; has "$(entraw)" "${E}[33mcap login" || bad="$bad [a rejected login is no longer yellow]"
why "tls 60"; attempt "$(date +%s)"; has "$(entraw)" "${E}[33mcap tls" || bad="$bad [tls not yellow]"
why "offline 7"; attempt "$(date +%s)"; has "$(entraw)" "${E}[2mcap offline" || bad="$bad [offline not dim]"
verdict enterprise-calm-reasons-are-dim "$bad"
# With no refresher that can run (left out of a manual install, or without its
# execute bit) the line says so in yellow instead of waiting for ever, with or
# without an old snapshot; while a first fetch is on its way, a dim placeholder.
rm -f "$H/.claude/.usage-unavailable" "$H/.claude/.usage-attempt"; out=$(entraw); bad=
has "$out" "${E}[2mcap …" || bad=" [first fetch: $(printf '%s' "$out" | strip)]"
mv "$H/usage-refresh.sh" "$H/usage-refresh.off"; rm -f "$H/.claude/.usage-attempt"; out=$(entraw)
has "$out" "${E}[33mcap no refresher" || bad="$bad [none: $(printf '%s' "$out" | strip)]"
[ "$(head -1 "$H/.claude/.usage-unavailable" 2>/dev/null)" = norefresher ] || bad="$bad [not recorded]"
snap 9000 42; rm -f "$H/.claude/.usage-unavailable" "$H/.claude/.usage-attempt"
has "$(ent)" "· cap no refresher" || bad="$bad [old snapshot: $(ent)]"
verdict no-refresher-says-so "$bad"
# The same for a refresher that lost its execute bit. Skipped where a script
# that starts with #! stays executable whatever its mode (Git Bash).
cp "$H/usage-refresh.off" "$H/usage-refresh.sh"; chmod 644 "$H/usage-refresh.sh"
if [ -x "$H/usage-refresh.sh" ]; then
  echo "ok   no-refresher-not-executable (skipped: a script cannot lose its execute bit here)"
else
  rm -f "$H/.claude/.usage-unavailable" "$H/.claude/.usage-attempt"
  check no-refresher-not-executable "$(ent)" "· cap no refresher"
fi
mv -f "$H/usage-refresh.off" "$H/usage-refresh.sh"; chmod 755 "$H/usage-refresh.sh"
rm -f "$H/.claude/.usage-unavailable" "$H/.claude/.usage-cache.json" "$H/.claude/.rl-spend-state"
# After an expired token, the next look comes 2 minutes on, not 5: that try sent
# nothing, and Claude Code renews the token on its next request.
why expired; bad=
attempt $(( $(date +%s) - 60 ));  ent >/dev/null; nocall || bad=" [60 s]"
attempt $(( $(date +%s) - 130 )); ent >/dev/null; calls || bad="$bad [130 s]"
why login
attempt $(( $(date +%s) - 130 )); ent >/dev/null; nocall || bad="$bad [a rejected login waits longer]"
verdict expired-token-looks-again-soon "$bad"
rm -f "$H/.claude/.usage-unavailable"
# A snapshot with the share but without the amounts still draws the share; only
# the dollars need the amounts.
printf '{"fetched_at":%s,"spend_seen":0,"percent":42,"used_minor":null,"limit_minor":null,"severity":null}\n' "$(date +%s)" > "$H/.claude/.usage-cache.json"
attempt "$(date +%s)"; out=$(ent CC_SPEND_DOLLARS=1); bad=
{ has "$out" '42%' && ! has "$out" '$'; } || bad=" [drew: $out]"
verdict enterprise-share-without-amounts "$bad"
# `CC_SPEND_DOLLARS` adds the dollars to the monthly figure; 0 means off, as
# unset does.
snap 60 42; attempt "$(date +%s)"; bad=
has "$(ent CC_SPEND_DOLLARS=1)" 'cap 01/' && has "$(ent CC_SPEND_DOLLARS=1)" ' $84.00/200 42%' || bad=" [1: $(ent CC_SPEND_DOLLARS=1)]"
has "$(ent CC_SPEND_DOLLARS=0)" '$' && bad="$bad [0: $(ent CC_SPEND_DOLLARS=0)]"
verdict spend-dollars-0-is-off "$bad"
# One snapshot serves every session, so a lower figure in the same month is the
# server's newer word (a raised cap), drawn at once, not outvoted by the record.
snap 60 91; ent >/dev/null; snap 60 45; bad=
has "$(ent)" '45%' || bad=" [the lower figure was not drawn]"
verdict enterprise-drop-shows-at-once "$bad"
rm -f "$H/.claude/.usage-unavailable" "$H/.claude/.rl-spend-state"
# A figure carries no age, in any width: it is drawn as fetched until it is too
# old to trust, and then replaced. Here it is 33 minutes old.
snap 2000 42.3; attempt "$(date +%s)"; bad=
for w in 0 8; do out=$(ent CC_WIDTH=$w); { has "$out" 'cap ' && has "$out" '42%' && ! has "$out" '42%…'; } || bad="$bad [width $w: $out]"; done
out=$(ent CC_WIDTH=8 CC_ASCII=1); { has "$out" 'cap 42%' && ! has "$out" '42%..'; } || bad="$bad [ascii: $out]"
verdict an-old-figure-shows-no-age "$bad"
# Past three times the floor a figure is not drawn, failure or none: a 6-day-old
# 100% reads as stale, with its age, in one dim word, not as a full cap. The
# ASCII line reads the same.
snap 518400 100; attempt "$(date +%s)"; bad=
out=$(ent); { has "$out" '· cap 6d-stale' && ! has "$out" '100%'; } || bad=" [drew: $out]"
has "$(entraw)" "${E}[2mcap 6d-stale" || bad="$bad [not dim]"
has "$(ent CC_ASCII=1)" '| cap 6d-stale' || bad="$bad [ascii: $(ent CC_ASCII=1)]"
verdict old-snapshot-reads-stale "$bad"
# A snapshot is read through the same guard: an array runs nothing, quietly.
printf '{"fetched_at":%s,"spend_seen":0,"percent":["x","touch","%s/pwned"],"used_minor":8400,"limit_minor":20000}\n' "$(date +%s)" "$H" > "$H/.claude/.usage-cache.json"
attempt "$(date +%s)"; out=$(cd "$H" && ent 2>&1); bad=
{ [ ! -e "$H/pwned" ] && [ ! -e "$H/eol=1" ]; } || bad=" [it ran a command]"; has "$out" 'not found' && bad="$bad [stderr: $out]"
verdict hostile-snapshot-is-harmless "$bad"

# A 429 keeps the last figure, with the word beside it, for at least an hour,
# and no call goes out before the wait is over; past the hour, "throttled" alone.
snap 1200 91; why "throttled $(( $(date +%s) + 600 )) 1"; attempt $(( $(date +%s) - 600 ))
out=$(ent); bad=; like "$out" '*91% throttled' || bad=" [drew: $out]"; nocall || bad="$bad [called]"
snap 4000 91; has "$(ent)" 'cap throttled' || bad="$bad [past the hour]"
verdict throttled-keeps-the-figure-and-waits "$bad"
# A refresh that failed after the snapshot was fetched is said beside the
# figure at once, in the narrowest form too, whatever the figure's age: here a
# rejected login behind a 10-minute-old figure. A failure from before the
# snapshot was fetched is not.
rm -f "$H/.claude/.rl-spend-state"; snap 600 42; why login; attempt "$(date +%s)"; bad=
raw=$(entraw); out=$(printf '%s' "$raw" | strip)
like "$out" '* · cap 01/??? 42% login' || bad=" [drew: $out]"
has "$raw" "${E}[33mlogin" || bad="$bad [not yellow]"
has "$(ent CC_WIDTH=8)" 'cap 42% login' || bad="$bad [narrow: $(ent CC_WIDTH=8)]"
why login $(( $(date +%s) - 900 )); has "$(ent)" 'login' && bad="$bad [an older failure: $(ent)]"
verdict a-newer-failure-shows-beside-the-figure "$bad"
rm -f "$H/.claude/.usage-unavailable"
# At 00:10 UTC on the 1st, a snapshot fetched at 23:50 the day before is last
# month's: not drawn, however young, and a fresh one is asked for. Its spend
# seen matches, so only the month can ask. The clock is faked for date +%s
# alone, at the start of this real UTC month.
mkdir -p "$H/bin"; printf '#!/bin/sh\n[ "$*" = "+%%s" ] && [ -n "${FAKE_NOW:-}" ] && { echo "$FAKE_NOW"; exit 0; }\nexec "%s" "$@"\n' "$(command -v date)" > "$H/bin/date"; chmod +x "$H/bin/date"
m1=$(TZ=UTC date -j -f '%Y-%m-%d %H:%M:%S' "$(date -u +%Y-%m)-01 00:00:00" +%s 2>/dev/null || date -u -d "$(date -u +%Y-%m)-01 00:00:00" +%s)
printf '{"fetched_at":%s,"spend_seen":0.8,"percent":45,"used_minor":9000,"limit_minor":20000,"severity":"ok"}\n' $((m1 - 600)) > "$H/.claude/.usage-cache.json"
rm -f "$H/.claude/.usage-attempt" "$H/.claude/.usage-activity" "$H/.claude/.rl-spend-state"
out=$(ent PATH="$H/bin:$PATH" FAKE_NOW=$((m1 + 600))); bad=
has "$out" '45%' && bad=" [drew last month's figure: $out]"; calls || bad="$bad [no refresh asked]"
verdict last-months-snapshot-is-not-drawn "$bad"
rm -rf "$H/bin" "$H/.claude/.usage-cache.json"
# One call every 5 minutes at most (290 s: none, 300 s: one, with the spend total
# and version); after a rejected login, none for an hour.
rm -f "$H/.claude/.usage-unavailable"; snap 1200 91; bad=
attempt $(( $(date +%s) - 290 )); ent >/dev/null; nocall || bad=" [290 s]"
attempt $(( $(date +%s) - 300 )); ent >/dev/null; { calls && has "$(cat "$H/started")" " 2.1.252"; } || bad="$bad [300 s]"
why login; attempt $(( $(date +%s) - 400 )); ent >/dev/null; nocall || bad="$bad [login]"
why "tls 60"; attempt $(( $(date +%s) - 400 )); ent >/dev/null; nocall || bad="$bad [tls]"
why "login 1800000000000"; attempt $(( $(date +%s) - 400 )); ent >/dev/null; calls || bad="$bad [a fingerprinted login waited the hour]"
why login $(( $(date +%s) - 3700 ))
attempt $(( $(date +%s) - 400 )); ent >/dev/null; calls || bad="$bad [login after the hour]"
verdict call-gap-and-backoff "$bad"
# Spend is the trigger: a fresh snapshot is asked for again once the local
# spend since it was fetched reaches 0.25% of the cap, $0.50 of $200, and not
# before. This session has spent $0.80.
rm -f "$H/.claude/.usage-unavailable"; bad=
rm -f "$H/.claude/.usage-activity" "$H/.claude/.usage-attempt"; snap 60 42 0.4; ent >/dev/null; nocall || bad=" [asked at \$0.40 since]"
rm -f "$H/.claude/.usage-activity" "$H/.claude/.usage-attempt"; snap 60 42 0.3; ent >/dev/null; calls || bad="$bad [not asked at \$0.50 since]"
verdict spend-asks-for-a-refresh "$bad"
# `.usage-activity` forgets a session not seen for 8 days, whose cost is in the
# total already, keeps a recent one, and stamps a line from before there were
# stamps as seen now. This session's spend still adds to the total.
now=$(date +%s); snap 60 42; attempt "$now"; bad=
printf '#total 5.000000\nold 3.000000 %s\nrecent 1.000000 %s\nunstamped 1.000000\n' "$(( now - 777600 ))" "$(( now - 3600 ))" > "$H/.claude/.usage-activity"
ent >/dev/null; act=$(cat "$H/.claude/.usage-activity")
has "$act" 'old ' && bad=" [a session not seen for 9 days kept]"
has "$act" 'recent 1.000000' || bad="$bad [a recent session dropped]"
like "$act" "*unstamped 1.000000 [0-9]*" || bad="$bad [an unstamped line: $act]"
has "$act" '#total 5.800000' || bad="$bad [total: $act]"
like "$act" "*t-ent 0.800000 [0-9]*" || bad="$bad [this session unstamped]"
verdict activity-forgets-old-sessions "$bad"
# The waits after a failure, counted from when it happened: offline, only the
# 5-minute gap; an http error, 10 minutes.
snap 1200 91; bad=
why offline $(( $(date +%s) - 290 )); attempt $(( $(date +%s) - 290 )); ent >/dev/null; nocall || bad=" [offline inside the gap]"
why offline $(( $(date +%s) - 300 )); attempt $(( $(date +%s) - 300 )); ent >/dev/null; calls || bad="$bad [offline after the gap]"
why "http 500" $(( $(date +%s) - 400 )); attempt $(( $(date +%s) - 400 )); ent >/dev/null; nocall || bad="$bad [http within 10 minutes]"
why "http 500" $(( $(date +%s) - 700 )); attempt $(( $(date +%s) - 700 )); ent >/dev/null; calls || bad="$bad [http after 10 minutes]"
rm -f "$H/.claude/.usage-unavailable"
verdict failure-waits "$bad"
# The wait after a failure runs from the time written in the reason file. One
# from the future, which a clock moved back leaves behind (with the file's own
# date in the future too), is not trusted: the wait counts as over.
tstamp() { date -r "$1" +%Y%m%d%H%M.%S 2>/dev/null || date -d "@$1" +%Y%m%d%H%M.%S 2>/dev/null; }   # tstamp <epoch>: for touch -t
snap 1200 91; why offline $(( $(date +%s) + 7200 )); touch -t "$(tstamp $(( $(date +%s) + 7200 )))" "$H/.claude/.usage-unavailable"
attempt $(( $(date +%s) - 400 )); ent >/dev/null; bad=; calls || bad=" [a reason from the future held the call back]"
verdict future-reason-is-not-trusted "$bad"
# A snapshot dated in the future has no age to go by, so once a refresh has
# failed it is not drawn as current: the reason shows instead.
snap -3600 42; why login; attempt "$(date +%s)"; out=$(ent); bad=
{ has "$out" '· cap login' && ! has "$out" '42%'; } || bad=" [drew: $out]"
verdict future-snapshot-gives-way-to-a-failure "$bad"
rm -f "$H/.claude/.usage-unavailable"
# From 80% the floor is 5 minutes: a figure 4 minutes old is not asked for
# again, one 6 minutes old is. The spend seen is high, so only the age can ask.
snap 240 91 99; attempt $(( $(date +%s) - 400 )); ent >/dev/null; bad=; nocall || bad=" [4 minutes old: asked]"
snap 360 91 99; attempt $(( $(date +%s) - 400 )); ent >/dev/null; calls || bad="$bad [6 minutes old: not asked]"
verdict top-floor-is-5m "$bad"
# Through a native Windows `jq` the snapshot's last field, the spend seen at the
# last call, must still read as a number, or every render would take the spend
# for new and ask again.
crlfjq "$H/crlf"; rm -f "$H/.claude/.usage-attempt" "$H/.claude/.usage-activity"; snap 60 42 0.8
ent PATH="$H/crlf:$PATH" >/dev/null; bad=; nocall || bad=" [called]"
verdict crlf-jq-reads-the-spend-seen "$bad"
# The refresher runs in a session of its own, out of reach of the signal Claude
# Code sends a replaced render's process group. Needs a `ps` that takes -o.
if ps -o pgid= -p $$ >/dev/null 2>&1; then
  printf '#!/bin/sh\nps -o pgid= -p $$ > "${0%%/*}/started"\n' > "$H/usage-refresh.sh"
  rm -f "$H/.claude/.usage-attempt"; snap 1200 91; ent >/dev/null; bad=
  calls || bad=" [no start]"
  [ "$(tr -d ' ' < "$H/started" 2>/dev/null)" != "$(ps -o pgid= -p $$ | tr -d ' ')" ] || bad="$bad [same group]"
  verdict refresher-runs-in-its-own-group "$bad"
  printf '#!/bin/sh\necho "$*" >> "${0%%/*}/started"\n' > "$H/usage-refresh.sh"
else
  echo "ok   refresher-runs-in-its-own-group (skipped: ps here cannot print a process group)"
fi
# A folder the attempt time cannot be written to means no call at all, not one
# per render. Skipped where a read-only folder is still writable (root, Windows).
snap 1200 91; attempt $(( $(date +%s) - 400 )); chmod 555 "$H/.claude"
if ( : > "$H/.claude/.probe" ) 2>/dev/null; then
  rm -f "$H/.claude/.probe"; chmod 755 "$H/.claude"
  echo "ok   unwritable-state-means-no-call (skipped: a read-only folder is writable here)"
else
  ent >/dev/null; ent >/dev/null; sleep 2; chmod 755 "$H/.claude"
  check unwritable-state-means-no-call "$(cat "$H/started" 2>/dev/null)" "" "2.1"
fi
# A read-only config folder still draws the line, on the ledger and on the
# enterprise path: the state files are only missed. Skipped where a read-only
# folder is still writable (root, Windows).
X=$(mktemp -d); mkdir -p "$X/.claude"; cp "$sl" "$X/statusline.sh"; chmod 555 "$X/.claude"
if ( : > "$X/.claude/.probe" ) 2>/dev/null; then
  rm -f "$X/.claude/.probe"; echo "ok   read-only-folder-still-draws (skipped: a read-only folder is writable here)"
else
  bad=
  out=$(sed -e "s|__CWD__|$here|" "$here/payloads/apikey.json" | env HOME="$X" CC_WIDTH=0 "$shell" "$X/statusline.sh" 2>/dev/null | strip)
  has "$out" '· ctx 880 · $2.50' || bad=" [ledger: $out]"
  out=$(sed -e "s|__CWD__|$here|" "$here/payloads/enterprise.json" | env HOME="$X" CC_WIDTH=0 CC_ENTERPRISE=1 "$shell" "$X/statusline.sh" 2>/dev/null | strip)
  has "$out" '· ctx 12.0k' || bad="$bad [enterprise: $out]"
  verdict read-only-folder-still-draws "$bad"
fi
chmod 755 "$X/.claude"; rm -rf "$X"
# Times from the future (the clock moved back) are not trusted: a 30-day wait,
# a call dated tomorrow, a snapshot dated in an hour (drawn as new and asked
# again; its spend_seen is high, so only the date can ask).
now=$(date +%s); snap 1200 91; bad=
why "throttled $((now + 2592000)) 1"; attempt $((now - 400)); ent >/dev/null; calls || bad=" [30-day wait]"
rm -f "$H/.claude/.usage-unavailable"; attempt $((now + 86400)); ent >/dev/null; calls || bad="$bad [call tomorrow]"
snap -3600 42 99; attempt $((now - 400)); out=$(ent)
{ has "$out" 'cap 01/' && has "$out" '42%'; } || bad="$bad [snapshot: $out]"; calls || bad="$bad [snapshot not asked]"
verdict future-times-not-trusted "$bad"
# CC_USAGE_FLOOR: whole seconds, at least 300, no octal. The floor shows in when
# a figure is asked for again; the spend seen is high, so only the age can ask.
rm -f "$H/.claude/.usage-unavailable"; bad=
snap 400 42 99; attempt $(( $(date +%s) - 400 )); out=$(ent CC_USAGE_FLOOR=30m)     # not a number: 1800
{ has "$out" '42%' && nocall; } || bad=" [30m: $out]"
snap 200 42 99; attempt $(( $(date +%s) - 400 )); out=$(ent CC_USAGE_FLOOR=60)      # under 300: 300
{ has "$out" '42%' && nocall; } || bad="$bad [60: $out]"
snap 400 42 99; attempt $(( $(date +%s) - 400 )); out=$(ent CC_USAGE_FLOOR=0900)    # 900, not bad octal
{ has "$out" '42%' && nocall; } || bad="$bad [0900: $out]"
snap 1000 42 99; attempt $(( $(date +%s) - 400 )); ent CC_USAGE_FLOOR=0900 >/dev/null; calls || bad="$bad [0900, past the floor: not asked]"
verdict floor-setting-is-checked "$bad"
rm -rf "$H"
# A machine that moved from an enterprise seat to Pro or Max keeps the latch
# file. Recent 5-hour windows keep a new chat's first render (no limits yet) off
# the enterprise path: no cap, no call.
home; snap 9000 42; printf '%s 30\n' "$(date +%s)" > "$H/.claude/.rl-5h-state"
out=$(printf '{"session_id":"t","version":"2.1.287","workspace":{"current_dir":"%s"},"cost":{"total_cost_usd":0}}' "$H" \
      | env HOME="$H" CC_WIDTH=0 "$shell" "$H/statusline.sh" | strip)
sleep 1; bad=; { has "$out" '⌂' && ! has "$out" 'cap '; } || bad=" [drew: $out]"; [ ! -e "$H/started" ] || bad="$bad [called]"
verdict plan-windows-beat-the-latch "$bad"
rm -rf "$H"
# The latch holds for a snapshot under 8 days old. A 40-day-old one on a machine
# now on an API key gives way to the ledger, with no call; `.claude.json` naming
# an enterprise seat still keeps the path on, whatever the snapshot's age.
home; snap 60 42
touch -t "$(tstamp $(( $(date +%s) - 3456000 )))" "$H/.claude/.usage-cache.json"; bad=
out=$(sed -e "s|__CWD__|$here|" "$here/payloads/apikey.json" | env HOME="$H" CC_WIDTH=0 "$shell" "$H/statusline.sh" | strip)
{ has "$out" '· $2.50' && ! has "$out" 'cap'; } || bad=" [40 days: $out]"; sleep 1; [ ! -e "$H/started" ] || bad="$bad [called]"
touch "$H/.claude/.usage-cache.json"; attempt "$(date +%s)"
has "$(sed -e "s|__CWD__|$here|" "$here/payloads/apikey.json" | env HOME="$H" CC_WIDTH=0 "$shell" "$H/statusline.sh" | strip)" '· cap ' || bad="$bad [fresh latch]"
touch -t "$(tstamp $(( $(date +%s) - 3456000 )))" "$H/.claude/.usage-cache.json"; printf '{"seatTier":"enterprise_usage_based"}\n' > "$H/.claude.json"
has "$(sed -e "s|__CWD__|$here|" "$here/payloads/apikey.json" | env HOME="$H" CC_WIDTH=0 "$shell" "$H/statusline.sh" | strip)" '· cap ' || bad="$bad [named seat]"
verdict latch-holds-for-8-days "$bad"
rm -rf "$H"
# One folder per login: with `CLAUDE_CONFIG_DIR` set, the state lands there, and
# an enterprise seat is told from that folder's `.claude.json`, with its files
# beside it. Nothing lands in `~/.claude`.
X=$(mktemp -d); mkdir -p "$X/home/.claude" "$X/work" "$X/seat"; cp "$sl" "$X/statusline.sh"; bad=
printf '{"session_id":"s","workspace":{"current_dir":"%s"},"rate_limits":{"five_hour":{"used_percentage":30,"resets_at":%s}}}' "$X" "$(( $(date +%s) + 3600 ))" \
  | env HOME="$X/home" CC_WIDTH=0 CLAUDE_CONFIG_DIR="$X/work" "$shell" "$X/statusline.sh" >/dev/null
[ -s "$X/work/.rl-5h-state" ] || bad=" [no 5-hour state in the folder]"
printf '{"seatTier":"enterprise_usage_based"}\n' > "$X/seat/.claude.json"
printf '{"session_id":"e","workspace":{"current_dir":"%s"},"cost":{"total_cost_usd":0.5}}' "$X" \
  | env HOME="$X/home" CC_WIDTH=0 CLAUDE_CONFIG_DIR="$X/seat" "$shell" "$X/statusline.sh" >/dev/null
{ [ -e "$X/seat/.usage-activity" ] && [ -e "$X/seat/.usage-attempt" ]; } || bad="$bad [enterprise files: $(ls -A "$X/seat" | tr '\n' ' ')]"
[ -z "$(ls -A "$X/home/.claude")" ] || bad="$bad [wrote in ~/.claude: $(ls -A "$X/home/.claude" | tr '\n' ' ')]"
verdict state-lands-in-the-config-folder "$bad"
rm -rf "$X"

# `CC_ENTERPRISE=0` keeps the login out of it: with a leftover snapshot and a
# `.claude.json` naming an enterprise seat, no cap segment, no attempt written and
# no refresher started. The ledger draws the dollars instead.
home; snap 60 42; printf '{"seatTier":"enterprise_usage_based"}\n' > "$H/.claude.json"; bad=
out=$(sed -e "s|__CWD__|$here|" "$here/payloads/enterprise.json" | env HOME="$H" CC_WIDTH=0 CC_ENTERPRISE=0 "$shell" "$H/statusline.sh" | strip)
{ has "$out" '· $0.80' && ! has "$out" '· cap '; } || bad=" [drew: $out]"
[ -e "$H/.claude/.usage-attempt" ] && bad="$bad [an attempt was written]"
sleep 1; [ -e "$H/started" ] && bad="$bad [the refresher started]"
verdict enterprise-0-sends-nothing "$bad"
rm -rf "$H"
# A plan's first render in a new chat, before Claude Code has limits to pass,
# shows no dollars: a recent 5-hour record says the seat is a subscription.
H=$(mktemp -d); mkdir -p "$H/.claude"; cp "$sl" "$H/statusline.sh"
printf '%s 1800000000 1800000000 1800000000 30 0\n' "$(( $(date +%s) + 3600 ))" > "$H/.claude/.rl-5h-state"
out=$(printf '{"session_id":"n","workspace":{"current_dir":"%s"},"cost":{"total_cost_usd":0.5}}' "$H" | env HOME="$H" CC_WIDTH=0 "$shell" "$H/statusline.sh" | strip)
check new-chat-on-a-plan-shows-no-dollars "$out" '⌂' '$'
rm -rf "$H"
# The ledger adds up every session of the period ($2.50 and $1.00 read $3.50),
# drops a line from an earlier period, names the period `CC_SPEND_PERIOD` asks
# for, and reads $42.60 against a cap of 50 as 85%.
L=$(mktemp -d); mkdir -p "$L/.claude"; cp "$sl" "$L/statusline.sh"; bad=
lpay() {  # lpay <session> <usd> [VAR=value...]: one API-key render
  lp_s=$1 lp_u=$2; shift 2
  printf '{"session_id":"%s","workspace":{"current_dir":"%s"},"cost":{"total_cost_usd":%s}}' "$lp_s" "$L" "$lp_u" \
    | env HOME="$L" CC_WIDTH=0 "$@" "$shell" "$L/statusline.sh" | strip
}
printf '197001 old 99.0000\n' > "$L/.claude/.spend-ledger"
lpay a 2.5 >/dev/null; out=$(lpay b 1)
has "$out" '· $3.50' || bad=" [two sessions: $out]"
grep -q '^197001 ' "$L/.claude/.spend-ledger" && bad="$bad [an earlier period kept]"
lpay a 2.5 >/dev/null; has "$(lpay b 1.25)" '· $3.75' || bad="$bad [a session that spent more]"
rm -f "$L/.claude/.spend-ledger"; lpay a 1 CC_SPEND_PERIOD=day >/dev/null
grep -q "^$(date +%Y%m%d) a " "$L/.claude/.spend-ledger" || bad="$bad [day: $(cat "$L/.claude/.spend-ledger")]"
rm -f "$L/.claude/.spend-ledger"; has "$(lpay a 42.6 CC_SPEND_CAP=50)" '· $42.60/50 85%' || bad="$bad [cap: $(lpay a 42.6 CC_SPEND_CAP=50)]"
verdict ledger-adds-sessions-and-periods "$bad"
# A session open across the turn of its period (midnight, the week, the 1st)
# counts only what it spends after it: its line from the last period is its
# base. Another session's line from the last period is its base too, and not
# counted. A line not seen for 8 days goes.
now=$(date +%s); rm -f "$L/.claude"/.rl-*; bad=
printf '20000101 s 40.0000 0.0000 %s\n20000101 b 10.0000 0.0000 %s\n20000101 z 5.0000 0.0000 %s\n' \
  "$now" "$now" "$(( now - 777600 ))" > "$L/.claude/.spend-ledger"
out=$(lpay s 40 CC_SPEND_CAP=50); has "$out" '· $0.00/50 0%' || bad=" [no spend since: $out]"
out=$(lpay s 42.5 CC_SPEND_CAP=50); has "$out" '· $2.50/50 5%' || bad="$bad [after spend: $out]"
out=$(lpay b 13 CC_SPEND_CAP=50); has "$out" '· $5.50/50 11%' || bad="$bad [the other session: $out]"
grep -q ' z ' "$L/.claude/.spend-ledger" && bad="$bad [a line not seen for 8 days kept]"
verdict ledger-counts-only-this-periods-spend "$bad"
# With a cap the ledger keeps a record of its own, apart from the gateway's and
# the Enterprise cap's.
rm -f "$L/.claude"/.rl-*; lpay a 42.6 CC_SPEND_CAP=50 >/dev/null; bad=
[ -e "$L/.claude/.rl-ledger-state" ] || bad=" [no ledger record: $(ls -A "$L/.claude" | tr '\n' ' ')]"
[ -e "$L/.claude/.rl-spend-state" ] && bad="$bad [it wrote the spend record]"
verdict ledger-keeps-a-record-of-its-own "$bad"
rm -rf "$L"
# A record with a field such as 08, which arithmetic would read as bad octal and
# end the script under dash, is started over: the window still draws, quietly.
H=$(mktemp -d); mkdir -p "$H/.claude"; cp "$sl" "$H/statusline.sh"; r=$(( $(date +%s) + 3600 ))
printf '%s 08 08 08 09 0\n' "$r" > "$H/.claude/.rl-5h-state"
out=$(printf '{"workspace":{"current_dir":"%s"},"rate_limits":{"five_hour":{"used_percentage":30,"resets_at":%s}}}' "$H" "$r" \
      | env HOME="$H" CC_WIDTH=0 "$shell" "$H/statusline.sh" 2>"$H/err" | strip); bad=
has "$out" '· 5h ' || bad=" [drew: $out]"; [ -s "$H/err" ] && bad="$bad [stderr: $(head -1 "$H/err")]"
verdict corrupt-record-starts-over "$bad"
rm -rf "$H"

# Behind a gateway the refresher never runs, not even for a full 5-hour window
# in the same payload: no attempt written, no refresher started, no credits.
home; bad=
out=$(printf '{"workspace":{"current_dir":"%s"},"rate_limits":{"spend_limit":{"used_percentage":40,"resets_at":%s},"five_hour":{"used_percentage":100,"resets_at":%s}}}' \
        "$H" "$(( $(date +%s) + 200000 ))" "$(( $(date +%s) + 3600 ))" | env HOME="$H" CC_WIDTH=0 "$shell" "$H/statusline.sh" | strip)
has "$out" '¤' && bad=" [drew: $out]"; [ -e "$H/.claude/.usage-attempt" ] && bad="$bad [an attempt was written]"
sleep 1; [ -e "$H/started" ] && bad="$bad [the refresher started]"
verdict gateway-never-starts-the-refresher "$bad"
rm -rf "$H"
# A gateway session's first renders come before its first reply and carry no
# limits. With a gateway record from the last 8 days they draw no ledger, even
# with `CC_SPEND_CAP` set, and leave the gateway's record alone.
H=$(mktemp -d); mkdir -p "$H/.claude"; cp "$sl" "$H/statusline.sh"; bad=
printf '{"session_id":"g","workspace":{"current_dir":"%s"},"rate_limits":{"spend_limit":{"used_percentage":40,"resets_at":%s}}}' "$H" "$(( $(date +%s) + 200000 ))" \
  | env HOME="$H" CC_WIDTH=0 "$shell" "$H/statusline.sh" >/dev/null
before=$(cat "$H/.claude"/.rl-*-state 2>/dev/null)
out=$(printf '{"session_id":"g2","workspace":{"current_dir":"%s"},"cost":{"total_cost_usd":0}}' "$H" | env HOME="$H" CC_WIDTH=0 CC_SPEND_CAP=50 "$shell" "$H/statusline.sh" | strip)
has "$out" '$' && bad=" [drew the ledger: $out]"
[ "$(cat "$H/.claude"/.rl-*-state 2>/dev/null)" = "$before" ] || bad="$bad [a record changed: $(cat "$H/.claude"/.rl-*-state)]"
rm -rf "$H"; verdict gateway-first-renders-draw-no-ledger "$bad"

# --- narrow terminals ---
# A scratch repository gives the git group a known branch, written by hand so a
# non-ASCII name reaches the file as bytes, with no argument conversion on Windows.
N=$(mktemp -d); mkdir -p "$N/home/.claude" "$N/repo" "$N/a-very-long-folder-name"
git -C "$N/repo" init -q 2>/dev/null
branch() { printf 'ref: refs/heads/%s\n' "$1" > "$N/repo/.git/HEAD"; }
cp "$sl" "$N/statusline.sh"
now=$(date +%s)
npay() {  # npay <cwd>: a subscription payload with every group in it
  printf '{"session_id":"t-narrow","version":"2.1.287","model":{"display_name":"Opus 5 (1M context)"},"effort":{"level":"high"},"workspace":{"current_dir":"%s"},"context_window":{"total_input_tokens":36400,"used_percentage":17.6},"rate_limits":{"five_hour":{"used_percentage":24,"resets_at":%s},"seven_day":{"used_percentage":62,"resets_at":%s}}}' \
    "$1" "$((now+7200))" "$((now+200000))"
}
shown() { npay "${2:-$N/repo}" | env HOME="$N/home" LC_ALL=C CC_WIDTH="$1" "$shell" "$N/statusline.sh" | strip; }   # shown <width> [cwd]
fromcols() {  # fromcols <COLUMNS> [CC_WIDTH]: as Claude Code would have it drawn
  npay "$N/repo" | env -u CC_WIDTH HOME="$N/home" LC_ALL=C COLUMNS="$1" ${2:+CC_WIDTH="$2"} "$shell" "$N/statusline.sh" | strip
}
# The ladder, widest first (??:?? the reset time, ??? the weekday). Each form
# appears exactly when the one before stops fitting, and fills its width to the
# last column. The budget alone stays at any width; its 9 columns are counted
# by hand, which checks the measuring itself.
branch feat/a-long-branch-name-here
w=200 bad=
for form in \
  'git:(feat/a-long-branch-name-here) ✓ · Opus 5 (1M) ◊high · ctx 36.4k 18% · 5h ??:?? 24% · 7d ??? 62%' \
  'feat/a-long-branch-name-here ✓ · Opus 5 (1M) ◊high · ctx 36.4k 18% · 5h ??:?? 24% · 7d ??? 62%' \
  'feat/a-long-branch-name-here ✓ Opus 5 (1M) ◊high ctx 36.4k 18% 5h ??:?? 24% 7d ??? 62%' \
  'feat/a-long-branch-name-here ✓ Opus 5 ◊high ctx 18% 5h ??:?? 24% 7d ??? 62%' \
  'a-long-branc… ✓ Opus 5 ◊high ctx 18% 5h ??:?? 24% 7d ??? 62%' \
  'a-long-branc… ✓ Opus 5 ◊high ctx 18% 5h 24% 7d 62%' \
  'a-long-branc… ✓ ctx 18% 5h 24% 7d 62%' \
  'ctx 18% 5h 24% 7d 62%' \
  '5h 24% 7d 62%'
do
  out=$(shown "$w"); v=$(vis "$out")
  like "$out" "$form" || bad="$bad [at width $w: $out]"
  { [ "$v" -le "$w" ] && [ "$(shown "$v")" = "$out" ]; } || bad="$bad [the $v-column form does not fill its width]"
  w=$((v - 1))
done
[ "$v" = 13 ] || bad="$bad [the last form counts $v columns, not 13]"
[ "$(shown 1)" = '5h 24% 7d 62%' ] || bad="$bad [width 1 lost the budget]"
verdict narrow-ladder "$bad"
# The width is `COLUMNS` less the 4 columns round the status line box, unless
# `CC_WIDTH` says otherwise: a width, a negative margin, 0 for off. Form 5 needs 50.
f5='a-long-branc… ✓ Opus 5 ◊high ctx 18% 5h 24% 7d 62%' f6='a-long-branc… ✓ ctx 18% 5h 24% 7d 62%'
full='git:(feat/a-long-branch-name-here) ✓ · *'; bad=
for row in "54||$f5" "53||$f6" "62|-10|$f5" "200|50|$f5" "200|0|$full" "0||$full" "54|abc|$f5" "058|-08|$f5"; do
  c=${row%%|*} r=${row#*|}; wv=${r%%|*} want=${r#*|}
  got=$(fromcols "$c" "$wv"); like "$got" "$want" || bad="$bad [COLUMNS=$c CC_WIDTH=$wv: $got]"
done
like "$(npay "$N/repo" | env -u CC_WIDTH -u COLUMNS HOME="$N/home" LC_ALL=C "$shell" "$N/statusline.sh" | strip)" "$full" || bad="$bad [no COLUMNS]"
verdict narrow-width-rules "$bad"
# A long name is cut to 12 characters and an ellipsis, a folder's too. A name
# outside ASCII is never cut by a shell that counts bytes: whole in the C locale,
# valid UTF-8 in a UTF-8 one (this name's 12th byte is inside a letter).
bad=
[ "$(shown 36 "$N/a-very-long-folder-name")" = '⌂a-very-long-… ctx 18% 5h 24% 7d 62%' ] || bad=" [folder]"
branch feat/zażółć-gęślą-jaźń-długa
[ "$(shown 47)" = 'zażółć-gęślą-jaźń-długa ✓ ctx 18% 5h 24% 7d 62%' ] || bad="$bad [C locale]"
branch feat/łódź-źdźbło-żółw
verdict narrow-names-are-cut-safely "$bad"
# In a UTF-8 locale the cut falls between characters: the line stays valid UTF-8.
u8=; for l in C.UTF-8 en_US.UTF-8 C.utf8 en_US.utf8; do [ "$(LC_ALL=$l locale charmap 2>/dev/null)" = UTF-8 ] && { u8=$l; break; }; done
if ! command -v iconv >/dev/null 2>&1 || [ -z "$u8" ]; then
  echo "ok   narrow-cut-stays-valid-utf8 (skipped: no iconv or no UTF-8 locale here)"
else
  bad=; npay "$N/repo" | env HOME="$N/home" LC_ALL="$u8" CC_WIDTH=44 "$shell" "$N/statusline.sh" 2>/dev/null \
    | iconv -f UTF-8 -t UTF-8 >/dev/null 2>&1 || bad=" [invalid UTF-8 under $u8]"
  verdict narrow-cut-stays-valid-utf8 "$bad"
fi
rm -rf "$N"

# A native Windows `jq` ends its output with a carriage return. It must land in
# the unread field at the end of the one `jq` call, not in the version the
# refresher is handed for its User-Agent.
home; J=$(mktemp -d); crlfjq "$J"
sed -e "s|__CWD__|$here|" "$here/payloads/enterprise.json" | env HOME="$H" PATH="$J:$PATH" CC_WIDTH=0 CC_ENTERPRISE=1 "$shell" "$H/statusline.sh" >/dev/null
bad=; calls || bad=" [no start]"
got=$(cat "$H/started" 2>/dev/null); cr=$(printf '\r')
case "$got" in
  *"$cr"*) bad="$bad [a carriage return reached the arguments]" ;;
  "0.800000 2.1.252") ;;
  *) bad="$bad [started with: $got]" ;;
esac
verdict crlf-jq-keeps-the-last-field "$bad"
rm -rf "$J" "$H"
# A folder path with control characters in it (a BEL would end the folder link
# and start a forged one) loses them before the link is built: no sequence can
# be forged, and no BEL or ESC of its own reaches the terminal.
H=$(mktemp -d); mkdir -p "$H/.claude"; cp "$sl" "$H/statusline.sh"
raw=$(printf '{"workspace":{"current_dir":"/tmp/x\\u0007\\u001b]8;;https://evil.example/\\u0007y"}}' | env HOME="$H" CC_WIDTH=0 "$shell" "$H/statusline.sh")
rm -rf "$H"
bad=; { has "$raw" "${E}]8;;https" || has "$raw" "$(printf '\007')"; } && bad=" [a forged link: $(printf '%s' "$raw" | LC_ALL=C od -c | head -3 | tr -s ' ')]"
verdict folder-path-with-control-characters-cannot-forge-a-link "$bad"
# The C1 controls too (U+0080 to U+009F, here CSI, NEL and OSC), which a shell
# that counts bytes, or any shell in the C locale, does not see as controls.
H=$(mktemp -d); mkdir -p "$H/.claude"; cp "$sl" "$H/statusline.sh"
raw=$(printf '{"workspace":{"current_dir":"/tmp/a\\u009b31mb"},"model":{"display_name":"Opus\\u0085 5"},"effort":{"level":"hi\\u009dgh"}}' | env HOME="$H" CC_WIDTH=0 "$shell" "$H/statusline.sh")
rm -rf "$H"; bad=
for c in '\302\233' '\302\205' '\302\235'; do has "$raw" "$(printf "$c")" && bad="$bad [$c got through]"; done
[ "$(printf '%s' "$raw" | strip)" = '⌂a31mb · Opus 5 ◊high' ] || bad="$bad [drew: $(printf '%s' "$raw" | strip)]"
verdict names-lose-c1-controls "$bad"
# The folder, model and effort names lose their control characters, so none of
# them can drive the terminal: no clipboard write (OSC 52), no screen clear, no
# BEL. The script's own colour and link codes stay.
H=$(mktemp -d); mkdir -p "$H/.claude"; cp "$sl" "$H/statusline.sh"
raw=$(printf '{"workspace":{"current_dir":"/tmp/a\\u001b]52;c;aGk=\\u0007b"},"model":{"display_name":"Opus\\u001b]52;c;aGk=\\u0007 5"},"effort":{"level":"hi\\u001b[2Jgh"}}' \
      | env HOME="$H" CC_WIDTH=0 "$shell" "$H/statusline.sh")
rm -rf "$H"; bad=
{ has "$raw" "${E}]52" || has "$raw" "${E}[2J" || has "$raw" "$(printf '\007')"; } && bad=" [a control character got through]"
[ "$(printf '%s' "$raw" | strip)" = '⌂a]52;c;aGk=b · Opus]52;c;aGk= 5 ◊hi[2Jgh' ] || bad="$bad [drew: $(printf '%s' "$raw" | strip)]"
verdict names-lose-control-characters "$bad"
# git's ownership guard stays on. A repository owned by another account is
# refused, so its core.fsmonitor command never runs, and the line shows the
# folder. `GIT_TEST_ASSUME_DIFFERENT_OWNER` is git's own switch for testing this.
# The user's and the system's git config are left out: a CI runner's trusts
# every folder (`safe.directory=*`), which would skip the check.
O=$(mktemp -d); mkdir -p "$O/home/.claude"; cp "$sl" "$O/statusline.sh"; git init -q "$O/repo" 2>/dev/null
printf '#!/bin/sh\ntouch "%s/ran"\n' "$O" > "$O/mon"; chmod +x "$O/mon"; git -C "$O/repo" config core.fsmonitor "$O/mon"
owner="GIT_TEST_ASSUME_DIFFERENT_OWNER=1 GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1"
if env $owner git -C "$O/repo" rev-parse --git-dir >/dev/null 2>&1; then
  echo "ok   foreign-repo-shows-the-folder (skipped: this git does not check who owns a repository)"
else
  out=$(printf '{"workspace":{"current_dir":"%s/repo"}}' "$O" | env HOME="$O/home" CC_WIDTH=0 $owner "$shell" "$O/statusline.sh" | strip)
  bad=; [ "$out" = '⌂repo' ] || bad=" [drew: $out]"; [ ! -e "$O/ran" ] || bad="$bad [the repository's fsmonitor ran]"
  verdict foreign-repo-shows-the-folder "$bad"
fi
rm -rf "$O"
# A render takes no lock in the repository. After a file is touched, git status
# would refresh the index and write it back, and a git commit at that moment
# fails on index.lock.
I=$(mktemp -d); mkdir -p "$I/home/.claude"; cp "$sl" "$I/statusline.sh"; git init -q "$I/repo" 2>/dev/null
printf 'a\n' > "$I/repo/f"; git -C "$I/repo" add f; git -C "$I/repo" -c user.name=t -c user.email=t@t commit -qm x 2>/dev/null
touch -t 202001010000 "$I/repo/f"
idx() { printf '%s %s' "$(ls -i "$I/repo/.git/index" | awk '{print $1}')" "$(cksum < "$I/repo/.git/index")"; }
before=$(idx)
out=$(printf '{"workspace":{"current_dir":"%s/repo"}}' "$I" | env HOME="$I/home" CC_WIDTH=0 "$shell" "$I/statusline.sh" | strip)
bad=; [ "$(idx)" = "$before" ] || bad=" [the index was rewritten]"; has "$out" 'git:(' || bad="$bad [drew: $out]"
verdict render-leaves-the-index-alone "$bad"
rm -rf "$I"

# --- `usage-refresh.sh` itself ---
# `curl` and `security` are shims first on `PATH`, so the real keychain and the
# real endpoint cannot be reached. The `curl` shim records its arguments and
# standard input, then answers from `FAKE_CURL_*` (body, headers, http code, a
# delay, or an exit status as if the request failed).
R=$(mktemp -d); RH="$R/home"; mkdir -p "$R/bin" "$R/log" "$RH/.claude"
cat > "$R/bin/curl" <<'EOF'
#!/bin/sh
# Like `curl`, read `~/.curlrc` unless `-q` is the first argument. Of its options this
# stand-in honours one, trace-ascii, which copies what is sent to a file.
trace=; [ "${1:-}" != -q ] && [ -r "$HOME/.curlrc" ] && trace=$(sed -n 's/^trace-ascii *= *//p' "$HOME/.curlrc")
for a in "$@"; do printf '%s\n' "$a"; done > "$FAKE_LOG/argv"
echo x >> "$FAKE_LOG/calls"
cat > "$FAKE_LOG/stdin"
[ -n "$trace" ] && cp "$FAKE_LOG/stdin" "$trace"
out= hdr=
while [ $# -gt 0 ]; do case "$1" in -o) out=$2 ;; -D) hdr=$2 ;; esac; shift; done
echo "$$" > "$FAKE_LOG/curl.pid"
[ -n "${FAKE_CURL_SLEEP:-}" ] && sleep "$FAKE_CURL_SLEEP"
[ -n "${FAKE_CURL_EXIT:-}" ] && exit "$FAKE_CURL_EXIT"
# Like a native `curl.exe` under Git Bash, which cannot open a path that holds an
# apostrophe: such a path is handed over unconverted.
case "$out$hdr" in *\'*) exit 23 ;; esac
[ -n "$out" ] && printf '%s' "${FAKE_CURL_BODY:-}" > "$out"
[ -n "$hdr" ] && printf '%s' "${FAKE_CURL_HEADERS:-}" > "$hdr"
printf '%s' "${FAKE_CURL_CODE:-200}"
EOF
# The security shim records its arguments too. With `FAKE_SERVICE` set it holds
# only that item, as a keychain with one login would; with `FAKE_ACCOUNT` set, the
# item is that account's, so a lookup for another account finds nothing and one
# that names no account finds it. `FAKE_EXPIRES` adds an `expiresAt` to the record.
cat > "$R/bin/security" <<'EOF'
#!/bin/sh
for a in "$@"; do printf '%s\n' "$a"; done > "$FAKE_LOG/security.argv"
s= ac=; while [ $# -gt 0 ]; do case "$1" in -s) s=$2 ;; -a) ac=$2 ;; esac; shift; done
[ -z "${FAKE_SERVICE:-}" ] || [ "$s" = "$FAKE_SERVICE" ] || exit 44
[ -z "${FAKE_ACCOUNT:-}" ] || [ -z "$ac" ] || [ "$ac" = "$FAKE_ACCOUNT" ] || exit 44
x=; [ -n "${FAKE_EXPIRES:-}" ] && x=",\"expiresAt\":$FAKE_EXPIRES"
printf '{"claudeAiOauth":{"accessToken":"%s","refreshToken":"FAKE-REFRESH-TOKEN"%s}}\n' "$FAKE_TOKEN" "$x"
EOF
chmod +x "$R/bin/curl" "$R/bin/security"
faketok=FAKE-ACCESS-TOKEN-0123456789
again() {  # again [VAR=value...]: run the real refresher in $RH, keeping its state
  t=$(date +%s)   # a 429 is dated from the start of this run
  env HOME="$RH" PATH="$R/bin:$PATH" FAKE_LOG="$R/log" FAKE_TOKEN="$faketok" "$@" \
    "$shell" "$here/../usage-refresh.sh" "${ARGS1:-12.5}" "${ARGS2:-2.1.252}" ${ARGS3:+"$ARGS3" "$ARGS4"} </dev/null
}
clean() { rm -rf "$RH"/.claude/.usage-* "$RH"/.claude/.credits-* "$R"/log/*; }
refresh() { clean; again "$@"; }   # the same, from scratch
away() {  # away <streak> <seconds>: is the last 429 written down as that? A slow machine only adds to it.
  read -r w u n < "$RH/.claude/${DEAD:-.usage-unavailable}" 2>/dev/null; d=$(( ${u:-0} - t )); got="$w $n, $d s"
  [ "$w" = throttled ] && [ "$n" = "$1" ] && [ "$d" -ge $(($2 - 1)) ] && [ "$d" -le $(($2 + 5)) ]
}
body='{"spend":{"percent":42.3,"used":{"amount_minor":8460},"limit":{"amount_minor":20000},"severity":"ok"}}'
resolved=$(env PATH="$R/bin:$PATH" sh -c 'command -v curl; command -v security')
if [ "$resolved" != "$R/bin/curl
$R/bin/security" ]; then
  echo "FAIL refresh-shims-first: curl or security would resolve outside the shim folder, so the refresher tests did not run"
  fails=$((fails+1))
else
  refresh FAKE_CURL_BODY="$body"
  check refresh-token-not-in-argv "$(cat "$R/log/argv")" "https://api.anthropic.com/api/oauth/usage" "$faketok"
  check refresh-token-on-stdin    "$(cat "$R/log/stdin")" "Authorization: Bearer $faketok"
  check refresh-snapshot "$(jq -c '[.percent,.limit_minor,.spend_seen]' "$RH/.claude/.usage-cache.json" 2>&1)" "[42.3,20000,12.5]"
  check refresh-leaves-only-the-snapshot "[$(ls -A "$RH/.claude" | tr '\n' ' ')]" "[.usage-cache.json ]"
  # The headers the endpoint expects, as `curl` receives them: the OAuth beta and
  # the client version in the User-Agent.
  argv=$(cat "$R/log/argv"); bad=
  has "$argv" "anthropic-beta: oauth-2025-04-20" || bad=" [no anthropic-beta]"
  has "$argv" "User-Agent: claude-code/2.1.252" || bad="$bad [no User-Agent with the version]"
  verdict refresh-sends-its-headers "$bad"
  # A user's `~/.curlrc` never applies: `-q` comes first, the only place `curl`
  # honours it. This one would copy the request, token and all, to a file.
  printf 'trace-ascii = %s/trace\n' "$RH" > "$RH/.curlrc"; refresh FAKE_CURL_BODY="$body"; bad=
  [ "$(head -1 "$R/log/argv")" = -q ] || bad=" [first argument: $(head -1 "$R/log/argv")]"
  [ ! -e "$RH/trace" ] || bad="$bad [the token was written to a trace file]"
  rm -f "$RH/.curlrc" "$RH/trace"
  verdict refresh-ignores-curlrc "$bad"
  # What the refresher writes is for this account alone, mode 600, whatever the
  # umask it was started with. Skipped where file modes are not kept (Windows).
  ( umask 077; : > "$R/probe" )
  if [ "$(ls -l "$R/probe" | cut -c1-10)" != -rw------- ]; then
    echo "ok   refresh-files-are-private (skipped: this system does not keep file modes)"
  else
    refresh FAKE_CURL_BODY="$body"; m1=$(ls -l "$RH/.claude/.usage-cache.json" | cut -c1-10)
    refresh FAKE_CURL_CODE=401; m2=$(ls -l "$RH/.claude/.usage-unavailable" | cut -c1-10)
    check refresh-files-are-private "$m1 $m2" "-rw------- -rw-------"
  fi
  rm -f "$R/probe"
  refresh FAKE_CURL_CODE=401
  check refresh-401-is-login "[$(head -1 "$RH/.claude/.usage-unavailable" 2>&1)]" "[login]"
  # A rejected token is not sent again. The reason carries its expiry as a
  # fingerprint; while the token is the same no call goes out, and a new /login,
  # with a new expiry, is tried at once.
  x=$(( ($(date +%s) + 3600) * 1000 )); bad=
  refresh FAKE_CURL_CODE=401 FAKE_EXPIRES=$x
  [ "$(head -1 "$RH/.claude/.usage-unavailable" 2>&1)" = "login $x" ] || bad=" [recorded: $(head -1 "$RH/.claude/.usage-unavailable" 2>&1)]"
  rm -f "$R/log/argv"; again FAKE_CURL_CODE=401 FAKE_EXPIRES=$x
  [ ! -e "$R/log/argv" ] || bad="$bad [the rejected token was sent again]"
  [ "$(head -1 "$RH/.claude/.usage-unavailable" 2>&1)" = "login $x" ] || bad="$bad [then: $(head -1 "$RH/.claude/.usage-unavailable" 2>&1)]"
  again FAKE_EXPIRES=$((x + 1000)) FAKE_CURL_BODY="$body"
  { [ -e "$RH/.claude/.usage-cache.json" ] && [ ! -e "$RH/.claude/.usage-unavailable" ]; } || bad="$bad [a new login was not tried]"
  verdict refresh-rejected-token-waits-for-a-new-one "$bad"
  refresh FAKE_CURL_CODE=401
  # The reason file's second line is when it was written.
  t2=$(sed -n 2p "$RH/.claude/.usage-unavailable" 2>/dev/null); case "$t2" in ''|*[!0-9]*) t2=0 ;; esac
  d=$(( $(date +%s) - t2 )); bad=; { [ "$d" -ge 0 ] && [ "$d" -le 5 ]; } || bad=" [second line: $t2]"
  verdict refresh-records-when "$bad"
  # The reply is capped at 1 MiB, and one over the cap (`curl` exit 63) is not a
  # usage reply: "api", not "offline".
  refresh FAKE_CURL_BODY="$body"; bad=
  [ "$(awk 'p { print; exit } $0 == "--max-filesize" { p = 1 }' "$R/log/argv")" = 1048576 ] || bad=" [no --max-filesize 1048576]"
  refresh FAKE_CURL_EXIT=63
  [ "$(head -1 "$RH/.claude/.usage-unavailable" 2>&1)" = api ] || bad="$bad [exit 63 read as: $(head -1 "$RH/.claude/.usage-unavailable" 2>&1)]"
  verdict refresh-caps-the-reply "$bad"
  refresh FAKE_CURL_EXIT=7
  check refresh-curl-failure-is-offline "$(head -1 "$RH/.claude/.usage-unavailable" 2>&1)" "offline 7"
  # A refused certificate or handshake is "tls", with `curl`'s exit code, and so
  # is not taken for a dropped network.
  bad=; for rc in 35 60 77; do
    refresh FAKE_CURL_EXIT=$rc; [ "$(head -1 "$RH/.claude/.usage-unavailable" 2>&1)" = "tls $rc" ] || bad="$bad [$rc: $(head -1 "$RH/.claude/.usage-unavailable" 2>&1)]"
  done
  verdict refresh-tls-is-not-offline "$bad"

  # 429: keep away for the longer of what the server asks and 5 minutes, doubled
  # for each further 429 in a row, at most an hour. Any other reason in the file,
  # "http 429" here, starts the count afresh; a success clears it.
  clean; printf 'http 429\n' > "$RH/.claude/.usage-unavailable"; bad=
  again FAKE_CURL_CODE=429; away 1 300  || bad="$bad [first: $got]"
  again FAKE_CURL_CODE=429; away 2 600  || bad="$bad [second: $got]"
  printf 'throttled %s 60\n' "$(date +%s)" > "$RH/.claude/.usage-unavailable"
  again FAKE_CURL_CODE=429; away 61 3600 || bad="$bad [61st: $got]"
  for row in '3037:3037' '120:300' '99999:3600' 'Wed, 21 Oct 2026 07:28:00 GMT:300'; do
    refresh FAKE_CURL_CODE=429 FAKE_CURL_HEADERS="$(printf 'HTTP/1.1 429 Too Many Requests\r\nRetry-After: %s\r\n\r\n' "${row%:*}")"
    away 1 "${row##*:}" || bad="$bad [Retry-After ${row%:*}: $got]"
  done
  again FAKE_CURL_BODY="$body"; [ ! -e "$RH/.claude/.usage-unavailable" ] || bad="$bad [a success left it]"
  verdict refresh-429-backs-off "$bad"
  # Stopped mid-call, the way Claude Code stops a run a newer one replaces: no
  # reason recorded (not even "offline"), no snapshot, no lock left.
  clean; env HOME="$RH" PATH="$R/bin:$PATH" FAKE_LOG="$R/log" FAKE_TOKEN="$faketok" FAKE_CURL_SLEEP=5 FAKE_CURL_BODY="$body" \
    "$shell" "$here/../usage-refresh.sh" 12.5 2.1.252 </dev/null &
  rpid=$!
  i=0; while [ ! -s "$R/log/curl.pid" ] && [ "$i" -lt 20 ]; do sleep 1; i=$((i + 1)); done
  kill -TERM "$rpid" "$(cat "$R/log/curl.pid" 2>/dev/null)" 2>/dev/null; wait "$rpid" 2>/dev/null
  check refresh-stopped-leaves-nothing "[$(ls -A "$RH/.claude" | tr '\n' ' ')]" "[]"
  # The lock records its holder. A dead holder's lock, or one older than five
  # minutes with no pid, is taken over; a refresher still at work keeps its
  # lock however old (a Mac asleep mid-call finishes it on waking).
  ago() { date -r "$1" +%Y%m%d%H%M.%S 2>/dev/null || date -d "@$1" +%Y%m%d%H%M.%S 2>/dev/null; }
  lockrun() { rm -f "$RH/.claude/.usage-cache.json"; again FAKE_CURL_BODY="$body"; [ -e "$RH/.claude/.usage-cache.json" ]; }
  mkdir -p "$R/holder"; printf '#!/bin/sh\nsleep 30\n:\n' > "$R/holder/usage-refresh.sh"
  live() { "$shell" "$R/holder/usage-refresh.sh" & lv=$!; sleep 1; }   # live: a stand-in refresher at work, its pid in $lv
  lk="$RH/.claude/.usage-cache.lock"
  sh -c 'exit 0' & gone=$!; wait "$gone"; bad=
  clean; mkdir "$lk"; echo "$gone" > "$lk/pid"
  lockrun || bad=" [dead holder]"; [ ! -e "$lk" ] || bad="$bad [lock not given back]"
  mkdir "$lk"; touch -t "$(ago $(( $(date +%s) - 600 )))" "$lk"
  lockrun || bad="$bad [old lock without pid]"
  live; mkdir "$lk"; echo "$lv" > "$lk/pid"; touch -t "$(ago $(( $(date +%s) - 3600 )))" "$lk"
  lockrun && bad="$bad [a running refresher's hour-old lock was taken]"
  kill "$lv" 2>/dev/null; rm -rf "$lk"
  verdict refresh-lock-knows-its-holder "$bad"
  # A pid in the lock that now belongs to another program, which happens after
  # a refresher was killed outright, does not hold it. Skipped where `ps`
  # cannot show a command (Git Bash).
  sleep 30 & other=$!
  if ! ps -o command= -p "$other" >/dev/null 2>&1; then
    echo "ok   refresh-lock-reused-pid-is-taken-over (skipped: ps here cannot show a command)"
  else
    clean; mkdir "$lk"; echo "$other" > "$lk/pid"; bad=
    lockrun || bad=" [a lock held by another program's pid was kept]"
    verdict refresh-lock-reused-pid-is-taken-over "$bad"
  fi
  kill "$other" 2>/dev/null; rm -rf "$lk"
  # A run gives the lock back only while it holds its pid: one that lost it to
  # another run's takeover leaves that run's lock alone.
  clean; live; bad=
  env HOME="$RH" PATH="$R/bin:$PATH" FAKE_LOG="$R/log" FAKE_TOKEN="$faketok" FAKE_CURL_SLEEP=3 FAKE_CURL_BODY="$body" \
    "$shell" "$here/../usage-refresh.sh" 12.5 2.1.252 </dev/null & a=$!
  i=0; while [ ! -s "$lk/pid" ] && [ "$i" -lt 20 ]; do sleep 1; i=$((i + 1)); done
  echo "$lv" > "$lk/pid"; wait "$a"
  [ "$(cat "$lk/pid" 2>/dev/null)" = "$lv" ] || bad=" [the other run's lock was deleted]"
  kill "$lv" 2>/dev/null; rm -rf "$lk"
  verdict refresh-gives-back-only-its-own-lock "$bad"
  # Of two runs that find one stale lock, one takes it over and the other then
  # finds a refresher at work: one call. An `rm` that takes 3 seconds on the
  # lock leaves the time for the second to come in between.
  mkdir -p "$R/slowrm"; printf '#!/bin/sh\ncase "$*" in *usage-cache.lock*) sleep 3 ;; esac\nexec "%s" "$@"\n' "$(command -v rm)" > "$R/slowrm/rm"; chmod +x "$R/slowrm/rm"
  clean; mkdir "$lk"; echo "$gone" > "$lk/pid"; bad=
  for d in 0 2; do
    sleep "$d"
    env HOME="$RH" PATH="$R/slowrm:$R/bin:$PATH" FAKE_LOG="$R/log" FAKE_TOKEN="$faketok" FAKE_CURL_SLEEP=5 FAKE_CURL_BODY="$body" \
      "$shell" "$here/../usage-refresh.sh" 12.5 2.1.252 </dev/null &
  done
  wait
  [ "$(wc -l < "$R/log/calls" 2>/dev/null | tr -d ' ')" = 1 ] || bad=" [calls: $(wc -l < "$R/log/calls" 2>/dev/null | tr -d ' ')]"
  rm -rf "$lk"
  verdict refresh-takeover-is-atomic "$bad"

  # Credits mode keeps the extra_usage part, in files of its own: the enterprise
  # snapshot file would mark the machine as an enterprise seat.
  ARGS1=1.5 ARGS2=2.1.287 ARGS3=credits ARGS4=s1
  cbody='{"five_hour":{"utilization":100,"resets_at":null},"extra_usage":{"is_enabled":true,"monthly_limit":5000,"used_credits":1250.0,"utilization":25.0,"currency":"USD"}}'
  refresh FAKE_CURL_BODY="$cbody"; bad=
  got=$(jq -c '[.enabled,.used_minor,.limit_minor,(.percent|floor),.currency,.spend_seen,.session]' "$RH/.claude/.credits-cache.json" 2>&1)
  [ "$got" = '[true,1250,5000,25,"USD","1.5","s1"]' ] || bad=" [kept: $got]"
  e=$(jq -r .resets_at "$RH/.claude/.credits-cache.json" 2>/dev/null)
  [ "$(date -r "$e" +%d 2>/dev/null || date -d "@$e" +%d 2>/dev/null)" = 01 ] || bad="$bad [reset not on the 1st]"
  [ ! -e "$RH/.claude/.usage-cache.json" ] || bad="$bad [wrote the enterprise latch]"
  again FAKE_CURL_BODY='{"five_hour":{"utilization":100},"extra_usage":null}'
  [ "$(jq -c '[.enabled,.used_minor]' "$RH/.claude/.credits-cache.json" 2>&1)" = '[false,null]' ] || bad="$bad [no credits block is not off]"
  # The share is kept only as a number and the currency only as a string, so the
  # cache never holds an array the line would read as several words.
  refresh FAKE_CURL_BODY='{"five_hour":{"utilization":100},"extra_usage":{"is_enabled":true,"monthly_limit":5000,"used_credits":1250,"utilization":["x","touch","/x"],"currency":{"a":1}}}'
  got=$(jq -c '[.percent,.currency]' "$RH/.claude/.credits-cache.json" 2>&1)
  [ "$got" = '[null,"USD"]' ] || bad="$bad [kept from odd types: $got]"
  verdict refresh-credits-keeps-the-figures "$bad"
  refresh FAKE_CURL_BODY='{"error":{"type":"not_found_error"}}'; bad=
  [ "$(head -1 "$RH/.claude/.credits-unavailable" 2>&1)" = api ] || bad=" [not a usage reply]"
  [ ! -e "$RH/.claude/.usage-unavailable" ] || bad="$bad [wrote the enterprise failure file]"
  DEAD=.credits-unavailable; again FAKE_CURL_CODE=429; away 1 300 || bad="$bad [429: $got]"; DEAD=
  again FAKE_CURL_BODY="$cbody"; [ ! -e "$RH/.claude/.credits-unavailable" ] || bad="$bad [a success left the failure]"
  verdict refresh-credits-fail-in-their-own-file "$bad"
  ARGS1= ARGS2= ARGS3= ARGS4=

  # The Enterprise share is the amount divided by the limit when both are there,
  # because spend.percent comes rounded (1 for 297 of 20000); else spend.percent.
  # A usage reply with neither is "nofigure", not "api"; a reply that is not a
  # usage reply at all is still "api".
  spend() { printf '{"five_hour":null,"seven_day":null,"limits":[],"spend":{"percent":%s,"used":{"amount_minor":%s},"limit":{"amount_minor":%s},"severity":"ok"}}' "$1" "$2" "$3"; }
  bad=
  for row in '1 297 20000:[1.485,297,20000]' '42 null null:[42,null,null]' 'null 8460.0 20000:[42.3,8460,20000]' '7 100 0:[7,100,0]'; do
    set -- ${row%%:*}; refresh FAKE_CURL_BODY="$(spend "$1" "$2" "$3")"
    got=$(jq -c '[.percent,.used_minor,.limit_minor]' "$RH/.claude/.usage-cache.json" 2>&1)
    [ "$got" = "${row#*:}" ] || bad="$bad [$1 $2 $3: $got]"
  done
  for b in "$(spend null null null)" '{"five_hour":null,"seven_day":null,"spend":null}'; do
    refresh FAKE_CURL_BODY="$b"
    { [ "$(head -1 "$RH/.claude/.usage-unavailable" 2>&1)" = nofigure ] && [ ! -e "$RH/.claude/.usage-cache.json" ]; } || bad="$bad [no figure: $(head -1 "$RH/.claude/.usage-unavailable" 2>&1)]"
  done
  refresh FAKE_CURL_BODY='{"error":{"type":"not_found_error"}}'
  [ "$(head -1 "$RH/.claude/.usage-unavailable" 2>&1)" = api ] || bad="$bad [not a usage reply]"
  verdict refresh-enterprise-share-and-no-figure "$bad"

  # An expired token is never sent: no call, and "expired" for the line to say
  # login calmly. The expiry is in milliseconds, as Claude Code writes it; a
  # figure in seconds is read as seconds, not as a date in 1970.
  bad=; t=$(date +%s)
  refresh FAKE_EXPIRES=$(( (t - 60) * 1000 ))
  [ ! -e "$R/log/argv" ] || bad=" [called with an expired token]"
  [ "$(head -1 "$RH/.claude/.usage-unavailable" 2>&1)" = expired ] || bad="$bad [reason: $(head -1 "$RH/.claude/.usage-unavailable" 2>&1)]"
  refresh FAKE_EXPIRES=$(( (t + 3600) * 1000 )) FAKE_CURL_BODY="$body"
  [ -e "$RH/.claude/.usage-cache.json" ] || bad="$bad [a live token was not sent]"
  refresh FAKE_EXPIRES=$((t + 3600)) FAKE_CURL_BODY="$body"
  [ -e "$RH/.claude/.usage-cache.json" ] || bad="$bad [an expiry in seconds read as expired]"
  printf '{"claudeAiOauth":{"accessToken":"%s","expiresAt":%s}}\n' "$faketok" "$(( (t - 60) * 1000 ))" > "$RH/.claude/.credentials.json"
  refresh FAKE_SERVICE=none FAKE_CURL_BODY="$body"      # an empty keychain: the file is read
  [ "$(head -1 "$RH/.claude/.usage-unavailable" 2>&1)" = expired ] || bad="$bad [the credentials file: $(head -1 "$RH/.claude/.usage-unavailable" 2>&1)]"
  rm -f "$RH/.claude/.credentials.json"
  verdict refresh-expired-token-is-not-sent "$bad"
  # Through a native Windows `jq`, which ends its output with a carriage return,
  # the expiry still reads as a number, and a reply with no figure still reads
  # as one, not as a shape that moved.
  crlfjq "$R/crlf"; bad=
  refresh PATH="$R/crlf:$R/bin:$PATH" FAKE_EXPIRES=$(( ($(date +%s) - 60) * 1000 ))
  [ ! -e "$R/log/argv" ] || bad=" [an expired token was sent]"
  refresh PATH="$R/crlf:$R/bin:$PATH" FAKE_CURL_BODY='{"five_hour":null,"seven_day":null,"spend":null}'
  [ "$(head -1 "$RH/.claude/.usage-unavailable" 2>&1)" = nofigure ] || bad="$bad [no figure read as: $(head -1 "$RH/.claude/.usage-unavailable" 2>&1)]"
  verdict refresh-survives-a-crlf-jq "$bad"

  # One folder per login. With `CLAUDE_CONFIG_DIR` set, the refresher reads the
  # keychain item Claude Code keeps for that folder: the plain name plus "-" and
  # the first 8 hex digits of the folder's sha256, for the account `$USER`. The
  # shim holds only that item, so the plain name would find nothing. Every file
  # lands in that folder, none in `~/.claude`.
  mkdir -p "$RH/work"; bad=
  if command -v sha256sum >/dev/null 2>&1; then sum=$(printf '%s' "$RH/work" | sha256sum)
  elif command -v shasum >/dev/null 2>&1; then sum=$(printf '%s' "$RH/work" | shasum -a 256)
  else sum=$(printf '%s' "$RH/work" | openssl dgst -sha256 -r); fi
  item="Claude Code-credentials-$(printf '%.8s' "$sum")"
  refresh CLAUDE_CONFIG_DIR="$RH/work" FAKE_SERVICE="$item" USER=tester FAKE_CURL_BODY="$body"
  [ "$(tr '\n' ' ' < "$R/log/security.argv" 2>/dev/null)" = "find-generic-password -a tester -w -s $item " ] \
    || bad=" [asked for: $(tr '\n' ' ' < "$R/log/security.argv" 2>/dev/null)]"
  [ -e "$RH/work/.usage-cache.json" ] || bad="$bad [no snapshot in the folder]"
  [ -z "$(ls -A "$RH/.claude")" ] || bad="$bad [wrote in ~/.claude: $(ls -A "$RH/.claude" | tr '\n' ' ')]"
  # Nothing in the keychain for that folder: the folder's own `.credentials.json`,
  # never the one in `~/.claude`.
  rm -rf "$RH/work"/.usage-*
  printf '{"claudeAiOauth":{"accessToken":"%s"}}\n' "$faketok" > "$RH/work/.credentials.json"
  printf '{"claudeAiOauth":{"accessToken":"OTHER-LOGIN-TOKEN"}}\n' > "$RH/.claude/.credentials.json"
  again CLAUDE_CONFIG_DIR="$RH/work" FAKE_SERVICE=none FAKE_CURL_BODY="$body"
  has "$(cat "$R/log/stdin" 2>/dev/null)" "Bearer $faketok" || bad="$bad [sent: $(cat "$R/log/stdin" 2>/dev/null)]"
  rm -rf "$RH/work" "$RH/.claude/.credentials.json"
  verdict refresh-one-folder-per-login "$bad"
  # A config folder with an apostrophe in its path. Git Bash hands such a path
  # unconverted to a native `jq.exe` or `curl.exe`, which then cannot open it; the
  # stand-ins here refuse it the same way. The refresher hands `jq` its files on
  # stdin and gives `curl` names inside the folder, and the line reads the
  # snapshot on stdin too.
  A="$RH/it's here"; mkdir -p "$A" "$R/apos"; bad=
  printf '#!/bin/sh\nfor a do case "$a" in /*\\'"'"'*) exit 2 ;; esac; done\nexec "%s" "$@"\n' "$(command -v jq)" > "$R/apos/jq"; chmod +x "$R/apos/jq"
  printf '{"claudeAiOauth":{"accessToken":"%s"}}\n' "$faketok" > "$A/.credentials.json"
  again CLAUDE_CONFIG_DIR="$A" PATH="$R/apos:$R/bin:$PATH" FAKE_SERVICE=none FAKE_CURL_BODY="$body"
  [ -e "$A/.usage-cache.json" ] || bad=" [no snapshot: $(head -1 "$A/.usage-unavailable" 2>&1)]"
  cp "$sl" "$R/statusline.sh"; printf '%s\n' "$(date +%s)" > "$A/.usage-attempt"
  out=$(sed -e "s|__CWD__|$here|" "$here/payloads/enterprise.json" | env HOME="$RH" CLAUDE_CONFIG_DIR="$A" PATH="$R/apos:$PATH" CC_WIDTH=0 CC_ENTERPRISE=1 "$shell" "$R/statusline.sh" | strip)
  has "$out" ' 42%' || bad="$bad [drew: $out]"
  rm -rf "$A" "$R/statusline.sh"
  verdict apostrophe-folder-reads-and-writes "$bad"

  # A Claude Code that keeps the item under another account name, as a later
  # version might: nothing for `$USER`, so the same item is read under any
  # account.
  refresh USER=tester FAKE_ACCOUNT=claude-code-user FAKE_CURL_BODY="$body"; bad=
  [ -e "$RH/.claude/.usage-cache.json" ] || bad=" [no snapshot: $(head -1 "$RH/.claude/.usage-unavailable" 2>&1)]"
  [ "$(tr '\n' ' ' < "$R/log/security.argv" 2>/dev/null)" = "find-generic-password -w -s Claude Code-credentials " ] \
    || bad="$bad [asked for: $(tr '\n' ' ' < "$R/log/security.argv" 2>/dev/null)]"
  verdict refresh-keychain-any-account "$bad"
fi
rm -rf "$R"

# The keychain name per folder, as Claude Code 2.1.292 was seen to name its
# items, against digests computed separately with Python's hashlib: the folder
# as set, trailing slash and all, and an empty one meaning the plain name.
body=$(sed -n '/^service()/,/^}/p' "$here/../usage-refresh.sh"); bad=
for row in '/Users/test/.claude-work|-03abf0ee' '/Users/test/.claude-work/|-8bd6f0f5' '|'; do
  cd_=${row%%|*} want="Claude Code-credentials${row#*|}"
  got=$(env CLAUDE_CONFIG_DIR="$cd_" "$shell" -c "$body; service; printf '%s' \"\$svc\"")
  [ "$got" = "$want" ] || bad="$bad [$row: $got]"
done
verdict keychain-name-per-folder "$bad"
# A decomposed é is normalized first, as Claude Code does. Needs `perl`'s
# Unicode::Normalize.
if perl -MUnicode::Normalize -e 1 2>/dev/null; then
  got=$(env CLAUDE_CONFIG_DIR="$(printf '/Users/test/cafe\314\201')" "$shell" -c "$body; service; printf '%s' \"\$svc\"")
  check keychain-name-normalizes "[$got]" "[Claude Code-credentials-ec5578f1]"
else
  echo "ok   keychain-name-normalizes (skipped: no perl Unicode::Normalize here)"
fi

# --- usage credits: a subscription window at or past 100% ---
# The same stand-in refresher. `LC_ALL=C` pins the month name. Each check that
# wants no call starts with no recent call, so the 5-minute gap cannot hide one.
home; C=$H
nextreset=$(sh -c "$(sed -n '/^nextmonth()/,/^}/p' "$here/../usage-refresh.sh"); nextmonth")
cpay() {  # cpay <5h %> <5h reset> <7d %>: a subscription payload, session s1 at $1.50
  printf '{"session_id":"s1","version":"2.1.287","cost":{"total_cost_usd":1.5},"workspace":{"current_dir":"%s"},"rate_limits":{"five_hour":{"used_percentage":%s,"resets_at":%s},"seven_day":{"used_percentage":%s,"resets_at":%s}}}' \
    "$C" "$1" "$2" "$3" "$(( $(date +%s) + 200000 ))"
}
cred() {  # cred <5h %> [VAR=value...]: one render, keeping the attempt file as it was before
  p=$1; shift; rm -f "$C/started"; cp "$C/.claude/.usage-attempt" "$C/before" 2>/dev/null || : > "$C/before"
  cpay "$p" "$(( $(date +%s) + 7200 ))" 62 | env HOME="$C" CC_WIDTH=0 LC_ALL=C "$@" "$shell" "$C/statusline.sh"
}
credcache() {  # credcache <age> <enabled> <used> <limit> <percent> [currency] [spend seen] [session]
  printf '{"fetched_at":%s,"enabled":%s,"used_minor":%s,"limit_minor":%s,"percent":%s,"currency":"%s","resets_at":%s,"spend_seen":"%s","session":"%s"}\n' \
    "$(( $(date +%s) - $1 ))" "$2" "$3" "$4" "$5" "${6:-USD}" "$nextreset" "${7:-1.5}" "${8:-s1}" > "$C/.claude/.credits-cache.json"
}
noatt()  { rm -f "$C/.claude/.usage-attempt"; }
recent() { attempt $(( $(date +%s) - 60 )); }      # a call a minute ago, so no new one muddies the drawing
call="1.5 2.1.287 credits s1"
quiet() {  # quiet <name> <5h %> [VAR=value...]: no ¤ drawn and no call
  n=$1 p=$2; shift 2; noatt; out=$(cred "$p" "$@" | strip); bad=
  has "$out" '¤' && bad=" [drew: $out]"; nocall || bad="$bad [called]"; verdict "$n" "$bad"
}
quiet credits-not-below-100 99
noatt; out=$(cred 100 | strip); bad=; like "$out" '*5h ??:?? 100% · 7d ??? 62% · ¤credits' || bad=" [drew: $out]"
{ calls && [ "$(cat "$C/started")" = "$call" ]; } || bad="$bad [called with: $(cat "$C/started" 2>/dev/null)]"
verdict credits-at-100-ask-with-session-and-spend "$bad"
# While the first figure is on its way nobody has to act, so ¤credits is dim,
# like the cap's placeholder.
recent; bad=; has "$(cred 100)" "${E}[2m¤credits" || bad=" [not dim: $(cred 100 | strip)]"
verdict credits-placeholder-is-dim "$bad"
# A full window past its reset, with no newer one known, is over: no credits.
noatt; rm -f "$C/.claude"/.rl-*
out=$(cpay 100 "$(( $(date +%s) - 60 ))" 62 | env HOME="$C" CC_WIDTH=0 LC_ALL=C "$shell" "$C/statusline.sh" | strip)
check credits-not-for-a-window-past-its-reset "$out" '5h reset' '¤'
quiet credits-0-turns-it-off 100 CC_CREDITS=0
printf '{\n  "cachedExtraUsageDisabledReason": "org_level_disabled"\n}\n' > "$C/.claude.json"
quiet credits-off-for-the-account 104.5
printf '{\n  "cachedExtraUsageDisabledReason": null\n}\n' > "$C/.claude.json"
# Dollars spent this month, coloured by how close they are to the monthly
# limit (green, yellow from 50%, red from 80%), in the account's currency.
recent; bad=
credcache 30 true 1250 5000 25; like "$(cred 100 | strip)" '*· ¤$12.50' || bad=" [text]"
has "$(cred 100)" "${E}[32m¤\$12.50" || bad="$bad [25%]"
credcache 30 true 3000 5000 60; has "$(cred 100)" "${E}[33m¤\$30.00" || bad="$bad [60%]"
credcache 30 true 4500 5000 90; has "$(cred 100)" "${E}[31m¤\$45.00" || bad="$bad [90%]"
credcache 30 true 1250 null null EUR; like "$(cred 100 | strip)" '*· ¤12.50 EUR' || bad="$bad [EUR]"
verdict credits-in-dollars "$bad"
# A cache with hostile values: nothing in it runs, and nothing odd is drawn.
recent; bad=
printf '{"fetched_at":%s,"enabled":true,"used_minor":1250,"limit_minor":null,"percent":null,"currency":"US\\"; system(\\"touch %s/pwned\\") #"}\n' "$(date +%s)" "$C" > "$C/.claude/.credits-cache.json"
like "$(cred 100 | strip)" '*· ¤$12.50' || bad=" [odd currency]"
printf '{"fetched_at":%s,"enabled":true,"used_minor":"1250; system(\\"touch %s/pwned\\")","limit_minor":null}\n' "$(date +%s)" "$C" > "$C/.claude/.credits-cache.json"
out=$(cred 100 | strip); { has "$out" '¤credits' && ! has "$out" '$'; } || bad="$bad [odd amount: $out]"
# An array would come out of @sh as several words and run as a command (from
# the folder of the render: here $C), an object would fail the read. Neither may.
printf '{"fetched_at":%s,"enabled":true,"used_minor":1250,"limit_minor":5000,"percent":["x","touch","%s/pwned"],"currency":"USD"}\n' "$(date +%s)" "$C" > "$C/.claude/.credits-cache.json"
out=$(cd "$C" && cred 100 | strip); like "$out" '*· ¤$12.50' || bad="$bad [an array: $out]"
printf '{"fetched_at":%s,"enabled":true,"used_minor":1250,"limit_minor":5000,"percent":25,"currency":{"x":["touch","%s/pwned"]}}\n' "$(date +%s)" "$C" > "$C/.claude/.credits-cache.json"
out=$(cd "$C" && cred 100 | strip); like "$out" '*· ¤$12.50' || bad="$bad [an object: $out]"
{ [ ! -e "$C/pwned" ] && [ ! -e "$C/eol=1" ]; } || bad="$bad [it ran a command]"
verdict credits-hostile-cache-is-harmless "$bad"
# Off on the server's word: nothing drawn, fresh or old, and asked at most hourly.
bad=
recent; credcache 30 false 0 null null;   has "$(cred 100 | strip)" '¤' && bad=" [fresh]"
noatt;  credcache 1000 false 0 null null; cred 100 >/dev/null; nocall || bad="$bad [called within the hour]"
noatt;  credcache 4000 false 0 null null; has "$(cred 100 | strip)" '¤' && bad="$bad [old]"
{ calls && [ "$(cat "$C/started")" = "$call" ]; } || bad="$bad [not called after the hour]"
verdict credits-off-in-the-reply "$bad"
# No figure: say why, from credits' own failure file. The enterprise file does
# not hold credits back.
rm -f "$C/.claude/.credits-cache.json"; bad=
for row in 'login:¤login' 'throttled:¤throttled' 'api:¤api moved' 'nocurl:¤no curl'; do
  w=${row%%:*}; [ "$w" = throttled ] && w="throttled $(( $(date +%s) + 600 )) 1"
  printf '%s\n' "$w" > "$C/.claude/.credits-unavailable"; recent
  out=$(cred 100 | strip); { has "$out" "${row#*:}" && ! has "$out" '¤credits'; } || bad="$bad [${row%%:*}: $out]"
done
rm -f "$C/.claude/.credits-unavailable"; why api; noatt
cred 100 >/dev/null; { calls && [ "$(cat "$C/started")" = "$call" ]; } || bad="$bad [held back by the enterprise file]"
rm -f "$C/.claude/.usage-unavailable"
verdict credits-say-why "$bad"
# No refresher for the credits either: said, in yellow.
mv "$C/usage-refresh.sh" "$C/usage-refresh.off"; noatt; rm -f "$C/.claude/.credits-cache.json" "$C/.claude/.credits-unavailable"; bad=
has "$(cred 100)" "${E}[33m¤no refresher" || bad=" [drew: $(cred 100 | strip)]"
mv -f "$C/usage-refresh.off" "$C/usage-refresh.sh"; rm -f "$C/.claude/.credits-unavailable"
verdict credits-no-refresher-says-so "$bad"
# When to ask again: 5 minutes after spend, in this session or another; half an hour without.
bad=
noatt; credcache 400  true 1250 5000 25 USD 1.5 s1; cred 100 >/dev/null; nocall || bad=" [no spend, called]"
noatt; credcache 400  true 1250 5000 25 USD 1.2 s1; cred 100 >/dev/null; calls || bad="$bad [spend since]"
noatt; credcache 400  true 1250 5000 25 USD 1.5 s2; cred 100 >/dev/null; calls || bad="$bad [another session]"
noatt; credcache 2000 true 1250 5000 25 USD 1.5 s1; cred 100 >/dev/null; calls || bad="$bad [half an hour]"
verdict credits-ask-after-spend "$bad"
# An older figure shows no age, in the narrowest form either; past an hour it
# is not drawn. A full week counts as much as a full five hours.
recent; bad=; credcache 700 true 1250 5000 25
like "$(cred 100 | strip)" '*¤$12.50' || bad=" [full: $(cred 100 | strip)]"
like "$(cred 100 CC_WIDTH=18 | strip)" '*¤$12.50' || bad="$bad [narrow: $(cred 100 CC_WIDTH=18 | strip)]"
credcache 4000 true 1250 5000 25; out=$(cred 100 | strip); { has "$out" '¤credits' && ! has "$out" '$12'; } || bad="$bad [past the hour]"
credcache 30 true 1250 5000 25
like "$(cpay 12 "$(( $(date +%s) + 7200 ))" 100 | env HOME="$C" CC_WIDTH=0 LC_ALL=C "$shell" "$C/statusline.sh" | strip)" '*7d ??? 100% · ¤$*' || bad="$bad [full week]"
verdict credits-old-figure-and-week "$bad"
# The same for the usage credits: a failure after the figure was fetched shows
# beside it.
recent; credcache 300 true 1250 5000 25; printf 'login\n%s\n' "$(date +%s)" > "$C/.claude/.credits-unavailable"; bad=
like "$(cred 100 | strip)" '*· ¤$12.50 login' || bad=" [drew: $(cred 100 | strip)]"
rm -f "$C/.claude/.credits-unavailable"
verdict credits-newer-failure-shows-beside "$bad"
# A credits cache whose month is over holds last month's spend, however young:
# not drawn, and asked for again.
noatt; printf '{"fetched_at":%s,"enabled":true,"used_minor":4500,"limit_minor":5000,"percent":90,"currency":"USD","resets_at":%s,"spend_seen":"1.5","session":"s1"}\n' \
  "$(( $(date +%s) - 300 ))" "$(( $(date +%s) - 60 ))" > "$C/.claude/.credits-cache.json"
out=$(cred 100 | strip); bad=; has "$out" '$45.00' && bad=" [drew: $out]"; calls || bad="$bad [not asked]"
verdict credits-last-month-is-not-drawn "$bad"
# Plain ASCII: + for the credits sign.
recent; bad=; credcache 700 true 1250 5000 25
like "$(cred 100 CC_ASCII=1 | strip)" '* | +$12.50' || bad=" [figure: $(cred 100 CC_ASCII=1 | strip)]"
rm -f "$C/.claude/.credits-cache.json"; printf 'login\n' > "$C/.claude/.credits-unavailable"; recent
like "$(cred 100 CC_ASCII=1 | strip)" '* | +login' || bad="$bad [reason]"
rm -f "$C/.claude/.credits-unavailable"; recent
like "$(cred 100 CC_ASCII=1 | strip)" '* | +credits' || bad="$bad [on its way]"
verdict ascii-credits "$bad"
rm -rf "$C"

# --- several sessions: one record per window (see "one record per window" in `statusline.sh`) ---
# A `date` shim fakes the clock for `date +%s` alone (`FAKE_NOW`), so a window can
# be played through in a moment; every other call reaches the real date. Each
# render names its session, so two sessions on one machine can take turns.
W=$(mktemp -d); mkdir -p "$W/bin" "$W/home/.claude"; cp "$sl" "$W/statusline.sh"
printf '#!/bin/sh\n' > "$W/usage-refresh.sh"; chmod +x "$W/usage-refresh.sh"    # a stand-in that does nothing
printf '#!/bin/sh\n[ "$*" = "+%%s" ] && [ -n "${FAKE_NOW:-}" ] && { echo "$FAKE_NOW"; exit 0; }\nexec "%s" "$@"\n' "$(command -v date)" > "$W/bin/date"
chmod +x "$W/bin/date"
T0=1800000000
wl() {  # wl <time> <session> <five_hour|seven_day> <percent> <reset> [VAR=value...]: one render, escape codes and all
  w_t=$1 w_s=$2 w_k=$3 w_p=$4 w_r=$5; shift 5
  printf '{"session_id":"%s","workspace":{"current_dir":"%s"},"rate_limits":{"%s":{"used_percentage":%s,"resets_at":%s}}}' \
    "$w_s" "$W" "$w_k" "$w_p" "$w_r" | env PATH="$W/bin:$PATH" FAKE_NOW="$w_t" HOME="$W/home" CC_WIDTH=0 LC_ALL=C "$@" "$shell" "$W/statusline.sh"
}
rec() { cat "$W/home/.claude/.rl-$1-state" 2>/dev/null; }    # rec <key>: the record, one line
anew() { rm -f "$W/home/.claude"/.rl-*; }
mins() {  # mins <line>: the burn estimate in whole minutes, or nothing
  printf '%s' "$1" | strip | LC_ALL=C awk '{ if (match($0, /↯[0-9.]+[mhd]/)) {
    s = substr($0, RSTART + 3, RLENGTH - 3); n = substr(s, 1, length(s) - 1) + 0
    if (s ~ /h$/) n = int(n * 60 + 0.5); else if (s ~ /d$/) n = n * 1440
    print n } }'
}
# Two sessions on one machine. A works and climbs a point every 7.5 minutes; B
# sits idle on the 45% it heard last and draws in between, as refreshInterval
# has it. Read as a reset, B's lower figure would make A's next render measure a
# jump: a red ↯ of minutes in a window far from full. Here nothing may be red,
# the record keeps A's figure, and B draws it.
anew; t=$T0 rs=$((T0 + 10800)) bad=
wl $t B five_hour 45 $rs >/dev/null
t=$((t + 30)); wl $t A five_hour 50 $rs >/dev/null
for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
  t=$((t + 300)); has "$(wl $t A five_hour $((50 + i)) $rs)" "${E}[31m↯" && bad="$bad [A red at $((50 + i))%]"
  t=$((t + 150)); raw=$(wl $t B five_hour 45 $rs); out=$(printf '%s' "$raw" | strip)
  like "$out" "*5h ??:?? $((50 + i))%*" || bad="$bad [B drew: $out]"
  has "$raw" "${E}[31m↯" && bad="$bad [B red at $((50 + i))%]"
done
set -- $(rec 5h); [ "${5:-}" = 62 ] || bad="$bad [record: $(rec 5h)]"
verdict two-sessions-one-stale "$bad"
# A new window is a later reset time, not a drop. 30% then 29% with a reset 5
# hours on starts a new record; 60% then 20% with the same reset, give or take
# 2 minutes, keeps it, and the session on 20% draws 60%. A reset more than 10
# minutes earlier is a session still on the last window: it draws its own
# figure and leaves the record alone.
anew; bad=
wl $T0 A five_hour 30 $((T0 + 3600)) >/dev/null
wl $((T0 + 3700)) A five_hour 29 $((T0 + 21600)) >/dev/null
set -- $(rec 5h); [ "${1:-} ${5:-}" = "$((T0 + 21600)) 29" ] || bad=" [after a reset: $(rec 5h)]"
anew; wl $T0 A five_hour 60 $((T0 + 3600)) >/dev/null
out=$(wl $((T0 + 60)) B five_hour 20 $((T0 + 3720)) | strip)
set -- $(rec 5h); [ "${1:-} ${5:-}" = "$((T0 + 3600)) 60" ] || bad="$bad [after a drop: $(rec 5h)]"
like "$out" '*5h ??:?? 60%*' || bad="$bad [the session on 20% drew: $out]"
out=$(wl $((T0 + 90)) C five_hour 90 $((T0 + 2700)) | strip)
{ like "$out" '*5h ??:?? 90%*' && [ "$(set -- $(rec 5h); echo "${5:-}")" = 60 ]; } || bad="$bad [the last window: $out, $(rec 5h)]"
verdict a-new-window-is-a-later-reset-time "$bad"
# Nobody has shown the record's figure for 30 minutes: a session draws its own.
# That is how a figure the server lowers gets in.
out=$(wl $((T0 + 1900)) B five_hour 20 $((T0 + 3600)) | strip); bad=
like "$out" '*5h ??:?? 20%' || bad=" [drew: $out]"
verdict a-stale-record-gives-way "$bad"
# A window whose reset has passed is over. An idle session still on one draws
# the newer window another session has seen, in that window's colour, and leaves
# the record alone. With no newer window known it reads "5h reset", dim: no old
# figure, no old stamp, no burn estimate.
anew; bad=
wl $T0 A five_hour 95 $((T0 + 600)) >/dev/null
wl $((T0 + 1200)) B five_hour 3 $((T0 + 18600)) >/dev/null
raw=$(wl $((T0 + 1260)) A five_hour 95 $((T0 + 600))); out=$(printf '%s' "$raw" | strip)
like "$out" '*5h ??:?? 3%' || bad=" [drew: $out]"
has "$raw" "${E}[32m5h " || bad="$bad [not green]"
set -- $(rec 5h); [ "${1:-} ${5:-}" = "$((T0 + 18600)) 3" ] || bad="$bad [record: $(rec 5h)]"
anew; wl $T0 A five_hour 90 $((T0 + 600)) >/dev/null; wl $((T0 + 300)) A five_hour 95 $((T0 + 600)) >/dev/null
raw=$(wl $((T0 + 1200)) A five_hour 95 $((T0 + 600)))
out=$(printf '%s' "$raw" | strip)
{ like "$out" '* · 5h reset' && has "$raw" "${E}[2m5h reset"; } || bad="$bad [an old window: $out]"
has "$raw" '↯' && bad="$bad [a burn estimate on an old window]"
verdict a-window-past-its-reset-is-over "$bad"
# The usage credits follow the window drawn: an idle session that draws the
# record's newer window at 100% shows ¤credits, though its own window is over.
anew; rm -f "$W/home/.claude/.usage-attempt" "$W/home/.claude/.credits-cache.json"; bad=
wl $T0 A five_hour 95 $((T0 + 600)) >/dev/null
wl $((T0 + 1200)) B five_hour 100 $((T0 + 18600)) >/dev/null
out=$(wl $((T0 + 1260)) A five_hour 95 $((T0 + 600)) | strip)
like "$out" '*5h ??:?? 100% · ¤credits' || bad=" [drew: $out]"
verdict credits-follow-the-window-drawn "$bad"
rm -f "$W/home/.claude/.usage-attempt"
# The rate. A steady climb, a point every 2 minutes from 40%, drawn every minute:
# from 50% the estimate is there at every render, never blank, and within a
# quarter of the truth. A burst of 10 points in 5 minutes then shortens it, red.
# An idle hour after that lets it fade, longer at each look, never blank, until
# it is dim.
anew; t=$T0 rs=$((T0 + 14400)) p=40 m=0 bad=
while [ "$m" -le 44 ]; do
  [ "$m" -gt 0 ] && [ $((m % 2)) = 0 ] && p=$((p + 1))
  e=$(mins "$(wl $t A five_hour $p $rs)")
  if [ "$p" -ge 50 ]; then
    truth=$(( (100 - p) * 2 ))
    if [ -z "$e" ]; then bad="$bad [blank at minute $m]"
    elif [ $((e * 4)) -lt $((truth * 3)) ] || [ $((e * 4)) -gt $((truth * 5)) ]; then bad="$bad [minute $m: ${e}m, truth ${truth}m]"; fi
  fi
  t=$((t + 60)); m=$((m + 1))
done
before=$e
for i in 1 2 3 4 5; do p=$((p + 2)); raw=$(wl $t A five_hour $p $rs); t=$((t + 60)); done
e=$(mins "$raw")
{ has "$raw" "${E}[31m↯" && [ "${e:-9999}" -lt "$before" ]; } || bad="$bad [after the burst: $(printf '%s' "$raw" | strip), before ${before}m]"
prev=$e
for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
  t=$((t + 300)); raw=$(wl $t A five_hour $p $rs); e=$(mins "$raw")
  if [ -z "$e" ]; then bad="$bad [blank while idle]"; elif [ "$e" -le "$prev" ]; then bad="$bad [${e}m after ${prev}m]"; fi
  prev=${e:-$prev}
done
has "$raw" "${E}[2m↯" || bad="$bad [still red after an idle hour: $(printf '%s' "$raw" | strip)]"
verdict the-rate-is-steady-then-fades "$bad"
# The same estimate in plain ASCII reads ~ for the arrow.
check ascii-burn-estimate "$(wl $((t + 300)) A five_hour $p $rs CC_ASCII=1 | strip)" "% ~" "↯"
# The weekly window: a slow, steady overspend, a point an hour from 60% with the
# reset 60 hours away, so it fills 20 hours early. Nothing below 70%; red from
# 70%. A point every 4 hours from 70% would not fill in time: dim.
anew; t=$T0 rs=$((T0 + 216000)) p=60 bad=
while [ "$p" -le 75 ]; do
  out=$(wl $t A seven_day $p $rs)
  if [ "$p" -lt 70 ]; then has "$out" '↯' && bad="$bad [shown at $p%]"
  else has "$out" "${E}[31m↯" || bad="$bad [not red at $p%: $(printf '%s' "$out" | strip)]"; fi
  t=$((t + 3600)); p=$((p + 1))
done
anew; t=$T0 p=70
while [ "$p" -le 75 ]; do out=$(wl $t A seven_day $p $rs); t=$((t + 14400)); p=$((p + 1)); done
has "$out" "${E}[2m↯" || bad="$bad [a slow week: $(printf '%s' "$out" | strip)]"
verdict weekly-overspend-shows-from-70 "$bad"
# The estimate's digits: whole minutes under an hour, never under 1m; one
# decimal under 10 hours, none on a whole hour; whole hours under 2 days; then
# whole days. Each band rounds down, so a time just short of the next band
# never prints 60m, 10.0h or 48h. Each case is a record whose pace puts 100%
# that many seconds away, read with the clock stopped.
eta() {  # eta <seconds>: the estimate drawn for a 5-hour window at 50% that fills in that many seconds
  anew; printf '%s %s %s %s 50 %s\n' $((T0 + 10800)) $((T0 - 200000)) "$T0" "$T0" \
    "$(LC_ALL=C awk -v s="$1" 'BEGIN { printf "%.12g", 50 / (s + 0.5) }')" > "$W/home/.claude/.rl-5h-state"
  wl "$T0" A five_hour 50 $((T0 + 10800)) | strip | LC_ALL=C awk '{ if (match($0, /↯[^ ]*/)) print substr($0, RSTART + 3, RLENGTH - 3) }'
}
bad=
for c in 30:1m 119:1m 1500:25m 3599:59m 3600:1h 3959:1h 3960:1.1h 5400:1.5h 35999:9.9h 36000:10h \
         129600:36h 172799:47h 172800:2d 777600:9d 100000000000000:1157407407d; do
  got=$(eta "${c%%:*}"); [ "$got" = "${c#*:}" ] || bad="$bad [${c%%:*}s: ${got:-none}, not ${c#*:}]"
done
verdict burn-estimate-digits "$bad"
# The credits check reads the freshest figure: an idle session still on 97%,
# while another has seen 100%, draws 100% and asks for the credits figures.
anew; bad=
wl $T0 A five_hour 100 $((T0 + 3600)) >/dev/null; rm -f "$W/home/.claude/.usage-attempt"
out=$(wl $((T0 + 60)) B five_hour 97 $((T0 + 3600)) | strip)
like "$out" '*5h ??:?? 100% · ¤credits' || bad=" [drew: $out]"
[ -e "$W/home/.claude/.usage-attempt" ] || bad="$bad [did not ask]"
verdict credits-from-the-freshest-figure "$bad"
# A new session has no limits until its first reply. Until then it draws each
# window from its record, while the record's reset is still to come and some
# session has seen its figure in the last 30 minutes. Each check that something
# is not drawn sits beside the same render a moment earlier, which draws it.
lim() {  # lim <time> <session> <rate_limits JSON, or '' for none> [VAR=value...]: one render
  l_t=$1 l_s=$2 l_j=; [ -n "$3" ] && l_j=",\"rate_limits\":$3"; shift 3
  printf '{"session_id":"%s","workspace":{"current_dir":"%s"}%s}' "$l_s" "$W" "$l_j" \
    | env PATH="$W/bin:$PATH" FAKE_NOW="$l_t" HOME="$W/home" CC_WIDTH=0 LC_ALL=C "$@" "$shell" "$W/statusline.sh"
}
pro() { printf '{"five_hour":{"used_percentage":%s,"resets_at":%s},"seven_day":{"used_percentage":%s,"resets_at":%s}}' "$1" "$t5" "$2" "$t7"; }
gw() { printf '{"spend_limit":{"used_percentage":%s,"resets_at":%s}}' "$1" "$2"; }
ondisk() { (cd "$W/home/.claude" && ls -A && cksum .rl-*-state) 2>/dev/null; }   # every file there, and each record's checksum
# It draws them as the session that saw them does, at the same moment: colours,
# reset times and burn estimate alike, in every width.
anew; bad=; t5=$((T0 + 10800)) t7=$((T0 + 300000))
lim $T0 A "$(pro 50 41)" >/dev/null; lim $((T0 + 300)) A "$(pro 55 41)" >/dev/null; lim $((T0 + 600)) A "$(pro 60 41)" >/dev/null
for w in 0 44 36 24; do
  a=$(lim $((T0 + 660)) A "$(pro 60 41)" CC_WIDTH=$w); b=$(lim $((T0 + 660)) B '' CC_WIDTH=$w)
  [ "$b" = "$a" ] || bad="$bad [width $w: B drew $(printf '%s' "$b" | strip), A $(printf '%s' "$a" | strip)]"
done
raw=$(lim $((T0 + 660)) B ''); out=$(printf '%s' "$raw" | strip)
like "$out" '*· 5h ??:?? 60% ↯*m · 7d ??? 41%' || bad="$bad [drew: $out]"
{ has "$raw" "${E}[33m5h " && has "$raw" "${E}[31m↯" && has "$raw" "${E}[32m7d "; } || bad="$bad [colours]"
verdict a-new-session-draws-the-shared-figures "$bad"
# Reading the records starts no process: drawing them costs a new session no
# more processes than the session that saw them pays to draw its own. Stand-ins
# first on `PATH` note each command started.
mkdir -p "$W/count"; bad=
for t in awk basename cat cut date dirname find git grep head jq ls mv perl rm sed setsid stat tr uname wc; do
  real=$(command -v "$t") || continue; [ "$t" = date ] && real="$W/bin/date"
  printf '#!/bin/sh\necho %s >> "%s/count/log"\nexec "%s" "$@"\n' "$t" "$W" "$real" > "$W/count/$t"; chmod +x "$W/count/$t"
done
: > "$W/count/log"; lim $((T0 + 660)) A "$(pro 60 41)" PATH="$W/count:$W/bin:$PATH" >/dev/null; na=$(wc -l < "$W/count/log" | tr -d ' ')
: > "$W/count/log"; out=$(lim $((T0 + 660)) B '' PATH="$W/count:$W/bin:$PATH" | strip); nb=$(wc -l < "$W/count/log" | tr -d ' ')
like "$out" '*· 5h ??:?? 60% ↯*m · 7d ??? 41%' || bad=" [drew: $out]"
[ "$nb" -le "$na" ] || bad="$bad [$nb processes, against $na: $(sort "$W/count/log" | uniq -c | tr -s ' \n' ' ')]"
verdict a-new-session-starts-no-more-processes "$bad"
# Past 30 minutes since a session last saw a window's figure, the figure may be
# old, and a new session draws none of it. Each window goes by its own: A last
# saw both at +600s, and C, with a 5-hour window of its own, saw that one rise
# at +1200s.
lim $((T0 + 1200)) C '{"five_hour":{"used_percentage":61,"resets_at":'"$t5"'}}' >/dev/null; bad=
out=$(lim $((T0 + 2400)) B '' | strip); like "$out" '*· 5h ??:?? 61% ↯* · 7d ??? 41%' || bad=" [30 minutes on: $out]"
out=$(lim $((T0 + 2401)) B '' | strip); { like "$out" '*· 5h ??:?? 61% ↯*' && ! has "$out" '· 7d'; } || bad="$bad [a second more: $out]"
out=$(lim $((T0 + 3000)) B '' | strip); like "$out" '*· 5h ??:?? 61% ↯*' || bad="$bad [30 minutes after the rise: $out]"
out=$(lim $((T0 + 3001)) B '' | strip); { has "$out" '· 5h' || has "$out" '· 7d'; } && bad="$bad [a second more: $out]"
verdict a-shared-figure-lasts-30-minutes "$bad"
# A window whose reset has passed is over: a new session draws none of it, not
# even `5h reset`, which is for a session whose own window ran out.
anew; bad=; t5=$((T0 + 900))
lim $T0 A "$(pro 70 41)" >/dev/null
out=$(lim $((T0 + 899)) B '' | strip); like "$out" '*· 5h ??:?? 70% · 7d ??? 41%' || bad=" [before the reset: $out]"
out=$(lim $((T0 + 900)) B '' | strip); { like "$out" '*· 7d ??? 41%' && ! has "$out" '· 5h'; } || bad="$bad [at the reset: $out]"
verdict a-shared-figure-ends-with-its-window "$bad"
# It only reads the records, not even moving the `seen` an equal figure moves
# every 5 minutes. B draws them at every render, yet they still lapse 30
# minutes after A last saw them.
anew; bad=; t5=$((T0 + 10800))
lim $T0 A "$(pro 64 41)" >/dev/null; before=$(ondisk)
for d in 60 400 1000 1500 1800; do
  out=$(lim $((T0 + d)) B '' | strip); like "$out" '*· 5h ??:?? 64% · 7d ??? 41%' || bad="$bad [at +${d}s: $out]"
done
[ "$(ondisk)" = "$before" ] || bad="$bad [the files changed: $(ondisk | tr '\n' ' ')]"
out=$(lim $((T0 + 1801)) B '' | strip); { has "$out" '· 5h' || has "$out" '· 7d'; } && bad="$bad [kept alive: $out]"
verdict a-new-session-only-reads-the-records "$bad"
# The gateway's cap the same way, from its own record: drawn as the gateway
# session draws it, a time within a day and a date past one, gone 30 minutes
# after that session last saw it or at its reset, and only read.
anew; bad=
for r in $((T0 + 3600)):'??:??' $((T0 + 200000)):'[0-3][0-9]/[A-Z][a-z][a-z]'; do
  f=${r#*:} r=${r%%:*}
  lim $T0 G "$(gw 85 "$r")" >/dev/null; before=$(ondisk)
  a=$(lim $((T0 + 60)) G "$(gw 85 "$r")"); b=$(lim $((T0 + 60)) B '')
  [ "$b" = "$a" ] || bad="$bad [B drew $(printf '%s' "$b" | strip), G $(printf '%s' "$a" | strip)]"
  like "$(printf '%s' "$b" | strip)" "*· cap $f 85%" || bad="$bad [drew: $(printf '%s' "$b" | strip)]"
  out=$(lim $((T0 + 1800)) B '' | strip); has "$out" '· cap ' || bad="$bad [30 minutes on: $out]"
  [ "$(ondisk)" = "$before" ] || bad="$bad [the files changed]"
  out=$(lim $((T0 + 1801)) B '' | strip); has "$out" '· cap' && bad="$bad [a second more: $out]"
  anew
done
lim $T0 G "$(gw 85 $((T0 + 600)))" >/dev/null
out=$(lim $((T0 + 599)) B '' | strip); like "$out" '*· cap ??:?? 85%' || bad="$bad [before the reset: $out]"
out=$(lim $((T0 + 600)) B '' | strip); has "$out" '· cap' && bad="$bad [at the reset: $out]"
verdict a-new-session-draws-the-gateway-cap-the-same-way "$bad"
# A payload with limits of its own draws them alone, as before: a 5-hour window
# brings no 7d from the record, a 7-day window no 5h, a gateway cap neither,
# and an Enterprise seat none of them. Only a payload with no limits at all
# draws the records.
anew; bad=; t5=$((T0 + 10800)) t7=$((T0 + 300000))
lim $T0 A "$(pro 64 41)" >/dev/null; lim $T0 G "$(gw 85 $((T0 + 3600)))" >/dev/null
out=$(lim $((T0 + 60)) B '' | strip); like "$out" '*· 5h ??:?? 64% · 7d ??? 41% · cap ??:?? 85%' || bad=" [no limits: $out]"
out=$(lim $((T0 + 60)) C '{"five_hour":{"used_percentage":64,"resets_at":'"$t5"'}}' | strip)
{ like "$out" '*· 5h ??:?? 64%' && ! has "$out" '· 7d' && ! has "$out" '· cap'; } || bad="$bad [5-hour only: $out]"
out=$(lim $((T0 + 60)) C '{"seven_day":{"used_percentage":41,"resets_at":'"$t7"'}}' | strip)
{ like "$out" '*· 7d ??? 41%' && ! has "$out" '· 5h' && ! has "$out" '· cap'; } || bad="$bad [7-day only: $out]"
out=$(lim $((T0 + 60)) C "$(gw 85 $((T0 + 3600)))" | strip)
{ like "$out" '*· cap ??:?? 85%' && ! has "$out" '· 5h' && ! has "$out" '· 7d'; } || bad="$bad [gateway only: $out]"
out=$(lim $((T0 + 60)) B '' CC_ENTERPRISE=1 | strip)
{ has "$out" '· cap' && ! has "$out" '· 5h' && ! has "$out" '· 7d' && ! has "$out" '85%'; } || bad="$bad [Enterprise: $out]"
verdict a-session-with-limits-of-its-own-is-unchanged "$bad"
# Only before the session's first reply, while it has spent nothing. A session
# that has spent something and still has no limits is on an API key, Bedrock or
# Vertex, or was resumed with its cost carried over: it draws no window from
# the records, however fresh. A cost of 0, as at the start, still draws them.
anew; bad=; t5=$((T0 + 10800)) t7=$((T0 + 300000))
lim $T0 A "$(pro 64 41)" >/dev/null
spent() {  # spent <cost>: a render a minute on, with that cost and no limits
  printf '{"session_id":"K","workspace":{"current_dir":"%s"},"cost":{"total_cost_usd":%s}}' "$W" "$1" \
    | env PATH="$W/bin:$PATH" FAKE_NOW=$((T0 + 60)) HOME="$W/home" CC_WIDTH=0 LC_ALL=C "$shell" "$W/statusline.sh" | strip
}
for c in 0 0.0; do
  out=$(spent $c); like "$out" '*· 5h ??:?? 64% · 7d ??? 41%' || bad="$bad [cost $c: $out]"
done
for c in 0.42 0.0001 1e-7; do
  out=$(spent $c); { has "$out" '· 5h' || has "$out" '· 7d'; } && bad="$bad [cost $c: $out]"
done
verdict only-before-the-first-reply "$bad"
rm -rf "$W"

# --- plain ASCII ---
# look [VAR=value...]: "ascii" or "symbols", as one subscription render draws
# it, with every input the guess reads cleared first. `uname` is a stand-in that
# answers `FAKE_UNAME` and notes each call in `$U/called`.
U=$(mktemp -d); mkdir -p "$U/bin" "$U/home/.claude"; cp "$sl" "$U/statusline.sh"
printf '#!/bin/sh\necho x >> "%s/called"\necho "${FAKE_UNAME:-Linux}"\n' "$U" > "$U/bin/uname"; chmod +x "$U/bin/uname"
look() {
  o=$(sed -e "s|__CWD__|$here|" -e "s|__T1__|$(( $(date +%s) + 7200 ))|" -e "s|__T2__|$(( $(date +%s) + 200000 ))|" "$here/payloads/subscription.json" \
    | env -u CC_ASCII -u LC_ALL -u LC_CTYPE -u LANG -u TERM -u WT_SESSION -u TERM_PROGRAM -u OS \
          HOME="$U/home" PATH="$U/bin:$PATH" CC_WIDTH=0 "$@" "$shell" "$U/statusline.sh" 2>/dev/null | strip)
  case "$o" in *'(1M) high | ctx'*) echo ascii ;; *'(1M) ◊high · ctx'*) echo symbols ;; *) echo "neither: $o" ;; esac
}
utf=LANG=en_US.UTF-8 win=OS=Windows_NT gitbash=FAKE_UNAME=MINGW64_NT-10.0-19045; bad=
for row in "ascii|CC_ASCII=1 $utf TERM_PROGRAM=x" "symbols|CC_ASCII=0 TERM=linux $win $gitbash" \
           "ascii|TERM=linux $utf" "ascii|" "ascii|LANG=C" "ascii|LANG=de_DE.ISO8859-1" \
           "symbols|$utf" "symbols|LC_CTYPE=en_US.UTF-8" "symbols|LC_ALL=C.UTF-8" "symbols|LANG=C.utf8" \
           "ascii|$utf $win $gitbash" "ascii|$utf $win FAKE_UNAME=MSYS_NT-10.0-19045" "ascii|$utf $win FAKE_UNAME=CYGWIN_NT-10.0-19045" \
           "symbols|$utf $win $gitbash WT_SESSION=0b9e" "symbols|$utf $win $gitbash TERM_PROGRAM=mintty" "symbols|$utf $win FAKE_UNAME=Linux"; do
  want=${row%%|*}; set -- ${row#*|}
  got=$(look "$@"); [ "$got" = "$want" ] || bad="$bad [${row#*|}: $got]"
done
verdict ascii-rules "$bad"
# Off Windows the guess costs no process: `uname` is never asked, even with no
# terminal named.
rm -f "$U/called"; look "$utf" "$gitbash" >/dev/null
check ascii-asks-uname-only-on-windows "$(cat "$U/called" 2>/dev/null)" "" "x"
# The whole line in plain ASCII, from a repository with an uncommitted change.
git init -q "$U/repo" 2>/dev/null; git -C "$U/repo" symbolic-ref HEAD refs/heads/main
printf 'a\n' > "$U/repo/f"; git -C "$U/repo" add f; git -C "$U/repo" -c user.name=t -c user.email=t@t commit -qm x 2>/dev/null
apay() { apayraw "$@" | strip; }   # apay <cwd> [VAR=value...]: the full subscription line, with CC_ASCII=1
apayraw() {  # the same, escape codes and all
  c=$1; shift
  printf '{"model":{"display_name":"Opus 5 (1M context)"},"effort":{"level":"high"},"workspace":{"current_dir":"%s"},"context_window":{"total_input_tokens":36400,"used_percentage":17.6},"rate_limits":{"five_hour":{"used_percentage":24,"resets_at":%s},"seven_day":{"used_percentage":62,"resets_at":%s}}}' \
    "$c" "$(( $(date +%s) + 7200 ))" "$(( $(date +%s) + 200000 ))" | env HOME="$U/home" CC_WIDTH=0 CC_ASCII=1 "$@" "$shell" "$U/statusline.sh"
}
printf 'b\n' >> "$U/repo/f"; out=$(apay "$U/repo"); bad=
like "$out" 'git:(main) \* | Opus 5 (1M) high | ctx 36.4k 18% | 5h ??:?? 24% | 7d ??? 62%' || bad=" [dirty: $out]"
[ "$(printf '%s' "$out" | LC_ALL=C tr -d '\040-\176' | wc -c | tr -d ' ')" = 0 ] || bad="$bad [not plain ASCII]"
git -C "$U/repo" checkout -q -- f; out=$(apay "$U/repo")
like "$out" 'git:(main) | Opus*' || bad="$bad [clean: $out]"
verdict ascii-full-line "$bad"
# With the symbols, an uncommitted change is a yellow ✗ and a clean tree a green ✓.
printf 'b\n' >> "$U/repo/f"; raw=$(apayraw "$U/repo" CC_ASCII=0); bad=
like "$(printf '%s' "$raw" | strip)" 'git:(main) ✗ · Opus*' || bad=" [dirty: $(printf '%s' "$raw" | strip)]"
has "$raw" "${E}[33m✗" || bad="$bad [✗ not yellow]"
git -C "$U/repo" checkout -q -- f; raw=$(apayraw "$U/repo" CC_ASCII=0)
like "$(printf '%s' "$raw" | strip)" 'git:(main) ✓ · Opus*' || bad="$bad [clean: $(printf '%s' "$raw" | strip)]"
has "$raw" "${E}[32m✓" || bad="$bad [✓ not green]"
verdict dirty-tree-is-marked "$bad"
# Narrow: a long name keeps 11 characters and "..", the same 13 columns; the
# folder has no mark; the effort alone says what it is.
mkdir -p "$U/a-very-long-folder-name"; git -C "$U/repo" checkout -q -b feat/a-long-branch-name-here; bad=
[ "$(apay "$U/repo" CC_WIDTH=35)" = 'a-long-bran.. ctx 18% 5h 24% 7d 62%' ] || bad=" [branch: $(apay "$U/repo" CC_WIDTH=35)]"
[ "$(apay "$U/a-very-long-folder-name" CC_WIDTH=35)" = 'a-very-long.. ctx 18% 5h 24% 7d 62%' ] || bad="$bad [folder: $(apay "$U/a-very-long-folder-name" CC_WIDTH=35)]"
out=$(sed -e "s|__CWD__|$here|" "$here/payloads/effort-only.json" | env HOME="$U/home" CC_WIDTH=0 CC_ASCII=1 "$shell" "$U/statusline.sh" | strip)
has "$out" ' | effort high | ctx 880' || bad="$bad [effort alone: $out]"
verdict ascii-narrow-and-effort "$bad"
rm -rf "$U"

# static guarantees
# Docs point at the scripts and never paste them: a pasted copy forks the moment
# one side is edited. A pasted body carries a shebang or the longest line of the
# script, so look for both in every doc. A missing doc is a failure too, or the
# check would pass on a path that no longer exists.
bad=
for f in "$here/../README.md" "$here"/../docs/*.md; do
  [ -f "$f" ] || { bad="$bad missing:$f"; continue; }
  grep -q '^#!/' "$f" && bad="$bad shebang:$f"
  for s in statusline.sh usage-refresh.sh; do
    longest=$(awk 'length($0) > m { m = length($0); l = $0 } END { print l }' "$here/../$s")
    [ -n "$longest" ] && grep -qF -- "$longest" "$f" && bad="$bad $s:$f"
  done
done
if [ -z "$bad" ]; then echo "ok   doc-references-not-embeds"
else echo "FAIL doc-references-not-embeds:$bad"; fails=$((fails+1)); fi
sh -n "$sl" && sh -n "$here/../usage-refresh.sh" && echo "ok   syntax" || { echo "FAIL syntax"; fails=$((fails+1)); }

[ "$fails" -eq 0 ] && echo "ALL PASS" || echo "$fails FAILED"
exit "$fails"
