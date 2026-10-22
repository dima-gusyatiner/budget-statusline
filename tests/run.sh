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
E=$(printf '\033')

# What a terminal would show: colour codes and the hyperlink wrapper removed.
strip() { LC_ALL=C awk '{ gsub(/\033\]8;;[^\033]*\033\\/, ""); gsub(/\033\[[0-9;]*m/, ""); print }'; }

# A check made of several cases: each case adds what went wrong to `$bad`.
verdict() { if [ -z "$2" ]; then echo "ok   $1"; else echo "FAIL $1:$2"; fails=$((fails+1)); fi; }
has() { case "$1" in *"$2"*) return 0 ;; esac; return 1; }    # has <text> <part>

# A folder path with control characters in it (a BEL would end the folder link
# and start a forged one) loses them before the link is built: no sequence can
# be forged, and no BEL or ESC of its own reaches the terminal.
H=$(mktemp -d); mkdir -p "$H/.claude"; cp "$sl" "$H/statusline.sh"
raw=$(printf '{"workspace":{"current_dir":"/tmp/x\\u0007\\u001b]8;;https://evil.example/\\u0007y"}}' | env HOME="$H" "$shell" "$H/statusline.sh")
rm -rf "$H"
bad=; { has "$raw" "${E}]8;;https" || has "$raw" "$(printf '\007')"; } && bad=" [a forged link: $(printf '%s' "$raw" | LC_ALL=C od -c | head -3 | tr -s ' ')]"
verdict folder-path-with-control-characters-cannot-forge-a-link "$bad"
# The C1 controls too (U+0080 to U+009F, here CSI, NEL and OSC), which a shell
# that counts bytes, or any shell in the C locale, does not see as controls.
H=$(mktemp -d); mkdir -p "$H/.claude"; cp "$sl" "$H/statusline.sh"
raw=$(printf '{"workspace":{"current_dir":"/tmp/a\\u009b31mb"},"model":{"display_name":"Opus\\u0085 5"},"effort":{"level":"hi\\u009dgh"}}' | env HOME="$H" "$shell" "$H/statusline.sh")
rm -rf "$H"; bad=
for c in '\302\233' '\302\205' '\302\235'; do has "$raw" "$(printf "$c")" && bad="$bad [$c got through]"; done
[ "$(printf '%s' "$raw" | strip)" = '⌂a31mb · Opus 5 ◊high' ] || bad="$bad [drew: $(printf '%s' "$raw" | strip)]"
verdict names-lose-c1-controls "$bad"
# The folder, model and effort names lose their control characters, so none of
# them can drive the terminal: no clipboard write (OSC 52), no screen clear, no
# BEL. The script's own colour and link codes stay.
H=$(mktemp -d); mkdir -p "$H/.claude"; cp "$sl" "$H/statusline.sh"
raw=$(printf '{"workspace":{"current_dir":"/tmp/a\\u001b]52;c;aGk=\\u0007b"},"model":{"display_name":"Opus\\u001b]52;c;aGk=\\u0007 5"},"effort":{"level":"hi\\u001b[2Jgh"}}' \
      | env HOME="$H" "$shell" "$H/statusline.sh")
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
  out=$(printf '{"workspace":{"current_dir":"%s/repo"}}' "$O" | env HOME="$O/home" $owner "$shell" "$O/statusline.sh" | strip)
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
out=$(printf '{"workspace":{"current_dir":"%s/repo"}}' "$I" | env HOME="$I/home" "$shell" "$I/statusline.sh" | strip)
bad=; [ "$(idx)" = "$before" ] || bad=" [the index was rewritten]"; has "$out" 'git:(' || bad="$bad [drew: $out]"
verdict render-leaves-the-index-alone "$bad"
rm -rf "$I"

# static guarantees
sh -n "$sl" && echo "ok   syntax" || { echo "FAIL syntax"; fails=$((fails+1)); }

[ "$fails" -eq 0 ] && echo "ALL PASS" || echo "$fails FAILED"
exit "$fails"
