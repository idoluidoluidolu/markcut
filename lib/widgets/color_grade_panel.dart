import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/color_grade.dart';
import '../theme.dart';

/// 一條修正軸：兩端各是一種「我覺得畫面…」的說法。
/// 往你覺得的問題那端拉，系統就往反方向修。
///
/// 標籤直接用對應的顏色寫，不用讀完字才知道「洋紅」長什麼樣
const _fixes = <({String left, String right, String axis, Color lc, Color rc})>[
  // ── 顏色組 ──
  (
    left: '偏紅',
    right: '偏青',
    axis: 'r',
    lc: Color(0xFFFF6B6B),
    rc: Color(0xFF4FE0E0),
  ),
  (
    left: '偏綠',
    right: '偏洋紅',
    axis: 'g',
    lc: Color(0xFF5FDD73),
    rc: Color(0xFFFF74D2),
  ),
  (
    left: '偏藍',
    right: '偏黃',
    axis: 'b',
    lc: Color(0xFF6E9DFF),
    rc: Color(0xFFFFD24F),
  ),
];

/// 明暗組：曝光／亮度／對比本來就有慣用名稱，用一般滑桿就好，
/// 不用套顏色那種「說問題」的引導式。
///
/// 曝光是乘法、亮度是加減、對比是繞中灰縮放——三者數學上互相獨立，
/// 不是同一件事換名字
const _tones = <({String label, String axis})>[
  (label: '曝光', axis: 'e'),
  (label: '亮度', axis: 'v'),
  (label: '對比', axis: 'c'),
];

/// 飽和度歸在「顏色」組（它調的是顏色濃淡，不是明暗）
const _colorTones = <({String label, String axis})>[(label: '飽和度', axis: 's')];

/// 顏色那三條是引導式：往你覺得的問題那端拉，實際往反方向修。
/// 明暗這三條是一般滑桿：右邊就是多、左邊就是少
double _valueOf(ColorGrade g, String axis) => switch (axis) {
  'r' => g.balR,
  'g' => g.balG,
  'b' => g.balB,
  'v' => g.brightness / 0.5,
  's' => g.saturation - 1,
  'e' => g.exposure,
  _ => g.contrast - 1,
};

void _setValue(ColorGrade g, String axis, double v) {
  switch (axis) {
    case 'r':
      g.balR = v;
    case 'g':
      g.balG = v;
    case 'b':
      g.balB = v;
    case 'v':
      g.brightness = v * 0.5;
    case 's':
      g.saturation = 1 + v;
    case 'e':
      g.exposure = v;
    default:
      g.contrast = 1 + v;
  }
}

/// 調色盤：分「顏色」「明暗」兩組，一次只看三條，不會一片滑桿海。
/// 六條軸各自獨立，可以疊加。影片片段和照片共用這個元件
class ColorGradePanel extends StatefulWidget {
  final ColorGrade grade;

  /// 動到任何一條就回呼（父層負責重繪預覽與存檔）
  final VoidCallback onChanged;

  /// 第一次動到之前叫一次，給父層拍復原快照
  final VoidCallback? onBeforeChange;

  /// 右上角「完成」；不給就不顯示
  final VoidCallback? onDone;

  /// 按住「原圖」時回報 true、放開回報 false。
  /// 父層收到 true 就先不要套調色，讓使用者比對前後差異
  final ValueChanged<bool>? onCompare;

  const ColorGradePanel({
    super.key,
    required this.grade,
    required this.onChanged,
    this.onBeforeChange,
    this.onDone,
    this.onCompare,
  });

  @override
  State<ColorGradePanel> createState() => _ColorGradePanelState();
}

class _ColorGradePanelState extends State<ColorGradePanel> {
  /// 目前看的是哪一組（0 = 顏色，1 = 明暗）
  /// 記住上次用的分頁（顏色/明暗）：調色常常是同一種活連續做,
  /// 每次打開都跳回「顏色」會一直要多點一下
  static int _lastGroup = 0;
  int _group = _lastGroup;

  /// 正在按著「原圖」比對
  bool _comparing = false;

  /// 用法說明只在第一次進來時出現，關掉就不再打擾（記在本機）。
  /// 關掉之後還是可以按標題旁的「?」把它叫回來
  static const _hintKey = 'color_grade_hint_seen_v2';
  bool _showHint = false;

  @override
  void initState() {
    super.initState();
    _loadHint();
  }

