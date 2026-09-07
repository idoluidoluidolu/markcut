// 草稿素材的複本（DraftAssets）：存草稿時留一份在 support 底下、
// 草稿記的路徑不見了照來源找回複本、離開時只清「選取器的複本」
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:markcut/services/draft_assets.dart';

void main() {
  final sep = Platform.pathSeparator;
  late Directory root;
  late Directory support;
  late Directory picker;
  late Directory other;

  setUp(() async {
    // 放在專案的 build/ 底下：系統暫存目錄那顆碟可能是滿的
    final base = await Directory(
      '${Directory.current.path}${sep}build${sep}draft_assets_test',
    ).create(recursive: true);
    root = await base.createTemp('run_');
    support = await Directory('${root.path}${sep}support').create();
    picker = await Directory('${root.path}${sep}picker').create();
    other = await Directory('${root.path}${sep}other').create();
    DraftAssets.supportDirOverride = support;
    DraftAssets.pickerRootsOverride = [picker];
  });

  tearDown(() async {
    DraftAssets.supportDirOverride = null;
    DraftAssets.pickerRootsOverride = null;
    try {
      await root.delete(recursive: true);
    } catch (_) {}
  });

  Future<String> touch(String p, [String body = 'x']) async {
    await File(p).writeAsString(body);
    return p;
  }

  String ownDir(String kind) =>
      '${support.path}$sep'
      'draft_assets$sep$kind$sep';

  test('secure：複製進 support/draft_assets/<kind>/、同一個來源不重複、複本本人直接回', () async {
    final src = await touch('${picker.path}${sep}IMG_1.HEIC', 'abc');
    final copy = await DraftAssets.secure(DraftAssets.batch, src);
    expect(copy, isNotNull);
    expect(copy!.startsWith(ownDir(DraftAssets.batch)), isTrue, reason: copy);
    expect(
      copy.endsWith('${sep}IMG_1.HEIC'),
      isTrue,
      reason: '檔名要留著（下游照副檔名認影片）',
    );
    expect(await File(copy).readAsString(), 'abc');

    // 同一個來源再留一次：同一份，不會多一個檔
    expect(await DraftAssets.secure(DraftAssets.batch, src), copy);
    final files = await Directory(
      ownDir(DraftAssets.batch),
    ).list(recursive: true).where((e) => e is File).length;
    expect(files, 1);

    // 已經是複本：直接回它
    expect(await DraftAssets.secure(DraftAssets.batch, copy), copy);
    // 來源不見了：null（呼叫端照記原路徑）
    expect(
      await DraftAssets.secure(
        DraftAssets.batch,
        '${picker.path}${sep}nope.jpg',
      ),
      isNull,
    );
    expect(await DraftAssets.secure(DraftAssets.batch, ''), isNull);
    // 批次跟拼圖各自一格
    final c2 = await DraftAssets.secure(DraftAssets.collage, src);
    expect(c2!.startsWith(ownDir(DraftAssets.collage)), isTrue);
  });

  test('resolve：路徑還在就是它；不在了但留過複本就用複本；都沒有回 null', () async {
    final src = await touch('${picker.path}${sep}a.jpg');
    expect(await DraftAssets.resolve(DraftAssets.batch, src), src);
    final copy = (await DraftAssets.secure(DraftAssets.batch, src))!;
    await File(src).delete();
    expect(
      await DraftAssets.resolve(DraftAssets.batch, src),
      copy,
      reason: '原路徑不見了要找回複本',
    );
    expect(await DraftAssets.resolve(DraftAssets.batch, copy), copy);
    expect(
      await DraftAssets.resolve(DraftAssets.collage, src),
      isNull,
      reason: '別格的複本不算',
    );
    expect(await DraftAssets.resolve(DraftAssets.batch, ''), isNull);
  });

  test('retain：只留 keep 的複本，其餘刪掉、空資料夾一起收', () async {
    final a = (await DraftAssets.secure(
      DraftAssets.batch,
      await touch('${picker.path}${sep}a.jpg'),
    ))!;
    final b = (await DraftAssets.secure(
      DraftAssets.batch,
      await touch('${picker.path}${sep}b.jpg'),
    ))!;
    final c = (await DraftAssets.secure(
      DraftAssets.collage,
      await touch('${picker.path}${sep}c.jpg'),
    ))!;
    expect(await DraftAssets.retain(DraftAssets.batch, {a}), 1);
    expect(File(a).existsSync(), isTrue);
    expect(File(b).existsSync(), isFalse);
    expect(File(b).parent.existsSync(), isFalse, reason: '空掉的資料夾要收');
    expect(File(c).existsSync(), isTrue, reason: '別格不動');
    expect(await DraftAssets.retain(DraftAssets.batch, {}), 1);
    expect(File(a).existsSync(), isFalse);
    // 目錄不存在也不炸
    expect(await DraftAssets.retain('nothing', {}), 0);
  });

  test('discardPickerCopies：只刪選取器目錄底下的；keep 的、自己的複本、別處的檔案都不碰', () async {
    final p1 = await touch('${picker.path}${sep}p1.jpg');
    final p2 = await touch('${picker.path}${sep}p2.jpg');
    final sub = await Directory('${picker.path}${sep}uuid').create();
    final p3 = await touch('${sub.path}${sep}p3.mp4');
    final o = await touch('${other.path}${sep}real.jpg');
    final copy = (await DraftAssets.secure(DraftAssets.batch, p1))!;

    final n = await DraftAssets.discardPickerCopies(
      [p1, p2, p3, o, copy, '', '${picker.path}${sep}gone.jpg'],
      keep: {p2},
    );
    expect(n, 2);
    expect(File(p1).existsSync(), isFalse);
    expect(File(p2).existsSync(), isTrue, reason: 'keep 的留著');
    expect(File(p3).existsSync(), isFalse);
    expect(sub.existsSync(), isFalse, reason: '安卓一次挑選一個資料夾：空了一起收');
    expect(picker.existsSync(), isTrue, reason: '選取器的根目錄本身不動');
    expect(File(o).existsSync(), isTrue, reason: '不在選取器目錄底下的是真檔案，不能刪');
    expect(File(copy).existsSync(), isTrue, reason: '自己的複本歸 retain 管');
  });

  test('afterLeave：草稿留著的都在、其餘的複本與選取器複本都走', () async {
    final p1 = await touch('${picker.path}${sep}p1.jpg');
    final p2 = await touch('${picker.path}${sep}p2.jpg');
    final c1 = (await DraftAssets.secure(DraftAssets.collage, p1))!;
    final c2 = (await DraftAssets.secure(DraftAssets.collage, p2))!;
    await DraftAssets.afterLeave(
      DraftAssets.collage,
      keep: {c1},
      received: [p1, p2],
    );
    expect(File(c1).existsSync(), isTrue);
    expect(File(c2).existsSync(), isFalse);
    expect(File(p1).existsSync(), isFalse);
    expect(File(p2).existsSync(), isFalse);
  });
}
