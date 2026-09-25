#!/bin/sh
# Rebuilds the launch videos into assets/: the square clip (silent, for the README), its animated WebP preview, and
# the 16:9 clip with the house track (for YouTube and X). Needs Swift, ffmpeg and img2webp (brew install webp).
set -eu
cd "$(dirname "$0")"
assets=../../assets
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

swiftc -O render.swift -o "$work/render"
swiftc -O music.swift -o "$work/music"
mkdir -p "$work/square" "$work/wide" "$work/preview" "$assets"

"$work/render" "$work/square"
"$work/render" "$work/wide" --wide
"$work/music" "$work/music.wav"

x264="-c:v libx264 -preset slow -crf 18 -pix_fmt yuv420p -movflags +faststart"
ffmpeg -v error -y -framerate 30 -i "$work/square/f%04d.png" $x264 "$assets/herdr-voice-launch.mp4"
ffmpeg -v error -y -framerate 30 -i "$work/wide/f%04d.png" -i "$work/music.wav" $x264 -profile:v high \
    -c:a aac -b:a 192k -shortest "$assets/herdr-voice-launch-16x9.mp4"

# README preview: animated WebP, 720 px at 15 fps (GitHub plays images, not repo videos).
ffmpeg -v error -y -i "$assets/herdr-voice-launch.mp4" -vf "fps=15,scale=720:720:flags=lanczos" "$work/preview/p%04d.png"
img2webp -loop 0 -lossy -q 72 -m 6 -d 67 "$work"/preview/p*.png -o "$assets/herdr-voice-launch.webp" >/dev/null

ls -la "$assets"/herdr-voice-launch*
