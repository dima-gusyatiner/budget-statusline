#!/bin/sh
# Tests for `statusline.sh`. POSIX sh, no framework. Each case pipes a payload
# through the script with `HOME` pointed at a scratch folder, then checks the
# output with the colour codes stripped. Every failure is counted, and the exit
# status is the number of failures.
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
unset CC_WIDTH CC_SPEND_CAP CC_SPEND_PERIOD CC_ASCII COLUMNS
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
# The gateway cap's reset: a date when it is more than a day away, the time of
# day when it is sooner.
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

# --- several sessions: one record per window (see "one record per window" in `statusline.sh`) ---
# A `date` shim fakes the clock for `date +%s` alone (`FAKE_NOW`), so a window can
# be played through in a moment; every other call reaches the real date. Each
# render names its session, so two sessions on one machine can take turns.
W=$(mktemp -d); mkdir -p "$W/bin" "$W/home/.claude"; cp "$sl" "$W/statusline.sh"
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
  printf '%s' "$1" | strip | LC_ALL=C awk '{ if (match($0, /↯[0-9.]+[mh]/)) {
    s = substr($0, RSTART + 3, RLENGTH - 3); n = substr(s, 1, length(s) - 1) + 0
    if (s ~ /h$/) n = int(n * 60 + 0.5)
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
sh -n "$sl" && echo "ok   syntax" || { echo "FAIL syntax"; fails=$((fails+1)); }

[ "$fails" -eq 0 ] && echo "ALL PASS" || echo "$fails FAILED"
exit "$fails"
