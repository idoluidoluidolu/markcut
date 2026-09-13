import 'dart:convert';

/// Local, bounded measurements. Channel acknowledgements never count as display
/// presentation, and absent samples never count as a pass.
enum QualityMetric {
  uiBuild('UI 建構', 17, 60, 'ms；非影片顯示 FPS'),
  uiRaster('Flutter 繪製', 17, 60, 'ms；不含 AVPlayerLayer'),
  playbackLag('播放時鐘落後', 80, 5, 'ms；非螢幕掉幀'),
  playStart('起播確認', 200, 5, 'ms；位置開始前進，非首幀'),
  geometryAck('浮水印幾何通道', 50, 10, 'ms；發送至原生確認，非上屏'),
  visibilityAck('整軌隱藏通道', 100, 5, 'ms；發送至原生確認，非上屏'),
  overlayBake('樣式重製', 150, 5, 'ms；不含原生顯示'),
  overlayAck('樣式傳輸', 50, 5, 'ms；原生確認，非上屏'),
  overlayDraw('預覽部件繪圖', 30, 5, 'ms；含圖片解碼等待'),
  overlayRaster('預覽部件點陣化', 100, 5, 'ms；toImage'),
  overlayReadback('預覽部件回讀', 50, 5, 'ms；含 PNG 編碼或 RGBA 回讀'),
  logoDecode('圖片預覽解碼', 300, 3, 'ms；快取未命中'),
  imageRead('圖片檔案讀取', 1000, 3, 'ms；選定後讀取，不含選圖與裁切操作'),
  importMetadata('影片資料接入', 1000, 3, 'ms／支；不含系統選檔與雲端下載'),
  importGate('匯入遮罩等待', 5000, 1, 'ms；遮罩收起不等於首幀已呈現'),
  composition('播放器建置', 1000, 3, 'ms；包含準備與通道，非上屏');

  const QualityMetric(this.label, this.budgetMs, this.minimum, this.meaning);
  final String label;
  final double budgetMs;
  final int minimum;
  final String meaning;
  String get hint => switch (this) {
    uiBuild => '檢查整頁重建、同步 JSON 與主執行緒工作。',
    uiRaster || overlayRaster => '檢查離屏圖尺寸、平鋪、模糊及 GPU 競爭。',
    geometryAck || visibilityAck || overlayAck => '檢查平台佇列、原生拒收及重畫調度；另驗實際上屏。',
    overlayBake || overlayDraw || logoDecode => '檢查快取命中、重複解碼、樣式變更是否誤重製圖片。',
    overlayReadback => '檢查回讀範圍、PNG 編碼及位元組傳輸量。',
    imageRead ||
    importMetadata ||
    importGate => '區分本機讀取、中繼資料、縮圖與背景代理；系統選檔不在此計時。',
    composition => '檢查是否在拖曳或隱藏時重建播放器。',
    playbackLag || playStart => '對照播放器供格、緩衝及代理就緒狀態；時鐘落後不等於顯示掉幀。',
  };
}

enum QualityScenario {
  importMedia('匯入', '重新加入影片、圖片、GIF；分別測首次與快取匯入。'),
  playback('播放穩定', '播放至少 30 秒並跨片段接縫；播放／暫停重複 5 次。'),
  scrub('時間軸拖曳', '來回拖曳、跨接縫、停在第一幀與最後一幀。'),
  style('樣式跟手', '圖片與文字各連續移動、縮放、旋轉、調透明度 10 次。'),
  visibility('整軌顯示', '影片、圖片與浮水印軌各隱藏／恢復 5 次。'),
  flicker('不閃動', '觀察暫停、恢復播放、切頁、換樣式、開關軌道時有無閃屏。'),
  color('顏色與 HDR', '同一素材、同一時間點，比較暫停與播放、加入圖片前後；以原片及匯出成品比對。'),
  export('成品一致', '匯出 SDR／HDR，回相簿確認顏色、亮度、片尾、浮水印與聲音。');

  const QualityScenario(this.label, this.instructions);
  final String label;
  final String instructions;
}

enum QualityObservation { untested, acceptable, problem }

