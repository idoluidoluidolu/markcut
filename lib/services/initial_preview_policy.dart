/// Android uses individual players rather than the iOS composition player.
/// Prepare its working media before the first playback so 4K decoding does
/// not compete with the initial background transcode.
bool waitForInitialPreview({required bool requested, required bool android}) =>
    requested || android;
