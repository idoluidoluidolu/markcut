import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

/// 診斷工具箱。
///
/// 這支 App 最難查的三種問題，共同點都是「現場什麼都沒留下」：
///
/// 一、匯出閃退。被 iOS 的 jetsam 收掉不會有當機報告、不會有 log，
///     使用者只看到 App 消失。所以要有黑盒子：每個危險步驟開始前先把
///     「我正在做什麼、當下吃多少記憶體」寫進檔案，正常結束就擦掉。
///     下次開 App 如果檔案還在，就知道上次死在哪一步、死的時候多大。
///
/// 二、記憶體。手機上完全看不到，只能靠猜。這裡跟系統要真正的數字：
///     iOS 用 phys_footprint（jetsam 判定用的就是它）＋ 還剩多少額度，
///     Android 用 totalPss。
///
/// 三、「LAG」「不順」。描述沒辦法比較，要有數字：掉了幾格、最久一格
///     多久。
///
/// 全部都是本機的，不打網路、不自己上傳；使用者從診斷畫面複製給我
class Diag {
  Diag._();

  static const _ch = MethodChannel('markcut/diag');

  /// 這次執行看到過的最大記憶體（MB）
  static int peakMb = 0;

  /// 最近一次讀到的記憶體與剩餘額度（MB）
  static int lastMb = 0;
  static int lastFreeMb = 0;

  static final Map<String, int> _counts = {};
  static final List<String> _notes = [];

  /// 互動事件流：毫秒級時間線（上下台/換件/重建/斷流/卡格），
  /// 使用者不用口述，報告自己講「幾秒幾毫秒發生了什麼」
  static final List<String> _evs = [];
  static final _evT0 = DateTime.now();
  static void ev(String msg) {
    final t = DateTime.now().difference(_evT0).inMilliseconds;
    _evs.add('${(t / 1000).toStringAsFixed(2)}s  $msg');
    if (_evs.length > 90) _evs.removeAt(0);
  }
  static Timer? _sampler;

  /// 上次執行沒有正常結束時留下的現場（開 App 時讀一次）
  static String? crumbFromLastRun;

  // ===== 記憶體 =====

  /// 目前的記憶體用量（MB）。拿不到回 null（web、原生沒接上）
  static Future<int?> memoryMb() async {
    if (kIsWeb) return null;
    try {
      final m = await _ch.invokeMapMethod<String, dynamic>('memory');
      if (m == null) return null;
      final used = (m['usedMb'] as num?)?.round() ?? 0;
      final free = (m['freeMb'] as num?)?.round() ?? 0;
      lastMb = used;
      lastFreeMb = free;
      if (used > peakMb) peakMb = used;
      return used;
    } catch (_) {
      return null;
    }
  }

  /// 開始定期取樣（匯出、播放這種會吃記憶體的時候開）
  static void startSampling({Duration every = const Duration(seconds: 2)}) {
    _sampler?.cancel();
    _sampler = Timer.periodic(every, (_) => memoryMb());
    unawaited(memoryMb());
  }

  static void stopSampling() {
    _sampler?.cancel();
    _sampler = null;
  }

  // ===== 黑盒子 =====

  static Future<File?> _crumbFile() async {
    if (kIsWeb) return null;
    try {
      final dir = await getApplicationSupportDirectory();
      return File('${dir.path}${Platform.pathSeparator}last_run.json');
    } catch (_) {
      return null;
    }
  }

  /// 記下「我正在做什麼」。危險步驟開始前呼叫，正常做完呼叫 [clearMark]
  static Future<void> mark(String stage, {Map<String, Object?>? data}) async {
    if (kIsWeb) return;
    final mb = await memoryMb();
    try {
      final f = await _crumbFile();
      await f?.writeAsString(
        jsonEncode({
          'stage': stage,
          'at': DateTime.now().toIso8601String(),
          'usedMb': mb ?? lastMb,
          'freeMb': lastFreeMb,
          'peakMb': peakMb,
          ...?data,
        }),
      );
    } catch (_) {}
  }