class QualitySamples {
  final List<double> values = [];
  int count = 0;
  int failures = 0;
  double total = 0;
  double maximum = 0;
  void add(double ms, bool success) {
    if (!ms.isFinite || ms < 0) return;
    if (!success) {
      failures++;
      return;
    }
    count++;
    total += ms;
    if (ms > maximum) maximum = ms;
    if (values.length == 300) values.removeAt(0);
    values.add(ms);
  }

  double? get p95 {
    if (values.isEmpty) return null;
    final sorted = [...values]..sort();
    return sorted[(sorted.length * .95).ceil() - 1];
  }

  String status(QualityMetric metric) {
    if (failures > 0 ||
        (p95 ?? 0) > metric.budgetMs ||
        maximum > metric.budgetMs * 4) {
      return '需處理';
    }
    return count < metric.minimum ? '待量測' : '取樣內達標';
  }

  Map<String, Object?> toJson(QualityMetric metric) => {
    'count': count,
    'failed': failures,
    'meanMs': count == 0 ? null : total / count,
    'p95Ms': p95,
    'p95Window': values.length,
    'maxMs': count == 0 ? null : maximum,
    'budgetMs': metric.budgetMs,
    'minimumSamples': metric.minimum,
    'status': status(metric),
    'measurement': metric.meaning,
  };
}

class QualitySpan {
  QualitySpan(this.session, this.metric, this.startUs);
  final int session;
  final QualityMetric metric;
  final int startUs;
  bool finished = false;
}

class QualityDiagnostics {
  static final instance = QualityDiagnostics();
  final Stopwatch _clock = Stopwatch()..start();
  int _session = 0;
  int get session => _session;
  final Set<QualitySpan> _pending = {};
  bool recording = false;
  bool panelVisible = false;
  DateTime? startedAt;
  String build = '?';
  final Map<QualityMetric, QualitySamples> samples = {};
  final Map<QualityScenario, QualityObservation> observations = {};
  final List<Map<String, Object?>> events = [];
  final Map<String, Object?> environment = {};
  Map<String, Object?>? nativeSnapshot;

  void start({required String buildTag}) {
    _session++;
    build = buildTag;
    startedAt = DateTime.now().toUtc();
    _clock
      ..reset()
      ..start();
    samples.clear();
    observations.clear();
    events.clear();
    environment.clear();
    nativeSnapshot = null;
    _pending.clear();
    recording = true;
  }

  void stop() {
    recording = false;
    _clock.stop();
  }

  QualitySpan? begin(QualityMetric metric) {
    if (!recording) return null;
    final span = QualitySpan(_session, metric, _clock.elapsedMicroseconds);
    if (_pending.length < 100) _pending.add(span);
    return span;
  }

  void finish(QualitySpan? span, {bool success = true}) {
    if (span == null || span.finished) return;
    span.finished = true;
    _pending.remove(span);
    if (span.session != _session || !recording) return;
    record(
      span.metric,
      (_clock.elapsedMicroseconds - span.startUs) / 1000,
      success: success,
    );
  }

  void record(QualityMetric metric, double ms, {bool success = true}) {
    if (!recording) return;
    if (!ms.isFinite || ms < 0) return;
    final s = samples[metric] ??= QualitySamples();
    // Keep first failures and new slow peaks as timestamped breadcrumbs, not
    // a per-frame log storm. Never include payloads or user content.
    if ((!success && s.failures == 0) ||
        (success && ms > metric.budgetMs && ms > s.maximum)) {
      events.add({
        'atMs': _clock.elapsedMilliseconds,
        'metric': metric.name,
        'durationMs': ms,
        'result': success ? 'slowPeak' : 'failed',
      });
      if (events.length > 100) events.removeAt(0);
    }
    s.add(ms, success);
  }

  Future<T> measure<T>(
    QualityMetric metric,
    Future<T> Function() operation,
  ) async {
    final span = begin(metric);
    var success = false;
    try {
      final value = await operation();
      success = true;
      return value;
    } finally {
      finish(span, success: success);
    }
  }

