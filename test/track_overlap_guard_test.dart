// 「同一軌永遠不重疊」在編輯頁的接線守門。
//
// 規則本身（推開、落點、把手貼齊）由 track_overlap_test 釘著；這裡守的是
// 「螢幕每一條會改片段時間的路都真的接上了」——這些都是 VideoEditorScreen
// 的私有方法，要從外面驅動得整頁跑起來（video_editor_overlap_test 只跑得
// 了圖片那條），所以跟 auto_tidy_from_zero_test 一樣掃原始碼。
// 漏接一條的症狀就是實機 189：那條路做出來的重疊進了合成，指針跟畫面
// 從那一段起對不上
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 抓 `void _foo(...) { ... }` 一整個方法的內容（到下一個同縮排的 `}`）
String _body(String src, String signature) {
  final i = src.indexOf(signature);
  expect(i, isNot(-1), reason: '找不到 $signature，改名了就要一起改這支測試');
  final end = src.indexOf('\n  }', i);
  expect(end, isNot(-1), reason: '$signature 的結尾找不到');
  return src.substring(i, end);
}

void main() {
  final src = File('lib/screens/video_editor_screen.dart').readAsStringSync();

  test('放下不再覆寫（carveRange），改成吸邊＋pin 住推開', () {
    final body = _body(src, 'void _dropClip(int id, double newOffset, int target, bool insert)');
    expect(body.contains('carveRange('), isFalse, reason: '放下不能再裁掉被壓到的片段');
    expect(body.contains('placeOffsetOnTrack('), isTrue);
    expect(RegExp(r'resolveOverlaps\([^)]*pinnedId:\s*clip\.id').hasMatch(body), isTrue);
    expect(src.contains('_tl.carveRange('), isFalse, reason: '整頁都不該再覆寫');
  });

  test('修剪把手：地板、貼齊用 snapTrimEdge、拖完推開', () {
    final body = _body(src, 'void _trimClip(int id, double dSec, bool fromLeft)');
    expect(body.contains('floorOnTrack('), isTrue, reason: '左把手要有地板');
    expect(body.contains('snapTrimEdge('), isTrue, reason: '貼齊不能吸會被推動的段');
    expect(body.contains('snapEdge('), isFalse);
    expect(body.contains('resolveOverlaps(track: c.track)'), isTrue);
  });

  test('貼上與新加素材走 _placeNewClip', () {
    final paste = _body(src, 'Future<void> _pasteClipboard({double? at, int? track})');
    expect(paste.contains('_placeNewClip('), isTrue);
    final helper = _body(src, 'void _placeNewClip(TimelineClip clip)');
    expect(helper.contains('placeOffsetOnTrack('), isTrue);
    expect(RegExp(r'resolveOverlaps\([^)]*pinnedId:\s*clip\.id').hasMatch(helper), isTrue);
    // 會落在既有軌道上的新片段：音樂、旁白、GIF、圖片（單張與批次）
    expect(RegExp(r'_placeNewClip\(clip\)').allMatches(src).length, greaterThanOrEqualTo(6));
  });

  test('變速（含倒轉的幾條退路）與換片段實例之後都推開', () {
    for (final sig in const [
      'void _swapClip(TimelineClip oldClip, TimelineClip newClip)',
      'void _unreverseClip(int clipId, double sp, VoidCallback onDone)',
    ]) {
      expect(_body(src, sig).contains('resolveOverlaps('), isTrue, reason: sig);
    }
    // 速度選單的 apply：改 speed 那一行緊接著推開
    expect(
      RegExp(r'sel\.speed = sp;\s*(//[^\n]*\s*)*_tl\.resolveOverlaps\(track: sel\.track\)').hasMatch(src),
      isTrue,
      reason: '速度滑桿改了 speed 要當場推開',
    );
    // _reverseClip 的兩條退路（Web／非影片、倒轉檔沒做成）
    expect(
      RegExp(r'c\.reverse = true;\s*_tl\.resolveOverlaps\(track: c\.track\)').hasMatch(src),
      isTrue,
    );
    expect(
      RegExp(r'cur\.reverse = true;\s*_tl\.resolveOverlaps\(track: cur\.track\)').hasMatch(src),
      isTrue,
    );
  });

  test('載入草稿時正規化（舊草稿的重疊不能進合成）', () {
    final body = _body(src, 'Future<void> _loadDraft(Map<String, dynamic> j)');
    final fix = body.indexOf('fixDuplicateIds()');
    final norm = body.indexOf('resolveOverlaps()');
    expect(norm, isNot(-1));
    expect(norm > fix, isTrue, reason: '先補 id 再推開（推開用 id 當 tie-break）');
  });
}
