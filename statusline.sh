#!/bin/sh
# A Claude Code status line: git · model effort · context · budget.
# A window segment is <label> <when it resets> <pct>%, drawn at 0% too, and
# colour alone carries severity. Which segments appear depends on the account:
#   subscription       5h 20:57 24%, 7d Thu 62%  `rate_limits` in the payload
#   gateway spend cap  cap 23/Oct 78%            `rate_limits.spend_limit`
#   enterprise seat    cap 01/Nov 80%            `usage-refresh.sh`, no limits sent
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
# One `jq` call reads every field of the payload, straight from stdin. The
# `eol=1` at the end is a field nobody reads: a native Windows `jq` ends its
# output with a carriage return, and it lands there instead of in `ver`.
eval "$(jq -r "$JV"' @sh "cwd=\(v(.workspace.current_dir; v(.cwd; ""))) mdl=\(v(.model.display_name; "")) eff=\(v(.effort.level; "")) tok=\(v(.context_window.total_input_tokens; 0)) ctxp=\(v(.context_window.used_percentage; "")) p5=\(v(.rate_limits.five_hour.used_percentage; "")) r5=\(v(.rate_limits.five_hour.resets_at; "")) p7=\(v(.rate_limits.seven_day.used_percentage; "")) r7=\(v(.rate_limits.seven_day.resets_at; "")) ps=\(v(.rate_limits.spend_limit.used_percentage; "")) rs=\(v(.rate_limits.spend_limit.resets_at; "")) usd=\(v(.cost.total_cost_usd; 0)) sid=\(v(.session_id; "")) ver=\(v(.version; "")) eol=1"' 2>/dev/null)"

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
# for a figure on its way, then the marks for a dirty and a clean tree, a
# folder outside git, the effort and the burn estimate.
if [ -n "$asc" ]; then
  SEP=" ${DIM}|${Z} " ELL=.. KEEP=11 DIRTY='*' CLEAN= FOLDER= EFFORT= BURN='~'
else
  SEP=" ${DIM}·${Z} " ELL=… KEEP=12 DIRTY=✗ CLEAN=✓ FOLDER=⌂ EFFORT=◊ BURN=↯
fi
now=$(date +%s)
# The login's config folder: `CLAUDE_CONFIG_DIR` when set, else `~/.claude`.
# Every state file lives there, so two logins on one machine never share one.
CLAUDE=${CLAUDE_CONFIG_DIR:-$HOME/.claude}
# Claude Code's own state file for this login: `.claude.json` in
# `CLAUDE_CONFIG_DIR` when set, else in the home folder, unless the config folder
# holds a `.config.json`, the name older Claude Code versions used.
cj="$CLAUDE/.config.json"; [ -f "$cj" ] || cj="${CLAUDE_CONFIG_DIR:-$HOME}/.claude.json"

# `sh` has no `local`, so the longer functions prefix their working variables
# (`yg_`, `r_`) to keep clear of the globals.

# at <epoch> <format>: the time in the local zone, by BSD `date -r`, else GNU
# `date -d @`. Empty for anything but a whole epoch.
at() { case "$1" in ''|*[!0-9]*) return;; esac
  date -r "$1" +"$2" 2>/dev/null || date -d "@$1" +"$2" 2>/dev/null; }
# agefmt <seconds>: 12m, 3h or 6d, for stamping how old a cached figure is
agefmt() { if [ "$1" -ge 86400 ]; then printf '%dd' $(($1 / 86400))
  elif [ "$1" -ge 3600 ]; then printf '%dh' $(($1 / 3600))
  else printf '%dm' $(($1 / 60)); fi; }
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

# young <file>: true when the file exists and was written in the last 8 days.
# `date -r` reads a file's time on both BSD and GNU; `stat` differs between
# them, so it is the fallback and needs both spellings.
young() {
  [ -f "$1" ] || return 1
  yg_m=$(date -r "$1" +%s 2>/dev/null || stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null) || return 1
  case "$yg_m" in ''|*[!0-9]*) return 1 ;; esac
  [ $((now - yg_m)) -lt 691200 ]
}

