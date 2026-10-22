#!/bin/sh
# Tests for the deploy logic: `hooks/deploy.sh`, the plugin's `SessionStart` hook,
# and `install.sh`, the same rules for machines without the plugin system.
# Plain sh, no framework. Every case runs in a scratch folder from `mktemp`, and
# `HOME` and the config folder are passed explicitly, so the real `~/.claude` is
# never read or written. The exit status is the number of failed checks.
set -u
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo=$(dirname -- "$here")
# `SL_SHELL=dash sh tests/test-deploy.sh` runs the hook and the installer under another shell.
shell=${SL_SHELL:-sh}
fails=0

# macOS sets TMPDIR with a trailing slash. Strip it, or every path built from
# `$base` carries a doubled slash and cannot equal a path the installer cleaned.
tmp_root=${TMPDIR:-/tmp}
tmp_root=${tmp_root%/}
base=$(mktemp -d "$tmp_root/budget-statusline-test.XXXXXX") || exit 1
trap 'chmod -R u+rwx "$base" 2>/dev/null; rm -rf "$base"' EXIT

# What this system keeps. Git Bash (Windows) cannot set a file mode, makes a
# copy where ln -s asks for a link (unless symbolic links are switched on), and
# its installers name the interpreter in the command: "bash <path>". The checks
# of modes and links print a skip line there; the command checks expect `$pre`.
pre=; case "$(uname -s 2>/dev/null)" in MINGW*|MSYS*|CYGWIN*) pre="bash " ;; esac
: > "$base/probe"; chmod 600 "$base/probe"; modes=; [ "$(ls -l "$base/probe" | cut -c1-10)" = -rw------- ] && modes=1
ln -s "$base/probe" "$base/probe.l" 2>/dev/null; links=; [ -L "$base/probe.l" ] && links=1
rm -f "$base/probe" "$base/probe.l"
skip() { echo "ok   $1 (skipped: $2)"; }   # skip <name> <why>
nomodes="this system does not keep file modes"; nolinks="this system makes no symbolic links"

pass() { echo "ok   $1"; }
fail() { echo "FAIL $1${2:+: $2}"; fails=$((fails+1)); }
eq()  { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "got [$2], want [$3]"; fi; }  # eq <name> <got> <want>
has() { case "$2" in *"$3"*) pass "$1" ;; *) fail "$1" "[$3] not in [$2]" ;; esac; }     # has <name> <text> <needle>
yes() { name=$1; shift; if "$@"; then pass "$name"; else fail "$name"; fi; }            # yes <name> <command...>
lacks() { case "$2" in *"$3"*) fail "$1" "unexpected [$3] in [$2]" ;; *) pass "$1" ;; esac; }  # lacks <name> <text> <needle>
absent() { for p in "$@"; do if [ -e "$p" ] || [ -L "$p" ]; then return 1; fi; done; }           # absent <path...>: none exists

cases=0
fresh() {  # a new case folder $S with an empty home; the config folder $CFG does not exist yet
  cases=$((cases+1)); S="$base/case$cases"; CFG="$S/cfg"; mkdir -p "$S/home"
}
snap() {  # inode, checksum and name of every file under $1: equal snapshots mean nothing was touched
  ( cd "$1" && find . -type f | sort | while read -r f; do
      printf '%s %s %s\n' "$(ls -i "$f" | awk '{print $1}')" "$(cksum < "$f")" "$f"
    done )
}
mode() { ls -l "$1" | cut -c1-10; }
jqs()  { jq -r "$1" 2>/dev/null < "$2" | tr -d '\r'; }   # on stdin, as the scripts read it; a native jq.exe ends lines with \r
log()  { cat "$CFG/.budget-statusline.log" 2>/dev/null; }
mkplugin() {  # mkplugin <dir> <tag>: a stand-in for a newer plugin release
  mkdir -p "$1"
  for f in statusline.sh usage-refresh.sh; do { cat "$repo/$f"; printf '# %s\n' "$2"; } > "$1/$f"; done
}
# hook [VAR=value...]: the plugin hook against `$CFG`, `HOME` inside the case folder.
# Later assignments win, so a case can swap `CLAUDE_PLUGIN_ROOT` or `PATH`.
hook() {
  env HOME="$S/home" CLAUDE_CONFIG_DIR="$CFG" CLAUDE_PLUGIN_ROOT="$repo" "$@" "$shell" "$repo/hooks/deploy.sh"
}
# inst [args...]: `install.sh` with `HOME` inside the case folder and no inherited
# `CLAUDE_CONFIG_DIR`, so only the arguments pick the folder. inst_p <PATH> [args...]
# does the same with a `PATH` of its own.
inst()   { env -u CLAUDE_CONFIG_DIR HOME="$S/home" "$shell" "$repo/install.sh" "$@"; }
inst_p() { p=$1; shift; env -u CLAUDE_CONFIG_DIR HOME="$S/home" PATH="$p" "$shell" "$repo/install.sh" "$@"; }
# nojq: a `PATH` folder holding the tools the scripts use, and no `jq`. Each is a
# small script that runs the real one: a link would be a copy on Windows, and a
# copied MSYS program cannot find its DLLs.
nojq() {
  d="$base/nojq"; [ -d "$d" ] && return; mkdir -p "$d"
  for t in awk basename cat chmod cksum cp date dirname find grep head ls mkdir mv rm sed "$shell" sort tail tr uname wc; do
    p=$(command -v "$t") && { printf '#!/bin/sh\nexec "%s" "$@"\n' "$p" > "$d/$t"; chmod +x "$d/$t"; }
  done
}

# The hook and the installer share these helpers word for word, so a fix to one
# copy reaches the other. A one-line function ends on its own line, any other at
# the first line that is just `}`.
fnbody() {  # fnbody <name> <file>: the function's text
  awk -v n="$1" 'index($0, n "() {") == 1 { on = 1; print; if ($0 ~ /; }$/) exit; next }
                 on { print; if ($0 == "}") exit }' "$2"
}
bad=
for f in sum recorded record edited stranger ours settings_state lock deploying unlock; do
  a=$(fnbody "$f" "$repo/hooks/deploy.sh"); b=$(fnbody "$f" "$repo/install.sh")
  [ -n "$a" ] || bad="$bad [$f is not in the hook]"; [ -n "$b" ] || bad="$bad [$f is not in the installer]"
  [ "$a" = "$b" ] || bad="$bad [$f differs]"
done
if [ -z "$bad" ]; then pass shared-helpers-match; else fail shared-helpers-match "$bad"; fi

# ---- `hooks/deploy.sh` ---------------------------------------------------------