  /// 做完了，把現場擦掉——留著的話下次開 App 會被當成上次死在這裡
  static Future<void> clearMark() async {
    if (kIsWeb) return;
    try {
      final f = await _crumbFile();
      if (f != null && f.existsSync()) await f.delete();
    } catch (_) {}
  }

  /// 開 App 時讀一次：上次有沒有做到一半就消失
  static Future<void> loadLastRun() async {
    if (kIsWeb) return;
    try {
      final f = await _crumbFile();
      if (f == null || !f.existsSync()) return;
      final j = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
      final stage = j['stage'] ?? '?';
      final used = j['usedMb'] ?? 0;
      final free = j['freeMb'] ?? 0;
      final extra = <String>[];
      j.forEach((k, v) {
        if (!const {'stage', 'at', 'usedMb', 'freeMb', 'peakMb'}.contains(k)) {
          extra.add('$k=$v');
        }
      });
      crumbFromLastRun =
          '上次執行沒有正常結束\n'
          '  停在：$stage${extra.isEmpty ? '' : '（${extra.join('、')}）'}\n'
          '  當下記憶體：$used MB（系統還剩 $free MB）\n'
          '  時間：${j['at']}';
      await f.delete();
    } catch (_) {}
  }

  /// 上次是不是死在匯出（給編輯器進場時提醒用）
  static bool get lastRunDiedExporting =>
      crumbFromLastRun?.contains('匯出') ?? false;

  // ===== 畫面時間（分辨「誰在卡」）=====
  //
  // 「卡頓」有三種完全不同的來源，處理方式也完全不同：
  //   1. UI 執行緒（build/layout 太重）→ 要減少重建範圍
  //   2. 合成執行緒（raster：saveLayer、模糊、太多圖層）→ 要減少特效
  //   3. 影片本身（解碼器沒把影格送上來）→ 跟 Flutter 無關
  //
  // 前兩種 Flutter 自己會報時間，第三種要看播放器的位置有沒有前進。
  // 沒有這三個數字就只能猜——而三次猜錯的成本是三次白做

  static int frames = 0;
  static int jankBuild = 0; // UI 執行緒超過一格
  static int jankRaster = 0; // 合成執行緒超過一格
  static int worstBuildMs = 0;
  static int worstRasterMs = 0;
  static bool _watchingFrames = false;

  /// 一格的預算：60Hz 是 16.7ms，抓 17 當門檻
  static const _budgetMs = 17;

  static void watchFrames() {
    if (_watchingFrames) return;
    _watchingFrames = true;
    SchedulerBinding.instance.addTimingsCallback((list) {
      for (final t in list) {
        frames++;
        final b = t.buildDuration.inMilliseconds;
        final r = t.rasterDuration.inMilliseconds;
        if (b > _budgetMs) jankBuild++;
        if (r > _budgetMs) jankRaster++;
        if (b > 120) ev('UI卡 ${b}ms');
        if (r > 120) ev('合成執行緒卡 ${r}ms');
        if (b > worstBuildMs) worstBuildMs = b;
        if (r > worstRasterMs) worstRasterMs = r;
      }
    });
  }

  /// 播放器的位置有沒有真的在前進（第三種卡頓）。
  /// 每次取樣比對「時鐘走了多少」與「播放器走了多少」，差太多就是
  /// 影格沒送上來——這種卡頓在 Flutter 這邊完全看不到
  static int playSamples = 0;
  static int playStalls = 0;
  static int worstStallMs = 0;

  /// [callMs] 是「問播放器位置」這通平台呼叫自己花的時間。
  /// 不扣掉的話，平台執行緒忙的時候會被記成「影格落後」——
  /// 上一份報告的「最久落後 210ms」很可能就是這樣來的假訊號
  static void notePlaybackSample(int wallMs, int playerMs, int callMs) {
    if (wallMs < 50) return;
    playSamples++;
    final behind = wallMs - playerMs - callMs;
    if (behind > 80) {
      playStalls++;
      if (behind > worstStallMs) worstStallMs = behind;
    }
    if (callMs > 50) count('問位置這通平台呼叫就花了 50ms 以上');
  }

