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
# The locale too: the suite reads numbers and dates in the C locale, and a check
# that wants another one sets it.
unset LANG LC_ALL LC_CTYPE LC_NUMERIC LC_TIME LC_COLLATE LC_MESSAGES LC_MONETARY
E=$(printf '\033')

# What a terminal would show: colour codes and the hyperlink wrapper removed.
strip() { LC_ALL=C awk '{ gsub(/\033\]8;;[^\033]*\033\\/, ""); gsub(/\033\[[0-9;]*m/, ""); print }'; }

# run <payload> <extra-env...>  -> stripped output on stdout
run() { runraw "$@" | strip; }
runraw() {  # runraw <payload> <extra-env...>: the same, escape codes and all
  p=$1; shift
  H=$(mktemp -d) || exit 1
  mkdir -p "$H/.claude"
  cp "$sl" "$H/statusline.sh"
  now=$(date +%s)
  sed -e "s|__CWD__|$here|" -e "s|__T1__|$((now+7200))|" -e "s|__T2__|$((now+200000))|" \
    "$here/payloads/$p" | env HOME="$H" "$@" "$shell" "$H/statusline.sh"
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
# 50%, red from 80%. Each render gets a fresh `HOME`.
bands() {  # bands <ctx %> <5h %> <7d %>: one render, escape codes and all
  H=$(mktemp -d); mkdir -p "$H/.claude"; cp "$sl" "$H/statusline.sh"
  printf '{"workspace":{"current_dir":"%s"},"context_window":{"total_input_tokens":5,"used_percentage":%s},"rate_limits":{"five_hour":{"used_percentage":%s,"resets_at":%s},"seven_day":{"used_percentage":%s,"resets_at":%s}}}' \
    "$H" "$1" "$2" "$(( $(date +%s) + 7200 ))" "$3" "$(( $(date +%s) + 200000 ))" | env HOME="$H" "$shell" "$H/statusline.sh"
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
      | env HOME="$H" "$shell" "$H/statusline.sh" | strip); rm -rf "$H"
match gateway-cap-soon "$out" '*· cap [0-2][0-9]:[0-5][0-9] 78%'
# A gateway reset time that is not a whole epoch still draws the cap, with no
# stamp and nothing on stderr.
H=$(mktemp -d); mkdir -p "$H/.claude"; cp "$sl" "$H/statusline.sh"; bad=
for r in 1800000000.5 '"2026-11-01T00:00:00Z"'; do
  out=$(printf '{"workspace":{"current_dir":"%s"},"rate_limits":{"spend_limit":{"used_percentage":78.4,"resets_at":%s}}}' "$H" "$r" \
        | env HOME="$H" "$shell" "$H/statusline.sh" 2>"$H/err" | strip)
  has "$out" '· cap 78%' || bad="$bad [$r: $out]"; [ -s "$H/err" ] && bad="$bad [$r, stderr: $(head -1 "$H/err")]"
done
rm -rf "$H"; verdict gateway-odd-reset-still-draws "$bad"

# A field of the wrong type (an array, an object, a string where an object
# belongs) leaves that field empty and the rest of the line intact, quietly.
H=$(mktemp -d); mkdir -p "$H/.claude"; cp "$sl" "$H/statusline.sh"; bad=
for odd in '"model":{"display_name":["a","b"]}' '"model":{"display_name":{"x":1}}' '"model":"Opus","effort":[1]' '"workspace":"/x","cwd":7'; do
  out=$(printf '{%s,"context_window":{"total_input_tokens":5},"rate_limits":{"five_hour":{"used_percentage":24,"resets_at":%s}}}' "$odd" "$(( $(date +%s) + 7200 ))" \
        | env HOME="$H" "$shell" "$H/statusline.sh" 2>"$H/err" | strip)
  like "$out" '* · ctx 5 · 5h ??:?? 24%' || bad="$bad [$odd: $out]"
  [ -s "$H/err" ] && bad="$bad [$odd, stderr: $(head -1 "$H/err")]"
done
rm -rf "$H"; verdict odd-payload-fields-keep-the-line "$bad"

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