  Future<void> _loadHint() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() => _showHint = !(prefs.getBool(_hintKey) ?? false));
  }

  Future<void> _dismissHint() async {
    setState(() => _showHint = false);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_hintKey, true);
  }

  void _setCompare(bool on) {
    if (_comparing == on) return;
    setState(() => _comparing = on);
    widget.onCompare?.call(on);
  }

  @override
  void dispose() {
    // 面板被收掉時手指還按著的話，要把預覽還原回調過的樣子
    if (_comparing) widget.onCompare?.call(false);
    super.dispose();
  }

  /// 手勢開始（按下滑桿）時拍一次 undo 快照：
  /// 一次拖曳（到放開為止）＝一步，跟使用者的直覺一致
  void _beginEdit() => widget.onBeforeChange?.call();

  /// 非滑桿的單發動作（重設、黑白鈕）：動作前自己拍一次
  void _edit(VoidCallback change) {
    setState(change);
    widget.onChanged();
  }

  /// 某一組裡有沒有動過（切到另一組時，分頁上要看得出來那邊有東西）
  bool _groupTouched(int group) {
    final axes = group == 0
        ? [..._fixes.map((f) => f.axis), ..._colorTones.map((t) => t.axis)]
        : _tones.map((t) => t.axis);
    for (final a in axes) {
      if (_valueOf(widget.grade, a).abs() > 0.005) return true;
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final g = widget.grade;

    return Column(
      children: [
        Container(
          padding: const EdgeInsets.fromLTRB(12, 6, 12, 6),
          decoration: const BoxDecoration(
            border: Border(bottom: BorderSide(color: kBorder)),
          ),
          child: Row(
            children: [
              const Icon(Icons.tune, size: 16, color: kAmber),
              const SizedBox(width: 6),
              const Text(
                '調色',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
              ),
              // 說明關掉之後還叫得回來，不然關了就永遠找不到。
              // 只在「顏色」組給——說明講的就是色偏那三條
              if (!_showHint && _group == 0)
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => setState(() => _showHint = true),
                  child: const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                    child: Icon(Icons.help_outline, size: 15, color: kTextDim),
                  ),
                ),
              const Spacer(),
              // 按住＝暫時看原圖，放開回到調過的樣子。
              // 用 Listener 收原始指標事件，不進手勢仲裁——
              // 用 GestureDetector 的話按住約半秒長按手勢會把
              // 點擊手勢踢掉、觸發 onTapCancel，畫面自己彈回去
              Listener(
                behavior: HitTestBehavior.opaque,
                onPointerDown: (_) => _setCompare(true),
                onPointerUp: (_) => _setCompare(false),
                onPointerCancel: (_) => _setCompare(false),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 11,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: _comparing ? kPanelHi : Colors.transparent,
                    borderRadius: BorderRadius.circular(99),
                    border: Border.all(
                      color: _comparing ? kAmber : kClipBorder,
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.compare_arrows,
                        size: 14,
                        color: _comparing ? kAmber : kTextDim,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        '原圖',
                        style: TextStyle(
                          fontSize: 11.5,
                          color: _comparing ? kText : kTextDim,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 6),
              TextButton(
                onPressed: g.hasColor
                    ? () {
                        _beginEdit(); // 單發動作：先拍快照
                        _edit(g.reset);
                      }
                    : null,
                style: TextButton.styleFrom(
                  foregroundColor: kTextDim,
                  minimumSize: const Size(0, 32),
                ),
                child: const Text('重設', style: TextStyle(fontSize: 12)),
              ),
              if (widget.onDone != null) ...[
                const SizedBox(width: 4),
                FilledButton(
                  onPressed: widget.onDone,
                  style: FilledButton.styleFrom(
                    minimumSize: const Size(0, 32),
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                  ),
                  child: const Text('完成', style: TextStyle(fontSize: 12.5)),
                ),
              ],
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Container(
            padding: const EdgeInsets.all(3),
            decoration: BoxDecoration(
              color: kBg,
              borderRadius: BorderRadius.circular(9),
            ),
            child: Row(children: [_groupTab(0, '顏色'), _groupTab(1, '明暗')]),
          ),
        ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            children: [
              // 用法擺在最上面，但只出現一次——滑桿本身看不出「拉哪邊代表
              // 什麼」，看過就不用再佔版面。
              // 切到「明暗」自動收起：那句話講的是色偏，對明暗沒意義
              if (_showHint && _group == 0)
                Padding(
                  padding: const EdgeInsets.only(bottom: 14),
                  child: Container(
                    padding: const EdgeInsets.fromLTRB(11, 9, 6, 9),
                    decoration: const BoxDecoration(
                      color: Color(0xFF15151A),
                      border: Border(left: BorderSide(color: kAmber, width: 2)),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Expanded(
                          child: Text(
                            '覺得現在畫面偏向哪個顏色，就往那邊拉。\n'
                            '按住「原圖」可以比對調色前。',
                            style: TextStyle(
                              fontSize: 11,
                              color: kIcon,
                              height: 1.65,
                            ),
                          ),
                        ),
                        GestureDetector(
                          onTap: _dismissHint,
                          behavior: HitTestBehavior.opaque,
                          child: const Padding(
                            padding: EdgeInsets.all(4),
                            child: Icon(Icons.close, size: 14, color: kTextDim),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              if (_group == 0) ...[
                for (final f in _fixes) _fixRow(g, f),
                const SizedBox(height: 4),
                for (final t in _colorTones) _toneRow(g, t),
              ] else
                for (final t in _tones) _toneRow(g, t),
              const SizedBox(height: 12),
              _monoButton(g),
            ],
          ),
        ),
      ],
    );
  }

  Widget _groupTab(int group, String label) {
    final on = _group == group;
    // 沒在看的那組如果有調過，掛個小點提醒
    final dot = !on && _groupTouched(group);
    return Expanded(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => setState(() {
          _group = group;
          _lastGroup = group;
        }),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 8),
          decoration: BoxDecoration(
            color: on ? kPanelHi : Colors.transparent,
            borderRadius: BorderRadius.circular(7),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                label,
                style: TextStyle(
                  fontSize: 12.5,
                  color: on ? kText : kTextDim,
                  fontWeight: on ? FontWeight.w700 : FontWeight.w400,
                ),
              ),
              if (dot) ...[
                const SizedBox(width: 5),
                Container(
                  width: 5,
                  height: 5,
                  decoration: const BoxDecoration(
                    color: kSelect,
                    shape: BoxShape.circle,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  /// 目前是不是黑白（飽和度歸零、色偏也清掉才是真的黑白）
  bool _isMono(ColorGrade g) =>
      g.saturation < 0.005 &&
      g.balR.abs() < 0.005 &&
      g.balG.abs() < 0.005 &&
      g.balB.abs() < 0.005;

  /// 「調不好？直接黑白」：色偏一定要一起清掉，
  /// 不然通道位移會在灰階上留下色調
  Widget _monoButton(ColorGrade g) {
    final on = _isMono(g);
    return OutlinedButton.icon(
      onPressed: () => _edit(() {
        _beginEdit(); // 單發動作：先拍快照
        if (on) {
          // 再按一次＝把顏色還回來（亮度對比留著，那是另一回事）
          g.saturation = 1;
        } else {
          g.balR = 0;
          g.balG = 0;
          g.balB = 0;
          g.saturation = 0;
        }
      }),
      style: OutlinedButton.styleFrom(
        minimumSize: const Size.fromHeight(42),
        side: BorderSide(color: on ? kAmber : kClipBorder),
        foregroundColor: on ? kText : kTextDim,
      ),
      icon: Icon(Icons.filter_b_and_w, size: 16, color: on ? kAmber : kTextDim),
      label: Text(
        on ? '調不好不管了（再按還原）' : '調不好不管了',
        style: const TextStyle(fontSize: 12.5),
      ),
    );
  }

  /// 明暗組的一般滑桿：左邊名稱、右邊數值，右拉就是多
  Widget _toneRow(ColorGrade g, ({String label, String axis}) t) {
    final v = _valueOf(g, t.axis);
    final on = v.abs() > 0.005;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        children: [
          SizedBox(
            width: 52,
            child: Text(
              t.label,
              style: const TextStyle(fontSize: 12, color: kText),
            ),
          ),
          Expanded(
            child: SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 3,
                overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
              ),
              child: Slider(
                value: v.clamp(-1.0, 1.0),
                min: -1,
                max: 1,
                onChangeStart: (_) => _beginEdit(),
                onChanged: (nv) => _edit(
                  // 靠近正中間就吸回 0，不然很難回到「完全沒調」
                  () => _setValue(g, t.axis, nv.abs() < 0.04 ? 0.0 : nv),
                ),
              ),
            ),
          ),
          SizedBox(
            width: 34,
            child: Text(
              on ? '${v > 0 ? '+' : ''}${(v * 100).round()}' : '0',
              textAlign: TextAlign.right,
              style: TextStyle(
                fontSize: 11.5,
                color: on ? kText : kTextDim,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 一條修正軸：標籤跟滑桿排在同一行，才不會塞爆版面
  Widget _fixRow(
    ColorGrade g,
    ({String left, String right, String axis, Color lc, Color rc}) f,
  ) {
    final v = _valueOf(g, f.axis);
    final on = v.abs() > 0.005;
    final pct = (v.abs() * 100).round();
    // 沒在修的那端調暗一點，正在修的那端才跳出來
    Widget side(String label, Color base, bool active, bool alignRight) {
      return SizedBox(
        width: 58,
        child: Text(
          active ? '$label $pct' : label,
          textAlign: alignRight ? TextAlign.right : TextAlign.left,
          maxLines: 1,
          style: TextStyle(
            fontSize: 11.5,
            color: active ? base : base.withValues(alpha: 0.45),
            fontWeight: active ? FontWeight.w700 : FontWeight.w400,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        children: [
          side(f.left, f.lc, on && v < 0, false),
          Expanded(
            child: SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 3,
                overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
              ),
              child: Slider(
                value: v.clamp(-1.0, 1.0),
                min: -1,
                max: 1,
                onChangeStart: (_) => _beginEdit(),
                onChanged: (nv) => _edit(
                  // 靠近正中間就吸回 0，不然很難回到「完全沒修」
                  () => _setValue(g, f.axis, nv.abs() < 0.04 ? 0.0 : nv),
                ),
              ),
            ),
          ),
          side(f.right, f.rc, on && v > 0, true),
        ],
      ),
    );
  }
}