# fresh install: files, modes, manifest, `settings.json`, a silent exit 0
fresh
out=$(hook 2>&1); rc=$?
eq  hook-exits-0 "$rc" 0
eq  hook-prints-nothing "$out" ""
yes hook-installs-statusline cmp -s "$repo/statusline.sh" "$CFG/statusline.sh"
yes hook-installs-refresher cmp -s "$repo/usage-refresh.sh" "$CFG/usage-refresh.sh"
if [ -n "$modes" ]; then eq hook-file-modes "$(mode "$CFG/statusline.sh") $(mode "$CFG/usage-refresh.sh")" "-rwxr-xr-x -rwxr-xr-x"
else skip hook-file-modes "$nomodes"; fi
eq  hook-manifest-names "$(awk '{print $1}' "$CFG/.budget-statusline-manifest" | sort | tr '\n' ' ')" "statusline.sh usage-refresh.sh "
eq  hook-wires-statusline "$(jqs '.statusLine.type + " " + .statusLine.command + " " + (.statusLine.refreshInterval | tostring)' "$CFG/settings.json")" "command ${pre}$CFG/statusline.sh 60"

# a second run changes nothing: same inodes, same bytes, same log
before=$(snap "$CFG"); hook; after=$(snap "$CFG")
eq  hook-rerun-is-a-noop "$after" "$before"

# a script that lost its execute bit gets it back at the next start, as long as
# its content is current; skipped where file modes are not kept
if [ -n "$modes" ]; then
  chmod 644 "$CFG/usage-refresh.sh"; hook
  eq  hook-restores-a-lost-mode "$(mode "$CFG/usage-refresh.sh")" "-rwxr-xr-x"
  has hook-logs-the-restored-mode "$(log)" "mode restored: $CFG/usage-refresh.sh"
else skip hook-restores-a-lost-mode "$nomodes"; skip hook-logs-the-restored-mode "$nomodes"; fi

# a local edit stays, and the manifest still records the version we wrote
printf '# my edit\n' >> "$CFG/statusline.sh"
mine=$(cksum < "$CFG/statusline.sh"); manifest=$(cat "$CFG/.budget-statusline-manifest")
hook
eq  hook-keeps-local-edit "$(cksum < "$CFG/statusline.sh")" "$mine"
eq  hook-manifest-ignores-edit "$(cat "$CFG/.budget-statusline-manifest")" "$manifest"
has hook-logs-the-skip "$(log)" "skip (edited locally)"

# the usual plugin setup has no `CLAUDE_CONFIG_DIR`: the files land in `~/.claude`,
# and the command names it with a tilde
fresh; env -u CLAUDE_CONFIG_DIR HOME="$S/home" CLAUDE_PLUGIN_ROOT="$repo" "$shell" "$repo/hooks/deploy.sh"
yes hook-default-folder-installs cmp -s "$repo/statusline.sh" "$S/home/.claude/statusline.sh"
eq  hook-default-folder-command "$(jqs .statusLine.command "$S/home/.claude/settings.json")" "${pre}~/.claude/statusline.sh"

# a plugin update replaces an unedited file and spares an edited one
fresh; hook
mkplugin "$S/v2" v2; hook CLAUDE_PLUGIN_ROOT="$S/v2"
yes hook-update-replaces-statusline cmp -s "$S/v2/statusline.sh" "$CFG/statusline.sh"
yes hook-update-replaces-refresher cmp -s "$S/v2/usage-refresh.sh" "$CFG/usage-refresh.sh"
# either script edited holds back both, so the two never run as different
# versions: the unedited one stays at v2, and the log says what held it back
printf '# my edit\n' >> "$CFG/usage-refresh.sh"; mine=$(cksum < "$CFG/usage-refresh.sh")
mkplugin "$S/v3" v3; hook CLAUDE_PLUGIN_ROOT="$S/v3"
yes hook-update-holds-back-the-unedited-file cmp -s "$S/v2/statusline.sh" "$CFG/statusline.sh"
eq  hook-update-spares-the-edited-file "$(cksum < "$CFG/usage-refresh.sh")" "$mine"
has hook-logs-what-held-the-update-back "$(log)" "skip (held back, usage-refresh.sh edited locally): $CFG/statusline.sh"

# A hook stopped between the copy and the manifest line leaves the plugin's new
# file under the old checksum. The next start takes it back instead of calling
# it a local edit, and later updates land.
fresh; hook; mkplugin "$S/v2" v2; cp "$S/v2/statusline.sh" "$CFG/statusline.sh"
hook CLAUDE_PLUGIN_ROOT="$S/v2"
lacks hook-repairs-a-stale-manifest-line "$(log)" "edited locally"
mkplugin "$S/v3" v3; hook CLAUDE_PLUGIN_ROOT="$S/v3"
yes hook-updates-after-the-repair cmp -s "$S/v3/statusline.sh" "$CFG/statusline.sh"

# One deploy at a time: a held lock leaves the work to its holder, a lock left by
# a killed hook is taken over after a minute, and none is left behind.
fresh; mkdir -p "$CFG/.budget-statusline.lock"; out=$(hook 2>&1); rc=$?
eq  hook-held-lock-exits-0 "$rc $out" "0 "
yes hook-held-lock-installs-nothing absent "$CFG/statusline.sh"
touch -t 200001010000 "$CFG/.budget-statusline.lock"; hook
yes hook-takes-over-an-old-lock cmp -s "$repo/statusline.sh" "$CFG/statusline.sh"
yes hook-leaves-no-lock absent "$CFG/.budget-statusline.lock"
# The lock holds its holder's pid. A dead holder's lock is taken over at once; a
# hook or installer still at work keeps its lock however old; and a run gives
# the lock back only while it holds its own pid.
mkdir -p "$base/stand" "$base/slow"; printf '#!/bin/sh\nsleep 30\n:\n' > "$base/stand/deploy.sh"
printf '#!/bin/sh\nsleep 3\nexec "%s" "$@"\n' "$(command -v cp)" > "$base/slow/cp"; chmod +x "$base/slow/cp"   # a `cp` that takes 3 seconds
sh -c 'exit 0' & gone=$!; wait "$gone"
fresh; mkdir -p "$CFG/.budget-statusline.lock"; echo "$gone" > "$CFG/.budget-statusline.lock/pid"; hook
yes hook-takes-a-dead-holders-lock-at-once cmp -s "$repo/statusline.sh" "$CFG/statusline.sh"
"$shell" "$base/stand/deploy.sh" & lv=$!; sleep 1
fresh; mkdir -p "$CFG/.budget-statusline.lock"; echo "$lv" > "$CFG/.budget-statusline.lock/pid"
touch -t 200001010000 "$CFG/.budget-statusline.lock"; hook
yes hook-leaves-a-running-holders-lock absent "$CFG/statusline.sh"
fresh; env HOME="$S/home" CLAUDE_CONFIG_DIR="$CFG" CLAUDE_PLUGIN_ROOT="$repo" PATH="$base/slow:$PATH" "$shell" "$repo/hooks/deploy.sh" & hp=$!
i=0; while [ ! -s "$CFG/.budget-statusline.lock/pid" ] && [ "$i" -lt 20 ]; do sleep 1; i=$((i + 1)); done
echo "$lv" > "$CFG/.budget-statusline.lock/pid"; wait "$hp"
eq  hook-gives-back-only-its-own-lock "$(cat "$CFG/.budget-statusline.lock/pid" 2>/dev/null)" "$lv"
fresh; mkdir -p "$CFG/.budget-statusline.lock"; echo "$gone" > "$CFG/.budget-statusline.lock/pid"; inst --config-dir "$CFG" >/dev/null 2>&1
yes install-takes-a-dead-holders-lock-at-once cmp -s "$repo/statusline.sh" "$CFG/statusline.sh"
kill "$lv" 2>/dev/null

