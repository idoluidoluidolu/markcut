import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:shared_preferences/shared_preferences.dart';

import '../theme.dart';

/// 顏文字面板：點一個＝複製到剪貼簿，回輸入框貼上就能用。
/// 最近用過的自動排在最上面一區（存在本機，跨頁共用）。
///
/// 不做「點了直接插進輸入框」——複製的話在別的 App 也用得到，
/// 而且不用管游標在哪（使用者指定：點選複製）。

const _kRecentKey = 'kaomoji_recent_v1';
const _kRecentCap = 24;

/// 分類與內容。字串一律用 raw string，反斜線那些字元才不會被吃掉
const _kGroups = <(String, List<String>)>[
  (
    '開心',
    [
      r'( ´ ▽ ` )',
      r'(◍•ᴗ•◍)',
      r'(๑˃̵ᴗ˂̵)و',
      r'(＾▽＾)',
      r'(*´∀`)~♥',
      r'(☆ω☆)',
      r'♪(´▽｀)',
      r'(๑´ㅂ`๑)',
      r'(灬ºωº灬)',
      r'( ˘ ³˘)♥',
      r'(≧∇≦)/',
      r'ヽ(●´∀`●)ﾉ',
    ],
  ),
  (
    '可愛',
    [
      r'(｡•ᴗ-)_',
      r'(●´ω｀●)',
      r'(◕ᴗ◕✿)',
      r'ʕ•ᴥ•ʔ',
      r'(=^･ω･^=)',
      r'(´,,•ω•,,)♡',
      r'( ˶ˆᗜˆ˵ )',
      r'(๑•́ ₃ •̀๑)',
      r'₍ᐢ..ᐢ₎',
      r'(≧ω≦)',
      r'(・ω<)☆',
      r'(๑>◡<๑)',
    ],
  ),
  (
    '難過',
    [
      r'(´;ω;`)',
      r'(╥﹏╥)',
      r'(ﾉД`)',
      r'(个_个)',
      r'( ; ; )',
      r'･ﾟ･(つд`ﾟ)･ﾟ･',
      r'(◞‸◟)',
      r'(TT)',
      r'( ˘･з･)',
      r'(´•̥̥̥ω•̥̥̥`)',
    ],
  ),
  (
    '生氣',
    [
      r'(＃`Д´)',
      r'(╬ Ò﹏Ó)',
      r'(¬_¬)',
      r'(＞︿＜)',
      r'(￣ヘ￣)',
      r'ヽ(`Д´)ﾉ',
      r'(ノ°▽°)ノ︵┻━┻',
      r'(◣_◢)',
      r'凸(￣ヘ￣)',
    ],
  ),
  (
    '驚訝',
    [
      r'(⊙_⊙)',
      r'Σ(°△°|||)',
      r'(ﾟдﾟ)',
      r'(⊙ω⊙)',
      r'Σ(っ°Д°;)っ',
      r'(°ロ°)!',
      r'w(ﾟДﾟ)w',
      r'(((ﾟДﾟ)))',
    ],
  ),
  (
    '無奈',
    [
      r'┐(´д`)┌',
      r'╮(╯▽╰)╭',
      r'(￣▽￣)"',
      r'(´-ω-`)',
      r'(¬‿¬)',
      r'( ˘･_･˘ )',
      r'(・_・;)',
      r'╮(╯_╰)╭',
      r'(躺)_(:3」∠)_',
    ],
  ),
  (
    '打招呼',
    [
      r'(・∀・)ノ',
      r'ヾ(＾∇＾)',
      r'(｡･∀･)ﾉﾞ',
      r'( ^_^)／',
      r'ᕕ( ᐛ )ᕗ',
      r'(=ﾟωﾟ)ﾉ',
      r'ヾ(￣▽￣)Bye~',
      r'(揮手)ヾ(*´∀ ˋ*)ﾉ',
    ],
  ),
  (
    '慶祝',
    [
      r'✧*。(ˊᗜˋ*)✧*。',
      r'(ﾉ>ω<)ﾉ :｡･:*:･ﾟ’★',
      r'☆*:.｡.o(≧▽≦)o.｡.:*☆',
      r'(°∀°)b',
      r'(๑•̀ㅂ•́)و✧',
      r'♪(^∇^*)',
      r'(≧∀≦)ゞ',
      r'○( ＾皿＾)っ',
    ],
  ),
];

/// 複製成功的提示：整頁壓暗 45%＋畫面中央的深色大卡（顏文字本人
/// 放大），約 1.2 秒自動消失（A 案，使用者指定）
void _showCopied(BuildContext context, String k) {
  final overlay = Overlay.of(context, rootOverlay: true);
  late final OverlayEntry entry;
  entry = OverlayEntry(
    builder: (_) => IgnorePointer(
      child: Container(
        color: const Color(0x73000000), // 暗幕：提示在跳的時候背景壓暗
        alignment: Alignment.center,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
          decoration: BoxDecoration(
            color: const Color(0xF2141418),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: const Color(0xFF3A3A40)),
            boxShadow: const [
              BoxShadow(
                color: Color(0x80000000),
                blurRadius: 30,
                offset: Offset(0, 8),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                k,
                style: const TextStyle(
                  fontSize: 24,
                  color: Colors.white,
                  height: 1.3,
                  decoration: TextDecoration.none,
                  fontWeight: FontWeight.w500,
                ),
              ),
              const SizedBox(height: 5),
              const Text(
                '已複製',
                style: TextStyle(
                  fontSize: 12.5,
                  color: Color(0xFFB9B9BF),
                  decoration: TextDecoration.none,
                  fontWeight: FontWeight.w400,
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
  overlay.insert(entry);
  Future<void>.delayed(const Duration(milliseconds: 1200), () {
    if (entry.mounted) entry.remove();
  });
}

Future<void> showKaomojiSheet(BuildContext context) async {
  final prefs = await SharedPreferences.getInstance();
  var recent = prefs.getStringList(_kRecentKey) ?? const [];
  if (!context.mounted) return;
  await showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (context) => StatefulBuilder(
      builder: (context, setSheet) {
        Widget chip(String k) => InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: () async {
            await Clipboard.setData(ClipboardData(text: k));
            // 記進「最近用過」：去重、最新的排最前、封頂
            recent = [k, ...recent.where((e) => e != k)];
            if (recent.length > _kRecentCap) {
              recent = recent.sublist(0, _kRecentCap);
            }
            await prefs.setStringList(_kRecentKey, recent);
            if (context.mounted) {
              setSheet(() {});
              _showCopied(context, k);
            }
          },
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: kPanelHi,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: kClipBorder),
            ),
            child: Text(
              k,
              style: const TextStyle(fontSize: 15, color: kText, height: 1.2),
            ),
          ),
        );

        Widget section(String title, List<String> items, {bool hot = false}) =>
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(2, 14, 2, 8),
                  child: Text(
                    title,
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w700,
                      color: hot ? kSelect : kTextDim,
                    ),
                  ),
                ),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [for (final k in items) chip(k)],
                ),
              ],
            );

        return SizedBox(
          height: MediaQuery.of(context).size.height * 0.72,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Padding(
                padding: EdgeInsets.fromLTRB(18, 0, 18, 4),
                child: Text(
                  '顏文字（點一個複製）',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
                ),
              ),
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                  children: [
                    if (recent.isNotEmpty) section('最近用過', recent, hot: true),
                    for (final (title, items) in _kGroups)
                      section(title, items),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    ),
  );
}