  void observe(
    QualityScenario scenario,
    QualityObservation result, {
    double? position,
  }) {
    observations[scenario] = result;
    events.add({
      'atMs': _clock.elapsedMilliseconds,
      'scenario': scenario.name,
      'result': result.name,
      if (position?.isFinite == true) 'timelineSeconds': position,
    });
    if (events.length > 100) events.removeAt(0);
  }

  List<String> get priorities => [
    if (nativeSnapshot?['itemFailed'] == true) '原生播放器回報失敗：優先檢查來源、解碼及組建。',
    for (final scenario in QualityScenario.values)
      if (observations[scenario] == QualityObservation.problem)
        '${scenario.label}：使用者已標記問題，對照事件時間重現。',
    for (final metric in QualityMetric.values)
      if (samples[metric]?.status(metric) == '需處理')
        '${metric.label}：${metric.hint}',
  ];
  Map<String, Object?> toJson() => {
    'schemaVersion': 1,
    'session': _session,
    'build': build,
    'startedAt': startedAt?.toIso8601String(),
    'recording': recording,
    'elapsedMs': _clock.elapsedMilliseconds,
    'scope': '本機本輪取樣；無素材內容與路徑；非全裝置品質認證',
    'environment': environment,
    'nativeSnapshot': nativeSnapshot,
    'metrics': {
      for (final m in QualityMetric.values)
        m.name: (samples[m] ?? QualitySamples()).toJson(m),
    },
    'manualChecks': {
      for (final s in QualityScenario.values)
        s.name: (observations[s] ?? QualityObservation.untested).name,
    },
    'events': events,
    'priorities': priorities,
    'pendingOperations': [
      for (final p in _pending)
        {
          'metric': p.metric.name,
          'elapsedMs': (_clock.elapsedMicroseconds - p.startUs) / 1000,
          'status': '尚未完成，不納入成功延遲；停止記錄不等於操作失敗',
        },
    ],
  };
  String jsonReport() => const JsonEncoder.withIndent('  ').convert(toJson());
  String report() {
    final b = StringBuffer('=== 品質驗收診斷 v1 ===\nBUILD：$build\n');
    b.writeln(
      '本輪：${startedAt?.toIso8601String() ?? '未開始'}／${recording ? '記錄中' : '已停止'}',
    );
    b.writeln('門檻以 60Hz 為初步工程目標，不是所有機型保證；P95 為最近 300 筆，最大值涵蓋本輪。');
    b.writeln('HDR 標記 ≠ 色準；通道確認 ≠ 畫面呈現；黑像素 ≠ 閃屏。');
    b.writeln('色準、HDR 視覺、實際順暢與閃屏須同幀原片／成品／實機比對。');
    if (nativeSnapshot == null) {
      b.writeln('原生快照：未取得（未接線、未更新或沒有合成播放器），不可判定原生顯示品質。');
    }
    b.writeln('--- 本輪量測 ---');
    for (final m in QualityMetric.values) {
      final s = samples[m] ?? QualitySamples();
      b.writeln(
        '${s.status(m)}｜${m.label}：n=${s.count}／失敗=${s.failures}／'
        'P95=${s.p95?.toStringAsFixed(1) ?? '—'}／'
        '最大=${s.count == 0 ? '—' : s.maximum.toStringAsFixed(1)}／目標≤${m.budgetMs}',
      );
      b.writeln('  ${m.meaning}');
    }
    b.writeln('未完成操作：${_pending.length}（不算成功，也不直接判定閃退）');
    b.writeln('--- 人工驗收（不是自動驗證）---');
    for (final s in QualityScenario.values) {
      final state = observations[s] ?? QualityObservation.untested;
      b.writeln(
        '${s.label}：${switch (state) {
          QualityObservation.untested => '未測',
          QualityObservation.acceptable => '本輪主觀可接受',
          QualityObservation.problem => '有問題',
        }}',
      );
    }
    b.writeln('--- 優先處理 ---');
    b.writeln(priorities.isEmpty ? '尚無已記錄異常；不代表全部通過。' : priorities.join('\n'));
    b.writeln('--- 環境與問題時間點 ---');
    b.writeln(
      jsonEncode({
        'environment': environment,
        'native': nativeSnapshot,
        'events': events,
      }),
    );
    return b.toString();
  }
}