# an existing statusLine is the user's choice
fresh; mkdir -p "$CFG"
printf '{"model":"opus","statusLine":{"type":"command","command":"echo mine"}}\n' > "$CFG/settings.json"
want=$(cksum < "$CFG/settings.json"); hook
eq  hook-keeps-existing-statusline "$(cksum < "$CFG/settings.json")" "$want"
yes hook-still-installs-the-scripts cmp -s "$repo/statusline.sh" "$CFG/statusline.sh"

# wiring into a `settings.json` that has other keys keeps them, and keeps mode 600
fresh; mkdir -p "$CFG"
printf '{"model":"opus","env":{"A":"b"}}\n' > "$CFG/settings.json"; chmod 600 "$CFG/settings.json"
hook
eq  hook-wire-keeps-other-keys "$(jqs '.model + " " + .env.A + " " + .statusLine.command' "$CFG/settings.json")" "opus b ${pre}$CFG/statusline.sh"
if [ -n "$modes" ]; then eq hook-wire-keeps-file-mode "$(mode "$CFG/settings.json")" "-rw-------"
else skip hook-wire-keeps-file-mode "$nomodes"; fi

# a corrupt `settings.json` is never rewritten
fresh; mkdir -p "$CFG"; printf '{ not json' > "$CFG/settings.json"
want=$(cksum < "$CFG/settings.json"); hook
eq  hook-leaves-corrupt-settings "$(cksum < "$CFG/settings.json")" "$want"

# Whatever is left unwired is said in the log, with the line to add: an empty
# `settings.json`, one with a // comment or a trailing comma, and one with a
# statusLine of its own. The hook's own wiring says nothing on the next start.
for row in 'empty|' 'comment|// mine\n{}\n' 'comma|{"model":"opus",}\n'; do
  fresh; mkdir -p "$CFG"; printf "${row#*|}" > "$CFG/settings.json"; hook
  has "hook-logs-unwired-settings-${row%%|*}" "$(log)" 'not a valid JSON object (empty, a comment, a trailing comma?), left alone. Add inside its top-level braces: "statusLine": { "type": "command"'
done
fresh; mkdir -p "$CFG"; printf '{"statusLine":{"type":"command","command":"echo mine"}}\n' > "$CFG/settings.json"; hook
has hook-logs-a-statusline-of-its-own "$(log)" 'has a statusLine of its own, left alone. To use this one, set: "statusLine": { "type": "command"'
fresh; hook; hook; lacks hook-says-nothing-of-its-own-wiring "$(log)" 'left alone'

# Git Bash hands a native `jq.exe` every `/path` argument rewritten as `C:/path`. The
# hook and the installer must still know their own wiring: the stand-in `jq` here
# rewrites --arg values that way (files stay readable).
msysjq() {
  d="$base/msysjq"; [ -d "$d" ] && return; mkdir -p "$d"
  { printf '#!/bin/sh\n'
    printf 'w=\n'
    printf 'for a do shift\n'
    printf '  if [ "$w" = v ]; then case "$a" in /*) a="C:$a" ;; esac; w=\n'
    printf '  elif [ "$w" = n ]; then w=v\n'
    printf '  elif [ "$a" = --arg ]; then w=n; fi\n'
    printf '  set -- "$@" "$a"\n'
    printf 'done\n'
    printf 'exec "%s" "$@"\n' "$(command -v jq)"; } > "$d/jq"; chmod +x "$d/jq"
}
# With `uname` saying MINGW too, the command is `bash /path`, which Git Bash leaves
# as it is.
msysjq; mkdir -p "$base/mingw"; printf '#!/bin/sh\necho MINGW64_NT-10.0-19045\n' > "$base/mingw/uname"; chmod +x "$base/mingw/uname"
win="$base/msysjq:$base/mingw:$PATH"
fresh; hook PATH="$win"; hook PATH="$win"
lacks hook-knows-its-wiring-through-a-windows-jq "$(log)" 'of its own'
fresh; inst_p "$win" --config-dir "$CFG" >/dev/null 2>&1; out=$(inst_p "$win" --config-dir "$CFG" --uninstall 2>&1)
eq  uninstall-knows-its-wiring-through-a-windows-jq "$(jqs '.statusLine | tostring' "$CFG/settings.json")" "null"

# What needs the user is told once, as a `systemMessage`: JSON on stdout, which
# Claude Code shows the user and keeps out of Claude's context. It is said
# again only when it changes, and nothing is said while all is well.
notice() { printf '%s' "$1" | jq -r '.systemMessage // empty' 2>&1 | tr -d '\r'; }   # notice <hook stdout>
fresh; hook; printf '# my edit\n' >> "$CFG/statusline.sh"; mkplugin "$S/v2" v2
out=$(hook CLAUDE_PLUGIN_ROOT="$S/v2")
has hook-notice-names-the-edited-script "$(notice "$out")" "budget-statusline: statusline.sh in $CFG is edited locally, so neither script was updated"
eq  hook-notice-is-one-json-object "$(printf '%s' "$out" | jq -c 'keys' 2>&1 | tr -d '\r')" '["systemMessage"]'
eq  hook-notice-shows-once "$(hook CLAUDE_PLUGIN_ROOT="$S/v2")" ""
cp "$repo/statusline.sh" "$CFG/statusline.sh"; out=$(hook CLAUDE_PLUGIN_ROOT="$S/v2")
eq  hook-notice-says-nothing-once-resolved "$out" ""
yes hook-notice-file-goes-once-resolved absent "$CFG/.budget-statusline-notice"
fresh; mkdir -p "$CFG"; printf '// mine\n{}\n' > "$CFG/settings.json"
has hook-notice-invalid-settings "$(notice "$(hook)")" 'settings.json is not valid JSON (empty, a comment, a trailing comma?), so the status line was not set up. Add inside its top-level braces: "statusLine": {'
fresh; mkdir -p "$CFG"; printf '{"statusLine":{"type":"command","command":"echo mine"}}\n' > "$CFG/settings.json"
has hook-notice-statusline-of-its-own "$(notice "$(hook)")" "settings.json already has a statusLine of its own, so it was left alone"
eq  hook-notice-statusline-of-its-own-once "$(hook)" ""
printf '{ broken' > "$CFG/settings.json"
has hook-notice-again-when-it-changes "$(notice "$(hook)")" "settings.json is not valid JSON"

