import 'package:flutter_test/flutter_test.dart';
import 'package:markcut/services/reverse_video_settings.dart';
import 'package:markcut/models/timeline.dart';
import 'package:markcut/services/work_files.dart';

void main() {
  for (final transfer in ['arib-std-b67', 'smpte2084']) {
    test('倒轉 $transfer 保留 HDR 與 Main10 色深', () {
      final settings = reverseVideoSettings(
        apple: true,
        hdr: true,
        transfer: transfer,
        primaries: 'bt2020',
        matrix: 'bt2020nc',
        range: 'tv',
      );
      expect(settings.encoder, 'hevc_videotoolbox');
      expect(settings.pixelFormat, 'p010le');
      expect(settings.options, contains('-profile:v main10'));
      expect(settings.options, contains('-color_trc $transfer'));
      expect(settings.options, isNot(contains('bt709')));
    });
  }
  test('SDR 色彩不強制重新標成 709', () {
    final s = reverseVideoSettings(
      apple: false,
      hdr: false,
      transfer: 'smpte170m',
      primaries: 'smpte170m',
      matrix: 'smpte170m',
      range: 'pc',
    );
    expect(s.options, contains('-colorspace smpte170m'));
    expect(s.options, contains('-color_range pc'));
    expect(s.options, isNot(contains('bt709')));
  });
  test('草稿攜帶倒轉色彩版本，旧草稿預設待更新', () {
    final source = MediaSource(
      path: 'reverse.mp4',
      name: 'reverse',
      kind: ClipKind.video,
      duration: 3,
      revOf: 'original.mov',
      revEnd: 3,
      revColorVersion: WorkFiles.reverseColorVersion,
    );
    expect(
      MediaSource.fromJson(source.toJson()).revColorVersion,
      WorkFiles.reverseColorVersion,
    );
    expect(
      source.withPath('copy.mp4').revColorVersion,
      WorkFiles.reverseColorVersion,
    );
    final old = source.toJson()..remove('revColorVersion');
    expect(MediaSource.fromJson(old).revColorVersion, 0);
  });
}