# The enterprise path (keychain, usage endpoint) runs only where it applies.
# `CC_ENTERPRISE=1` forces it on, `0` forces it off. Unset, it runs when
# `.claude.json` names an enterprise usage-based seat or an earlier fetch left a
# snapshot under 8 days old (the latch below). Otherwise an API-key machine
# with a leftover claude.ai login would send that token upstream every hour.
case "${CC_ENTERPRISE:-}" in
  1) ent=1 ;;
  0) ent= ;;
  *) ent=
     # The latch: a machine that fetched a valid snapshot in the last 8 days
     # stays on through it, even if the string in `.claude.json` moves, and
     # `grep` is not needed. An older one no longer holds: an API-key machine
     # with a leftover snapshot would read the keychain hourly and draw "login"
     # in place of its dollars.
     if young "$CLAUDE/.usage-cache.json" || grep -qs enterprise_usage_based "$cj"; then
       ent=1
     fi ;;
esac

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

# --- one record per window, shared by every session of this login ---
# A session only hears the replies to its own requests, so an idle one keeps
# showing the figures it heard last. The record keeps what all of them have
# seen of one window, as one line in `.rl-<key>-state` in the config folder:
#   <window> <born> <rose> <seen> <percent> <pace>
# A window is its key (`5h`, `7d`, `gateway`, `spend` for the Enterprise cap,
# `ledger`) plus its reset time. A reset time more than 10 minutes later starts
# a new record; within 10 minutes it is the same window, whatever the percentage
# does. An earlier one is a session still on the last window, and it leaves the
# record alone. While its window lasts it draws its own figure; once that window
# is over, the record's newer one. A window whose reset time has passed, with no
# newer one known, reads "5h reset" in dim until a reply brings the new window:
# its old figure no longer counts, and its old stamp would read as the next
# reset.
# Within a window usage only goes up: a higher figure raises the record, a lower
# one is an older reading and never lowers it. `seen` is the last time a
# session's own figure reached the record's. While that is under 30 minutes
# ago, a session whose own figure is lower draws the record's; past that, its
# own, which is how a figure the server lowers gets in. (A figure every session
# reads from one file is the exception, see `record`.)
# The burn estimate comes from the record's rises: `pace`, in points a second,
# is an exponentially weighted moving average of them. A rise counts in full
# when it comes and fades with time constant `tau`, 30 minutes on the 5-hour
# window and a day on the longer ones, both picked by simulating several
# methods on synthetic usage. It is never restarted within a window, so it does
# not go blank. The first 2 minutes of a record only raise it: every open
# session draws in that time, and a record born from an idle session's old
# figure would read the others catching up as a burst. The estimate waits until
# the pace is 5 minutes old: 7 minutes into a record.