# a symlinked `settings.json` (dotfiles) is not replaced by a regular file
if [ -n "$links" ]; then
  fresh; mkdir -p "$CFG"; printf '{}\n' > "$S/dotfiles-settings.json"; ln -s "$S/dotfiles-settings.json" "$CFG/settings.json"
  hook
  yes hook-keeps-symlinked-settings test -L "$CFG/settings.json"
  eq  hook-symlinked-settings-target-untouched "$(cat "$S/dotfiles-settings.json")" "{}"
else
  skip hook-keeps-symlinked-settings "$nolinks"
  skip hook-symlinked-settings-target-untouched "$nolinks"
fi

# a `statusline.sh` we did not write is left alone, and `settings.json` is not
# pointed at it. The other script is held back too: it would run beside it.
fresh; mkdir -p "$CFG"; printf '# someone else\n' > "$CFG/statusline.sh"
want=$(cksum < "$CFG/statusline.sh"); out=$(hook)
eq  hook-spares-foreign-file "$(cksum < "$CFG/statusline.sh")" "$want"
has hook-logs-foreign-file "$(log)" "skip (held back, statusline.sh not installed by this plugin)"
yes hook-holds-back-the-other-script absent "$CFG/usage-refresh.sh"
yes hook-does-not-wire-a-foreign-file test ! -e "$CFG/settings.json"
has hook-notice-names-the-foreign-file "$(printf '%s' "$out" | jq -r '.systemMessage // empty' 2>&1 | tr -d '\r')" "statusline.sh in $CFG was not installed by this plugin, so neither script was installed or updated"
# and the case that matters: a hand-copied refresher, which the new status line
# would run, holds back `statusline.sh` and the wiring
fresh; mkdir -p "$CFG"; printf '#!/bin/sh\n# an old hand copy\n' > "$CFG/usage-refresh.sh"; hook
yes hook-installs-nothing-beside-a-hand-copy absent "$CFG/statusline.sh"
yes hook-wires-nothing-beside-a-hand-copy test ! -e "$CFG/settings.json"

# a symlink at the destination is not followed or replaced
if [ -n "$links" ]; then
  fresh; mkdir -p "$CFG"; printf '# elsewhere\n' > "$S/elsewhere.sh"; ln -s "$S/elsewhere.sh" "$CFG/statusline.sh"
  hook
  yes hook-spares-symlink test -L "$CFG/statusline.sh"
  eq  hook-symlink-target-untouched "$(cat "$S/elsewhere.sh")" "# elsewhere"
else
  skip hook-spares-symlink "$nolinks"
  skip hook-symlink-target-untouched "$nolinks"
fi

# the hard case: we wrote the file, the user later swapped it for a symlink to
# a copy with the same bytes (a dotfiles manager does this), and a newer plugin
# ships. Checksum and manifest both say "ours", so only the symlink rule saves it.
if [ -n "$links" ]; then
  fresh; hook
  mv "$CFG/statusline.sh" "$S/managed-elsewhere.sh"; ln -s "$S/managed-elsewhere.sh" "$CFG/statusline.sh"
  mkplugin "$S/v2" v2; hook CLAUDE_PLUGIN_ROOT="$S/v2"
  yes hook-update-spares-a-swapped-symlink test -L "$CFG/statusline.sh"
  yes hook-update-leaves-the-symlink-target cmp -s "$repo/statusline.sh" "$S/managed-elsewhere.sh"
else
  skip hook-update-spares-a-swapped-symlink "$nolinks"
  skip hook-update-leaves-the-symlink-target "$nolinks"
fi

# Stopped by a signal mid-deploy, the hook and the installer still give their
# lock back: `dash` runs no `EXIT` trap on a signal unless the signal is trapped
# too. A `cp` that takes 3 seconds holds them there.
mkdir -p "$base/slow"; printf '#!/bin/sh\nsleep 3\nexec "%s" "$@"\n' "$(command -v cp)" > "$base/slow/cp"; chmod +x "$base/slow/cp"
stopped() {  # stopped <script> [args...]: run it with $shell in the background, TERM it once it holds the lock, wait
  env -u CLAUDE_CONFIG_DIR HOME="$S/home" CLAUDE_CONFIG_DIR="$CFG" CLAUDE_PLUGIN_ROOT="$repo" PATH="$base/slow:$PATH" "$shell" "$@" >/dev/null 2>&1 &
  sp=$!; i=0
  while [ ! -d "$CFG/.budget-statusline.lock" ] && [ "$i" -lt 20 ]; do sleep 1; i=$((i + 1)); done
  kill -TERM "$sp" 2>/dev/null; wait "$sp" 2>/dev/null
}
leftover() { ls -A "$1" 2>/dev/null | grep -E '\.[0-9]+$' | tr '\n' ' '; }   # leftover <folder>: temporary files of a run
fresh; stopped "$repo/hooks/deploy.sh"; c1=$CFG
yes hook-stopped-gives-the-lock-back absent "$CFG/.budget-statusline.lock"
fresh; stopped "$repo/install.sh" --config-dir "$CFG"; c2=$CFG
yes install-stopped-gives-the-lock-back absent "$CFG/.budget-statusline.lock"
# A run that died at once would leave its `cp` running, to write a temporary
# file after the run is gone; wait for that before looking.
sleep 4
eq  hook-stopped-leaves-no-temporary-file "$(leftover "$c1")" ""
eq  install-stopped-leaves-no-temporary-file "$(leftover "$c2")" ""

# it never fails a session and never speaks
fresh; mkdir -p "$CFG"; chmod 555 "$CFG"
out=$(hook 2>&1); rc=$?; chmod 755 "$CFG"
eq  hook-unwritable-folder-exits-0 "$rc" 0
eq  hook-unwritable-folder-is-silent "$out" ""
fresh
out=$(env -u HOME -u CLAUDE_CONFIG_DIR CLAUDE_PLUGIN_ROOT="$repo" "$shell" "$repo/hooks/deploy.sh" 2>&1); rc=$?
eq  hook-without-home-exits-0 "$rc" 0
eq  hook-without-home-is-silent "$out" ""
fresh; mkdir "$S/empty"
out=$(hook CLAUDE_PLUGIN_ROOT="$S/empty" 2>&1); rc=$?
eq  hook-empty-plugin-exits-0 "$rc" 0
has hook-empty-plugin-is-logged "$(log)" "missing in plugin"

# no `jq`: the scripts still land, `settings.json` is not touched, the log says why
nojq; fresh
out=$(hook PATH="$base/nojq" 2>&1); rc=$?
eq  hook-nojq-exits-0 "$rc" 0
yes hook-nojq-installs-the-scripts cmp -s "$repo/statusline.sh" "$CFG/statusline.sh"
yes hook-nojq-leaves-settings-alone test ! -e "$CFG/settings.json"
has hook-nojq-logs-the-line-to-add "$(log)" '"statusLine": { "type": "command"'