  // ===== 計數與備註 =====

  /// 現場可切的實驗開關。
  ///
  /// 卡頓這種只有實機才重現的問題，最快的路是「當場關掉一個東西看看」。
  /// 每個假設都要重新出一次 build 的話，一個假設就要花掉一天；做成開關
  /// 之後三十秒就試得完，而且是使用者自己在真的卡的那支專案上試
  static final preheat = ValueNotifier(true);
  static final driftFix = ValueNotifier(true);
  static final scrubPrefetch = ValueNotifier(true);

  /// 只養一顆播放器：把不是「現在這一段」的播放器整顆放掉。
  /// iOS 上每顆 AVPlayer 都佔一組解碼與影格輸出資源，同時養三顆時
  /// 系統會在它們之間排隊——排除掉前面全部之後，這是最後的嫌疑
  static final singlePlayer = ValueNotifier(false);

  /// 合成播放器：整條時間軸交給系統的一顆播放器（見 CompPlayer）。
  /// 這是「一片段一顆播放器」那套的替代品，也是排除到最後剩下的解法。
  /// 實機驗過之後扶正為預設；關掉＝退回舊路徑（備援用）
  static final compPlayer = ValueNotifier(true);

  /// 預覽改用系統的影片圖層（AVPlayerLayer）而不是 Flutter 材質。
  ///
  /// 材質那條路是「影格複製進 Flutter 材質、再由 Flutter 合成」；就算
  /// 一格都沒掉，節奏也可能不均（16ms、50ms、16ms…每格都準時畫，但畫的
  /// 是同一張）。所有 Flutter 端的指標都看不到它，眼睛卻很敏感——這是
  /// 「成品在相簿裡很順、App 裡就是卡」最後一個沒被排除的結構差異。
  /// 打開之後走的是跟相簿播放同一條路：零複製、影格節奏由系統排。
  /// 跟合成播放器一起扶正為預設
  static final playerLayer = ValueNotifier(true);

  /// 匯出的浮水印合成走 GPU（自訂 AVVideoCompositing + Core Image）。
  /// 舊路徑（CoreAnimationTool）是匯出最大的單一瓶頸——它把渲染拉到
  /// Core Animation 的離線繪製。關掉＝退回舊路徑（成品有異狀時的備援）
  static final ciExport = ValueNotifier(true);

  /// HDR 預覽播「HLG 代理」而不是 4K 原檔。
  /// 原檔關鍵幀疏（seek 慢、要靠拖曳快取幀補）；代理是 HLG 直通
  /// 密關鍵幀（不動色彩、seek 快）。當初為了驗 Dolby Vision 顯示
  /// 管理才直接播原檔——實驗做完沒收回。留開關：實機若出現
  /// 過飽和（DV 中繼資料被剝），關掉就回原檔路
  /// 149 實測：合成器吃 HDR 代理後交黑格（交格亮度 0.5→0.063），
  /// 吃原檔正常——先關掉，代理仍供引擎滑動用。查明代理路徑的
  /// 真因（層數/幾何探針）後再開回
  /// 2026-09-01（實機 163）重開：合成器啃 4K 原檔＝一格 50~425ms，
  /// 是「暫停閃卡/樣式閃卡/來回拉卡住/不及時」四個症狀的共同根。
  /// 149 的代理黑畫面若重現，交格亮度探針（0.063）一份報告定罪，
  /// 屆時再關回來
  static final hdrProxyPreview = ValueNotifier(true);

  /// Metal 預覽引擎：滑動/暫停中的畫面改由自家 Metal 管線出
  ///（每軌獨立供格、GPU 疊合、EDR 直出）。關掉＝回合成播放器路
  static final metalPreview = ValueNotifier(true);