# record <key> <percent> <window> [shared]: the figure to draw in `$rf` and its
# window in `$rw`, the burn estimate in `$bt` (" ↯25m", dim or red, or nothing).
# The window is a reset time, or a name for a period (the local ledger, which
# has none). `shared`: every session reads this figure from one file (the
# enterprise snapshot), so a lower one is the server's newer word, a raised cap
# say, and starts the record again instead of being outvoted.
record() {
  rf=$2 rw=$3 bt= r_st="$CLAUDE/.rl-$1-state" r_k=$1 r_p=$2 r_w=$3 r_sh=${4:-} r_rise=0 r_wr=
  case "$r_p" in ''|*[!0-9]*) return ;; esac
  case "$r_w" in ''|0*|*[!0-9A-Za-z]*) return ;; esac
  # seconds to the reset, for a window that is a reset time; none for a name
  r_l=; case "$r_w" in *[!0-9]*) ;; *) r_l=$((r_w - now)) ;; esac
  fields "$r_st"
  if [ -n "$r_ok" ]; then
    case "$r_W$r_w" in
      *[!0-9]*) [ "$r_W" = "$r_w" ] || r_ok= ;;
      *) [ $((r_w - r_W)) -gt 600 ] && r_ok=
         if [ $((r_w - r_W)) -lt -600 ]; then
           [ "$r_w" -gt "$now" ] || rf=$r_P rw=$r_W    # over: the newer window
           return
         fi ;;
    esac
    # a time from the future: the clock moved back, so the record cannot be read
    { [ "$r_T" -gt $((now + 60)) ] || [ "$r_S" -gt $((now + 60)) ]; } && r_ok=
  fi
  if [ -z "$r_ok" ] || { [ -n "$r_sh" ] && [ "$r_p" -lt "$r_P" ]; }; then
    keep "$r_st" "$r_w $now $now $now $r_p 0"
    return
  fi
  if [ "$r_p" -gt "$r_P" ]; then
    [ $((now - r_B)) -ge 120 ] && r_rise=$((r_p - r_P))
    [ "$r_rise" -gt 0 ] || r_T=$now
    r_W=$r_w r_P=$r_p r_S=$now r_wr=1
  elif [ "$r_p" -eq "$r_P" ]; then
    # seen moves on at most every 5 minutes: a write on every render would cost
    # a process each time, and the 30 minutes do not need it
    [ $((now - r_S)) -ge 300 ] && r_S=$now r_wr=1
  elif [ $((now - r_S)) -le 1800 ]; then
    rf=$r_P
  else
    return
  fi
  estimate
  # a rise the maths could not take in is not written, so the next render has it
  if [ "$r_rise" -gt 0 ]; then
    if [ -n "$r_e" ]; then r_E=$r_e r_T=$now; else r_wr=; fi
  fi
  [ -n "$r_wr" ] && keep "$r_st" "$r_W $r_B $r_T $r_S $r_P $r_E"
  burnmark
}
# fields <file>: a record's fields into `$r_W`, `$r_B`, `$r_T`, `$r_S`, `$r_P`
# and `$r_E`, with `$r_ok` set when all of them are well formed. Every field is
# checked: arithmetic reads `08` as bad octal, which ends the script under
# `dash`, and anything else would be a guess.
fields() {
  r_W= r_B= r_T= r_S= r_P= r_E= r_ok=1
  [ -r "$1" ] && read -r r_W r_B r_T r_S r_P r_E _ 2>/dev/null < "$1"
  for r_f in "$r_B" "$r_T" "$r_S" "$r_P"; do
    case "$r_f" in 0) ;; ''|0*|*[!0-9]*) r_ok= ;; esac
  done
  case "$r_W" in ''|0*|*[!0-9A-Za-z]*) r_ok= ;; esac
  case "$r_E" in ''|*[!0-9.e+-]*) r_ok= ;; esac
}
# estimate: the record's pace after this render in `$r_e`, and when the estimate
# shows, the time to 100% in `$r_eta` ("25m", "4.5h", "36h", "2d") and 1 in
# `$r_red` when that comes before the reset. It reads `$r_k`, `$rf`, `$r_B`,
# `$r_T`, `$r_E`, `$r_l` and `$r_rise`, as `record` leaves them.
# The time has a decimal only under 10 hours, where it still changes what to do:
# whole minutes under an hour, never under 1m; tenths of an hour under 10 hours,
# with no ".0" on a whole hour; whole hours under 2 days; whole days from there.
# Each band rounds down, so a time on its way to the next band never prints
# that band's first value: 59m59s reads 59m, never 60m, then 10.0h and 48h.
# Shown from 50% on the 5-hour window and 70% on longer ones, below 100%, once
# the pace is 5 minutes old, and never for a window whose reset has passed:
# `window()` draws no estimate for one, and leaving `r_show` empty there spares
# the `awk` call below on every render until the next window arrives. One `awk`
# call does the maths and the time format.
estimate() {
  case "$r_k" in 5h) r_tau=1800 r_gate=50 ;; *) r_tau=86400 r_gate=70 ;; esac
  r_show=
  [ "$rf" -ge "$r_gate" ] && [ "$rf" -lt 100 ] && [ $((now - r_B)) -ge 420 ] &&
    { [ -z "$r_l" ] || [ "$r_l" -gt 0 ]; } && r_show=1
  r_e= r_eta= r_red=
  [ "$r_rise" -gt 0 ] || { [ -n "$r_show" ] && [ "$r_E" != 0 ]; } || return 0
  set -- $(awk -v e="$r_E" -v dt=$((now - r_T)) -v age=$((now - r_B - 120)) -v tau="$r_tau" \
               -v rise="$r_rise" -v cur="$rf" -v show="$r_show" -v left="$r_l" 'BEGIN {
    if (dt < 0) dt = 0
    e = e * exp(-dt / tau) + rise / tau
    printf "%.6g", e
    if (show == "" || e <= 0) exit
    eta = int((100 - cur) / (e / (1 - exp(-age / tau))))
    if (eta < 3600) { n = int(eta / 60); printf " %dm", (n < 1 ? 1 : n) }
    else if (eta < 36000) { n = int(eta / 360); if (n % 10) printf " %d.%dh", int(n / 10), n % 10; else printf " %dh", n / 10 }
    else if (eta < 172800) printf " %dh", int(eta / 3600)
    else printf " %.0fd", int(eta / 86400)
    printf " %d", (left != "" && eta < left + 0)
  }' 2>/dev/null)
  r_e=${1:-} r_eta=${2:-} r_red=${3:-}
}
# burnmark: the estimate as it is drawn, in `$bt`: " ↯25m", dim, or red when the
# window would fill before its reset; nothing when there is no estimate
burnmark() {
  bt=; [ -n "$r_eta" ] || return 0
  r_c=$DIM; [ "$r_red" = 1 ] && r_c=$RED
  bt=" ${r_c}${BURN}$r_eta${Z}"
}
# keep <file> <text>: the text into the file, through a temporary file so no
# reader sees it half written. False when it could not be written.
keep() {
  printf '%s\n' "$2" 2>/dev/null > "$1.$$" && mv -f "$1.$$" "$1" 2>/dev/null && return 0
  rm -f "$1.$$" 2>/dev/null; return 1
}

