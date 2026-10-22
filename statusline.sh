#!/bin/sh
# A Claude Code status line: git · model effort · context · budget.
# A window segment is <label> <when it resets> <pct>%, drawn at 0% too, and
# colour alone carries severity. Which segments appear depends on the account:
#   subscription       5h 20:57 24%, 7d Thu 62%  `rate_limits` in the payload
#   gateway spend cap  cap 23/Oct 78%            `rate_limits.spend_limit`
#   API key            $2.50, $42.60/50 85%      a local ledger, no server data
command -v jq >/dev/null 2>&1 || { printf 'statusline: jq not installed'; exit 0; }
# Every JSON file this reads goes through `jq` into an `eval` of `@sh`, and every
# field through `v(path; default)` from `$JV`, which keeps a field only when it
# is a string or a number: an array in its place would come out of `@sh` as
# several words and turn the `eval` into a command, and an object, or a path
# through a string, would fail the whole call. A string also loses its control
# characters, C0, DEL and C1 (code points 0 to 31 and 127 to 159), whatever the
# shell and locale: the folder, model and effort names reach the terminal, the
# folder inside a link, and a C1 control such as ST (U+009C) could end that
# link early in a terminal that honours them.
JV='def s: if type == "string" then explode | map(select(. >= 32 and (. < 127 or . > 159))) | implode elif type == "number" then . else empty end; def v(f; d): [f? | s][0] // d;'
# One `jq` call reads every field of the payload, straight from stdin.
eval "$(jq -r "$JV"' @sh "cwd=\(v(.workspace.current_dir; v(.cwd; ""))) mdl=\(v(.model.display_name; "")) eff=\(v(.effort.level; "")) tok=\(v(.context_window.total_input_tokens; 0)) ctxp=\(v(.context_window.used_percentage; "")) p5=\(v(.rate_limits.five_hour.used_percentage; "")) r5=\(v(.rate_limits.five_hour.resets_at; "")) p7=\(v(.rate_limits.seven_day.used_percentage; "")) r7=\(v(.rate_limits.seven_day.resets_at; "")) ps=\(v(.rate_limits.spend_limit.used_percentage; "")) rs=\(v(.rate_limits.spend_limit.resets_at; "")) usd=\(v(.cost.total_cost_usd; 0)) sid=\(v(.session_id; ""))"' 2>/dev/null)"

[ -n "$cwd" ] || cwd=$PWD
[ -n "$sid" ] || sid=-          # a session with no id still keeps its own lines
# Colours are plain variables built from one escape character. A `$(...)` per
# colour is a process per colour, and Git Bash pays for every one of them.
E=$(printf '\033')
Z="${E}[0m" DIM="${E}[2m" RED="${E}[31m" GRN="${E}[32m" YEL="${E}[33m"
MAG="${E}[35m" CYN="${E}[36m" BLU="${E}[1;34m"

# Plain ASCII or symbols. `CC_ASCII=1` forces plain ASCII, `0` keeps the
# symbols. Unset, the line goes plain where the symbols are likely to break: the
# Linux text console (`TERM=linux`), a locale that does not name UTF-8, and the
# classic Windows console, which is Git Bash with neither `WT_SESSION` (Windows
# Terminal) nor `TERM_PROGRAM` (mintty, VS Code) set. A wrong guess costs a
# plainer line, never a broken one. `uname` costs a process, so it is asked only
# on Windows (`OS=Windows_NT`) when nothing cheaper has settled the question.
asc=
case "${CC_ASCII:-}" in
  1) asc=1 ;;
  0) ;;
  *) [ "${TERM:-}" = linux ] && asc=1
     case "${LC_ALL:-} ${LC_CTYPE:-} ${LANG:-}" in *[Uu][Tt][Ff]-8*|*[Uu][Tt][Ff]8*) ;; *) asc=1 ;; esac
     if [ -z "$asc" ] && [ "${OS:-}" = Windows_NT ] && [ -z "${WT_SESSION:-}${TERM_PROGRAM:-}" ]; then
       case "$(uname -s 2>/dev/null)" in MINGW*|MSYS*|CYGWIN*) asc=1 ;; esac
     fi ;;