  /// 播放接管（最終型態）：播放中的畫面也由引擎出——每軌 pump
  /// 各自硬解、CADisplayLink 逐格合成，合成播放器退居幕後只出
  /// 聲音跟時鐘。關掉＝播放畫面回合成播放器。
  /// 129 卡頓根因＝引擎與合成雙重解碼；現在接管時合成的視訊軌
  /// 硬體級停用（AV 分離，解碼器 100% 歸引擎），預設開
  static final metalPlayback = ValueNotifier(true);

  /// 引擎常駐＝關（實機 160 定案）：暫停時引擎上台＝播放器畫面
  /// 換成引擎畫面，兩套管線輸出差半格/一絲色差，每按一次暫停就
  /// 閃一次——使用者回報五個版本的「暫停閃動」就是這個換手。
  /// 暫停畫面留在系統播放器（它的停格就是精確幀）；樣式/幾何調整
  /// 由合成器催重畫即時顯示（setOverlays/setOvXform 都有 nudge）；
  /// 引擎只在滑動/拖曳接管時上台（有就緒檢查＋首格護持，不閃）
  static final metalResident = ValueNotifier(false);

  /// HLG 合成裡的圖片素材套「反 OOTF」（實驗開關，預設關）。
  ///
  /// 使用者回報：HDR 專案裡加進來的照片顏色跟原圖不合。合成器的色彩鏈
  /// 是 照片(P3/sRGB)→延伸線性 sRGB→HLG 碼；影片是 HLG→線性→HLG，
  /// 來回抵銷，只有圖片是「從線性空間插進來」的。Core Image 的 HLG
  /// 轉換若是純反 OETF（場景參考），線性 0.18 會寫成 HLG 碼 0.378，
  /// 顯示端再套 BT.2100 的 OOTF（γ1.2）就變成 0.128——中間調暗約半檔、
  /// 白還是白，跟回報一模一樣；若含 OOTF（顯示參考）則 0.18 寫成 0.436、
  /// 顯示正確。Apple 文件沒寫是哪一種，只能實機定罪：組建時的中灰探針
  ///（健康報告「中灰探針」那行）直接印出 CI 給 0.18 的 HLG 碼。
  /// 開了＝原生端在載入時對圖片乘 Y^(1/1.2−1)（BT.2100 OOTF 的反函數，
  /// 色度不變），SDR 合成一個位元都不碰。診斷面板有開關，切了就重組
  static final hlgStillInverseOotf = ValueNotifier(false);

  static String get tuning =>
      '預熱=${preheat.value ? '開' : '關'}／'
      '脫節校正=${driftFix.value ? '開' : '關'}／'
      '背景抽幀=${scrubPrefetch.value ? '開' : '關'}／'
      '只養一顆播放器=${singlePlayer.value ? '開' : '關'}／'
      '合成播放器=${compPlayer.value ? '開' : '關'}／'
      '系統影片圖層=${playerLayer.value ? '開' : '關'}／'
      'GPU匯出=${ciExport.value ? '開' : '關'}／'
      'HDR代理預覽=${hdrProxyPreview.value ? '開' : '關'}／'
      'Metal預覽=${metalPreview.value ? '開' : '關'}／'
      'Metal播放=${metalPlayback.value ? '開' : '關'}／'
      'Metal常駐=${metalResident.value ? '開' : '關'}／'
      'HLG圖片反OOTF=${hlgStillInverseOotf.value ? '開' : '關'}';

  static void count(String key, [int n = 1]) {
    _counts[key] = (_counts[key] ?? 0) + n;
  }

  /// 「同時幾個」的峰值：匯入期間同時活著的播放器／轉檔／抽縮圖。
  /// 多素材匯入閃退查的就是這個——十支一起匯入時到底有幾顆解碼器
  /// 同時活著，報告裡直接看得到，不用再猜
  static final Map<String, int> _peaks = {};

  static void peak(String key, int now) {
    if (now > (_peaks[key] ?? 0)) _peaks[key] = now;
  }

