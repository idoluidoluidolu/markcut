/// Interactive preview preparation yields the decoder on both platforms.
/// Only an explicit request should put the entire import behind a prep gate.
bool waitForInitialPreview({required bool requested, required bool android}) =>
    requested;
