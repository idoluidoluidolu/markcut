/// Reversal changes time order, not transfer function or color gamut.
/// HDR must stay Main10; an unavailable encoder is a failure, not permission
/// to silently produce an SDR replacement for the original footage.
({String encoder, String pixelFormat, String options}) reverseVideoSettings({
  required bool apple,
  required bool hdr,
  required String transfer,
  String primaries = '',
  String matrix = '',
  String range = '',
}) {
  String tag(String name, String value) {
    if (value.isEmpty ||
        value == 'unknown' ||
        value == 'unspecified' ||
        !RegExp(r'^[a-zA-Z0-9_-]+$').hasMatch(value)) {
      return '';
    }
    return '-$name $value ';
  }

  final options =
      '${hdr ? '-profile:v main10 -tag:v hvc1 ' : ''}'
      '${tag('color_primaries', primaries)}'
      '${tag('color_trc', transfer)}'
      '${tag('colorspace', matrix)}'
      '${tag('color_range', range)}';
  return (
    encoder:
        '${hdr ? 'hevc' : 'h264'}_${apple ? 'videotoolbox' : 'mediacodec'}',
    pixelFormat: hdr ? 'p010le' : 'nv12',
    options: options,
  );
}