esac
# `SEP` between groups, `ELL` for a name cut short (after `KEEP` characters) and
# then the marks for a dirty and a clean tree, a folder outside git and the
# effort.
if [ -n "$asc" ]; then
  SEP=" ${DIM}|${Z} " ELL=.. KEEP=11 DIRTY='*' CLEAN= FOLDER= EFFORT=
else
  SEP=" ${DIM}·${Z} " ELL=… KEEP=12 DIRTY=✗ CLEAN=✓ FOLDER=⌂ EFFORT=◊
fi
now=$(date +%s)
# The login's config folder: `CLAUDE_CONFIG_DIR` when set, else `~/.claude`.
# Every state file lives there, so two logins on one machine never share one.
CLAUDE=${CLAUDE_CONFIG_DIR:-$HOME/.claude}

# at <epoch> <format>: the time in the local zone, by BSD `date -r`, else GNU
# `date -d @`. Empty for anything but a whole epoch.
at() { case "$1" in ''|*[!0-9]*) return;; esac
  date -r "$1" +"$2" 2>/dev/null || date -d "@$1" +"$2" 2>/dev/null; }
# ramp <percent>: its colour, in `$R`: green under 50, yellow from 50, red from 80
ramp() { if [ "$1" -ge 80 ]; then R=$RED; elif [ "$1" -ge 50 ]; then R=$YEL; else R=$GRN; fi; }

# width: the columns the line may take, in `$cols`, or empty when unknown.
# Claude Code passes its terminal width as `COLUMNS`, and the status line box
# loses 2 columns of padding on each side. Its `padding` setting takes 2 more
# per step, which the script cannot see: `CC_WIDTH` covers that. A positive
# `CC_WIDTH` is the width itself, a negative one is taken off `COLUMNS` instead
# of the 4, and 0 turns the fitting off. A resize alone does not re-run the
# command, so the line catches up at the next update or `refreshInterval` tick.
width() {
  cols=
  m=4
  case "${CC_WIDTH:-}" in
    0) return ;;
    -*[!0-9]*|-) ;;
    -*) m=${CC_WIDTH#-} ;;
    *[!0-9]*|'') ;;
    *) cols=$CC_WIDTH; return ;;
  esac
  c=${COLUMNS:-}
  case "$c" in ''|*[!0-9]*) return ;; esac
  # Arithmetic reads a leading 0 as octal, and `08` is an error that ends the
  # script under `dash`, so strip leading zeros first.
  m=${m#"${m%%[!0]*}"}; m=${m:-0}
  c=${c#"${c%%[!0]*}"}; c=${c:-0}
  [ "$c" -gt "$m" ] && cols=$((c - m))
}

# The line is put together at the very end, out of one variable per group:
# `sg` git, `sm` model and effort, `sc` context, `sb` budget. Each group also
# keeps one or two shorter forms (`sg1`, `sg2`, `sm1`, `sc1`, `sbs`, `sb1`) for a
# terminal too narrow for the full line. See "fit the terminal" at the bottom.

# short <text>: a text over 13 characters cut to 12 and an ellipsis, in
# `$short` (11 and `..` in plain ASCII, the same 13 columns); at 13 or fewer the
# cut would save nothing. A shell that counts bytes (`dash`, or any shell in the
# C locale) would cut a character in half. Such a shell also sees non-ASCII
# bytes as unprintable, so the `[:print:]` test leaves those names whole there,
# and a shell that counts characters cuts between characters.
short() {
  short=$1
  case "$short" in *[![:print:]]*) return ;; esac
  [ "${#short}" -gt 13 ] || return 0
  while [ "${#short}" -gt "$KEEP" ]; do short=${short%?}; done
  short="${short}${ELL}"
}