# Budget items collect three times over: `$sb` in full with a dot between items,
# `$sbs` the same with a space, and `$sb1` bare: the label and the figure,
# without the reset stamp, the burn estimate or the dollars.
# add <full> [bare]: an item with no shorter form passes one argument
# more <text>: more of the last item, in all three forms (a reason)
sb= sbs= sb1=
add() { sb="${sb:+$sb$SEP}$1"; sbs="${sbs:+$sbs }$1"; sb1="${sb1:+$sb1 }${2:-$1}"; }
more() { sb="$sb$1"; sbs="$sbs$1"; sb1="$sb1$1"; }

# window <pct> <resets_at> <label> <time-format> <state-key> [mid] [shared]: one
# window as a budget item. The label carries its own trailing space ("5h "), so
# the bare form reads 5h 24%.
window() {
  rw=$2
  p=$(printf '%.0f' "$1" 2>/dev/null) || return
  [ "$p" -lt 0 ] && return                            # a negative figure is garbage
  stamp=$(at "$2" "$4")
  record "$5" "$p" "$2" "${7:-}"; p=$rf
  case "$rw" in ''|*[!0-9]*) ;; *) [ "$rw" -gt "$now" ] || { add "${DIM}$3reset${Z}"; return 0; } ;; esac
  [ "$rw" = "$2" ] || stamp=$(at "$rw" "$4")         # the record's newer window
  ramp "$p"
  add "${R}$3${stamp:+$stamp }${6:+$6 }${p}%${Z}${bt}" "${R}$3${p}%${Z}"
}

