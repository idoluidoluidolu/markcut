import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter_test/flutter_test.dart';
import 'package:markcut/services/crop_image_decoder.dart';

Future<Uint8List> sourcePng(int w, int h) async {
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder).drawPaint(ui.Paint()..color = const ui.Color(0xff408020));
  final picture = recorder.endRecording();
  final image = await picture.toImage(w, h);
  picture.dispose();
  try {
    return (await image.toByteData(
      format: ui.ImageByteFormat.png,
    ))!.buffer.asUint8List();
  } finally {
    image.dispose();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'large crop preview is bounded; original dimensions remain available',
    () async {
      final result = await decodeCropImage(
        await sourcePng(4000, 3000),
        maxSide: 2048,
      );
      try {
        expect((result.image.width, result.image.height), (2048, 1536));
        expect((result.sourceWidth, result.sourceHeight), (4000, 3000));
        final full = cropOutputPlan(
          result.sourceWidth,
          result.sourceHeight,
          const ui.Rect.fromLTWH(0, 0, 1, 1),
          maxSide: 4096,
        );
        expect((full.width, full.height, full.decodeSide), (4000, 3000, 4000));
      } finally {
        result.image.dispose();
      }
    },
  );
  test('whole 48MP photo decodes only the resolution needed for a 4K crop', () {
    final plan = cropOutputPlan(
      8000,
      6000,
      const ui.Rect.fromLTWH(0, 0, 1, 1),
      maxSide: 4096,
    );
    expect((plan.width, plan.height, plan.decodeSide), (4096, 3072, 4096));
  });
  test('small crops retain source detail, not pixels from the UI preview', () {
    final plan = cropOutputPlan(
      8000,
      6000,
      const ui.Rect.fromLTWH(.2, .2, .25, .25),
      maxSide: 4096,
    );
    expect((plan.width, plan.height, plan.decodeSide), (2000, 1500, 8000));
  });
  test('uncapped and small original output are not resized or upscaled', () {
    final full = cropOutputPlan(4000, 3000, const ui.Rect.fromLTWH(0, 0, 1, 1));
    expect((full.width, full.height), (4000, 3000));
    final small = cropOutputPlan(
      120,
      80,
      const ui.Rect.fromLTWH(0, 0, 1, 1),
      maxSide: 4096,
    );
    expect((small.width, small.height, small.decodeSide), (120, 80, 120));
  });
  test(
    'corrupt source reports an error without returning a borrowed image',
    () async {
      await expectLater(
        decodeCropImage(Uint8List.fromList([1, 2, 3]), maxSide: 2048),
        throwsException,
      );
    },
  );
}