# Git Bash cannot run a bare .sh path, so the command names bash. The Windows
# `uname` is simulated with a shim: this is not a run on Windows.
fresh; mkdir -p "$S/shim"; printf '#!/bin/sh\necho MINGW64_NT-10.0-19045\n' > "$S/shim/uname"; chmod +x "$S/shim/uname"
hook PATH="$S/shim:$PATH"
eq  hook-windows-command "$(jqs .statusLine.command "$CFG/settings.json")" "bash $CFG/statusline.sh"

# a config folder with a space in its path: files land, the command is quoted
fresh; CFG="$S/cfg with space"
hook
yes hook-space-installs cmp -s "$repo/statusline.sh" "$CFG/statusline.sh"
eq  hook-space-quotes-the-command "$(jqs .statusLine.command "$CFG/settings.json")" "${pre}'$CFG/statusline.sh'"

# ---- `install.sh` --------------------------------------------------------------

# usage errors come first and change nothing
fresh
out=$(inst --help 2>&1); rc=$?
eq  install-help-exits-0 "$rc" 0
has install-help-says-usage "$out" "usage: sh install.sh"
out=$(inst --bogus 2>&1); rc=$?
eq  install-unknown-option-exits-2 "$rc" 2
has install-unknown-option-says-so "$out" "unknown option: --bogus"
out=$(inst --config-dir 2>&1); rc=$?
eq  install-missing-folder-exits-2 "$rc" 2
out=$(inst --config-dir "" 2>&1); rc=$?
eq  install-empty-folder-exits-2 "$rc" 2
yes install-empty-folder-changes-nothing absent "$S/home/.claude"

# --dry-run reports and creates nothing, not even the folder
fresh
out=$(inst --config-dir "$CFG" --dry-run 2>&1); rc=$?
eq  install-dry-run-exits-0 "$rc" 0
has install-dry-run-announces-the-install "$out" "would install statusline.sh"
has install-dry-run-announces-the-wiring "$out" "would create settings.json"
yes install-dry-run-creates-nothing test ! -e "$CFG"

# fresh install: same files, modes, manifest and settings as the hook
fresh
out=$(inst --config-dir "$CFG" 2>&1); rc=$?
eq  install-exits-0 "$rc" 0
has install-reports-the-install "$out" "installed statusline.sh"
yes install-copies-statusline cmp -s "$repo/statusline.sh" "$CFG/statusline.sh"
yes install-copies-refresher cmp -s "$repo/usage-refresh.sh" "$CFG/usage-refresh.sh"
if [ -n "$modes" ]; then eq install-file-modes "$(mode "$CFG/statusline.sh") $(mode "$CFG/usage-refresh.sh")" "-rwxr-xr-x -rwxr-xr-x"
else skip install-file-modes "$nomodes"; fi
eq  install-manifest-names "$(awk '{print $1}' "$CFG/.budget-statusline-manifest" | sort | tr '\n' ' ')" "statusline.sh usage-refresh.sh "
eq  install-wires-statusline "$(jqs '.statusLine.type + " " + .statusLine.command + " " + (.statusLine.refreshInterval | tostring)' "$CFG/settings.json")" "command ${pre}$CFG/statusline.sh 60"

# a second run is a no-op and says so
before=$(snap "$CFG"); out=$(inst --config-dir "$CFG" 2>&1); after=$(snap "$CFG")
eq  install-rerun-is-a-noop "$after" "$before"
has install-rerun-says-up-to-date "$out" "up to date: statusline.sh"

# either script edited holds back both, and the output says which file did
fresh; inst --config-dir "$CFG" >/dev/null
mkdir -p "$S/v2"; for f in statusline.sh usage-refresh.sh; do { cat "$repo/$f"; echo '# v2'; } > "$S/v2/$f"; done; cp "$repo/install.sh" "$S/v2/"
printf '# my edit\n' >> "$CFG/statusline.sh"
out=$(env -u CLAUDE_CONFIG_DIR HOME="$S/home" "$shell" "$S/v2/install.sh" --config-dir "$CFG" 2>&1)
yes install-update-holds-back-the-unedited-file cmp -s "$repo/usage-refresh.sh" "$CFG/usage-refresh.sh"
has install-says-what-held-the-update-back "$out" "skipped usage-refresh.sh: held back, because statusline.sh is edited locally"
fresh; inst --config-dir "$CFG" >/dev/null

# a script that lost its execute bit gets it back, as long as its content is
# current; skipped where file modes are not kept
if [ -n "$modes" ]; then
  chmod 644 "$CFG/usage-refresh.sh"; out=$(inst --config-dir "$CFG" 2>&1)
  eq  install-restores-a-lost-mode "$(mode "$CFG/usage-refresh.sh")" "-rwxr-xr-x"
  has install-says-it-restored-the-mode "$out" "up to date: usage-refresh.sh, its mode restored"
else skip install-restores-a-lost-mode "$nomodes"; skip install-says-it-restored-the-mode "$nomodes"; fi

# a local edit is left alone, and the message names the file
printf '# my edit\n' >> "$CFG/statusline.sh"; mine=$(cksum < "$CFG/statusline.sh")
out=$(inst --config-dir "$CFG" 2>&1)
eq  install-keeps-local-edit "$(cksum < "$CFG/statusline.sh")" "$mine"
has install-says-it-skipped-the-edit "$out" "skipped statusline.sh: edited locally"

# a run stopped between the copy and the manifest line: the next run takes the
# file back, and records it, instead of calling it a local edit
fresh; inst --config-dir "$CFG" >/dev/null
mkdir -p "$S/v2"; { cat "$repo/statusline.sh"; echo '# v2'; } > "$S/v2/statusline.sh"; cp "$repo/usage-refresh.sh" "$repo/install.sh" "$S/v2/"
cp "$S/v2/statusline.sh" "$CFG/statusline.sh"
out=$(env -u CLAUDE_CONFIG_DIR HOME="$S/home" "$shell" "$S/v2/install.sh" --config-dir "$CFG" 2>&1)
lacks install-repairs-a-stale-manifest-line "$out" "edited locally"
eq  install-repair-records-the-file "$(awk '$1=="statusline.sh" {print $2}' "$CFG/.budget-statusline-manifest")" "$(cksum < "$S/v2/statusline.sh" | awk '{print $1 "-" $2}')"
# and one writer at a time, with the hook
fresh; mkdir -p "$CFG/.budget-statusline.lock"; out=$(inst --config-dir "$CFG" 2>&1); rc=$?
eq  install-held-lock-fails "$rc" 1
has install-held-lock-says-so "$out" "another install or session start"
yes install-held-lock-installs-nothing absent "$CFG/statusline.sh"
rmdir "$CFG/.budget-statusline.lock"; inst --config-dir "$CFG" >/dev/null 2>&1
yes install-leaves-no-lock absent "$CFG/.budget-statusline.lock"