# detach <command...>: run it in the background, in a session of its own.
# Claude Code stops a status line run that a newer one replaces by signalling
# its whole process group, and a refresher started plainly with `&` sits in
# that group, `curl` and all. `setsid` does it on Linux, `perl` on a Mac;
# failing both, `nohup`, which survives a hangup but not that signal.
detach() {
  if command -v setsid >/dev/null 2>&1; then
    (setsid "$@" >/dev/null 2>&1 </dev/null &) 2>/dev/null
  elif command -v perl >/dev/null 2>&1; then
    (perl -MPOSIX -e 'POSIX::setsid(); exec @ARGV or exit 1' "$@" >/dev/null 2>&1 </dev/null &) 2>/dev/null
  else
    (nohup "$@" >/dev/null 2>&1 </dev/null &) 2>/dev/null
  fi
}

# monthreset: the epoch of the next UTC month boundary in `$mr`, and of this
# month's in `$ms`, or both empty. The usage reply has no reset time for the
# monthly cap, but a 429 from the server carried `resetsAt` of exactly
# 2026-09-01T00:00Z, the 1st in UTC, so this follows a checked value. This month
# began exactly its number of days before the next boundary, since UTC has no
# daylight saving: no second `date` call.
monthreset() {
  y=$(date -u +%Y) m=$(date -u +%m)
  # Arithmetic reads a leading 0 as octal, so `08` and `09` would fail. Strip it
  # by hand: the `bash` spelling `10#$m` is rejected by `dash`.
  m=${m#0}
  case "$m" in
    2) dm=28; [ $((y % 4)) = 0 ] && { [ $((y % 100)) != 0 ] || [ $((y % 400)) = 0 ]; } && dm=29 ;;
    4|6|9|11) dm=30 ;;
    *) dm=31 ;;
  esac
  m=$((m + 1)); [ "$m" -gt 12 ] && { m=1; y=$((y + 1)); }
  d=$(printf '%04d-%02d-01' "$y" "$m")
  mr=$(TZ=UTC date -j -f '%Y-%m-%d %H:%M:%S' "$d 00:00:00" +%s 2>/dev/null ||
    date -u -d "$d 00:00:00" +%s 2>/dev/null)
  ms=; case "$mr" in ''|*[!0-9]*) mr= ;; *) ms=$((mr - dm * 86400)) ;; esac
}


# failure <file>: why the last refresh failed, if it did, into `$why` and
# `$wdetail`, when in `$wat`, and how long to wait before retrying: `$backoff`
# in minutes from `$wat`, or `$until`, an epoch, after a 429 ("throttled
# <epoch>"). A network blip is worth another go soon, a rejected login is not.
failure() {
  dead=$1; why=; wdetail=; wat=0; backoff=60; until=0
  [ -f "$dead" ] || return 0
  { read -r why wdetail; read -r wat; } < "$dead" 2>/dev/null
  case "$why" in
    offline)   backoff=2 ;;   # transient: the 5-minute gap is the real wait
    http)      backoff=10 ;;  # server said no; give it a rest
    throttled) backoff=0; until=${wdetail%% *} ;;
    expired)   backoff=0 ;;   # no call went out: the shorter gap below is the wait
    # A rejected login with its token's fingerprint: the refresher sends nothing
    # while the token is the same, so it can look every 5 minutes for a new one.
    login)     [ -n "$wdetail" ] && backoff=0 ;;
    norefresher) backoff=0 ;; # no call either: looked for again after the gap
    *)         backoff=60 ;;  # nologin, a bare login, nocurl, tls, api, nofigure: hourly
  esac
  case "$until" in ''|*[!0-9]*) until=0 ;; esac
  # The refresher never asks for more than an hour. Further out, the clock
  # moved: a 30-day wait would read "clears itself" for 30 days.
  [ "$until" -gt $((now + 3600)) ] && until=0
  # When it was written. Missing (an older file), garbled, or in the future,
  # where a clock moved back leaves it: long ago, so its wait is over.
  case "$wat" in ''|0*|*[!0-9]*) wat=0 ;; esac
  [ "$wat" -gt $((now + 60)) ] && wat=0
  return 0
}

