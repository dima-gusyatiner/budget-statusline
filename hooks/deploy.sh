#!/bin/sh
# The `SessionStart` hook. Copies `statusline.sh` and `usage-refresh.sh` into
# the Claude Code config folder, because a plugin cannot set `statusLine` and
# `settings.json` needs a script at a stable path. Runs at every start, so the
# copies follow the plugin when it updates.
#
# Rules of the house:
#   - never touch a file we did not write (checked against a manifest), never
#     overwrite a local edit, never fail a session. Exit 0 no matter what.
#   - print nothing into Claude's context: `SessionStart` plain-text stdout is
#     added to it, and this is plumbing, not context. stdout and stderr go
#     nowhere and the log keeps what happened, except one JSON line, below,
#     when something needs the user.
#
# A managed `allowManagedHooksOnly`, or `disableAllHooks`, blocks both this hook
# and the status line command itself. Nothing here can work around that, by
# design.
set -u
# fd 3 keeps stdout for that one line; `command` keeps a closed stdout from
# ending the hook here.
command exec 2>/dev/null 3>&1 || exec 3>/dev/null
exec >/dev/null 2>&1
held=
# lock: take `$LOCK` and write this run's pid into it. Returns 0 when taken, 1
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
# deploying <pid>: the lock's holder is a hook still at work. A run killed with
# no chance to clean up leaves its pid to be reused, so where `ps` can show the
# command, it must still be a hook; where `ps` cannot tell, the pid alone
# counts.
deploying() {
  kill -0 "$1" 2>/dev/null || return 1
  dp_c=$(ps -o command= -p "$1" 2>/dev/null) || return 0
  case "$dp_c" in *deploy.sh*) return 0 ;; esac
  return 1
}
# unlock: give the lock back, but only while it holds this run's pid: a run that
# lost it to a takeover must not delete the one that took it.
unlock() { [ -n "$held" ] && [ "$(cat "$LOCK/pid" 2>/dev/null)" = "$$" ] && rm -rf "$LOCK" 2>/dev/null; return 0; }
# Even a failed expansion under `set -u` must not fail the session, and the lock
# goes with the hook that took it, with any temporary file of this run.
trap '[ -n "$held" ] && rm -f "$CLAUDE/statusline.sh.$$" "$CLAUDE/usage-refresh.sh.$$" "$MANIFEST.$$" "$CLAUDE/settings.json.$$" "$NOTICE.$$"; unlock; exit 0' EXIT
# A signal ends the hook through that trap too: `dash` runs no `EXIT` trap on a
# signal that is not trapped itself, and would leave the lock behind.
trap 'exit 0' HUP INT TERM

CLAUDE="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
ROOT="${CLAUDE_PLUGIN_ROOT:-$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)}"
MANIFEST="$CLAUDE/.budget-statusline-manifest"
LOG="$CLAUDE/.budget-statusline.log"
NOTICE="$CLAUDE/.budget-statusline-notice"
notice=                          # what the user should hear about, if anything
tell() { notice="${notice:+$notice }$*"; }

mkdir -p "$CLAUDE" 2>/dev/null
log() { printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG" 2>/dev/null; }
# a skip is logged again at every start, so cap the log
if [ -f "$LOG" ] && [ "$(wc -l < "$LOG" 2>/dev/null || echo 0)" -gt 400 ]; then
  tail -n 200 "$LOG" > "$LOG.$$" 2>/dev/null && mv -f "$LOG.$$" "$LOG" 2>/dev/null
fi

# One deploy at a time. Two sessions starting together would race on the
# manifest, and a lost line leaves a script that reads as not ours for good. The
# holder does the same work, so a held lock leaves nothing to do.
LOCK="$CLAUDE/.budget-statusline.lock"
lock; case $? in
  0) ;;
  2) log "FAILED: cannot write in $CLAUDE"; exit 0 ;;
  *) log "skip: another session start is deploying"; exit 0 ;;
esac

# The manifest lists what we wrote: "<name> <checksum>", names relative to the
# config folder, so a folder with a space in its path cannot confuse the split.
sum() { cksum < "$1" 2>/dev/null | awk '{print $1 "-" $2}'; }
recorded() { [ -f "$MANIFEST" ] && awk -v n="$1" '$1==n {print $2}' "$MANIFEST" 2>/dev/null; }
record() {  # remember that we own <name> at checksum <sum>
  tmp="$MANIFEST.$$"
  { [ -f "$MANIFEST" ] && awk -v n="$1" '$1!=n' "$MANIFEST"; printf '%s %s\n' "$1" "$2"; } > "$tmp" 2>/dev/null \
    && mv -f "$tmp" "$MANIFEST" 2>/dev/null || rm -f "$tmp" 2>/dev/null
}