  /// 按下播放到畫面真的動（毫秒）。使用者說的「撥放延遲」就是它——
  /// 一直被我讀成「卡頓」而查錯方向，其實數字從第一份報告就在 trace 裡
  static final List<int> playLatencies = [];

  /// 等待期間播放器有沒有回報「正在緩衝」。這是分辨「等的是資料」
  /// 還是「等的是別的東西」的關鍵——播放器自己說了算
  static int playBuffering = 0;

  static void notePlayLatency(int ms, {bool buffering = false}) {
    playLatencies.add(ms);
    if (buffering) playBuffering++;
    if (playLatencies.length > 30) playLatencies.removeAt(0);
  }

  static String get playLatencyText {
    if (playLatencies.isEmpty) return '還沒量到';
    final sum = playLatencies.reduce((a, b) => a + b);
    return '按 ${playLatencies.length} 次：平均 ${sum ~/ playLatencies.length}ms'
        '／最久 ${playLatencies.reduce((a, b) => a > b ? a : b)}ms'
        '／最快 ${playLatencies.reduce((a, b) => a < b ? a : b)}ms';
  }

  /// 先把音訊 session 啟用起來（進編輯器時做一次）。
  ///
  /// 播放器插件只設 category、從來不主動 setActive；iOS 是在播放真的
  /// 開始時才隱式啟用，而啟用要跟音訊伺服器協商——典型 100~300ms。
  /// 那正好是「按下播放要等一下畫面才動」的量級，而且完全不在影片
  /// 解碼那條路上，所以改 preroll、改 playImmediately 都沒用。
  /// 回傳這次啟用花了幾毫秒（那個數字本身就是證據）
  static Future<int?> activateAudio() async {
    if (kIsWeb) return null;
    try {
      final ms = await _ch.invokeMethod<int>('activateAudio');
      if (ms != null) {
        audioActivateMs = ms;
        note('啟用音訊 session 花了 ${ms}ms');
      }
      return ms;
    } catch (_) {
      return null;
    }
  }

  static int audioActivateMs = -1;

  static Future<void> deactivateAudio() async {
    if (kIsWeb) return;
    try {
      await _ch.invokeMethod('deactivateAudio');
    } catch (_) {}
  }

  // ===== 其他判斷器 =====

  /// 裝置的散熱狀態。連續匯出幾支 4K 之後手機會燙，系統一降頻，
  /// 什麼都會頓——這種「全部一起變慢」的卡頓查程式碼永遠查不到
  static String thermal = '?';
  static bool lowPower = false;

  static Future<void> readDeviceState() async {
    if (kIsWeb) return;
    try {
      final m = await _ch.invokeMapMethod<String, dynamic>('deviceState');
      if (m == null) return;
      thermal = (m['thermal'] as String?) ?? '?';
      lowPower = (m['lowPower'] as bool?) ?? false;
    } catch (_) {}
  }

  /// _syncMedia 每一格的成本（60fps 下超過 2ms 就吃掉 12% 的預算）
  static int syncCalls = 0;
  static int syncTotalUs = 0;
  static int syncWorstUs = 0;

  static void noteSync(int us) {
    syncCalls++;
    syncTotalUs += us;
    if (us > syncWorstUs) syncWorstUs = us;
  }

  /// 這一刻有幾顆播放器活著／幾顆正在播（同時播兩顆以上很可能就是頓的來源）
  static int livePlayers = 0;
  static int playingPlayers = 0;
  static int worstPlayingPlayers = 0;

  static void notePlayers(int live, int playing) {
    livePlayers = live;
    playingPlayers = playing;
    if (playing > worstPlayingPlayers) worstPlayingPlayers = playing;
  }

  // ===== 自動排查用的快照 =====

  static ({int frames, int jankB, int jankR, int stalls, int samples})
  snapshot() => (
    frames: frames,
    jankB: jankBuild,
    jankR: jankRaster,
    stalls: playStalls,
    samples: playSamples,
  );