# clean <text>: the text without control characters, left in `$clean`. A folder,
# model or effort name is printed as it is, and an escape or a BEL in it could
# drive the terminal: write the clipboard (OSC 52), forge a link, clear the
# screen. Branch names need none of this, since `git` refuses control characters
# in a ref. No process: each pass drops the first control character.
clean() {
  clean=$1
  while :; do
    case "$clean" in *[[:cntrl:]]*) ;; *) return 0 ;; esac
    clean="${clean%%[[:cntrl:]]*}${clean#*[[:cntrl:]]}"
  done
}

# --- 1. git branch / directory, click-through to VS Code ---
# A terminal hyperlink (OSC 8) wraps the segment: `lk` opens it, `fz` closes it.
# The path goes inside the escape sequence, where a control character (a BEL)
# could end the link early and start a forged one. The payload's path arrives
# without them (`$JV`); `$PWD`, its fallback, gets no link if it has one.
lk="${E}]8;;vscode://file${cwd}${E}\\" fz="${E}]8;;${E}\\"
case "$cwd" in *[[:cntrl:]]*) lk= fz= ;; esac
# `-C` runs `git` in the session's folder from the payload, wherever this script
# was started. `git`'s ownership guard stays on: `git status` in a repository
# owned by another account would run that repository's commands as you (a
# `core.fsmonitor` hook, a clean filter). `git` refuses such a repository, and
# then the line shows the folder instead. `GIT_OPTIONAL_LOCKS=0` keeps
# `git status` from refreshing the index and writing it back: a `git commit`
# started at that moment would fail on the index lock.
g() { GIT_OPTIONAL_LOCKS=0 git -C "$cwd" "$@" 2>/dev/null; }
br=$(g symbolic-ref --short HEAD)
if [ -n "$br" ]; then
  # the mark brings its own space, so a clean tree in plain ASCII adds nothing
  if [ -n "$(g status --porcelain | head -1)" ]; then f=" ${YEL}${DIRTY}"; else f="${CLEAN:+ ${GRN}$CLEAN}"; fi
  sg="${lk}${BLU}git:(${RED}${br}${BLU})${f}${Z}${fz}"
  sg1="${lk}${RED}${br}${f}${Z}${fz}"
  short "${br#*/}"               # `feat/narrow-layout` reads `narrow-layout`
  sg2="${lk}${RED}${short}${f}${Z}${fz}"
else
  clean "$(basename "$cwd")"; dir=$clean
  sg="${lk}${CYN}${FOLDER}${dir}${Z}${fz}"; sg1=$sg
  short "$dir"
  sg2="${lk}${CYN}${FOLDER}${short}${Z}${fz}"
fi

# --- 2. model, 3. effort: one group, a space between the two and no dot ---
clean "$mdl"; mdl=$clean; clean "$eff"; eff=$clean
# "Opus 5 (1M context)" reads "Opus 5 (1M)": the first " context)" loses its word.
case "$mdl" in *" context)"*) mdl="${mdl%% context)*})${mdl#* context)}" ;; esac
sm= sm1=
[ -n "$mdl" ] && { sm="${YEL}${mdl}${Z}"; sm1="${YEL}${mdl%% (*}${Z}"; }      # `sm1`: no "(1M)"
if [ -n "$eff" ]; then
  # Plain ASCII has no mark for the effort: after the model the level reads as
  # itself, alone it says what it is.
  ef="${MAG}${EFFORT}${eff}${Z}"
  [ -n "$asc" ] && [ -z "$mdl" ] && ef="${DIM}effort${Z} ${MAG}${eff}${Z}"
  sm="${sm:+$sm }$ef"; sm1="${sm1:+$sm1 }$ef"
fi