# edited <name>: true when the file there is ours (in the manifest), was
# edited since, and is not this release's file either. Either script edited
# holds back both, so an old `statusline.sh` never runs beside a new
# `usage-refresh.sh`, or the other way round. `$blocked` names the edited ones.
edited() {
  ed_d="$CLAUDE/$1"; [ -f "$ed_d" ] && [ ! -L "$ed_d" ] || return 1
  ed_m=$(recorded "$1"); [ -n "$ed_m" ] || return 1
  ed_h=$(sum "$ed_d"); [ "$ed_h" != "$ed_m" ] && [ "$ed_h" != "$(sum "$ROOT/$1")" ]
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

# fixmode: a file whose content is current but which cannot run (its execute
# bit lost) gets its mode back. A mode that still runs is the user's choice.
fixmode() { [ -x "$dest" ] || { chmod "$mode" "$dest" 2>/dev/null && log "mode restored: $dest"; }; }

# deploy <name> <mode>: put `$ROOT/<name>` at `$CLAUDE/<name>`. Skips a
# destination that exists and is not ours, so a hand-copied file or a symlink is
# never clobbered.
deploy() {
  src="$ROOT/$1" dest="$CLAUDE/$1" mode=$2
  [ -f "$src" ] || { log "missing in plugin: $src"; return; }
  if [ -L "$dest" ]; then log "skip (symlink, not ours): $dest"; return; fi
  if [ -e "$dest" ]; then
    [ -f "$dest" ] || { log "skip (not a regular file): $dest"; return; }
    have=$(sum "$dest"); mine=$(recorded "$1")
    [ -n "$mine" ] || { log "skip (pre-existing, not ours): $dest"; return; }
    if [ "$have" != "$mine" ]; then
      # The plugin's own file under a stale line: a hook stopped between the
      # copy and the manifest. Take it back rather than call it a local edit.
      [ "$have" = "$(sum "$src")" ] && { record "$1" "$have"; log "re-recorded: $dest"; fixmode; return; }
      log "skip (edited locally): $dest"; return
    fi
    [ "$have" = "$(sum "$src")" ] && { fixmode; return; }   # already current, say nothing
  fi
  [ -z "$blocked" ] || { log "skip (held back, $blocked edited locally): $dest"; return; }
  if cp "$src" "$dest.$$" 2>/dev/null && chmod "$mode" "$dest.$$" 2>/dev/null \
     && mv -f "$dest.$$" "$dest" 2>/dev/null; then
    record "$1" "$(sum "$dest")"; log "installed: $dest"
  else
    rm -f "$dest.$$" 2>/dev/null; log "FAILED to install: $dest"
  fi
}

blocked= strangers=
for n in statusline.sh usage-refresh.sh; do
  edited "$n" && blocked="${blocked:+$blocked and }$n"
  stranger "$n" && strangers="${strangers:+$strangers and }$n"
done
if [ -n "$strangers" ]; then
  log "skip (held back, $strangers not installed by this plugin): neither script installed, settings.json not wired"
else
  deploy statusline.sh 755
  deploy usage-refresh.sh 755
fi

# Point `settings.json` at the status line, but only on a machine that has no
# `statusLine` yet, and only at a script we wrote. An existing `statusLine` is
# the user's choice and stays untouched; so does a `statusline.sh` we did not
# install.
settings="$CLAUDE/settings.json"
# `~/.claude/...` on a normal machine, an absolute path when `CLAUDE_CONFIG_DIR`
# moves the config elsewhere. A path with odd characters gets quoted for the
# shell.
path="~/.claude/statusline.sh"; [ -n "${CLAUDE_CONFIG_DIR:-}" ] && path="$CLAUDE/statusline.sh"
# Inside the quotes each `'` is written `'\''`, or an apostrophe in the path
# would end the quoting early.
case "$path" in *[!A-Za-z0-9_./~:+=@%-]*) path="'$(printf '%s' "$path" | sed "s/'/'\\\\''/g")'" ;; esac
# Git Bash cannot run a bare `.sh` path as a command, so name the interpreter.
cmd=$path
case "$(uname -s 2>/dev/null)" in MINGW*|MSYS*|CYGWIN*) cmd="bash $path" ;; esac

