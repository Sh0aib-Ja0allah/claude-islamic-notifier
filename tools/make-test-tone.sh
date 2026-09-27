#!/bin/sh
# Write tests/fixtures/tone.wav, a quiet 1 s test tone for trying playback before the real
# recordings exist (docs/PLAN.md, section 10). Development only; the plugin never ships it.
#
# Format: 44.1 kHz, mono, 16-bit PCM WAV with the canonical 44-byte header, the same as the
# bundled clips (docs/PLAN.md, section 6). The wave is a 441 Hz triangle peaking at 2000
# (about -24 dBFS) with 10 ms fades. It is built with integer math only, so every run, on
# any awk, writes the same bytes.
#
# POSIX sh and awk, no ffmpeg. The bytes go out through printf octal escapes, because a
# shell variable cannot hold the 0x00 bytes the header needs.
#
# Usage: sh tools/make-test-tone.sh [output.wav]

LC_ALL=C
export LC_ALL

case $0 in
  */*) here=${0%/*} ;;
  *) here=. ;;
esac
out=${1:-"$here/../tests/fixtures/tone.wav"}
tmp=$out.tmp.$$
trap 'rm -f "$tmp"' EXIT
trap 'exit 1' HUP INT TERM

mkdir -p "${out%/*}" || exit 1

# awk prints the file as lines of printf octal escapes (\ooo), 64 bytes per line.
awk 'function le(v, n,    s, i) {   # v as n little-endian bytes
       s = ""
       for (i = 0; i < n; i++) { s = s sprintf("\\%03o", v % 256); v = int(v / 256) }
       return s
     }
     function str(t,    s, i) {     # ASCII text
       s = ""
       for (i = 1; i <= length(t); i++) s = s sprintf("\\%03o", code[substr(t, i, 1)])
       return s
     }
     BEGIN {
       for (i = 32; i < 127; i++) code[sprintf("%c", i)] = i
       rate = 44100; count = rate; bytes = count * 2; fade = 441
       print str("RIFF") le(36 + bytes, 4) str("WAVE")
       print str("fmt ") le(16, 4) le(1, 2) le(1, 2) le(rate, 4) le(rate * 2, 4) le(2, 2) le(16, 2)
       print str("data") le(bytes, 4)
       line = ""
       for (i = 0; i < count; i++) {
         p = i % 100
         t = (p < 50) ? p : 100 - p                  # 0 up to 50 and back: one period
         s = (4 * t - 100) * 20                      # -2000 .. 2000
         left = count - 1 - i
         if (i < fade) s = int(s * i / fade)
         else if (left < fade) s = int(s * left / fade)
         if (s == 0) s = 0                           # no negative zero
         if (s < 0) s += 65536                       # two complement
         line = line le(s, 2)
         if (i % 32 == 31) { print line; line = "" }
       }
       if (line != "") print line
     }' |
  while IFS= read -r line; do
    # shellcheck disable=SC2059 # the format is only octal escapes, made by the awk above
    printf "$line"
  done > "$tmp" || exit 1

size=$(wc -c < "$tmp")
size=${size##* }
if [ "$size" != 88244 ]; then
  printf 'make-test-tone: wrote %s bytes, expected 88244\n' "$size" >&2
  exit 1
fi
mv -f "$tmp" "$out" || exit 1