# an existing statusLine is left alone, and the output must not claim otherwise
fresh; mkdir -p "$CFG"
printf '{"model":"opus","statusLine":{"type":"command","command":"echo mine"}}\n' > "$CFG/settings.json"
want=$(cksum < "$CFG/settings.json"); out=$(inst --config-dir "$CFG" 2>&1)
eq  install-keeps-existing-statusline "$(cksum < "$CFG/settings.json")" "$want"
has install-says-statusline-was-left-alone "$out" "already has a statusLine, left alone"
lacks install-does-not-claim-it-set-one "$out" "pointed settings.json"

# a file we did not write, or a symlink, is left alone; `settings.json` is not pointed at it
fresh; mkdir -p "$CFG"; printf '# someone else\n' > "$CFG/statusline.sh"
want=$(cksum < "$CFG/statusline.sh"); out=$(inst --config-dir "$CFG" 2>&1)
eq  install-spares-foreign-file "$(cksum < "$CFG/statusline.sh")" "$want"
has install-says-the-file-is-foreign "$out" "this tool did not install it"
yes install-holds-back-the-other-script absent "$CFG/usage-refresh.sh"
yes install-does-not-wire-a-foreign-file test ! -e "$CFG/settings.json"
fresh; mkdir -p "$CFG"; printf '#!/bin/sh\n# an old hand copy\n' > "$CFG/usage-refresh.sh"; out=$(inst --config-dir "$CFG" 2>&1); rc=$?
yes install-installs-nothing-beside-a-hand-copy absent "$CFG/statusline.sh"
has install-says-what-held-it-back "$out" "skipped statusline.sh: held back, because usage-refresh.sh in $CFG was not installed by this tool"
eq  install-beside-a-hand-copy-fails "$rc" 1
if [ -n "$links" ]; then
  fresh; mkdir -p "$CFG"; printf '# elsewhere\n' > "$S/elsewhere.sh"; ln -s "$S/elsewhere.sh" "$CFG/statusline.sh"
  out=$(inst --config-dir "$CFG" 2>&1)
  yes install-spares-symlink test -L "$CFG/statusline.sh"
  eq  install-symlink-target-untouched "$(cat "$S/elsewhere.sh")" "# elsewhere"
else
  skip install-spares-symlink "$nolinks"
  skip install-symlink-target-untouched "$nolinks"
fi
# and the hard case, as for the hook: our file swapped for a symlink to a copy
# with the same bytes. Checksum and manifest say "ours", so only the symlink rule holds.
if [ -n "$links" ]; then
  fresh; inst --config-dir "$CFG" >/dev/null
  mv "$CFG/statusline.sh" "$S/managed-elsewhere.sh"; ln -s "$S/managed-elsewhere.sh" "$CFG/statusline.sh"
  mkdir -p "$S/v2"; { cat "$repo/statusline.sh"; echo '# v2'; } > "$S/v2/statusline.sh"; cp "$repo/usage-refresh.sh" "$S/v2/"
  cp "$repo/install.sh" "$S/v2/install.sh"
  env -u CLAUDE_CONFIG_DIR HOME="$S/home" "$shell" "$S/v2/install.sh" --config-dir "$CFG" >/dev/null 2>&1
  yes install-update-spares-a-swapped-symlink test -L "$CFG/statusline.sh"
  yes install-update-leaves-the-symlink-target cmp -s "$repo/statusline.sh" "$S/managed-elsewhere.sh"
else
  skip install-update-spares-a-swapped-symlink "$nolinks"
  skip install-update-leaves-the-symlink-target "$nolinks"
fi

