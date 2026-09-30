# MarkCut native artifact integrity patch

Based on pub.dev `ffmpeg_kit_flutter_new_full` 2.5.2, retaining its license and Dart/native API.

- `scripts/setup_ios.sh`: pin the 8.1.2-full iOS ZIP SHA-256, verify before extraction, and verify installed framework files before reusing the cache. Mirrors must serve identical bytes.
- `ios/ffmpeg_kit_flutter_new_full.podspec`: always invoke the verifier; the app's Podfile also invokes it because local pods can skip prepare commands.
- Expected ZIP: `ffmpeg-kit-ios-full-8.1.2.zip`, 49,275,024 bytes.
- SHA-256: `bdefd779553cb5636e36aeec9ba8cb4d04ee88381fc26c2d5447c2950a29ac0b`.
- Provenance: [upstream release metadata](https://api.github.com/repos/sk3llo/ffmpeg_kit_flutter/releases/tags/8.1.2-full), checked 2026-09-27. Updating requires reviewing and pinning the new artifact, not taking an environment-supplied digest.

This patch verifies artifact identity. It does not assert that every bundled codec is vulnerability-free. Android's separate media_kit/libmpv binary needs its own patch inventory.