# ask_refresh <arguments...>: start `usage-refresh.sh` with them, unless a call
# went out in the last 5 minutes or the last failure (read by `failure` first)
# says to wait. At most one call every 5 minutes, whatever asks for it: one a
# minute through a burst of spend is enough to draw a 429. The attempt file
# holds the time of the last call; an empty or garbled one counts as long ago. A
# token found expired sent nothing, so the next look comes after 2 minutes:
# Claude Code renews the token on its next request.
ask_refresh() {
  att="$CLAUDE/.usage-attempt"; last= gap=300
  [ "$why" = expired ] && gap=120
  [ -r "$att" ] && read -r last < "$att" 2>/dev/null
  case "$last" in ''|*[!0-9]*) last=0 ;; esac
  [ "$last" -gt "$now" ] && last=0          # a call "in the future": the clock moved back
  { [ $((now - last)) -ge "$gap" ] && [ "$now" -ge "$until" ]; } || return 0
  [ -f "$dead" ] && [ "$backoff" != 0 ] && [ $((now - wat)) -lt $((backoff * 60)) ] && return 0
  # The refresher beside this script first, so the two are always one version,
  # then the canonical install. It is looked for before anything is written:
  # with none that can run, no figure would ever come and nothing would say why.
  ur="$(CDPATH= cd -- "$(dirname -- "$0")" 2>/dev/null && pwd)/usage-refresh.sh"
  [ -x "$ur" ] || ur="$CLAUDE/usage-refresh.sh"
  # The time goes in first. If it cannot be written, no call: an unwritable
  # file would otherwise mean a call on every render.
  keep "$att" "$now" || return 0
  if [ ! -x "$ur" ]; then
    # Said like any other failure, and looked for again after the gap.
    keep "$dead" "norefresher
$now"; why=norefresher
    return 0
  fi
  detach "$ur" "$@"
  return 0
}

# reason: the last failure in words, in `$rt`, and in `$rc` the colour of who
# has to act: dim nothing for you to do, yellow you fix it, red the contract
# broke.
# Returns 1 when there is no reason it knows to show.
reason() {
  case "$why" in
    offline)   rc=$DIM rt=offline ;;
    throttled) rc=$DIM rt=throttled ;;      # HTTP 429: it clears itself
    expired)   rc=$DIM rt=login ;;          # Claude Code renews the token itself
    nofigure)  rc=$DIM rt='no figure' ;;    # the server has no figure for this seat
    login|nologin) rc=$YEL rt=login ;;
    nocurl)    rc=$YEL rt='no curl' ;;
    norefresher) rc=$YEL rt='no refresher' ;;   # `usage-refresh.sh` missing, or not executable
    tls)       rc=$YEL rt=tls ;;            # a certificate or handshake refused
    http)      rc=$RED rt="http ${wdetail}" ;;
    api)       rc=$RED rt='api moved' ;;
    *)         return 1 ;;
  esac
}
# said <label>: the reason as a budget item of its own, "cap login"
said() { reason && add "${rc}$1${rt}${Z}"; }
# beside <fetched at>: the reason after the figure drawn last, when the failure
# came after that figure was fetched. The figure is the last one known, and the
# reason says why no newer one came, at any age.
beside() { [ -n "$why" ] && [ "$wat" -ge "$1" ] && reason && more " ${rc}${rt}${Z}"; return 0; }

# money <minor units> <currency>: 1240 USD reads $12.40, 1240 EUR reads 12.40 EUR.
# The values reach `awk` as variables, never as program text.
money() {
  awk -v a="$1" -v c="$2" 'BEGIN { if (c == "USD") printf "$%.2f", a / 100; else printf "%.2f %s", a / 100, c }'
}