# The line to add by hand, JSON-escaped so it pastes as it is.
esc=$(printf '%s' "$cmd" | sed 's/\\/\\\\/g; s/"/\\"/g')
line="\"statusLine\": { \"type\": \"command\", \"command\": \"$esc\", \"refreshInterval\": 60 }"
# ours <command>: true when the command runs this folder's `statusline.sh` and
# nothing else: optional `NAME=value` words first (the docs put settings
# there), an optional `bash`, then the script's path as the hook writes
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
# Whatever is left unwired is said in the log, with the line to add: a status
# line that never appears should not come with a log of clean installs.
if [ -z "$strangers" ] && [ -f "$CLAUDE/statusline.sh" ] && [ -n "$(recorded statusline.sh)" ]; then
  if ! command -v jq >/dev/null 2>&1; then
    log "jq not found, settings.json not checked. If it has no statusLine, add: $line"
    tell "jq is not installed, so the status line cannot run and settings.json was not set up. Install jq, then start a new session."
  else
    case $(settings_state) in
      ours)    ;;                                      # wired already: nothing to say
      theirs)  log "settings.json has a statusLine of its own, left alone. To use this one, set: $line"
               tell "settings.json already has a statusLine of its own, so it was left alone. To use this one, set: $line" ;;
      invalid) log "settings.json is not a valid JSON object (empty, a comment, a trailing comma?), left alone. Add inside its top-level braces: $line"
               tell "settings.json is not valid JSON (empty, a comment, a trailing comma?), so the status line was not set up. Add inside its top-level braces: $line" ;;
      *) if [ -L "$settings" ]; then
           log "settings.json is a symlink, left alone. Add to the file it points to: $line"
           tell "settings.json is a symlink, so it was left alone. Add to the file it points to: $line"
         else
           tmp="$settings.$$"
           # `refreshInterval` keeps the clock and the burn estimate honest in an idle session
           filter='{type: "command", command: $c, refreshInterval: 60}'
           if [ ! -e "$settings" ]; then
             jq -n --arg c "$cmd" "{statusLine: $filter}" > "$tmp" 2>/dev/null
           else
             cp -p "$settings" "$tmp" 2>/dev/null            # keeps the file mode, which may be 600
             jq --arg c "$cmd" ".statusLine = $filter" 2>/dev/null < "$settings" > "$tmp"
           fi \
             && mv -f "$tmp" "$settings" 2>/dev/null && log "wired statusLine into settings.json: $cmd" \
             || { rm -f "$tmp" 2>/dev/null; log "FAILED to wire statusLine into settings.json"; }
         fi ;;
    esac
  fi
fi

# The user hears once what needs them: a held-back update or an unwired
# settings.json, as a `systemMessage`, which Claude Code shows the user and
# keeps out of Claude's context. The text is kept in `$NOTICE`, so it is said
# again only when it changes, and the file goes once all is well.
case "$strangers" in
  '') ;;
  *' and '*) tell "$strangers in $CLAUDE were not installed by this plugin, so neither script was installed or updated. Move them aside to let the plugin manage both." ;;
  *) tell "$strangers in $CLAUDE was not installed by this plugin, so neither script was installed or updated. Move it aside to let the plugin manage both." ;;
esac
case "$blocked" in
  '') ;;
  *' and '*) tell "$blocked in $CLAUDE are edited locally, so neither script was updated. Revert or delete the edits to get updates." ;;
  *) tell "$blocked in $CLAUDE is edited locally, so neither script was updated. Revert or delete the edit to get updates." ;;
esac
if [ -z "$notice" ]; then rm -f "$NOTICE" 2>/dev/null
elif [ "$(cat "$NOTICE" 2>/dev/null)" != "$notice" ] && printf '%s\n' "$notice" > "$NOTICE.$$" 2>/dev/null \
     && mv -f "$NOTICE.$$" "$NOTICE" 2>/dev/null; then
  m=$(printf 'budget-statusline: %s' "$notice" | tr -d '\000-\037' | sed 's/\\/\\\\/g; s/"/\\"/g')   # JSON-escaped
  printf '{"systemMessage": "%s"}\n' "$m" >&3
else rm -f "$NOTICE.$$" 2>/dev/null; fi

exit 0
