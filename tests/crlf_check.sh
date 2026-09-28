#!/bin/sh
# Fail if any .sh or .json file in this checkout has a CR byte (docs/PLAN.md, section 9: a
# CRLF checkout breaks notify.sh). .gitattributes asks git for LF; this checks what git
# actually wrote, on each CI runner, including Windows, where git converts to CRLF by default.
# POSIX sh; needs no git. Bytes are compared with tr and cmp, not grep: Git Bash's grep drops
# the CR before a line end, so it would never see one.
#
# Prints each file that has a CR, then "checked=N crlf=M"; exits non-zero if M > 0, or if it
# found no file at all.
#
# Usage, from the repo root: sh tests/crlf_check.sh

unset CDPATH
case $0 in
  */*) TESTS=${0%/*} ;;
  *) TESTS=. ;;
esac
REPO=$(cd "$TESTS/.." && pwd) || exit 2

checked=0
bad=0
while IFS= read -r f; do
  [ -n "$f" ] || continue
  checked=$((checked + 1))
  if ! tr -d '\015' < "$f" | cmp -s - "$f"; then
    bad=$((bad + 1))
    printf 'CRLF %s\n' "${f#"$REPO"/}"
  fi
done <<EOF
$(find "$REPO" -name .git -prune -o -type f \( -name '*.sh' -o -name '*.json' \) -print)
EOF
printf 'checked=%s crlf=%s\n' "$checked" "$bad"
[ "$checked" -gt 0 ] && [ "$bad" = 0 ]
