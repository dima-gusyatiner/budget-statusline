#!/bin/sh
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
eval "$(jq -r "$JV"' @sh "cwd=\(v(.workspace.current_dir; v(.cwd; ""))) mdl=\(v(.model.display_name; "")) eff=\(v(.effort.level; "")) tok=\(v(.context_window.total_input_tokens; 0)) ctxp=\(v(.context_window.used_percentage; ""))"' 2>/dev/null)"

[ -n "$cwd" ] || cwd=$PWD
# Colours are plain variables built from one escape character. A `$(...)` per
# colour is a process per colour, and Git Bash pays for every one of them.
E=$(printf '\033')
Z="${E}[0m" DIM="${E}[2m" RED="${E}[31m" GRN="${E}[32m" YEL="${E}[33m"
MAG="${E}[35m" CYN="${E}[36m" BLU="${E}[1;34m"

# `SEP` between groups, then the marks for a dirty and a clean tree, a
# folder outside git and the effort.
SEP=" ${DIM}·${Z} " DIRTY=✗ CLEAN=✓ FOLDER=⌂ EFFORT=◊

# ramp <percent>: its colour, in `$R`: green under 50, yellow from 50, red from 80
ramp() { if [ "$1" -ge 80 ]; then R=$RED; elif [ "$1" -ge 50 ]; then R=$YEL; else R=$GRN; fi; }

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
  if [ -n "$(g status --porcelain | head -1)" ]; then f=" ${YEL}${DIRTY}"; else f=" ${GRN}$CLEAN"; fi
  sg="${lk}${BLU}git:(${RED}${br}${BLU})${f}${Z}${fz}"
else
  clean "$(basename "$cwd")"; dir=$clean
  sg="${lk}${CYN}${FOLDER}${dir}${Z}${fz}"
fi

# --- 2. model, 3. effort: one group, a space between the two and no dot ---
clean "$mdl"; mdl=$clean; clean "$eff"; eff=$clean
# "Opus 5 (1M context)" reads "Opus 5 (1M)": the first " context)" loses its word.
case "$mdl" in *" context)"*) mdl="${mdl%% context)*})${mdl#* context)}" ;; esac
sm=
[ -n "$mdl" ] && sm="${YEL}${mdl}${Z}"
if [ -n "$eff" ]; then
  ef="${MAG}${EFFORT}${eff}${Z}"
  sm="${sm:+$sm }$ef"
fi

# --- 4. context window: raw / 36.4k / 235k ---
sc=
if [ "$tok" -gt 0 ] 2>/dev/null; then
  if [ "$tok" -lt 1000 ]; then k=$tok
  elif [ "$tok" -lt 100000 ]; then k=$(awk "BEGIN{printf\"%.1fk\",$tok/1000}")
  else k="$(( (tok + 500) / 1000 ))k"; fi
  sc="${DIM}ctx${Z} ${k}"
  # The share can be missing early in a session; then only the token count shows.
  if [ -n "$ctxp" ]; then
    ci=$(printf '%.0f' "$ctxp" 2>/dev/null)
    ramp "${ci:-0}" 2>/dev/null; sc="${sc} ${R}${ci}%${Z}"
  fi
fi

# join <separator> <group>...: the groups that are not empty, in `$line`
join() { j=$1; shift; line=; for s in "$@"; do [ -n "$s" ] && line="${line:+$line$j}$s"; done; }

join "$SEP" "$sg" "$sm" "$sc"; full=$line
printf '%s' "$full"
