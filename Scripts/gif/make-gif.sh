#!/bin/bash
# Converts the VHS recording into a GIF, shortening only long idle stretches
# (screen unchanged for more than MIN_FREEZE seconds) to KEEP seconds.
set -euo pipefail
export LC_ALL=C
IN=${1:-zen-demo.mp4}
OUT=${2:-zencode-subagents.gif}
MIN_FREEZE=${MIN_FREEZE:-9}
KEEP=${KEEP:-2.5}
WIDTH=${WIDTH:-1200}
TRIM_END=${TRIM_END:-1.5}
END=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$IN" | awk -v t="$TRIM_END" '{printf "%.2f", $1 - t}')

ranges=$(ffmpeg -hide_banner -i "$IN" -vf "freezedetect=n=0.001:d=$MIN_FREEZE" -map 0:v -f null - 2>&1 \
  | tr '\r' '\n' | grep -oE 'freeze_(start|end): [0-9.]+' | awk -v keep="$KEEP" '
    /start/ {s=$2}
    /end/   {e=$2; if (e - s > keep + 0.5) printf "+between(t,%.2f,%.2f)", s + keep, e - 0.3}
  ')
if [ -n "$ranges" ]; then
  cut="select='not(0${ranges})',setpts=N/10/TB,"
else
  cut=""
fi
echo "removed ranges: ${ranges:-none}" >&2

ffmpeg -v error -y -t "$END" -i "$IN" -vf "fps=10,${cut}scale=${WIDTH}:-1:flags=lanczos,split[a][b];[a]palettegen=stats_mode=diff:max_colors=128[p];[b][p]paletteuse=dither=bayer:bayer_scale=4:diff_mode=rectangle" -r 10 "$OUT"
ls -lh "$OUT"
ffprobe -v error -show_entries format=duration -of csv=p=0 "$OUT"