# a corrupt `settings.json` is never rewritten, and a read-only folder is an error, not a claim of success
fresh; mkdir -p "$CFG"; printf '{ not json' > "$CFG/settings.json"
want=$(cksum < "$CFG/settings.json"); out=$(inst --config-dir "$CFG" 2>&1)
eq  install-leaves-corrupt-settings "$(cksum < "$CFG/settings.json")" "$want"
has install-says-settings-is-invalid "$out" "not a valid JSON object"
# nothing wired means no status line: the installer gives the line to add and
# exits 1; next to a statusLine of its own it gives the line and exits 0
fresh; mkdir -p "$CFG"; printf '// mine\n{}\n' > "$CFG/settings.json"; out=$(inst --config-dir "$CFG" 2>&1); rc=$?
eq  install-invalid-settings-exits-1 "$rc" 1
has install-invalid-settings-gives-the-line "$out" '"statusLine": { "type": "command"'
fresh; mkdir -p "$CFG"; printf '{"statusLine":{"type":"command","command":"echo mine"}}\n' > "$CFG/settings.json"; out=$(inst --config-dir "$CFG" 2>&1); rc=$?
eq  install-statusline-of-its-own-exits-0 "$rc" 0
has install-statusline-of-its-own-gives-the-line "$out" 'replace it with:
  "statusLine": { "type": "command"'
# a symlinked `settings.json` (a dotfiles manager) is never swapped for a regular
# file, on install or on uninstall; the output says what to do by hand instead
if [ -n "$links" ]; then
  fresh; mkdir -p "$CFG"; printf '{}\n' > "$S/dotfiles-settings.json"; ln -s "$S/dotfiles-settings.json" "$CFG/settings.json"
  out=$(inst --config-dir "$CFG" 2>&1)
  yes install-keeps-symlinked-settings test -L "$CFG/settings.json"
  eq  install-symlinked-settings-target-untouched "$(cat "$S/dotfiles-settings.json")" "{}"
  has install-symlinked-settings-says-what-to-add "$out" '"statusLine": { "type": "command"'
  printf '{"statusLine":{"type":"command","command":"%s/statusline.sh"}}\n' "$CFG" > "$S/dotfiles-settings.json"
  want=$(cksum < "$S/dotfiles-settings.json")
  out=$(inst --config-dir "$CFG" --uninstall 2>&1)
  yes uninstall-keeps-symlinked-settings test -L "$CFG/settings.json"
  eq  uninstall-symlinked-settings-target-untouched "$(cksum < "$S/dotfiles-settings.json")" "$want"
  has uninstall-symlinked-settings-says-what-to-do "$out" "Remove its statusLine by hand"
else
  skip install-keeps-symlinked-settings "$nolinks"
  skip install-symlinked-settings-target-untouched "$nolinks"
  skip install-symlinked-settings-says-what-to-add "$nolinks"
  skip uninstall-keeps-symlinked-settings "$nolinks"
  skip uninstall-symlinked-settings-target-untouched "$nolinks"
  skip uninstall-symlinked-settings-says-what-to-do "$nolinks"
fi

fresh; mkdir -p "$CFG"; chmod 555 "$CFG"
out=$(inst --config-dir "$CFG" 2>&1); rc=$?
if ( : > "$CFG/.probe" ) 2>/dev/null; then       # root, or Windows: still writable
  rm -f "$CFG/.probe"; skip install-unwritable-folder-fails "a read-only folder is writable here"
  skip install-unwritable-folder-says-error "a read-only folder is writable here"
else eq  install-unwritable-folder-fails "$rc" 1; has install-unwritable-folder-says-error "$out" "error:"; fi
chmod 755 "$CFG"

# no `jq`: scripts land, `settings.json` stays untouched, and the line to add is valid JSON
nojq; fresh
out=$(inst_p "$base/nojq" --config-dir "$CFG" 2>&1); rc=$?
eq  install-nojq-exits-0 "$rc" 0
yes install-nojq-installs-the-scripts cmp -s "$repo/statusline.sh" "$CFG/statusline.sh"
yes install-nojq-leaves-settings-alone test ! -e "$CFG/settings.json"
line=$(printf '%s\n' "$out" | grep '"statusLine"')
eq  install-nojq-line-is-valid-json "$(printf '{\n%s\n}\n' "$line" | jq -r .statusLine.command 2>&1 | tr -d '\r')" "${pre}$CFG/statusline.sh"

# uninstall removes what was placed and nothing else
fresh; inst --config-dir "$CFG" >/dev/null
printf 'mine\n' > "$CFG/keep.txt"; printf '{"x":1}\n' > "$CFG/other.json"
jq '.model = "opus"' "$CFG/settings.json" > "$CFG/settings.tmp" && mv "$CFG/settings.tmp" "$CFG/settings.json"
out=$(inst --config-dir "$CFG" --uninstall 2>&1); rc=$?
eq  uninstall-exits-0 "$rc" 0
yes uninstall-removes-statusline test ! -e "$CFG/statusline.sh"
yes uninstall-removes-refresher test ! -e "$CFG/usage-refresh.sh"
yes uninstall-removes-manifest-and-log absent "$CFG/.budget-statusline-manifest" "$CFG/.budget-statusline.log"
eq  uninstall-keeps-other-files "$(cat "$CFG/keep.txt") $(cat "$CFG/other.json")" 'mine {"x":1}'
eq  uninstall-unwires-only-the-statusline "$(jqs '(.model) + " " + (.statusLine | tostring)' "$CFG/settings.json")" "opus null"

# uninstall spares an edited script, and then keeps the wiring that runs it
fresh; inst --config-dir "$CFG" >/dev/null
printf '# my edit\n' >> "$CFG/statusline.sh"; mine=$(cksum < "$CFG/statusline.sh")
out=$(inst --config-dir "$CFG" --uninstall 2>&1)
eq  uninstall-spares-the-edited-script "$(cksum < "$CFG/statusline.sh")" "$mine"
has uninstall-says-why "$out" "left alone statusline.sh: edited locally"
yes uninstall-still-removes-the-other-script test ! -e "$CFG/usage-refresh.sh"
eq  uninstall-keeps-wiring-for-the-kept-script "$(jqs '.statusLine.command' "$CFG/settings.json")" "${pre}$CFG/statusline.sh"
has uninstall-says-the-wiring-still-runs-it "$out" "settings.json still runs statusline.sh, left in place because it is edited locally. To remove both, delete $CFG/statusline.sh and run this uninstall again."
eq  uninstall-manifest-keeps-the-kept-script "$(awk '{print $1}' "$CFG/.budget-statusline-manifest")" "statusline.sh"
# and that advice works: with the file deleted, uninstall again removes the wiring
rm -f "$CFG/statusline.sh"; inst --config-dir "$CFG" --uninstall >/dev/null 2>&1
eq  uninstall-again-after-deleting-it-unwires "$(jqs '.statusLine | tostring' "$CFG/settings.json")" "null"

# A command is this tool's only when the whole of it runs this folder's script,
# settings in front and `bash` allowed: uninstall leaves a user's own command
# that only starts with the path, or does more after it.
bad=
for c in '~/.claude/statusline.sh.mine' '~/.claude/statusline.sh-v2' '~/.claude/statusline.sh | my-filter'; do
  fresh; inst >/dev/null 2>&1; st="$S/home/.claude/settings.json"
  jq --arg c "$c" '.statusLine.command = $c' "$st" > "$st.t" && mv "$st.t" "$st"
  inst --uninstall >/dev/null 2>&1
  [ "$(jqs .statusLine.command "$st")" = "$c" ] || bad="$bad [$c: $(jqs '.statusLine | tostring' "$st")]"
done
if [ -z "$bad" ]; then pass uninstall-keeps-a-command-that-is-not-ours; else fail uninstall-keeps-a-command-that-is-not-ours "$bad"; fi
bad=
for c in 'CC_SPEND_CAP=200 ~/.claude/statusline.sh' 'CC_WIDTH=-8  CC_ASCII=1 bash ~/.claude/statusline.sh'; do
  fresh; inst >/dev/null 2>&1; st="$S/home/.claude/settings.json"
  jq --arg c "$c" '.statusLine.command = $c' "$st" > "$st.t" && mv "$st.t" "$st"
  inst --uninstall >/dev/null 2>&1
  [ "$(jqs '.statusLine | tostring' "$st")" = null ] || bad="$bad [$c: kept]"
done
if [ -z "$bad" ]; then pass uninstall-unwires-ours-with-settings-in-front; else fail uninstall-unwires-ours-with-settings-in-front "$bad"; fi
# the hook knows the installer's `~/.claude` wiring when `CLAUDE_CONFIG_DIR`
# names that same folder
fresh; inst >/dev/null 2>&1
out=$(env HOME="$S/home" CLAUDE_CONFIG_DIR="$S/home/.claude" CLAUDE_PLUGIN_ROOT="$repo" "$shell" "$repo/hooks/deploy.sh" 2>&1)
eq  hook-knows-the-tilde-wiring "$out" ""
lacks hook-knows-the-tilde-wiring-in-its-log "$(cat "$S/home/.claude/.budget-statusline.log" 2>/dev/null)" "of its own"

# uninstall leaves a statusLine that points somewhere else
fresh; inst --config-dir "$CFG" >/dev/null
jq '.statusLine.command = "echo mine"' "$CFG/settings.json" > "$CFG/settings.tmp" && mv "$CFG/settings.tmp" "$CFG/settings.json"
out=$(inst --config-dir "$CFG" --uninstall 2>&1)
eq  uninstall-keeps-a-foreign-statusline "$(jqs '.statusLine.command' "$CFG/settings.json")" "echo mine"
has uninstall-says-so "$out" "does not point at this script"

# the ~ spelling names the default folder: removed there, but not mistaken for ours in another folder
fresh; inst >/dev/null; out=$(inst --uninstall 2>&1)
eq  uninstall-unwires-the-default-folder "$(jqs '.statusLine | tostring' "$S/home/.claude/settings.json")" "null"
fresh; inst --config-dir "$CFG" >/dev/null
jq '.statusLine.command = "~/.claude/statusline.sh"' "$CFG/settings.json" > "$CFG/settings.tmp" && mv "$CFG/settings.tmp" "$CFG/settings.json"
out=$(inst --config-dir "$CFG" --uninstall 2>&1)
eq  uninstall-keeps-the-default-folders-statusline "$(jqs '.statusLine.command' "$CFG/settings.json")" "~/.claude/statusline.sh"

# uninstall of files this tool never installed does nothing
fresh; mkdir -p "$CFG"; printf '# someone else\n' > "$CFG/statusline.sh"; before=$(snap "$CFG")
out=$(inst --config-dir "$CFG" --uninstall 2>&1); rc=$?
eq  uninstall-exits-0-on-a-foreign-folder "$rc" 0
eq  uninstall-leaves-foreign-files-alone "$(snap "$CFG")" "$before"
has uninstall-says-it-is-not-ours "$out" "this tool did not install it"

# uninstall --dry-run says what it would do and changes nothing
fresh; inst --config-dir "$CFG" >/dev/null; before=$(snap "$CFG")
out=$(inst --config-dir "$CFG" --uninstall --dry-run 2>&1)
eq  uninstall-dry-run-changes-nothing "$(snap "$CFG")" "$before"
has uninstall-dry-run-announces-removal "$out" "would remove statusline.sh"

# which folder: `--config-dir` beats `CLAUDE_CONFIG_DIR` beats `~/.claude`
fresh
env HOME="$S/home" CLAUDE_CONFIG_DIR="$S/decoy" "$shell" "$repo/install.sh" --config-dir "$S/chosen" >/dev/null 2>&1
yes install-flag-beats-env test -f "$S/chosen/statusline.sh"
yes install-flag-leaves-the-env-folder-alone absent "$S/decoy"
env HOME="$S/home" CLAUDE_CONFIG_DIR="$S/from-env" "$shell" "$repo/install.sh" >/dev/null 2>&1
yes install-env-beats-default test -f "$S/from-env/statusline.sh"
yes install-env-leaves-the-default-alone absent "$S/home/.claude"
inst >/dev/null 2>&1
yes install-default-is-home-dot-claude test -f "$S/home/.claude/statusline.sh"
eq  install-default-command-uses-the-tilde "$(jqs .statusLine.command "$S/home/.claude/settings.json")" "${pre}~/.claude/statusline.sh"
mkdir -p "$S/rel"; (cd "$S/rel" && inst --config-dir here >/dev/null 2>&1)
eq  install-relative-folder-becomes-absolute "$(jqs .statusLine.command "$S/rel/here/settings.json")" "${pre}$S/rel/here/statusline.sh"

# a folder with a space in its path, and the simulated Git Bash command
fresh; CFG="$S/cfg with space"; out=$(inst --config-dir "$CFG" 2>&1)
yes install-space-installs cmp -s "$repo/statusline.sh" "$CFG/statusline.sh"
eq  install-space-quotes-the-command "$(jqs .statusLine.command "$CFG/settings.json")" "${pre}'$CFG/statusline.sh'"
fresh; mkdir -p "$S/shim"; printf '#!/bin/sh\necho MINGW64_NT-10.0-19045\n' > "$S/shim/uname"; chmod +x "$S/shim/uname"
inst_p "$S/shim:$PATH" --config-dir "$CFG" >/dev/null 2>&1
eq  install-windows-command "$(jqs .statusLine.command "$CFG/settings.json")" "bash $CFG/statusline.sh"

# a folder with an apostrophe in its path: the command still parses as one word
# naming the script, from the hook and from the installer; uninstall still
# knows it as its own; and the line the hook logs without `jq` is valid JSON
words() { sh -c 'eval "set -- $1"; printf "%s:%s" "$#" "$1"' -- "${1#bash }" 2>&1; }   # words <command>: how a shell splits it
fresh; CFG="$S/it's here"; hook
eq  hook-apostrophe-command-parses "$(words "$(jqs .statusLine.command "$CFG/settings.json")")" "1:$CFG/statusline.sh"
fresh; CFG="$S/it's here"; inst --config-dir "$CFG" >/dev/null 2>&1
eq  install-apostrophe-command-parses "$(words "$(jqs .statusLine.command "$CFG/settings.json")")" "1:$CFG/statusline.sh"
inst --config-dir "$CFG" --uninstall >/dev/null 2>&1
eq  uninstall-apostrophe-unwires "$(jqs '.statusLine | tostring' "$CFG/settings.json")" "null"
# and through a `jq` that cannot open a path holding an apostrophe, as a native
# `jq.exe` cannot under Git Bash, which hands such a path over unconverted (a
# plain string with an apostrophe, the command, is fine): the
# hook knows its own wiring on the next start, and uninstall still removes it
d="$base/aposjq"; mkdir -p "$d"
printf '#!/bin/sh\nfor a do case "$a" in /*\\'"'"'*) exit 2 ;; esac; done\nexec "%s" "$@"\n' "$(command -v jq)" > "$d/jq"; chmod +x "$d/jq"
fresh; CFG="$S/it's here"; hook PATH="$d:$PATH"; hook PATH="$d:$PATH"
lacks hook-apostrophe-through-a-windows-jq "$(log)" 'left alone'
fresh; CFG="$S/it's here"; inst_p "$d:$PATH" --config-dir "$CFG" >/dev/null 2>&1; inst_p "$d:$PATH" --config-dir "$CFG" --uninstall >/dev/null 2>&1
eq  uninstall-apostrophe-through-a-windows-jq "$(jqs '.statusLine | tostring' "$CFG/settings.json")" "null"
nojq; fresh; CFG="$S/it's here"; hook PATH="$base/nojq"
want="${pre}'$S/it'\\''s here/statusline.sh'"
line=$(log | grep -o '"statusLine": {.*}')
eq  hook-nojq-apostrophe-line-is-valid-json "$(printf '{%s}' "$line" | jq -r .statusLine.command 2>&1 | tr -d '\r')" "$want"

# the hook and the installer share one manifest: each can update or remove the other's files
fresh; hook
out=$(inst --config-dir "$CFG" 2>&1)
has shared-installer-sees-the-hooks-files "$out" "up to date: statusline.sh"
out=$(inst --config-dir "$CFG" --uninstall 2>&1)
yes shared-installer-removes-the-hooks-files absent "$CFG/statusline.sh" "$CFG/usage-refresh.sh"
fresh; inst --config-dir "$CFG" >/dev/null
mkplugin "$S/v2" v2; hook CLAUDE_PLUGIN_ROOT="$S/v2"
yes shared-hook-updates-the-installers-files cmp -s "$S/v2/statusline.sh" "$CFG/statusline.sh"
out=$(inst --config-dir "$CFG" 2>&1)
has shared-installer-updates-after-the-hook "$out" "updated statusline.sh"
yes shared-installer-restores-the-shipped-script cmp -s "$repo/statusline.sh" "$CFG/statusline.sh"

[ "$fails" -eq 0 ] && echo "ALL PASS" || echo "$fails FAILED"
exit "$fails"