# --- 4. context window: raw / 36.4k / 235k ---
sc= sc1=
if [ "$tok" -gt 0 ] 2>/dev/null; then
  if [ "$tok" -lt 1000 ]; then k=$tok
  elif [ "$tok" -lt 100000 ]; then k=$(awk "BEGIN{printf\"%.1fk\",$tok/1000}")
  else k="$(( (tok + 500) / 1000 ))k"; fi
  sc="${DIM}ctx${Z} ${k}"; sc1=$sc
  # The share can be missing early in a session; then only the token count shows.
  if [ -n "$ctxp" ]; then
    ci=$(printf '%.0f' "$ctxp" 2>/dev/null)
    ramp "${ci:-0}" 2>/dev/null; sc="${sc} ${R}${ci}%${Z}"
    sc1="${DIM}ctx${Z} ${R}${ci}%${Z}"                # `sc1`: the share alone
  fi
fi

# Budget items collect three times over: `$sb` in full with a dot between items,
# `$sbs` the same with a space, and `$sb1` bare: the label and the figure,
# without the reset stamp or the dollars.
# add <full> [bare]: an item with no shorter form passes one argument
sb= sbs= sb1=
add() { sb="${sb:+$sb$SEP}$1"; sbs="${sbs:+$sbs }$1"; sb1="${sb1:+$sb1 }${2:-$1}"; }

# window <pct> <resets_at> <label> <time-format>: one window as a budget item.
# The label carries its own trailing space ("5h "), so the bare form reads
# 5h 24%.
window() {
  p=$(printf '%.0f' "$1" 2>/dev/null) || return
  [ "$p" -lt 0 ] && return                            # a negative figure is garbage
  stamp=$(at "$2" "$4")
  ramp "$p"
  add "${R}$3${stamp:+$stamp }${p}%${Z}" "${R}$3${p}%${Z}"
}

# --- 5. budget: always shown, colour carries severity, no threshold gating ---
[ -n "$p5" ] && window "$p5" "$r5" "5h " "%H:%M"   # 5-hour window
[ -n "$p7" ] && window "$p7" "$r7" "7d " "%a"      # 7-day window
if [ -n "$ps" ]; then                                  # gateway spend cap
  # Arithmetic on a reset time that is not a whole epoch (1792730959.5, an ISO
  # date) would end the script and blank the line. Such a time gets no stamp.
  fmt=%H:%M
  # The time when the reset is within a day, else the date.
  case "$rs" in ''|*[!0-9]*) ;; *) [ $((rs - now)) -gt 86400 ] && fmt=%d/%b ;; esac
  window "$ps" "$rs" "cap " "$fmt"
