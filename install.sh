#!/bin/sh
# Installs the status line on a machine that does not use the plugin system:
# copies `statusline.sh` and `usage-refresh.sh` into the Claude Code config
# folder and points `settings.json` at the status line. Run `sh install.sh
# --help` for the options.
#
# Same rules as `hooks/deploy.sh`, and the same manifest, so either can update
# what the other installed and `--uninstall` removes both: a file this tool did
# not write is never touched, a local edit is never overwritten, and
# `settings.json` gets a `statusLine` only when it has none, and loses it only
# when it points at this script. Keep the two in step.
set -u

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
SRC=$here                        # where the scripts come from, as the helpers shared with `hooks/deploy.sh` call it

usage() {
  cat <<'EOF'
usage: sh install.sh [--config-dir DIR] [--dry-run]
       sh install.sh --uninstall [--config-dir DIR] [--dry-run]

Copies statusline.sh and usage-refresh.sh into the Claude Code config folder and
points settings.json at the statusline, unless settings.json already has a
statusLine. The folder is --config-dir, else $CLAUDE_CONFIG_DIR, else ~/.claude.

  --dry-run    say what would happen and change nothing
  --uninstall  remove what this tool installed, and nothing else
EOF
}
die() { printf 'install.sh: %s\n' "$1" >&2; usage >&2; exit 2; }
say() { printf '%s\n' "$*"; }

dir= dry= remove= given=
while [ $# -gt 0 ]; do
  case "$1" in
    --config-dir)   [ $# -ge 2 ] || die "--config-dir needs a folder"; dir=$2; given=1; shift ;;
    --config-dir=*) dir=${1#--config-dir=}; given=1 ;;
    --dry-run)      dry=1 ;;
    --uninstall)    remove=1 ;;
    -h|--help)      usage; exit 0 ;;
    *)              die "unknown option: $1" ;;
  esac
  shift
done
# an empty folder is a typo, not a request for the default
[ -z "$given" ] || [ -n "$dir" ] || die "--config-dir needs a folder"