  /// 從某個快照到現在的變化（自動排查每一輪各拿一份）
  static ({int frames, int jankB, int jankR, int stalls, int samples}) since(
    ({int frames, int jankB, int jankR, int stalls, int samples}) s,
  ) => (
    frames: frames - s.frames,
    jankB: jankBuild - s.jankB,
    jankR: jankRaster - s.jankR,
    stalls: playStalls - s.stalls,
    samples: playSamples - s.samples,
  );

  /// 一句話的事實（工作檔轉好了、退到軟體編碼器了…）。最多留 40 條
  static void note(String msg) {
    _notes.add('${DateTime.now().toIso8601String().substring(11, 19)}  $msg');
    if (_notes.length > 40) _notes.removeAt(0);
  }

  static void reset() {
    _counts.clear();
    _peaks.clear();
    _notes.clear();
    _evs.clear();
    peakMb = 0;
    frames = jankBuild = jankRaster = worstBuildMs = worstRasterMs = 0;
    playSamples = playStalls = worstStallMs = 0;
    syncCalls = syncTotalUs = syncWorstUs = 0;
    worstPlayingPlayers = 0;
  }

  static String report() {
    final b = StringBuffer()..writeln('=== 診斷 ===');
    b.writeln('平台：${defaultTargetPlatform.name}${kIsWeb ? ' (web)' : ''}');
    if (lastMb > 0) {
      b.writeln('記憶體：現在 $lastMb MB／峰值 $peakMb MB／系統還剩 $lastFreeMb MB');
    } else {
      b.writeln('記憶體：讀不到（原生通道沒接上）');
    }
    if (crumbFromLastRun != null) {
      b.writeln('--- 上次執行 ---');
      b.writeln(crumbFromLastRun);
    }
    b.writeln('按下播放到畫面動：$playLatencyText');
    if (audioActivateMs >= 0) {
      b.writeln('音訊 session 啟用：${audioActivateMs}ms（進場時先付掉）');
    }
    if (playBuffering > 0) {
      b.writeln('按下播放後在緩衝：$playBuffering 次（播放器說它在等資料）');
    }
    b.writeln('實驗開關：$tuning');
    b.writeln('裝置狀態：散熱=$thermal${lowPower ? '／低耗電模式開著' : ''}');
    if (syncCalls > 0) {
      b.writeln(
        '每格對時成本：平均 ${(syncTotalUs / syncCalls / 1000).toStringAsFixed(2)}ms'
        '／最久 ${(syncWorstUs / 1000).toStringAsFixed(1)}ms（$syncCalls 次）',
      );
    }
    if (livePlayers > 0) {
      b.writeln('播放器：活著 $livePlayers 顆／同時在播最多 $worstPlayingPlayers 顆');
    }
    if (frames > 0) {
      b
        ..writeln('--- 畫面（共 $frames 格）---')
        ..writeln('  UI 執行緒超時：$jankBuild 格（最久 $worstBuildMs ms）')
        ..writeln('  合成執行緒超時：$jankRaster 格（最久 $worstRasterMs ms）');
    }
    if (playSamples > 0) {
      b
        ..writeln('--- 播放器跟不跟得上（取樣 $playSamples 次）---')
        ..writeln('  影格落後：$playStalls 次（最久落後 $worstStallMs ms）');
    }
    final wm = WmDiag.section();
    if (wm.isNotEmpty) b.write(wm);
    if (_evs.isNotEmpty) {
      b.writeln('--- 互動事件流（進場起算，最後 ${_evs.length} 筆）---');
      for (final e in _evs) {
        b.writeln('  $e');
      }
    }
    if (_counts.isNotEmpty) {
      b.writeln('--- 計數 ---');
      _counts.forEach((k, v) => b.writeln('  $k：$v'));
    }
    if (_peaks.isNotEmpty) {
      b.writeln('--- 同時峰值 ---');
      _peaks.forEach((k, v) => b.writeln('  $k：$v'));
    }
    if (_notes.isNotEmpty) {
      b.writeln('--- 過程 ---');
      for (final n in _notes) {
        b.writeln('  $n');
      }
    }
    return b.toString();
  }
}