elif [ -z "$p5" ]; then
  # No limits in the payload (API key, Bedrock, Vertex). Claude Code only
  # reports this session's estimated cost, all it has spent since it started,
  # so keep a local ledger per period, one line per session:
  #   <period> <session> <cost> <base> <seen>
  # `cost` is the session's cost at its last render, `seen` when that was, and
  # `base` its cost when the period began for it: the last cost it showed in an
  # earlier period. It counts `cost - base` toward its period, so a session
  # open across midnight, the week or the 1st brings none of the spend from
  # before. A line from an earlier period stays as that session's base, not
  # counted, until it has not been seen for 8 days (a line from before there
  # were stamps goes at once). A cost that went down is a counter that started
  # over. `CC_SPEND_PERIOD` is `day`, `week` or `month`
  # (the default); `CC_SPEND_CAP=<usd>` turns the sum into a share of that cap.
  case "${CC_SPEND_PERIOD:-month}" in day) pk=$(date +%Y%m%d);; week) pk=$(date +%GW%V);; *) pk=$(date +%Y%m);; esac
  led="$CLAUDE/.spend-ledger"; [ -f "$led" ] || true 2>/dev/null > "$led"
  sum=$(awk -v k="$pk" -v s="$sid" -v u="$usd" -v now="$now" -v o="$led.$$" '
    { c = $3 + 0; b = $4 + 0 }
    $2 == s { if ($1 == k) { base = b; mine = 1 } else if (!mine) base = c; next }
    $1 == k { print $1, $2, $3, b, ($5 == "" ? now : $5) > o; if (c > b) t += c - b; next }
    $5 != "" && $5 + 0 > now - 691200 { print $1, $2, $3, b, $5 > o }
    END { u += 0; if (u < base) base = 0
          printf "%s %s %.4f %.4f %d\n", k, s, u, base, now > o; close(o)
          printf "%.4f", t + u - base }' "$led" 2>/dev/null)
  mv -f "$led.$$" "$led" 2>/dev/null || rm -f "$led.$$" 2>/dev/null
  [ -z "$sum" ] && sum=$usd
  # `CC_SPEND_CAP` is a positive number of dollars, or it is ignored. Like the
  # sum, it reaches `awk` as a variable, never as program text, so a stray value
  # cannot run as code.
  cap=${CC_SPEND_CAP:-}
  case "$cap" in ''|*[!0-9.]*|*.*.*) cap= ;; *[1-9]*) ;; *) cap= ;; esac
  money=$(awk -v s="$sum" 'BEGIN { printf "%.2f", s }')
  if [ -n "$cap" ]; then
    p=$(awk -v s="$sum" -v c="$cap" 'BEGIN { printf "%d", s / c * 100 }')
    ramp "$p"
    add "${R}\$${money}/${cap} ${p}%${Z}" "${R}cap ${p}%${Z}"
  elif [ "$money" != "0.00" ]; then
    add "\$${money}"
  fi
fi

# --- fit the terminal ---
# join <separator> <group>...: the groups that are not empty, in `$line`
join() { j=$1; shift; line=; for s in "$@"; do [ -n "$s" ] && line="${line:+$line$j}$s"; done; }

join "$SEP" "$sg" "$sm" "$sc" "$sb"; full=$line
width
[ -n "$cols" ] || { printf '%s' "$full"; exit 0; }

# Narrower forms, each giving up a little more. The budget is the point of the
# line, so it goes last and never entirely. `awk` prints the first form that
# fits in `$cols` columns, or the last one when none does.
join "$SEP" "$sg1" "$sm"  "$sc"  "$sb";  l1=$line   # no `git:( )` around the branch
join ' '    "$sg1" "$sm"  "$sc"  "$sbs"; l2=$line   # spaces for the dots
join ' '    "$sg1" "$sm1" "$sc1" "$sbs"; l3=$line   # no (1M), no token count
join ' '    "$sg2" "$sm1" "$sc1" "$sbs"; l4=$line   # branch without its type, cut short
join ' '    "$sg2" "$sm1" "$sc1" "$sb1"; l5=$line   # budget bare: label and figure
join ' '    "$sg2" "$sc1" "$sb1";        l6=$line   # no model, no effort
join ' '    "$sc1" "$sb1";               l7=$line   # no branch
# Width is counted the way a terminal draws: colour codes and the hyperlink
# wrapper take no room, and a character is one column however many bytes it is.
# In the C locale `awk` sees bytes, so dropping UTF-8 continuation bytes (octal
# 200 to 277) leaves one byte per character.
LC_ALL=C awk -v w="$cols" 'BEGIN {
  for (i = 1; i < ARGC; i++) {
    if (ARGV[i] == "") continue
    s = pick = ARGV[i]
    gsub(/\033\]8;;[^\033]*\033\\/, "", s)
    gsub(/\033\[[0-9;]*m/, "", s)
    gsub(/[\200-\277]/, "", s)
    if (length(s) <= w) break
  }
  printf "%s", pick
}' "$full" "$l1" "$l2" "$l3" "$l4" "$l5" "$l6" "$l7" "$sb1" 2>/dev/null || printf '%s' "$full"