# which folder, and whether `settings.json` names it by its full path or as
# `~/.claude`
named=1
if [ -n "$dir" ]; then CLAUDE=$dir
elif [ -n "${CLAUDE_CONFIG_DIR:-}" ]; then CLAUDE=$CLAUDE_CONFIG_DIR
elif [ -n "${HOME:-}" ]; then CLAUDE="$HOME/.claude"; named=
else die "HOME is not set, so there is no default folder. Pass --config-dir"
fi
case "$CLAUDE" in "~/"*) CLAUDE="${HOME:-}/${CLAUDE#"~/"}" ;; esac
case "$CLAUDE" in /*) ;; *) CLAUDE="$PWD/$CLAUDE" ;; esac
CLAUDE=${CLAUDE%/}

MANIFEST="$CLAUDE/.budget-statusline-manifest"
LOG="$CLAUDE/.budget-statusline.log"
LOCK="$CLAUDE/.budget-statusline.lock"
settings="$CLAUDE/settings.json"
failed= held=
# lock: take `$LOCK`, the one lock this and the other installer share (the
# hook, `install.sh`), and write this run's pid into it. Returns 0 when taken, 1
# when another run holds it, 2 when the folder cannot be written. A holder still
# at work keeps it; a dead holder's lock is taken over at once, and one with no
# pid (a holder killed before writing it) after a minute. A takeover renames
# the stale lock away first, so of two runs only one gets it, and a lock that
# turns out to be someone's new one gets its pid back.
lock() {
  if mkdir "$LOCK" 2>/dev/null; then held=1; printf '%s\n' "$$" > "$LOCK/pid" 2>/dev/null; return 0; fi
  [ -d "$LOCK" ] || return 2
  lk_h=; [ -r "$LOCK/pid" ] && read -r lk_h < "$LOCK/pid"
  case "$lk_h" in *[!0-9]*) lk_h= ;; esac
  if [ -n "$lk_h" ]; then deploying "$lk_h" && return 1
  else [ -n "$(find "$LOCK" -maxdepth 0 -mmin +1 2>/dev/null)" ] || return 1; fi
  [ -e "$LOCK.$$" ] && rm -rf "$LOCK.$$" 2>/dev/null
  mv "$LOCK" "$LOCK.$$" 2>/dev/null || return 1
  if [ "$(cat "$LOCK.$$/pid" 2>/dev/null)" != "$lk_h" ]; then
    mkdir "$LOCK" 2>/dev/null && mv -f "$LOCK.$$/pid" "$LOCK/pid" 2>/dev/null
    rm -rf "$LOCK.$$" 2>/dev/null; return 1
  fi
  mkdir "$LOCK" 2>/dev/null || { rm -rf "$LOCK.$$" 2>/dev/null; return 1; }
  held=1; printf '%s\n' "$$" > "$LOCK/pid" 2>/dev/null
  rm -rf "$LOCK.$$" 2>/dev/null; return 0
}
# deploying <pid>: the lock's holder is a hook or an installer still at work. A
# run killed with no chance to clean up leaves its pid to be reused, so where
# `ps` can show the command, it must still be one of the two; where `ps` cannot
# tell, the pid alone counts.
deploying() {
  kill -0 "$1" 2>/dev/null || return 1
  dp_c=$(ps -o command= -p "$1" 2>/dev/null) || return 0
  case "$dp_c" in *deploy.sh*|*install.sh*) return 0 ;; esac
  return 1
}
# unlock: give the lock back, but only while it holds this run's pid: a run that
# lost it to a takeover must not delete the one that took it.
unlock() { [ -n "$held" ] && [ "$(cat "$LOCK/pid" 2>/dev/null)" = "$$" ] && rm -rf "$LOCK" 2>/dev/null; return 0; }
# The lock goes with the run that took it, with any temporary file of this run.
trap '[ -n "$held" ] && rm -f "$CLAUDE/statusline.sh.$$" "$CLAUDE/usage-refresh.sh.$$" "$MANIFEST.$$" "$settings.$$" 2>/dev/null; unlock' EXIT
# A signal ends it through that trap too: `dash` runs no `EXIT` trap on a signal
# that is not trapped itself, and would leave the lock behind.
trap 'exit 1' HUP INT TERM

locked() {  # take the lock, or say why not and stop
  lock; case $? in
    0) ;;
    2) say "error: cannot write in $CLAUDE"; exit 1 ;;
    *) say "error: another install or session start is changing $CLAUDE. Try again in a minute."; exit 1 ;;
  esac
}

# "<name> <checksum>" per line, names relative to the folder (see `hooks/deploy.sh`)
sum() { cksum < "$1" 2>/dev/null | awk '{print $1 "-" $2}'; }
recorded() { [ -f "$MANIFEST" ] && awk -v n="$1" '$1==n {print $2}' "$MANIFEST" 2>/dev/null; }
record() {  # remember that we own <name> at checksum <sum>
  tmp="$MANIFEST.$$"
  { [ -f "$MANIFEST" ] && awk -v n="$1" '$1!=n' "$MANIFEST"; printf '%s %s\n' "$1" "$2"; } > "$tmp" 2>/dev/null \
    && mv -f "$tmp" "$MANIFEST" 2>/dev/null || rm -f "$tmp" 2>/dev/null
}
forget() {  # drop <name> from the manifest
  [ -f "$MANIFEST" ] || return 0
  tmp="$MANIFEST.$$"
  awk -v n="$1" '$1!=n' "$MANIFEST" > "$tmp" 2>/dev/null && mv -f "$tmp" "$MANIFEST" 2>/dev/null \
    || rm -f "$tmp" 2>/dev/null
}

# What `settings.json` gets: `~/.claude/...` on a normal machine, the folder's
# own path when it was named. A path with odd characters is quoted for the shell,
# and Git Bash needs the interpreter spelled out because it cannot run a bare
# `.sh` path.
path="~/.claude/statusline.sh"; [ -n "$named" ] && path="$CLAUDE/statusline.sh"
# Inside the quotes each `'` is written `'\''`, or an apostrophe in the path
# would end the quoting early.
case "$path" in *[!A-Za-z0-9_./~:+=@%-]*) path="'$(printf '%s' "$path" | sed "s/'/'\\\\''/g")'" ;; esac
cmd=$path
case "$(uname -s 2>/dev/null)" in MINGW*|MSYS*|CYGWIN*) cmd="bash $path" ;; esac
filter='{type: "command", command: $c, refreshInterval: 60}'

# the one line to add by hand when `jq` is missing, JSON-escaped without `jq`
jsonline() {
  esc=$(printf '%s' "$cmd" | sed 's/\\/\\\\/g; s/"/\\"/g')
  printf '  "statusLine": { "type": "command", "command": "%s", "refreshInterval": 60 }' "$esc"
}

# edited <name>: true when the file there is ours (in the manifest), was
# edited since, and is not this release's file either. Either script edited
# holds back both, so an old `statusline.sh` never runs beside a new
# `usage-refresh.sh`, or the other way round. `$blocked` names the edited ones.
edited() {
  ed_d="$CLAUDE/$1"; [ -f "$ed_d" ] && [ ! -L "$ed_d" ] || return 1
  ed_m=$(recorded "$1"); [ -n "$ed_m" ] || return 1
  ed_h=$(sum "$ed_d"); [ "$ed_h" != "$ed_m" ] && [ "$ed_h" != "$(sum "$SRC/$1")" ]
}

# stranger <name>: true when something is at `$CLAUDE/<name>` that this tool did
# not put there: a symlink, something that is not a plain file, or a file the
# manifest does not list (a hand copy). It is never replaced, and it holds back
# the other script too, which would otherwise run beside it, or run it.
stranger() {
  sg_d="$CLAUDE/$1"
  [ -L "$sg_d" ] && return 0
  [ -e "$sg_d" ] || return 1
  [ -f "$sg_d" ] || return 0
  [ -z "$(recorded "$1")" ]
}

# current <name>: "up to date", and when the file cannot run (its execute bit
# lost) its mode back. A mode that still runs is the user's choice.
current() {
  if [ -x "$dest" ]; then say "up to date: $1"
  elif [ -n "$dry" ]; then say "would restore the mode of $1"
  elif chmod "$mode" "$dest" 2>/dev/null; then say "up to date: $1, its mode restored"
  else say "error: could not restore the mode of $dest"; failed=1; fi
}

# deploy <name> <mode>: put `$here/<name>` at `$CLAUDE/<name>`. Sets `owned=1`
# when the file there is, or is about to be, one this tool installed, edited
# since or not; `settings.json` is wired only then.
deploy() {
  src="$here/$1" dest="$CLAUDE/$1" mode=$2 owned=
  [ -f "$src" ] || { say "error: $src is missing. Run install.sh from a complete checkout."; failed=1; return; }
  if [ -L "$dest" ]; then say "skipped $1: $dest is a symlink, so it is not ours"; return; fi
  act=install past=installed
  if [ -e "$dest" ]; then
    [ -f "$dest" ] || { say "skipped $1: $dest is not a regular file"; return; }
    have=$(sum "$dest"); mine=$(recorded "$1")
    [ -n "$mine" ] || { say "skipped $1: $dest exists and this tool did not install it. Move it aside to let this tool manage it"; return; }
    owned=1
    if [ "$have" != "$mine" ]; then
      # This checkout's own file under a stale line: a run stopped between the
      # copy and the manifest. Take it back rather than call it a local edit.
      [ "$have" = "$(sum "$src")" ] && { [ -n "$dry" ] || record "$1" "$have"; current "$1"; return; }
      say "skipped $1: edited locally. Revert or delete the edit to let this tool manage it"; return
    fi
    [ "$have" = "$(sum "$src")" ] && { current "$1"; return; }
    act=update past=updated
  fi
  if [ -n "$strangers" ]; then
    say "skipped $1: held back, because $strangers in $CLAUDE was not installed by this tool and the two scripts must be one version. Move it aside to let this tool manage both"
    failed=1; return
  fi
  if [ -n "$blocked" ]; then
    say "skipped $1: held back, because $blocked is edited locally and the two scripts must be the same version"; return
  fi
  owned=1
  if [ -n "$dry" ]; then say "would $act $1"; return; fi
  if cp "$src" "$dest.$$" 2>/dev/null && chmod "$mode" "$dest.$$" 2>/dev/null \
     && mv -f "$dest.$$" "$dest" 2>/dev/null; then
    record "$1" "$(sum "$dest")"; say "$past $1"
  else
    rm -f "$dest.$$" 2>/dev/null; say "error: could not write $dest"; failed=1; owned=
  fi
}

# ours <command>: true when the command runs this folder's `statusline.sh` and
# nothing else: optional `NAME=value` words first (the docs put settings
# there), an optional `bash`, then the script's path as the installers write
# it, plain or quoted for the shell, or as `~/.claude/statusline.sh` when this
# is the default folder. A longer name (`statusline.sh.mine`) or anything after
# the path (`| my-filter`) makes it the user's own command.
ours() {
  ou_c=$1
  while :; do
    ou_c=${ou_c#"${ou_c%%[! ]*}"}
    ou_w=${ou_c%%' '*}
    [ "$ou_w" != "$ou_c" ] || break
    case "$ou_w" in [A-Za-z_]*=*) ;; *) break ;; esac
    case "${ou_w%%=*}" in *[!A-Za-z0-9_]*) break ;; esac
    ou_c=${ou_c#*' '}
  done
  case "$ou_c" in 'bash '*) ou_c=${ou_c#bash }; ou_c=${ou_c#"${ou_c%%[! ]*}"} ;; esac
  ou_f="$CLAUDE/statusline.sh"
  [ "$ou_c" = "$ou_f" ] && return 0
  [ "$ou_c" = "'$(printf '%s' "$ou_f" | sed "s/'/'\\\\''/g")'" ] && return 0
  [ "$CLAUDE" = "${HOME:-}/.claude" ] && [ "$ou_c" = '~/.claude/statusline.sh' ]
}
# settings_state: missing | invalid | none | ours | theirs, for `settings.json`.
# `jq` reads it on stdin and the command is compared here, not in `jq`: Git
# Bash rewrites a `/path` argument for a native `jq.exe` into `C:/...`, or
# leaves one with an apostrophe in it as it is, and then `jq.exe` cannot open
# it. A native `jq.exe` ends its output with a carriage return, which goes.
settings_state() {
  if [ ! -e "$settings" ] && [ ! -L "$settings" ]; then echo missing
  elif ! jq -e 'type == "object"' >/dev/null 2>&1 < "$settings"; then echo invalid
  elif ! jq -e 'has("statusLine")' >/dev/null 2>&1 < "$settings"; then echo none
  elif ours "$(jq -r '.statusLine.command? // "" | tostring' 2>/dev/null < "$settings" | tr -d '\r')"; then echo ours
  else echo theirs
  fi
}

# rewrite <message> <jq arguments...>: `settings.json` through `jq`, by way of
# a temporary file, then the message; or an error. A file that exists is copied
# first, so the new one keeps its mode, which may be 600; `jq` reads it on
# stdin.
rewrite() {
  rw_m=$1; shift; rw_in=/dev/null
  [ -e "$settings" ] && { rw_in=$settings; cp -p "$settings" "$settings.$$" 2>/dev/null; }
  if jq "$@" 2>/dev/null < "$rw_in" > "$settings.$$" && mv -f "$settings.$$" "$settings" 2>/dev/null; then say "$rw_m"
  else rm -f "$settings.$$" 2>/dev/null; say "error: could not write $settings"; failed=1; fi
}

wire() {
  if ! command -v jq >/dev/null 2>&1; then
    say "jq is not installed, so settings.json was not touched. Add this line inside the top-level braces of $settings, with a comma after it if other settings follow:"
    say "$(jsonline)"
    say "The statusline needs jq to run, so install it too."
    return
  fi
  case $(settings_state) in
    ours)    say "settings.json already runs this status line" ;;
    theirs)  say "settings.json already has a statusLine, left alone. To use this one instead, replace it with:"; say "$(jsonline)" ;;
    # Nothing could be wired, so the status line will not appear: a failure.
    invalid) say "settings.json is not a valid JSON object, so it was left alone. Add this line inside its top-level braces, with a comma after it if other settings follow:"
             say "$(jsonline)"; failed=1 ;;
    missing) if [ -n "$dry" ]; then say "would create settings.json with a statusLine: $cmd"
             else rewrite "created settings.json with a statusLine: $cmd" -n --arg c "$cmd" "{statusLine: $filter}"; fi ;;
    none)    if [ -L "$settings" ]; then
               say "settings.json is a symlink, left alone. Add this line to the file it points to:"; say "$(jsonline)"
             elif [ -n "$dry" ]; then say "would point settings.json at the statusline: $cmd"
             else rewrite "pointed settings.json at the statusline: $cmd" --arg c "$cmd" ".statusLine = $filter"; fi ;;
  esac
}

# unwire: remove the `statusLine` setting, but only when it points at the
# script being removed. A `statusLine` that points anywhere else is the user's
# own.
unwire() {
  [ -e "$settings" ] || [ -L "$settings" ] || return 0
  if ! command -v jq >/dev/null 2>&1; then
    say "jq is not installed. If settings.json has a statusLine that runs statusline.sh, remove it by hand."
    return
  fi
  st=$(settings_state)
  case "$st" in ours|theirs) ;; *) return 0 ;; esac
  if [ "$st" = ours ]; then
    if [ -L "$settings" ]; then say "settings.json is a symlink, left alone. Remove its statusLine by hand."
    elif [ -n "$dry" ]; then say "would remove the statusLine setting from settings.json"
    else rewrite "removed the statusLine setting from settings.json" 'del(.statusLine)'; fi
  else
    say "settings.json has a statusLine that does not point at this script, left alone"
  fi
}

uninstall() {
  kept=0 done_with_script= why_kept=
  for name in statusline.sh usage-refresh.sh; do
    dest="$CLAUDE/$name"; mine=$(recorded "$name")
    if [ -z "$mine" ]; then
      if [ -e "$dest" ] || [ -L "$dest" ]; then say "left alone $name: this tool did not install it"; else say "not installed: $name"; fi
      continue
    fi
    if [ ! -e "$dest" ] && [ ! -L "$dest" ]; then
      say "already gone: $name"; [ -n "$dry" ] || forget "$name"
    elif [ -L "$dest" ] || [ ! -f "$dest" ]; then
      say "left alone $name: it is no longer a plain file"; kept=$((kept+1))
      [ "$name" = statusline.sh ] && why_kept="it is no longer a plain file"; continue
    elif [ "$(sum "$dest")" != "$mine" ]; then
      say "left alone $name: edited locally"; kept=$((kept+1))
      [ "$name" = statusline.sh ] && why_kept="it is edited locally"; continue
    elif [ -n "$dry" ]; then say "would remove $name"
    elif rm -f "$dest" 2>/dev/null; then say "removed $name"; forget "$name"
    else say "error: could not remove $dest"; failed=1; kept=$((kept+1)); continue
    fi
    [ "$name" = statusline.sh ] && done_with_script=1
  done
  [ -n "$done_with_script" ] && unwire
  # A kept statusline.sh keeps its wiring, so the status line still runs it:
  # say so, and how to finish.
  if [ -n "$why_kept" ]; then
    finish="To remove both, delete $CLAUDE/statusline.sh and run this uninstall again."
    if ! command -v jq >/dev/null 2>&1; then
      say "If settings.json has a statusLine that runs statusline.sh, it still runs it, left in place because $why_kept. $finish"
    elif [ "$(settings_state)" = ours ]; then
      say "settings.json still runs statusline.sh, left in place because $why_kept. $finish"
    fi
  fi
  if [ "$kept" -eq 0 ] && [ -z "$failed" ] && { [ -f "$MANIFEST" ] || [ -f "$LOG" ]; }; then
    if [ -n "$dry" ]; then say "would remove the manifest and the log"
    else rm -f "$MANIFEST" "$LOG" "$CLAUDE/.budget-statusline-notice" 2>/dev/null; say "removed the manifest and the log"; fi
  fi
  say "left in place: the small state files the scripts keep in $CLAUDE (.usage-*, .credits-*, .rl-*-state, .spend-ledger). Delete them if you like."
}

say "config folder: $CLAUDE"
if [ -n "$remove" ]; then
  [ -z "$dry" ] && [ -d "$CLAUDE" ] && locked
  uninstall
else
  if [ -z "$dry" ]; then
    mkdir -p "$CLAUDE" 2>/dev/null || { say "error: cannot create $CLAUDE"; exit 1; }
    locked
  fi
  blocked= strangers=
  for n in statusline.sh usage-refresh.sh; do
    edited "$n" && blocked="${blocked:+$blocked and }$n"
    stranger "$n" && strangers="${strangers:+$strangers and }$n"
  done
  deploy statusline.sh 755
  [ -n "$owned" ] && ours=1 || ours=
  deploy usage-refresh.sh 755
  # A script this tool did not install holds back the wiring too: the status
  # line would run it, or run beside it.
  if [ -n "$strangers" ]; then say "settings.json was not changed: nothing was installed to point it at."; failed=1
  elif [ -n "$ours" ]; then wire; fi
fi
[ -n "$dry" ] && say "dry run: nothing was changed"
[ -z "$failed" ] || exit 1
exit 0