/// 浮水印管線偵測器：樣式改變→畫面更新的每一段成本（烘圖/傳輸/
/// 上屏延遲/快路使用率/拒收/即時幾何），一份報告全照出來
class WmDiag {
  static int syncs = 0;
  static int fastSyncs = 0;
  static int rejects = 0;
  static int dropped = 0;
  static int stale = 0;
  static int xfSends = 0;
  static int xfRejects = 0;
  static int skipBusy = 0;
  static int skipHold = 0;
  static int skipGeom = 0;
  static int demoted = 0;
  static int xfAfterBake = 0;
  static int lastParts = 0;
  static int lastBytes = 0;
  static final List<int> _lag = [];
  static final List<int> _bake = [];
  static final List<int> _send = [];
  static final List<int> _draw = [];
  static final List<int> _raster = [];
  static final List<int> _encode = [];

  /// 烘圖細目：畫（drawMarks）／點陣（toImage）／讀出（byteData）
  static void noteBakeDetail(int drawMs, int rasterMs, int encodeMs) {
    _push(_draw, drawMs);
    _push(_raster, rasterMs);
    _push(_encode, encodeMs);
  }

  static void noteSync({
    required bool fast,
    required int lagMs,
    required int bakeMs,
    required int sendMs,
    required int partsN,
    required int bytesN,
  }) {
    syncs++;
    if (fast) fastSyncs++;
    lastParts = partsN;
    lastBytes = bytesN;
    _push(_lag, lagMs);
    _push(_bake, bakeMs);
    _push(_send, sendMs);
  }

  static void _push(List<int> l, int v) {
    l.add(v < 0 ? 0 : v);
    if (l.length > 300) l.removeAt(0);
  }

  static String _stat(List<int> l) {
    if (l.isEmpty) return '—';
    final s = [...l]..sort();
    final avg = (l.reduce((a, b) => a + b) / l.length).round();
    final p90 = s[((s.length * 9) ~/ 10).clamp(0, s.length - 1)];
    return '平均 ${avg}ms／九成 ${p90}ms／最久 ${s.last}ms';
  }

  static String section() {
    if (syncs == 0 && xfSends == 0) return '';
    final b = StringBuffer()..writeln('--- 浮水印管線 ---');
    b.writeln(
      '  樣式更新：$syncs 次（即時快路 $fastSyncs／全解析 ${syncs - fastSyncs}）'
      '／烘完追最新：$stale 次／被拒收：$rejects 次／丟過期：$dropped 次',
    );
    b.writeln('  改變到上屏：${_stat(_lag)}（>150ms 就會有「跟」的感覺）');
    b.writeln('  烘圖：${_stat(_bake)}／傳輸：${_stat(_send)}');
    b.writeln(
      '  烘圖細目：畫 ${_stat(_draw)}／點陣 ${_stat(_raster)}'
      '／讀出 ${_stat(_encode)}',
    );
    b.writeln('  最近一版：$lastParts 個部件／${(lastBytes / 1024).round()} KB');
    if (xfSends > 0) {
      b.writeln(
        '  拖曳即時幾何：送 $xfSends 發／被拒收 $xfRejects 發'
        '／烘完200ms內又送 $xfAfterBake 發（>0 可疑：基準循環）',
      );
    }
    b.writeln(
      '  同步被擋：佔線 $skipBusy／等停穩 $skipHold／讓幾何 $skipGeom'
      '／全解析退背景 $demoted',
    );
    return b.toString();
  }

  static void clear() {
    syncs = fastSyncs = rejects = stale = xfSends = xfRejects = 0;
    dropped = demoted = 0;
    skipBusy = skipHold = skipGeom = xfAfterBake = 0;
    lastParts = lastBytes = 0;
    _lag.clear();
    _bake.clear();
    _send.clear();
    _draw.clear();
    _raster.clear();
    _encode.clear();
  }
}
