# Native scrub fixture

`native-scrub.mp4` is a generated, silent, gray H.264 Baseline video: 64×64,
30 fps, 30 frames, no B frames, keyframes every 10 frames, duration 1 second.
It is included only in the RunnerTests resource phase, not the app target.

The tail, paused-redraw and live-volume tests exercise decoding and composition;
they must not depend on starting a simulator encoder during each test. The old
AVAssetWriter fixture sometimes stayed in `.writing` beyond its 10-second setup
timeout, then handed an incomplete file to the actual test.

Regenerate with FFmpeg:

```sh
ffmpeg -f lavfi -i "color=c=gray:s=64x64:r=30" -frames:v 30 \
  -c:v libx264 -profile:v baseline -pix_fmt yuv420p \
  -g 10 -keyint_min 10 -sc_threshold 0 -bf 0 \
  -video_track_timescale 15360 -movflags +faststart native-scrub.mp4
```