# --- 5. budget: always shown, colour carries severity, no threshold gating ---
[ -n "$p5" ] && window "$p5" "$r5" "5h " "%H:%M" 5h   # 5-hour window
[ -n "$p7" ] && window "$p7" "$r7" "7d " "%a"    7d   # 7-day window
if [ -n "$ps" ]; then                                  # gateway spend cap
  # Arithmetic on a reset time that is not a whole epoch (1792730959.5, an ISO
  # date) would end the script and blank the line. Such a time gets no stamp.
  fmt=%H:%M
  # The time when the reset is within a day, else the date as the Enterprise
  # cap writes it: 23.10 beside a dollar figure would read as an amount.
  case "$rs" in ''|*[!0-9]*) ;; *) [ $((rs - now)) -gt 86400 ] && fmt=%d/%b ;; esac
  window "$ps" "$rs" "cap " "$fmt" gateway
elif [ -z "$p5" ] && [ -n "$ent" ]; then
  # Enterprise usage-based seat: no `rate_limits` in the payload at all, so the
  # figures come from the server through `usage-refresh.sh`, which leaves a
  # snapshot of about 120 bytes. Every name this uses starts empty here, so
  # nothing from the environment can stand in for a figure.
  uc="$CLAUDE/.usage-cache.json" ucx= cp= cu= cl= cts=0 cseen=0 mr= ms=
  if [ -f "$uc" ]; then
    ucx=1
    # `eol=1` takes a native Windows `jq`'s carriage return, as in the payload
    # read, or `cseen` would read as 0 and every render would ask for a refresh.
    # `jq` reads the file on stdin: Git Bash may hand a native `jq.exe` a path
    # it cannot open (one with an apostrophe in it).
    eval "$(jq -r "$JV"' @sh "cp=\(v(.percent; "")) cu=\(v(.used_minor; "")) cl=\(v(.limit_minor; "")) cts=\(v(.fetched_at; 0)) cseen=\(v(.spend_seen; 0)) eol=1"' 2>/dev/null < "$uc")"
  fi
  case "$cts"   in ''|*[!0-9]*)   cts=0   ;; esac
  # A snapshot dated in the future means the clock was moved back after it was
  # taken. Its age is unknown, so take it as new and ask again soon, rather than
  # draw it as current for as long as the clock takes to catch up.
  ufut=; [ "$cts" -gt $((now + 60)) ] && { cts=$now; ufut=1; }
  case "$cseen" in ''|*[!0-9.]*) cseen=0 ;; esac
  cage=$((now - cts))

  # Local spend observed so far, accumulated across sessions out of the one
  # figure every render does hand us (`cost.total_cost_usd`, this session only).
  # Monotonic, so a session ending or `/clear` cannot walk the total backwards.
  # One line per session, "<session> <cost> <seen>", under "#total <total>". A
  # session not seen for 8 days goes: its cost is in the total already, and the
  # file stays small though every render rewrites it. A line from before there
  # were stamps counts as seen now. `true`, not `:`: a failed redirect on the
  # special builtin `:` ends the shell, and a read-only config folder would
  # blank the line.
  af="$CLAUDE/.usage-activity"; [ -f "$af" ] || true 2>/dev/null > "$af"
  tot=$(awk -v sid="$sid" -v cost="$usd" -v now="$now" -v o="$af.$$" '
    $1=="#total" { tot=$2; next }
    $1==sid      { prev=$2; next }
    NF           { w = ($3 == "") ? now : $3 + 0; if (w > now - 691200) print $1, $2, w > o }
    END { if (cost >= prev) tot += cost - prev; else tot += cost
          printf "#total %.6f\n", tot > o
          printf "%s %.6f %d\n", sid, cost, now > o
          close(o); printf "%.6f", tot }' "$af" 2>/dev/null)
  mv -f "$af.$$" "$af" 2>/dev/null || rm -f "$af.$$" 2>/dev/null
  case "$tot" in ''|*[!0-9.]*) tot=0 ;; esac

  # Refresh policy. Spend is the trigger; the clock is only a backstop for spend
  # that happened on another machine. The floor tightens as the cap nears, but
  # never below the 5-minute gap between calls (`ask_refresh`). `CC_USAGE_FLOOR`
  # is whole seconds: anything else falls back to 1800, since "30m" would break
  # the arithmetic and blank the line, and a value under 300 is raised to 300,
  # since a floor under the gap would drop the figure as stale between calls.
  # Leading zeros go, or `08` would be read as octal.
  floor=${CC_USAGE_FLOOR:-1800}
  case "$floor" in ''|*[!0-9]*) floor=1800 ;; esac
  floor=${floor#"${floor%%[!0]*}"}; [ "${floor:-0}" -ge 300 ] || floor=300
  if [ -n "$cp" ]; then
    pi=$(printf '%.0f' "$cp" 2>/dev/null)
    [ "${pi:-0}" -ge 50 ] && floor=600
    [ "${pi:-0}" -ge 80 ] && floor=300
  fi
  need=
  [ -z "$ucx" ] && need=1
  [ "$cage" -ge "$floor" ] && need=1
  [ -n "$ufut" ] && need=1
  # 0.25% of the limit: one displayed point is 1%, so this cannot miss a change
  [ "${cl:-0}" -gt 0 ] 2>/dev/null &&
    awk "BEGIN{exit !(($tot - $cseen) >= ($cl / 100) * 0.0025)}" && need=1
  failure "$CLAUDE/.usage-unavailable"
  [ -n "$need" ] && ask_refresh "$tot" "$ver"
  # A snapshot from the future has no age to go by, so once a refresh has failed
  # it is not drawn as current until the clock catches up.
  [ -n "$ufut" ] && [ -n "$why" ] && cp=

  # Past 3x the floor the snapshot is dropped rather than drawn: a visible
  # unknown beats a confident wrong number, such as a 100% for a cap that has
  # since reset.
  # A 429 is the server asking for quiet, not a broken figure, so the last one
  # stays for at least an hour, with "throttled" beside it. Claude Code's own
  # /usage keeps its last figure too when the endpoint refuses it.
  drop=$((floor * 3))
  [ "$why" = throttled ] && [ "$drop" -lt 3600 ] && drop=3600
  [ "$cage" -gt "$drop" ] && cp=
  # A figure fetched before this UTC month began is last month's, however
  # young: the cap started over at the boundary. It is not drawn, and a fresh
  # one is asked for. `monthreset` is needed to draw the figure anyway.
  if [ -n "$cp" ]; then
    monthreset
    [ -n "$ms" ] && [ "$cts" -lt "$ms" ] && { cp=; ask_refresh "$tot" "$ver"; }
  fi
  case "$cp" in ''|*[!0-9.]*) cp= ;; esac
  # A reply can carry the share without the amounts: the share is still drawn,
  # only the dollars need them.
  case "$cu" in ''|*[!0-9]*) cu= ;; esac
  case "$cl" in ''|*[!0-9]*) cl= ;; esac
  if [ -n "$cp" ]; then
    # The dollars are noise next to how much of the month is gone, so they show
    # only with `CC_SPEND_DOLLARS` set, and not set to 0.
    dol=; case "${CC_SPEND_DOLLARS:-0}" in 0) ;; *) [ -n "$cu" ] && [ -n "$cl" ] && dol="$(money "$cu" USD)/$((cl / 100))" ;; esac
    window "$cp" "$mr" "cap " "%d/%b" spend "$dol" shared
    beside "$cts"
  else
    # No figure to draw: a snapshot too old, or none yet. Say why, or how old the
    # snapshot is, or, while the first fetch is on its way, a dim placeholder.
    said "cap " || { [ -n "$ucx" ] && add "${DIM}cap $(agefmt "$cage")-stale${Z}"; } || add "${DIM}cap ${ELL}${Z}"
  fi
elif [ -z "$p5" ]; then
  # No cached figures either (API key, Bedrock, Vertex). Claude Code only
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
    # The ledger has no reset time, so its period names the window, in a record
    # of its own. With no reset to beat, its estimate is never red.
    record ledger "$p" "l$pk"; p=$rf
    ramp "$p"
    add "${R}\$${money}/${cap} ${p}%${Z}${bt}" "${R}cap ${p}%${Z}"
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
