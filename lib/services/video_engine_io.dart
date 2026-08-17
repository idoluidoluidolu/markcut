import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show visibleForTesting;

import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit_config.dart';
import 'package:ffmpeg_kit_flutter_new/ffmpeg_session.dart';
import 'package:ffmpeg_kit_flutter_new/ffprobe_kit.dart';
import 'package:ffmpeg_kit_flutter_new/return_code.dart';
import 'package:ffmpeg_kit_flutter_new/stream_information.dart';
import 'package:gal/gal.dart';
import 'package:path_provider/path_provider.dart';

import '../models/timeline.dart';
import '../models/watermark_settings.dart';
import 'diagnostics.dart';
import 'native_export.dart';
import 'video_processor.dart';

/// 這個平台是否支援影片匯出
const bool videoExportSupported = true;

/// 把來源的某一段做成「已經倒轉好」的影片檔（按下倒轉時呼叫）。
///
/// 做完之後這段就是普通素材：預覽有聲音、播放流暢、匯出不用特殊處理。
/// 內部分段處理（每 2 秒一段、由後往前接），所以多長都倒得動、
/// 記憶體只用到一小段的量。
///
/// [targetW]/[targetH] 是輸出尺寸（呼叫端先把長邊 cap 在 1920 以內）。
/// 回傳檔案路徑；失敗或被取消回 null
Future<String?> renderReversedClip(
  String srcPath,
  double trimStart,
  double trimEnd,
  int targetW,
  int targetH, {
  void Function(double progress)? onProgress,
}) async {
  final probe = await _probe(srcPath);
  final temps = <String>[];
  final out = await _prerenderReverse(
    srcPath,
    trimStart,
    trimEnd,
    targetW,
    targetH,
    probe.hasAudio,
    probe.hdr ? (probe.trc.isEmpty ? 'unknown' : probe.trc) : '',
    temps,
    onProgress: onProgress,
  );
  if (out == null) {
    for (final p in temps) {
      try {
        File(p).deleteSync();
      } catch (_) {}
    }
    return null;
  }
  // 中間分段檔可以清了，只留最後接合出來的那個
  for (final p in temps) {
    if (p == out) continue;
    try {
      File(p).deleteSync();
    } catch (_) {}
  }
  return out;
}

/// 把倍速拆成 FFmpeg atempo 允許的範圍（單段 0.5~2.0）
String _atempoChain(double speed) {
  // 0、負數或 NaN 會讓下面的 while 迴圈轉不出來（UI 掛死）——
  // 正常操作到不了這裡，但壞掉的草稿 JSON 可能帶進來
  if (!speed.isFinite || speed <= 0) return 'atempo=1.0';
  final parts = <double>[];
  var s = speed.clamp(0.025, 256.0);
  while (s < 0.5) {
    parts.add(0.5);
    s /= 0.5;
  }
  while (s > 2.0) {
    parts.add(2.0);
    s /= 2.0;
  }
  parts.add(s);
  return parts.map((p) => 'atempo=${p.toStringAsFixed(4)}').join(',');
}

class _SourceProbe {
  final bool hasAudio;
  final double fps;

  /// HDR 素材（HLG／HDR10／杜比視界）：處理畫面時要先轉 SDR bt709，
  /// 不轉的話顏色整片灰白退色
  final bool hdr;
  final String codec; // 視訊編碼（hevc/h264/…，讀不到＝空字串）
  final String trc; // 轉換曲線（arib-std-b67=HLG、smpte2084=PQ）

  /// 旋轉校正後的顯示長寬（0＝讀不到）。手機直式影片多半是
  /// 「橫著存＋旋轉 90 度」的旗標，容器裡的 width/height 是橫的
  final int dispW;
  final int dispH;

  /// 影片的旋轉角度（0/90/180/270）
  final int rotation;

  const _SourceProbe(
    this.hasAudio,
    this.fps,
    this.hdr, [
    this.codec = '',
    this.trc = '',
    this.dispW = 0,
    this.dispH = 0,
    this.rotation = 0,
  ]);
}

/// HDR → SDR（bt709）色彩轉換。iPhone 預設就錄 HDR（HLG），
/// FFmpeg 不轉的話只是把 bt2020 的數值原封塞進 SDR 檔，
/// 匯出／縮圖整片灰白退色（播放正常是系統播放器自己會轉）。
/// min 版 FFmpeg 沒有 zscale/tonemap，colorspace 是原生濾鏡；
/// 它不認得 HLG 曲線，拿 bt2020-10 當近似（HLG 低亮度段就是這條），
/// 亮部稍微壓一點，但顏色是對的
/// HDR→SDR 的退路：只換原色與矩陣（bt2020→bt709），曲線動不了。
///
/// vf_colorspace 不支援 smpte2084（PQ）和 arib-std-b67（HLG）當輸入，
/// 給它 bt2020-10 只是騙它「曲線跟 bt709 一樣」——原色會轉對，但
/// HDR 的亮度曲線原封不動，畫面就是平的、灰的。這也是為什麼拖曳的
/// 快取幀和匯出都退色，而播放正常（播放走 AVPlayer，系統自己會轉）
const _kHdrFallback = 'colorspace=all=bt709:iall=bt2020:itrc=bt2020-10';

/// HDR→SDR：轉線性光再色調映射壓回 bt709。
///
/// 需要 zscale（libzimg）。為了它把 FFmpeg 從精簡版換成完整版，
/// APK 大了約 27MB——iPhone 近幾代預設就錄 HLG，大多數使用者的
/// 素材都走這條路。
///
/// 【教訓】曾試過對 HLG 用「參考白直接對應」（zscale 直轉、
/// npl=203），理論漂亮，實機顏色整個跑掉、比色調映射差得多。
/// 現在 HLG/PQ 都走這條 hable 鏈，已知偏差是「比系統稍亮」。
/// 要真的校到跟系統一致，需要拿實際素材對著螢幕截圖比——
/// 沒有樣本之前不要再盲調這裡
/// 組出 HDR→SDR 的濾鏡鏈。
///
/// [trc] 是素材的轉換曲線（arib-std-b67＝HLG、smpte2084＝PQ）。知道就
/// 明確寫進 zscale 的輸入參數——畫格的色彩標記經過某些濾鏡會掉失，
/// 一掉失 zscale 就會報 "no path between colorspaces" 整條鏈失敗。
///
/// [scaleH] 有給就把縮小摺進第一步。色調映射是 32 位元浮點運算，
/// 成本跟像素數成正比，先縮小再轉可以省十幾倍。縮小必須由 zscale
/// 自己做，不能用 scale——swscale 會把色彩標記換掉
String _hdrChain({String trc = '', int? scaleH}) {
  final tin = (trc == 'arib-std-b67' || trc == 'smpte2084')
      ? 'tin=$trc:min=bt2020nc:pin=bt2020:'
      : '';
  final sz = scaleH == null ? '' : 'w=-1:h=$scaleH:';
  return 'zscale=$tin${sz}t=linear:npl=100,format=gbrpf32le,'
      'tonemap=tonemap=hable:desat=0,'
      'zscale=p=bt709:t=bt709:m=bt709:r=tv,format=yuv420p';
}

/// 這次執行實際送出去的所有 HDR 鏈（失敗保底要把它們剝掉）
final _usedHdrChains = <String>{};

bool? _hasZscale;

/// 問一次這個 FFmpeg 有沒有 zscale／tonemap。
/// 用問的而不是寫死：換 FFmpeg 套件版本時這裡會自動跟上，
/// 不會出現「套件換了但程式還在走退路」這種查半天的狀況
Future<bool> _zscaleAvailable() async {
  if (_hasZscale != null) return _hasZscale!;
  try {
    // 只測「zscale 這個濾鏡在不在」，用最單純的縮放。
    //
    // 之前是拿合成的純色圖去跑「完整的轉換鏈」，結果那張圖沒有色彩
    // 標記，zscale=t=linear 不知道來源曲線，報 no path between
    // colorspaces——於是明明有 zscale 卻被判定成沒有，默默走了會退色
    // 的退路。測試題目要能單獨成立，不能連帶考到別的條件
    final ses = await FFmpegKit.execute(
      '-v error -f lavfi -i color=c=red:s=64x64:d=0.1 '
      '-vf "zscale=w=32:h=32" -frames:v 1 -f null -',
    );
    _hasZscale = ReturnCode.isSuccess(await ses.getReturnCode());
  } catch (_) {
    _hasZscale = false;
  }
  return _hasZscale!;
}

/// 這次實際會用哪條 HDR 轉換鏈（診斷用）
Future<String> hdrChainName() async => await _zscaleAvailable()
    ? 'zscale+tonemap（正確）'
    : 'colorspace（退路，會退色）';

/// 依素材挑 HDR→SDR 的濾鏡鏈。HLG 和 PQ 目前走同一條 hable 鏈，
/// 差別只在告訴 zscale 輸入是哪一種曲線
Future<String> _hdrChainFor(String trc, {int? scaleH}) async {
  if (!await _zscaleAvailable()) return _kHdrFallback;
  final c = _hdrChain(trc: trc, scaleH: scaleH);
  _usedHdrChains.add(c);
  return c;
}

/// 從串流資訊裡挖出旋轉角度。放的地方有兩種：新的檔案在
/// side_data_list 的 rotation（負角度），舊的在 tags.rotate。
/// 兩邊都翻一次，正規化成 0/90/180/270
int _rotationOf(StreamInformation s) {
  double? raw;
  final props = s.getAllProperties();
  if (props != null) {
    final sd = props['side_data_list'];
    if (sd is List) {
      for (final e in sd) {
        if (e is Map && e['rotation'] != null) {
          raw = double.tryParse('${e['rotation']}');
          break;
        }
      }
    }
    if (raw == null) {
      final tags = props['tags'];
      if (tags is Map && tags['rotate'] != null) {
        raw = double.tryParse('${tags['rotate']}');
      }
    }
  }
  if (raw == null) return 0;
  // side_data 的角度是「要轉回來的量」，習慣上取正值看
  var deg = (-raw).round() % 360;
  if (deg < 0) deg += 360;
  return const {0, 90, 180, 270}.contains(deg) ? deg : 0;
}

/// 同一個檔案的 probe 快取（檔案內容不會變，縮圖會反覆問同一支）
final Map<String, _SourceProbe> _probeCache = {};

Future<_SourceProbe> _probe(String path) async {
  final hit = _probeCache[path];
  if (hit != null) return hit;
  try {
    final session = await FFprobeKit.getMediaInformation(path);
    final info = session.getMediaInformation();
    final streams = info?.getStreams() ?? [];
    final hasAudio = streams.any((s) => s.getType() == 'audio');
    double fps = 0;
    var hdr = false;
    var codec = '';
    var trcOut = '';
    var vw = 0, vh = 0, rot = 0;
    for (final s in streams) {
      if (s.getType() == 'video') {
        codec = (s.getCodec() ?? '').toLowerCase();
        vw = s.getWidth() ?? 0;
        vh = s.getHeight() ?? 0;
        rot = _rotationOf(s);
        final r = s.getAverageFrameRate() ?? '';
        final parts = r.split('/');
        if (parts.length == 2) {
          final num = double.tryParse(parts[0]) ?? 0;
          final den = double.tryParse(parts[1]) ?? 1;
          if (den > 0) fps = num / den;
        } else {
          fps = double.tryParse(r) ?? 0;
        }
        final trc = '${s.getProperty('color_transfer') ?? ''}';
        final prim = '${s.getProperty('color_primaries') ?? ''}';
        hdr = trc == 'smpte2084' ||
            trc == 'arib-std-b67' ||
            prim.startsWith('bt2020');
        trcOut = trc;
        break;
      }
    }
    // 90/270 度＝長寬對調才是使用者看到的方向
    final swap = rot == 90 || rot == 270;
    final r = _SourceProbe(
      hasAudio,
      fps,
      hdr,
      codec,
      trcOut,
      swap ? vh : vw,
      swap ? vw : vh,
      rot,
    );
    _probeCache[path] = r;
    return r;
  } catch (_) {
    return _SourceProbe(true, 0, false);
  }
}

String _f(double v) => v.toStringAsFixed(3);

/// setpts 的除數要更準：0.25×0.25 這種組合用 3 位小數
/// （0.063 vs 0.0625）會累積出可感知的影音不同步
String _f6(double v) => v.toStringAsFixed(6);

/// 圖層的顯示區間（overlay 的 enable）。半開區間 [start, end)。
///
/// between() 兩端都含，交界那一格前後兩段會同時亮著，誰蓋住誰要看濾鏡鏈
/// 的先後——同軌的排序是「片段清單的順序」，上一段排在後面時，交界那一格
/// 蓋上去的是上一段的最後一幀，看起來就是倒退一格的閃爍。
/// 半開也跟 TimelineClip.covers 同一套判定，預覽本來就是這樣畫的
String _window(double start, double end) =>
    'gte(t\\,${_f(start)})*lt(t\\,${_f(end)})';

/// 片段調色 → FFmpeg 濾鏡（沒調過回空字串）
String _eq(TimelineClip c) => c.color.ffmpeg;

/// 組出通用圖層的 FFmpeg 指令：
/// 黑色畫布 → 由下層往上把每個影片片段 overlay 上去（各自只在自己的時間區間顯示）
/// → 疊浮水印；所有帶聲音的片段 delay 對位後 amix 混成一軌。
/// 縮放用 lanczos；編碼交給平台的硬體編碼器（見 _hwEncoder／_kbpsFor），
/// 失敗才退軟體。
Future<String> _buildCommand(
  ExportSpec spec,
  String? wmPath,
  Map<int, String> overlayFiles,
  String outPath, {
  double winStart = 0,
  double? winEnd,
  bool videoOnly = false,
}) async {
  final probes = <int, _SourceProbe>{};
  for (var i = 0; i < spec.sources.length; i++) {
    final s = spec.sources[i];
    probes[i] = (s.kind == ClipKind.video || s.kind == ClipKind.audio)
        ? await _probe(s.path)
        : const _SourceProbe(false, 0, false);
  }

  // 每個 HDR 來源依自己的曲線（HLG/PQ）挑轉換鏈。
  // 鏈本身在下面依各片段的輸出高度組出來——色調映射要在縮小之後做
  final hdrTrc = <int, String>{};
  for (var i = 0; i < spec.sources.length; i++) {
    if (probes[i]!.hdr) hdrTrc[i] = probes[i]!.trc;
  }
  final zOk = hdrTrc.isEmpty ? false : await _zscaleAvailable();
  /// 某個來源在「輸出高度 h」下要用的 HDR 轉換鏈（含結尾逗號）；
  /// 不是 HDR 就回空字串
  String hdrTrcOf(int srcIndex, int h) {
    final trc = hdrTrc[srcIndex];
    if (trc == null) return '';
    if (!zOk) return '$_kHdrFallback,';
    final c = _hdrChain(trc: trc, scaleH: h);
    _usedHdrChains.add(c);
    return '$c,';
  }

  final sp = spec.speed;
  final outDur = spec.outputDuration;

  // 這一次要算的時間範圍（輸出秒）。分段渲染時一次只做一段，
  // 只有這一段真的看得到的圖層會被組進濾鏡鏈——一段 4K HDR 的
  // 色調映射就要 1GB 以上，全部塞同一條鏈是匯出閃退的主因
  final w0 = winStart;
  final w1 = math.min(winEnd ?? outDur, outDur);
  final segDur = math.max(0.01, w1 - w0);

  /// 段內時間 t 換算成整支影片的絕對輸出時間（動畫運算式用）
  final tAbs = w0 <= 0.0005 ? 't' : '(t+${_f(w0)})';

  /// 這個圖層在這一段裡看得見的範圍（輸出秒，絕對時間）；
  /// 完全不在這一段就回 null
  (double, double)? visible(double start, double end) {
    final a = math.max(start, w0);
    final b = math.min(end, w1);
    return (b - a) <= 0.001 ? null : (a, b);
  }

  /// 這個片段在這一段裡有沒有戲份。輸入檔、split、圖層都照這個算——
  /// 照全部片段算的話，一段只用到一支素材卻開了三個輸入，
  /// 濾鏡圖裡還會留下接不到輸出的分支（ffmpeg 直接報錯）
  bool inWindow(TimelineClip c) => visible(c.offset / sp, c.end / sp) != null;

  /// 這一段要處理的片段（聲音那一趟不分段，見 _buildAudioMux）
  final segClips = [
    for (final c in spec.clips)
      if (inWindow(c)) c,
  ];

  // 畫布幀率取素材中最高者
  var fps = 0.0;
  for (var i = 0; i < spec.sources.length; i++) {
    if (spec.sources[i].isVideo && probes[i]!.fps > fps) fps = probes[i]!.fps;
  }
  fps = outputFps(fps, spec.outW, spec.outH);

  // 一個輸入串流只能被消費一次，被多個片段引用時要先 split
  final vNeed = <int, int>{};
  final aNeed = <int, int>{};
  bool clipHasAudio(int sourceIndex) {
    final s = spec.sources[sourceIndex];
    return switch (s.kind) {
      ClipKind.video => probes[sourceIndex]!.hasAudio,
      // 音訊來源也看 probe：「從影片提取聲音」可能選到沒音軌的影片，
      // 寫死 true 會引用不存在的 [i:a] 讓整個匯出失敗
      ClipKind.audio => probes[sourceIndex]!.hasAudio,
      _ => false,
    };
  }

  for (final c in segClips) {
    final k = spec.sources[c.sourceIndex].kind;
    // 文字有自己的輸入，不佔來源的 v 串流
    if (k == ClipKind.video || k == ClipKind.image) {
      vNeed[c.sourceIndex] = (vNeed[c.sourceIndex] ?? 0) + 1;
    }
    if (!videoOnly && clipHasAudio(c.sourceIndex)) {
      aNeed[c.sourceIndex] = (aNeed[c.sourceIndex] ?? 0) + 1;
    }
  }

  // 圖片素材用 -loop 輸入，長度取該素材所有片段的最大需求
  final stillNeed = <int, double>{};
  for (final c in segClips) {
    if (spec.sources[c.sourceIndex].kind == ClipKind.image) {
      final need = c.length / sp + 0.5;
      if (need > (stillNeed[c.sourceIndex] ?? 0)) {
        stillNeed[c.sourceIndex] = need;
      }
    }
  }
  // 輸入編號：文字／浮水印來源不佔輸入（每個片段各自一張烘好的 PNG），
  // 所以要建立「來源 → 輸入編號」對照表
  bool isPngClip(ClipKind k) => k == ClipKind.text || k == ClipKind.wm;
  // 沒有任何片段引用的來源不能開輸入：草稿裡檔案已被清掉的素材、
  // 還原倒轉後留下的暫存檔都在這裡，開下去 ffmpeg 直接開檔失敗
  final usedSources = <int>{for (final c in segClips) c.sourceIndex};
  final srcIn = <int, int>{};
  var nextInput = 0;
  for (var i = 0; i < spec.sources.length; i++) {
    final k = spec.sources[i].kind;
    // 馬賽克沒有檔案也不佔輸入（它是對畫面本身做的效果）
    if (!isPngClip(k) && k != ClipKind.mosaic && usedSources.contains(i)) {
      srcIn[i] = nextInput++;
    }
  }
  final textClipInput = <int, int>{}; // clip id → input index
  for (final c in segClips) {
    if (isPngClip(spec.sources[c.sourceIndex].kind)) {
      textClipInput[c.id] = nextInput++;
    }
  }
  final wmInputIdx = nextInput;

  final fc = StringBuffer();
  final vPool = <int, List<String>>{};
  final aPool = <int, List<String>>{};

  vNeed.forEach((idx, n) {
    final ii = srcIn[idx]!;
    final labels = [for (var k = 0; k < n; k++) 'sv${idx}x$k'];
    fc.write(
      n == 1
          ? '[$ii:v]null[${labels[0]}];'
          : '[$ii:v]split=$n${labels.map((l) => '[$l]').join()};',
    );
    vPool[idx] = labels;
  });
  aNeed.forEach((idx, n) {
    final ii = srcIn[idx]!;
    final labels = [for (var k = 0; k < n; k++) 'sa${idx}x$k'];
    fc.write(
      n == 1
          ? '[$ii:a]anull[${labels[0]}];'
          : '[$ii:a]asplit=$n${labels.map((l) => '[$l]').join()};',
    );
    aPool[idx] = labels;
  });

  // ===== 畫面：黑畫布 + 由下而上疊圖層 =====
  fc.write(
    'color=c=black:s=${spec.outW}x${spec.outH}:'
    'r=${fps.toStringAsFixed(3)}:d=${_f(segDur)}[base];',
  );

  // 疊放順序：track 小的是下層先疊；同一層時，清單裡較後面的疊在上面
  final clipOrder = <int, int>{};
  for (var i = 0; i < spec.clips.length; i++) {
    clipOrder[spec.clips[i].id] = i;
  }
  int cmpLayer(TimelineClip a, TimelineClip b) {
    final t = a.track.compareTo(b.track);
    return t != 0 ? t : (clipOrder[a.id] ?? 0).compareTo(clipOrder[b.id] ?? 0);
  }

  // 影片與圖片／文字／浮水印排在同一條 z 序裡，完全照軌道來（跟預覽一致）。
  // 以前是分兩批、圖片文字永遠疊在影片上面，時間軸上把圖片搬到影片下面
  // 也沒有用。馬賽克不在這裡：它是對合成後的畫面做的效果，最後才套
  final layerClips =
      segClips
          .where(
            (c) =>
                spec.sources[c.sourceIndex].isVideo ||
                spec.sources[c.sourceIndex].isOverlay,
          )
          .toList()
        ..sort(cmpLayer);

  // 依片段的位置/縮放算出圖層的框（像素座標）
  (int, int, int, int) layerBox(TimelineClip c, double srcAspect) {
    final canvasAspect = spec.outW / spec.outH;
    double fitW, fitH;
    if (srcAspect >= canvasAspect) {
      fitW = spec.outW.toDouble();
      fitH = fitW / srcAspect;
    } else {
      fitH = spec.outH.toDouble();
      fitW = fitH * srcAspect;
    }
    var w2 = (fitW * c.scale).round();
    var h2 = (fitH * c.scale).round();
    w2 = math.max(2, w2 - w2 % 2);
    h2 = math.max(2, h2 - h2 % 2);
    final x = (c.px * spec.outW - w2 / 2).round();
    final y = (c.py * spec.outH - h2 / 2).round();
    return (w2, h2, x, y);
  }

  /// 畫面淡入淡出。時間是「這個片段自己的時間」（0＝片段開頭），
  /// 不是輸出時間——分段渲染時一個片段可能被切成好幾段，用絕對時間的話
  /// 跨段的淡化需要負的起點，fade 濾鏡不收
  ///（Value -0.5 for parameter 'st' out of range）。
  /// 呼叫端負責把圖層的時間軸先移成「片段自己的時間」，見 writeVideoLayer
  String vFades(TimelineClip c) {
    final len = (c.end - c.offset) / sp;
    final fi = c.fadeIn / sp;
    final fo = c.fadeOut / sp;
    var out = '';
    if (fi > 0.01 || fo > 0.01) out += ',format=yuva420p';
    if (fi > 0.01) out += ',fade=t=in:st=0:d=${_f(fi)}:alpha=1';
    if (fo > 0.01) {
      out += ',fade=t=out:st=${_f(math.max(0, len - fo))}:d=${_f(fo)}:alpha=1';
    }
    return out;
  }

  var cur = 'base';
  var layerN = 0;

  void writeVideoLayer(TimelineClip c, int k) {
    final src = spec.sources[c.sourceIndex];
    final label = vPool[c.sourceIndex]!.removeLast();
    final start = c.offset / sp;
    final end = c.end / sp;
    // 這一段看得到的範圍，換算回素材自己的時間（含變速）
    final (a, b) = visible(start, end)!;
    final rate = sp * c.speed.clamp(0.1, 16.0);
    final srcA = c.trimStart + (a - start) * rate;
    final srcB = c.trimStart + (b - start) * rate;
    final (w2, h2, x, y) = layerBox(c, src.aspect);
    fc.write(
      '[$label]'
      'trim=start=${_f(srcA)}:end=${_f(srcB)},'
      // 先縮到輸出尺寸再倒轉：reverse 會把整段畫面存進記憶體，
      // 用原始解析度存會直接把記憶體吃爆。
      //
      // HDR 轉 SDR：縮小摺進轉換鏈的第一步，色調映射就在輸出尺寸上
      // 做。原本是先在原始解析度轉完再縮——色調映射是 32 位元浮點，
      // 一格 4K 的 gbrpf32le 就要上百 MB，手機直接被記憶體壓死（匯出
      // 閃退）。縮小必須由 zscale 自己做，不能用 scale：swscale 會把
      // 畫格的色彩標記換掉，換掉之後就不知道來源是 HLG/PQ 了
      '${hdrTrcOf(c.sourceIndex, h2)}'
      'scale=$w2:$h2:flags=lanczos,'
      '${c.mirror ? 'hflip,' : ''}'
      '${c.reverse ? 'reverse,' : ''}'
      // 全域速度 × 每片段速度一起壓進 PTS
      //（速度 clamp 到跟 TimelineClip.length 同一個範圍，
      // 兩邊算出來的時間才對得上）。倒轉會重排時間戳，
      // 所以 setpts 一定要放在 reverse 後面
      // 先移到「片段自己的時間」（0＝片段開頭）讓淡化算得對，
      // 淡化做完再移到「這一段的時間」。分段渲染時同一個片段可能
      // 被切成好幾段，兩段式位移是唯一不用負數起點的寫法
      'setpts=(PTS-STARTPTS)/${_f6(rate)}'
      '+${_f(a - start)}/TB'
      '${_eq(c)}'
      '${vFades(c)}'
      ',setpts=PTS-STARTPTS+${_f(a - w0)}/TB'
      '[lv$k];',
    );
    fc.write(
      '[$cur][lv$k]overlay=$x:$y:'
      'enable=${_window(a - w0, b - w0)}:'
      // 素材串流比片段短時要凍住最後一幀，不能讓底下的黑畫布露出來。
      // 手機拍的檔案很常「容器長度 > 視訊串流長度」（音軌比較長、
      // 或 VFR 的最後一幀提早結束），而片段長度是照容器長度算的——
      // 用 pass 的話那幾格就直接是黑的，交界處閃一下黑就是這樣來的
      'eof_action=repeat[ov$k];',
    );
  }

  void writeStillLayer(TimelineClip c, int k) {
    final src = spec.sources[c.sourceIndex];
    final start = c.offset / sp;
    final end = c.end / sp;
    // 靜態素材的輸入是 -loop 1，時間從「片段開頭」起算；
    // 這一段只取得到的那一截（見 writeVideoLayer 的兩段式位移）
    final (a, b) = visible(start, end)!;
    final cut =
        'trim=start=${_f(a - start)}:end=${_f(b - start)},'
        'setpts=PTS-STARTPTS+${_f(a - start)}/TB';
    const shift = ',setpts=PTS-STARTPTS';
    final toSeg = '$shift+${_f(a - w0)}/TB';
    if (src.kind == ClipKind.image) {
      final label = vPool[c.sourceIndex]!.removeLast();
      final (w2, h2, x, y) = layerBox(c, src.aspect);
      fc.write(
        '[$label]'
        'scale=$w2:$h2:flags=lanczos'
        '${c.mirror ? ',hflip' : ''}'
        '${_eq(c)}'
        ',format=rgba,'
        '$cut'
        '${vFades(c)}'
        '$toSeg'
        '[lv$k];',
      );
      fc.write(
        '[$cur][lv$k]overlay=$x:$y:'
        'enable=${_window(a - w0, b - w0)}:'
        'eof_action=repeat[ov$k];',
      );
    } else {
      // 文字／浮水印：整版透明 PNG（位置/縮放已烘進圖），每片段一個輸入
      final inputIdx = textClipInput[c.id]!;
      fc.write(
        '[$inputIdx:v]'
        '$cut'
        '${vFades(c)}'
        '$toSeg'
        '[lv$k];',
      );
      // 浮水印素材的動畫跟全域浮水印同一套 overlay 時間運算式：
      // 閃爍＝enable 週期開關；飄移/跑馬燈＝x,y 隨 t 變化
      var enable = _window(a - w0, b - w0);
      var pos = '0:0';
      var evalFrame = '';
      final wmSt = src.kind == ClipKind.wm ? src.wmStyle : null;
      if (wmSt != null && wmSt.animation != WmAnimation.none) {
        evalFrame = 'eval=frame:';
        // 動畫週期是「時間軸秒」；輸出時間 t 要乘回全域速度，
        // 不然 2 倍速匯出時動畫會慢一半、跟預覽對不上。
        // 分段渲染時 t 是段內時間，要先加回這一段的起點，
        // 不然每一段的動畫都會從頭開始
        final ts = sp == 1.0 ? tAbs : '($tAbs*${_f(sp)})';
        switch (wmSt.animation) {
          case WmAnimation.none:
            break;
          case WmAnimation.blink:
            enable =
                '$enable*lt(mod($ts\\,${_f(wmSt.blinkCycle)})'
                '\\,${_f(wmSt.blinkOn)})';
          case WmAnimation.drift:
            final f = _f(1.3 * wmSt.animSpeed);
            final f2 = _f(0.9 * wmSt.animSpeed);
            final amp = _f(0.02 * wmSt.animRange);
            pos = "x='sin($ts*$f)*W*$amp':y='cos($ts*$f2)*H*$amp'";
          case WmAnimation.marquee:
            final cy = _f(wmSt.marqueeCycle);
            pos = "x='W-mod($ts\\,$cy)*2*W/$cy':y=0";
        }
      }
      fc.write(
        '[$cur][lv$k]overlay=$pos:$evalFrame'
        'enable=$enable:'
        'eof_action=repeat[ov$k];',
      );
    }
  }

  for (final c in layerClips) {
    final k = layerN++;
    if (spec.sources[c.sourceIndex].isVideo) {
      writeVideoLayer(c, k);
    } else {
      writeStillLayer(c, k);
    }
    cur = 'ov$k';
  }

  // ===== 馬賽克：把區域裁下來、縮小再放大（鄰近取樣）疊回去 =====
  // 全部是 LGPL 濾鏡（split/crop/scale/overlay）。放在浮水印之前，
  // 馬賽克不會把浮水印一起打碼
  final mosaicClips =
      segClips
          .where((c) => spec.sources[c.sourceIndex].kind == ClipKind.mosaic)
          .toList()
        ..sort(cmpLayer);
  for (final c in mosaicClips) {
    final k = layerN++;
    final start = c.offset / sp;
    final end = c.end / sp;
    final seen = visible(start, end);
    if (seen == null) continue; // 這一段裡看不到
    final (a, b) = seen;
    var (w2, h2, x, y) = layerBox(c, 1.0);
    // crop 超出畫布會直接報錯，夾回來
    x = x.clamp(0, spec.outW - 2);
    y = y.clamp(0, spec.outH - 2);
    w2 = math.min(w2, spec.outW - x);
    h2 = math.min(h2, spec.outH - y);
    w2 = math.max(2, w2 - w2 % 2);
    h2 = math.max(2, h2 - h2 % 2);
    final ms = spec.sources[c.sourceIndex].mosaicStyle ?? MosaicStyle();
    final enable = 'enable=${_window(a - w0, b - w0)}';
    if (ms.type == 2) {
      // 純色遮蓋：直接畫實心色塊（顏色取 RGB，0xRRGGBB）
      final rgb = (ms.color & 0xFFFFFF).toRadixString(16).padLeft(6, '0');
      fc.write(
        '[$cur]drawbox=x=$x:y=$y:w=$w2:h=$h2:color=0x$rgb:t=fill:'
        '$enable[mz$k];',
      );
    } else if (ms.type == 1) {
      // 模糊：縮小再「平滑」放大（跟像素化同管線，只差放大用 bilinear）。
      // 不用 boxblur——裝置端的 min 版 FFmpeg 解析它會失敗
      //（"No option name near"），本機完整版卻正常，靠不住；
      // scale 在所有匯出路徑都驗證過。濃度越高縮越小＝越糊。
      // 邊緣柔化：同心 3 圈由外到內模糊漸強（外圈輕、內圈重），
      // 邊界不再是一條硬線——一樣只用 scale/crop/overlay。
      // 最後一圈輸出固定叫 mz$k，接回下面共用的 cur 指派
      final downFull = 2 + (ms.strength * 12).round();
      final margin = (ms.feather * 0.35 * math.min(w2, h2)).round();
      // 6 圈由外到內漸強：外圈幾乎不糊、內圈全糊，
      // 肉眼看不出圈與圈的階梯，邊界就沒有明顯分界線
      // 先畫「最外圈最大範圍、幾乎不糊」，一路往內越縮越糊
      final rings = margin >= 8
          ? [
              for (var i = 1; i <= 6; i++)
                (
                  (margin * (i - 1) / 5).round(),
                  math.max(2, (downFull * i / 6).round()),
                ),
            ]
          : [(0, downFull)];
      for (var i = 0; i < rings.length; i++) {
        final (inset, down) = rings[i];
        var rw = w2 - inset * 2;
        var rh = h2 - inset * 2;
        rw = math.max(2, rw - rw % 2);
        rh = math.max(2, rh - rh % 2);
        final rx = x + inset;
        final ry = y + inset;
        final dw = math.max(2, (rw / down).round());
        final dh = math.max(2, (rh / down).round());
        final out = i == rings.length - 1 ? 'mz$k' : 'mz${k}f$i';
        fc.write(
          '[$cur]split=2[mzA${k}f$i][mzB${k}f$i];'
          '[mzB${k}f$i]crop=$rw:$rh:$rx:$ry,scale=$dw:$dh,'
          'scale=$rw:$rh:flags=bilinear[mzP${k}f$i];'
          '[mzA${k}f$i][mzP${k}f$i]overlay=$rx:$ry:$enable:'
          'eof_action=pass[$out];',
        );
        cur = out;
      }
    } else {
      // 像素化：縮小再鄰近取樣放大。濃度越高格子越大
      //（橫向格數約 26 → 6）
      final cells = (26 - 20 * ms.strength).round().clamp(4, 40);
      final margin = (ms.feather * 0.35 * math.min(w2, h2)).round();
      // 柔邊：跟模糊同一套同心圈，只是由外到內格子越來越大——
      // 外圈幾乎是原畫面，邊界就沒有一條硬線
      final rings = margin >= 8
          ? [
              for (var i = 1; i <= 6; i++)
                (
                  (margin * (i - 1) / 5).round(),
                  // i=1 是最外圈：格數最多＝格子最細
                  (cells * (7 - i)).clamp(4, 240),
                ),
            ]
          : [(0, cells)];
      for (var i = 0; i < rings.length; i++) {
        final (inset, cn) = rings[i];
        var rw = w2 - inset * 2;
        var rh = h2 - inset * 2;
        rw = math.max(2, rw - rw % 2);
        rh = math.max(2, rh - rh % 2);
        final rx = x + inset;
        final ry = y + inset;
        final dw = math.max(2, math.min(cn, rw ~/ 2));
        final dh = math.max(2, (dw * rh / rw).round());
        final out = i == rings.length - 1 ? 'mz$k' : 'mz${k}p$i';
        fc.write(
          '[$cur]split=2[mzA${k}p$i][mzB${k}p$i];'
          '[mzB${k}p$i]crop=$rw:$rh:$rx:$ry,scale=$dw:$dh,'
          'scale=$rw:$rh:flags=neighbor[mzP${k}p$i];'
          '[mzA${k}p$i][mzP${k}p$i]overlay=$rx:$ry:$enable:'
          'eof_action=pass[$out];',
        );
        cur = out;
      }
    }
    cur = 'mz$k';
  }

  // 浮水印疊最上面（只在它的時間範圍內顯示）
  // 動畫用 overlay 的時間運算式做，不必逐格產圖：
  // 閃爍＝enable 週期開關；飄移/跑馬燈＝x,y 隨 t 變化（整版 PNG 一起位移）
  final hasWm = wmPath != null;
  if (hasWm) {
    final ws = (spec.wmStart / sp).clamp(0.0, outDur);
    final we = (spec.wmEnd / sp).clamp(0.0, outDur);
    final seen = visible(ws, we);
    // 這一段完全沒有浮水印時給一個永遠不成立的條件
    var enable = seen == null ? '0' : _window(seen.$1 - w0, seen.$2 - w0);
    var pos = 'x=0:y=0';
    // 動畫週期是「時間軸秒」；輸出時間 t 要乘回全域速度。
    // 分段渲染時 t 是段內時間，先加回這一段的起點
    final ts = sp == 1.0 ? tAbs : '($tAbs*${_f(sp)})';
    switch (spec.wmAnimation) {
      case WmAnimation.none:
        break;
      case WmAnimation.blink:
        enable =
            '$enable*lt(mod($ts\\,${_f(spec.wmCycle)})'
            '\\,${_f(spec.wmOn)})';
      case WmAnimation.drift:
        final f = _f(1.3 * spec.wmSpeed);
        final f2 = _f(0.9 * spec.wmSpeed);
        final amp = _f(0.02 * spec.wmRange);
        pos = "x='sin($ts*$f)*W*$amp':y='cos($ts*$f2)*H*$amp'";
      case WmAnimation.marquee:
        // 一輪由右向左掃過（整版 PNG 平移，超出畫面自然消失）
        final c = _f(spec.wmCycle);
        pos = "x='W-mod($ts\\,$c)*2*W/$c':y=0";
    }
    fc.write(
      '[$cur][$wmInputIdx:v]overlay=$pos:eval=frame:'
      'enable=$enable[vout];',
    );
    cur = 'vout';
  }

  // ===== 聲音：每段對位後混音（軌道沒有上下之分，全部疊加）=====
  //
  // 分段渲染時這裡整個跳過：聲音在畫面串好之後一次做完（見
  // _buildAudioMux）。一段一段配音的話，跨段的音樂會在每個接點
  // 留下 AAC 編碼縫隙，而且每段都要重新混一次
  final audioLabels = <String>[];
  for (var k = 0; k < segClips.length && !videoOnly; k++) {
    final c = segClips[k];
    if (!clipHasAudio(c.sourceIndex)) continue;
    final label = aPool[c.sourceIndex]!.removeLast();
    final delayMs = (c.offset / sp * 1000).round();
    // 音量淡入淡出（相對片段起點的輸出時間）
    final lenOut = c.length / sp;
    var fades = '';
    if (c.fadeIn > 0.01) {
      fades += ',afade=t=in:st=0:d=${_f(c.fadeIn / sp)}';
    }
    if (c.fadeOut > 0.01) {
      fades +=
          ',afade=t=out:st=${_f(math.max(0, lenOut - c.fadeOut / sp))}'
          ':d=${_f(c.fadeOut / sp)}';
    }
    fc.write(
      '[$label]'
      'atrim=start=${_f(c.trimStart)}:end=${_f(c.trimEnd)},'
      // 畫面倒轉時聲音也要倒過來，不然對不上嘴形／節奏
      '${c.reverse ? 'areverse,' : ''}'
      'asetpts=PTS-STARTPTS,'
      // 全域速度 × 每片段速度（clamp 跟畫面端同一個範圍）
      '${_atempoChain(sp * c.speed.clamp(0.1, 16.0))}'
      '$fades,'
      'volume=${c.volume.toStringAsFixed(2)},'
      'adelay=$delayMs:all=1,'
      'aresample=44100,aformat=channel_layouts=stereo[la$k];',
    );
    audioLabels.add('la$k');
  }

  String? aLabel;
  if (audioLabels.length == 1) {
    aLabel = audioLabels.first;
  } else if (audioLabels.length > 1) {
    fc.write(
      '${audioLabels.map((l) => '[$l]').join()}'
      'amix=inputs=${audioLabels.length}:duration=longest:normalize=0[aout];',
    );
    aLabel = 'aout';
  }

  // 去掉結尾多餘的分號
  var filter = fc.toString();
  if (filter.endsWith(';')) filter = filter.substring(0, filter.length - 1);

  final cmd = StringBuffer()..write('-y ');
  for (var i = 0; i < spec.sources.length; i++) {
    final s = spec.sources[i];
    // 跟上面 srcIn 的條件一致，不然輸入編號會整組錯位
    if (!usedSources.contains(i)) continue;
    switch (s.kind) {
      case ClipKind.video:
        cmd.write('${_hwDecode()}-i "${s.path}" ');
      case ClipKind.audio:
        cmd.write('-i "${s.path}" ');
      case ClipKind.image:
        cmd.write(
          '-loop 1 -framerate ${fps.toStringAsFixed(3)} '
          '-t ${_f(stillNeed[i] ?? 1)} -i "${s.path}" ',
        );
      case ClipKind.text || ClipKind.wm:
        break; // 每個片段一張 PNG，在下面接續
      case ClipKind.mosaic:
        break; // 對畫面本身做的效果，沒有輸入檔
    }
  }
  for (final c in segClips) {
    if (isPngClip(spec.sources[c.sourceIndex].kind)) {
      cmd.write(
        '-loop 1 -framerate ${fps.toStringAsFixed(3)} '
        '-t ${_f(c.length / sp + 0.5)} -i "${overlayFiles[c.id]}" ',
      );
    }
  }
  if (hasWm) cmd.write('-i "$wmPath" ');
  cmd
    ..write('-filter_complex "$filter" ')
    ..write('-map "[$cur]" ');
  if (aLabel != null) {
    cmd.write('-map "[$aLabel]" -c:a aac -b:a 256k ');
  } else {
    cmd.write('-an ');
  }
  cmd
    ..write('-t ${_f(segDur)} ')
    // 影格率寫死成畫布的：分段之後每一段都要「規格一模一樣」，
    // 串接才敢用 -c copy（不重編碼）
    ..write('-r ${fps.toStringAsFixed(3)} ')
    // LGPL 版沒有 x264：H.264 用手機的硬體編碼器（更快、更省電），
    // 畫質用位元率控制（硬體編碼器不吃 CRF）
    ..write(
      '-c:v ${_hwEncoder()} -b:v ${_kbpsFor(spec, fps)}k '
      '-maxrate ${(_kbpsFor(spec, fps) * 1.4).round()}k '
      '-bufsize ${_kbpsFor(spec, fps) * 2}k -pix_fmt nv12 ',
    )
    ..write('-movflags +faststart ')
    ..write('"$outPath"');
  return cmd.toString();
}

/// 平台對應的 H.264 硬體編碼器
String _hwEncoder() => (Platform.isIOS || Platform.isMacOS)
    ? 'h264_videotoolbox'
    : 'h264_mediacodec';

/// 影片輸入前面掛的硬體解碼旗標。
///
/// 編碼早就是硬體了，解碼一直是軟體——4K HEVC 用 CPU 解是 FFmpeg
/// 那條路第二大的成本（第一大是 HDR 色調映射）。iOS 的 videotoolbox
/// hwaccel 會自動把解好的畫格搬回記憶體給濾鏡鏈用，濾鏡不用改。
/// Android 的 mediacodec hwaccel 要接 surface，風險高，先不上。
/// 跑不動時 runFF 會把這面旗子剝掉重跑（見下面的保底）
const kHwDecodeFlag = '-hwaccel videotoolbox ';
String _hwDecode() =>
    (Platform.isIOS || Platform.isMacOS) ? kHwDecodeFlag : '';

/// 畫質檔位 → 位元率。表在 ExportQuality 上（video_processor.dart），
/// 兩邊共用一張——各自維護一份的話，加檔位時漏改一邊就會有兩檔
/// 輸出一模一樣的檔案
int _kbpsFor(ExportSpec spec, double fps) =>
    qualityFromCrf(spec.crf).kbpsFor(spec.outW, spec.outH, fps: fps);

/// 素材的視訊編碼、影格率與「旋轉校正後」的顯示長寬。
/// 讀不到就回空值（w/h 為 0）
Future<({String codec, double fps, int w, int h})> probeVideoInfo(
  String path,
) async {
  final p = await _probe(path);
  return (codec: p.codec, fps: p.fps, w: p.dispW, h: p.dispH);
}

/// 取消正在進行的匯出。兩條路都要通知：原生那條在跑的時候 FFmpeg 是閒著
/// 的，反之亦然，對沒在跑的那條喊取消不會有事
Future<void> cancelExport() async {
  await NativeExport.cancel();
  await FFmpegKit.cancel();
}

/// 把一段畫面「先做成倒轉好的暫存檔」。
///
/// FFmpeg 的 reverse 濾鏡要把整段解碼後全部存在記憶體裡才倒得出來，
/// 一段 26 秒的 1080p 就要好幾 GB。這裡改成分段處理：
/// 每 [chunkSec] 秒倒轉成一小段，再「由後往前」接起來——
/// 結果跟一次倒轉完全一樣，但記憶體只會用到一小段的量，多長都倒得動。
///
/// 回傳暫存檔路徑；失敗回 null。產生的檔案會加進 [temps] 等待清理
Future<String?> _prerenderReverse(
  String srcPath,
  double trimStart,
  double trimEnd,
  int outW,
  int outH,
  bool hasAudio,
  String hdrTrc, // 空字串＝SDR 素材
  List<String> temps, {
  void Function(double progress)? onProgress,
}) async {
  const chunkSec = 2.0;
  final total = trimEnd - trimStart;
  if (total <= 0.02) return null;
  final dir = await getTemporaryDirectory();
  final ts = DateTime.now().microsecondsSinceEpoch;
  final n = (total / chunkSec).ceil();

  final parts = <String>[];
  // 由最後一段往前做：接起來就是整段倒著播。
  // 分段只切「畫面」（-an）——聲音在下面整段一次倒，
  // 分段倒聲音會在每個接點留下 AAC 編碼縫隙，聽起來忽大忽小
  for (var i = n - 1; i >= 0; i--) {
    final s = trimStart + i * chunkSec;
    final e = math.min(trimEnd, s + chunkSec);
    if (e - s < 0.02) continue;
    final part = '${dir.path}${Platform.pathSeparator}rev_${ts}_$i.mp4';
    // 先縮到輸出尺寸再倒轉：用原始解析度倒轉一樣會吃爆記憶體。
    // 轉色排在縮放之前（理由同主匯出：swscale 縮完會把來源的
    // 色彩標記換掉，colorspace 再轉就沒作用了）
    final cmd =
        '-y -ss ${_f(s)} -to ${_f(e)} -i "$srcPath" '
        '-vf "${hdrTrc.isEmpty ? '' : '${await _hdrChainFor(hdrTrc)},'}'
        'scale=$outW:$outH:flags=bicubic,reverse" -an '
        '-c:v ${_hwEncoder()} -b:v 16000k -pix_fmt nv12 "$part"';
    var ses = await FFmpegKit.execute(cmd);
    var rc = await ses.getReturnCode();
    // 使用者按取消也是「非成功」，但不能當成硬體編碼器壞掉而重跑一次，
    // 不然按了取消還會把整段倒轉跑到底
    if (ReturnCode.isCancel(rc)) return null;
    if (!ReturnCode.isSuccess(rc)) {
      // 硬體編碼器不能用就退軟體編碼（跟主匯出同一套保底）
      ses = await FFmpegKit.execute(
        cmd
            .replaceFirst('-c:v ${_hwEncoder()}', '-c:v mpeg4 -q:v 3')
            .replaceFirst('-pix_fmt nv12', '-pix_fmt yuv420p'),
      );
      rc = await ses.getReturnCode();
      if (!ReturnCode.isSuccess(rc)) return null;
    }
    parts.add(part);
    temps.add(part);
    onProgress?.call(parts.length / n * 0.9);
  }
  if (parts.isEmpty) return null;

  // 畫面接起來（不重編碼）
  String video;
  if (parts.length == 1) {
    video = parts.first;
  } else {
    final listPath = '${dir.path}${Platform.pathSeparator}rev_${ts}_list.txt';
    await File(listPath).writeAsString(
      parts.map((p) => "file '${p.replaceAll("'", r"'\''")}'").join('\n'),
    );
    temps.add(listPath);
    video = '${dir.path}${Platform.pathSeparator}rev_${ts}_v.mp4';
    final ses = await FFmpegKit.execute(
      '-y -f concat -safe 0 -i "$listPath" -c copy "$video"',
    );
    if (!ReturnCode.isSuccess(await ses.getReturnCode())) return null;
    temps.add(video);
  }
  if (!hasAudio) return video;

  // 聲音整段一次倒（音訊很便宜：一分鐘也才十來 MB，不用分段），
  // 再跟畫面合起來
  final joined = '${dir.path}${Platform.pathSeparator}rev_${ts}_all.mp4';
  final mux = await FFmpegKit.execute(
    '-y -i "$video" '
    '-ss ${_f(trimStart)} -to ${_f(trimEnd)} -i "$srcPath" '
    '-filter_complex "[1:a]areverse[a]" '
    '-map 0:v -map "[a]" -c:v copy -c:a aac -b:a 256k '
    '-shortest "$joined"',
  );
  if (!ReturnCode.isSuccess(await mux.getReturnCode())) return video;
  temps.add(joined);
  onProgress?.call(1.0);
  return joined;
}

/// 分段的切點（輸出秒）。切在每個圖層的頭尾——這樣「一段裡有哪些圖層」
/// 是固定的，每一段只組它自己要的濾鏡，一次只有一條轉換鏈在跑。
///
/// 以前是整條時間軸塞同一個濾鏡圖：每一段素材都是一條完整的解碼＋
/// HDR 轉換＋縮放鏈，而且全部同時活著。實測 4K HLG 素材一段就要
/// 1.7GB、三段 2.7GB，iOS 直接把 App 收掉（匯出閃退）。
///
/// 太靠近的切點會合併：切得太碎的話每段都要付一次啟動成本，
/// 而且串接檔會變多。合併之後圖層可能只蓋住半段，所以 overlay 的
/// enable 還是照時間開關（見 _buildCommand 的 visible）
List<double> _segmentBounds(ExportSpec spec) {
  final sp = spec.speed;
  final outDur = spec.outputDuration;
  final marks = <double>{};
  for (final c in spec.clips) {
    if (spec.sources[c.sourceIndex].kind == ClipKind.audio) continue;
    marks
      ..add(c.offset / sp)
      ..add(c.end / sp);
  }
  if (spec.watermarkPng != null) {
    marks
      ..add(spec.wmStart / sp)
      ..add(spec.wmEnd / sp);
  }
  final inner = marks.where((v) => v > 0.35 && v < outDur - 0.35).toList()
    ..sort();
  final out = <double>[0];
  for (final v in inner) {
    if (v - out.last >= 0.35) out.add(v);
  }
  out.add(outDur);
  return out;
}

/// 把混好的聲音配到已經串好的畫面上。畫面直接 copy 不重編碼，
/// 這一趟只有音訊在跑，記憶體與時間都可以忽略。
///
/// 聲音不跟著畫面分段做：跨段的音樂會在每個接點留下 AAC 編碼縫隙
/// （倒轉那邊已經踩過一次，見 _prerenderReverse）。
/// 沒有任何聲音時回 null，呼叫端直接把畫面當成成品
Future<String?> _buildAudioMux(
  ExportSpec spec,
  String videoPath,
  String outPath,
) async {
  final sp = spec.speed;
  final hasAudio = <int, bool>{};
  for (var i = 0; i < spec.sources.length; i++) {
    final k = spec.sources[i].kind;
    hasAudio[i] = (k == ClipKind.video || k == ClipKind.audio)
        ? (await _probe(spec.sources[i].path)).hasAudio
        : false;
  }
  // 靜音的片段直接不進混音（音量 0 混進去只是白白多一路）
  final clips = [
    for (final c in spec.clips)
      if ((hasAudio[c.sourceIndex] ?? false) && c.volume > 0.001) c,
  ];
  if (clips.isEmpty) return null;

  // 輸入 0 是已經串好的畫面，聲音來源從 1 開始編號
  final srcIn = <int, int>{};
  final need = <int, int>{};
  var next = 1;
  for (final c in clips) {
    srcIn.putIfAbsent(c.sourceIndex, () => next++);
    need[c.sourceIndex] = (need[c.sourceIndex] ?? 0) + 1;
  }

  final fc = StringBuffer();
  final pool = <int, List<String>>{};
  need.forEach((idx, n) {
    final ii = srcIn[idx]!;
    final labels = [for (var k = 0; k < n; k++) 'sa${idx}x$k'];
    fc.write(
      n == 1
          ? '[$ii:a]anull[${labels[0]}];'
          : '[$ii:a]asplit=$n${labels.map((l) => '[$l]').join()};',
    );
    pool[idx] = labels;
  });

  final labels = <String>[];
  for (var k = 0; k < clips.length; k++) {
    final c = clips[k];
    final label = pool[c.sourceIndex]!.removeLast();
    final delayMs = (c.offset / sp * 1000).round();
    final lenOut = c.length / sp;
    var fades = '';
    if (c.fadeIn > 0.01) {
      fades += ',afade=t=in:st=0:d=${_f(c.fadeIn / sp)}';
    }
    if (c.fadeOut > 0.01) {
      fades +=
          ',afade=t=out:st=${_f(math.max(0, lenOut - c.fadeOut / sp))}'
          ':d=${_f(c.fadeOut / sp)}';
    }
    fc.write(
      '[$label]'
      'atrim=start=${_f(c.trimStart)}:end=${_f(c.trimEnd)},'
      '${c.reverse ? 'areverse,' : ''}'
      'asetpts=PTS-STARTPTS,'
      '${_atempoChain(sp * c.speed.clamp(0.1, 16.0))}'
      '$fades,'
      'volume=${c.volume.toStringAsFixed(2)},'
      'adelay=$delayMs:all=1,'
      'aresample=44100,aformat=channel_layouts=stereo[la$k];',
    );
    labels.add('la$k');
  }
  String aLabel;
  if (labels.length == 1) {
    aLabel = labels.first;
  } else {
    fc.write(
      '${labels.map((l) => '[$l]').join()}'
      'amix=inputs=${labels.length}:duration=longest:normalize=0[aout];',
    );
    aLabel = 'aout';
  }
  var filter = fc.toString();
  if (filter.endsWith(';')) filter = filter.substring(0, filter.length - 1);

  final cmd = StringBuffer()
    ..write('-y -i "$videoPath" ');
  final ordered = srcIn.entries.toList()
    ..sort((a, b) => a.value.compareTo(b.value));
  for (final e in ordered) {
    cmd.write('-i "${spec.sources[e.key].path}" ');
  }
  cmd
    ..write('-filter_complex "$filter" ')
    ..write('-map 0:v -c:v copy ')
    ..write('-map "[$aLabel]" -c:a aac -b:a 256k ')
    ..write('-t ${_f(spec.outputDuration)} ')
    ..write('-movflags +faststart ')
    ..write('"$outPath"');
  return cmd.toString();
}

// ===== 測試掛勾 =====
//
// 匯出指令是這支 App 最容易默默改壞的東西：改一個時間位移，交界處就
// 多一格黑、動畫就每段從頭跑一次，而這些只有實機匯出才看得到。
// 這幾個掛勾讓測試「不碰 FFmpeg 也組得出指令」，組出來的字串可以拿去
// 對真的 ffmpeg 跑（見 test/export_segment_test.dart）

/// 直接塞一筆 probe 結果進快取，測試才不用真的去讀檔
@visibleForTesting
void debugPrimeProbe(
  String path, {
  bool hasAudio = false,
  double fps = 30,
  bool hdr = false,
  String codec = 'h264',
  String trc = '',
  int dispW = 1920,
  int dispH = 1080,
  int rotation = 0,
}) {
  _probeCache[path] = _SourceProbe(
    hasAudio,
    fps,
    hdr,
    codec,
    trc,
    dispW,
    dispH,
    rotation,
  );
}

/// 這台機器有沒有 zscale（測試裡直接指定，不去問 FFmpeg）
@visibleForTesting
set debugZscaleAvailable(bool v) => _hasZscale = v;

@visibleForTesting
List<double> debugSegmentBounds(ExportSpec spec) => _segmentBounds(spec);

@visibleForTesting
Future<String> debugBuildCommand(
  ExportSpec spec,
  String outPath, {
  String? wmPath,
  Map<int, String> overlayFiles = const {},
  double winStart = 0,
  double? winEnd,
  bool videoOnly = false,
}) => _buildCommand(
  spec,
  wmPath,
  overlayFiles,
  outPath,
  winStart: winStart,
  winEnd: winEnd,
  videoOnly: videoOnly,
);

@visibleForTesting
Future<String?> debugBuildAudioMux(
  ExportSpec spec,
  String videoPath,
  String outPath,
) => _buildAudioMux(spec, videoPath, outPath);

/// 執行匯出並存到相簿。onProgress 回傳 0~1。
Future<({bool ok, String message, bool cancelled})> exportVideoToGallery(
  ExportSpec spec, {
  void Function(double progress)? onProgress,
}) async {
  final dir = await getTemporaryDirectory();
  final ts = DateTime.now().millisecondsSinceEpoch;
  final outPath = '${dir.path}${Platform.pathSeparator}watermarker_$ts.mp4';
  final revTemps = <String>[];

  // 倒轉的片段先各自做成「已經倒好」的暫存檔，主濾鏡就當成一般素材用。
  // 這樣長片段也倒得動（見 _prerenderReverse）
  if (spec.clips.any((c) => c.reverse)) {
    final sources = List<MediaSource>.of(spec.sources);
    final clips = <TimelineClip>[];
    for (final c in spec.clips) {
      final src = sources[c.sourceIndex];
      if (!c.reverse || src.kind != ClipKind.video) {
        clips.add(c);
        continue;
      }
      final probe = await _probe(src.path);
      final made = await _prerenderReverse(
        src.path,
        c.trimStart,
        c.trimEnd,
        spec.outW,
        spec.outH,
        probe.hasAudio,
        probe.hdr ? (probe.trc.isEmpty ? 'unknown' : probe.trc) : '',
        revTemps,
      );
      if (made == null) {
        for (final p in revTemps) {
          try {
            File(p).deleteSync();
          } catch (_) {}
        }
        return (ok: false, message: '倒轉處理失敗，請再試一次', cancelled: false);
      }
      sources.add(
        MediaSource(
          path: made,
          name: src.name,
          kind: ClipKind.video,
          duration: c.trimEnd - c.trimStart,
          w: spec.outW,
          h: spec.outH,
        ),
      );
      // 改指到倒好的暫存檔，並把 reverse 關掉（主濾鏡不用再倒一次）。
      // sourceIndex 是 final，只能走 JSON 重建
      clips.add(
        TimelineClip.fromJson({
          ...c.toJson(),
          'sourceIndex': sources.length - 1,
          'trimStart': 0.0,
          'trimEnd': c.trimEnd - c.trimStart,
          'reverse': false,
        }),
      );
    }
    spec = ExportSpec(
      sources: sources,
      clips: clips,
      timelineDuration: spec.timelineDuration,
      speed: spec.speed,
      watermarkPng: spec.watermarkPng,
      outW: spec.outW,
      outH: spec.outH,
      wmStart: spec.wmStart,
      wmEnd: spec.wmEnd,
      wmAnimation: spec.wmAnimation,
      wmSpeed: spec.wmSpeed,
      wmRange: spec.wmRange,
      overlayPngs: spec.overlayPngs,
      crf: spec.crf,
    );
  }

  /// 做好的檔案存進相簿。原生與 FFmpeg 兩條路共用
  Future<({bool ok, String message, bool cancelled})> saveToGallery() async {
    if (!await Gal.hasAccess(toAlbum: true)) {
      final granted = await Gal.requestAccess(toAlbum: true);
      if (!granted) {
        return (
          ok: false,
          message: '影片做好了，但沒有相簿存取權限。\n請到系統設定開啟權限後再匯出一次',
          cancelled: false,
        );
      }
    }
    try {
      await Gal.putVideo(outPath, album: '浮水印');
    } catch (e) {
      return (ok: false, message: '存到相簿失敗：$e', cancelled: false);
    }
    return (ok: true, message: '已存到「浮水印」相簿', cancelled: false);
  }

  /// GIF：把做好的影片轉一趟 GIF 再存相簿。
  ///
  /// 影格率與長邊上限吃 spec（GIF 製作頁可調），
  /// palettegen/paletteuse 兩段式調色盤——
  /// GIF 只有 256 色，不先算調色盤的話漸層會整片色帶。
  /// 這一趟接在「影片已經做好」之後，原生與 FFmpeg 兩條路共用
  Future<({bool ok, String message, bool cancelled})> saveAsGif() async {
    final gifPath = '${dir.path}${Platform.pathSeparator}out_$ts.gif';
    final side = spec.gifMaxSide;
    final session = await FFmpegKit.execute(
      '-y -i "$outPath" -filter_complex '
      '"[0:v]fps=${spec.gifFps},'
      'scale=w=$side:h=$side:force_original_aspect_ratio=decrease'
      ':flags=lanczos,split[a][b];[a]palettegen=stats_mode=diff[p];'
      '[b][p]paletteuse=dither=bayer:bayer_scale=4:diff_mode=rectangle[g]" '
      '-map "[g]" -an "$gifPath"',
    );
    final ok = ReturnCode.isSuccess(await session.getReturnCode());
    if (!ok) {
      return (ok: false, message: 'GIF 轉檔失敗', cancelled: false);
    }
    if (!await Gal.hasAccess(toAlbum: true)) {
      final granted = await Gal.requestAccess(toAlbum: true);
      if (!granted) {
        return (
          ok: false,
          message: 'GIF 做好了，但沒有相簿存取權限。\n請到系統設定開啟權限後再匯出一次',
          cancelled: false,
        );
      }
    }
    try {
      // GIF 對相簿來說是「圖片」，走圖片那條存
      await Gal.putImage(gifPath, album: '浮水印');
    } catch (e) {
      return (ok: false, message: '存到相簿失敗：$e', cancelled: false);
    } finally {
      try {
        File(gifPath).deleteSync();
      } catch (_) {}
    }
    return (ok: true, message: '已把 GIF 存到「浮水印」相簿', cancelled: false);
  }

  void delRevTemps() {
    for (final p in revTemps) {
      try {
        File(p).deleteSync();
      } catch (_) {}
    }
  }

  // 先試系統自己的管線：AVComposition ＋ Core Animation 圖層 ＋ 硬體
  // 編碼。記憶體由系統管（FFmpeg 的 HDR 色調映射一格 4K 要 100MB、
  // 峰值 1.7GB，那正是匯出閃退的來源）、跟預覽是同一份合成所以顏色
  // 天生一致、而且快好幾倍。
  //
  // 做不到的情況（馬賽克、照片素材、子母畫面、倒轉）原樣退回下面的
  // FFmpeg——這條路是加速，不是取代，任何一種舊功能都不能因此少掉
  if (Platform.isIOS && await NativeExport.available) {
    final why = NativeExport.whyNot(spec);
    if (why != null) {
      Diag.note('原生匯出用不了：$why（改用 FFmpeg）');
    } else {
      Diag.startSampling();
      final err = await NativeExport.run(spec, outPath, onProgress: onProgress);
      if (err == null) {
        Diag.note('原生匯出完成（峰值 ${Diag.peakMb} MB）');
        delRevTemps();
        final r = spec.gif ? await saveAsGif() : await saveToGallery();
        try {
          File(outPath).deleteSync();
        } catch (_) {}
        return r;
      }
      if (err == '已取消') {
        delRevTemps();
        try {
          File(outPath).deleteSync();
        } catch (_) {}
        return (ok: false, message: '已取消匯出', cancelled: true);
      }
      // 失敗就當作沒發生過，讓下面的 FFmpeg 照舊跑一次：使用者該拿到的
      // 是「慢一點但成功」，不是一則錯誤訊息
      Diag.note('原生匯出失敗，改用 FFmpeg：$err');
      try {
        File(outPath).deleteSync();
      } catch (_) {}
    }
  }

  String? wmPath;
  if (spec.watermarkPng != null) {
    wmPath = '${dir.path}${Platform.pathSeparator}wm_$ts.png';
    await File(wmPath).writeAsBytes(spec.watermarkPng!);
  }

  // 文字素材的整版 PNG 寫成暫存檔
  final overlayFiles = <int, String>{};
  for (final e in spec.overlayPngs.entries) {
    final p = '${dir.path}${Platform.pathSeparator}txt_${ts}_${e.key}.png';
    await File(p).writeAsBytes(e.value);
    overlayFiles[e.key] = p;
  }

  // 分段渲染用的暫存檔（每一段的畫面、串接清單、串好的無聲影片）
  final segTemps = <String>[];

  // 黑盒子：被系統收掉時不會有任何 log，只能靠開工前寫下的現場回推。
  // 正常做完會擦掉（見結尾的 clearMark）
  Diag.startSampling();
  final hdrCount = spec.sources.where((s) => s.kind == ClipKind.video).length;
  await Diag.mark(
    '匯出：準備',
    data: {
      '輸出': '${spec.outW}x${spec.outH}',
      '片段': spec.clips.length,
      '素材': hdrCount,
      '長度': spec.outputDuration.round(),
    },
  );

  /// 跑一次 FFmpeg，帶兩層保底：HDR 轉換鏈在這台機器跑不動就剝掉重跑
  /// （寧可顏色不對也不能匯不出來）、硬體編碼器不能用就退軟體編碼器
  Future<({bool ok, FFmpegSession session, dynamic rc})> runFF(
    String cmd,
  ) async {
    var session = await FFmpegKit.execute(cmd);
    var rc = await session.getReturnCode();
    var ok = ReturnCode.isSuccess(rc);
    // 硬體解碼跑不動（機型差異、編碼太怪）就剝掉重跑——軟解慢但一定行
    if (!ok && !ReturnCode.isCancel(rc) && cmd.contains(kHwDecodeFlag)) {
      Diag.note('硬體解碼不能用，退軟體解碼重跑');
      cmd = cmd.replaceAll(kHwDecodeFlag, '');
      session = await FFmpegKit.execute(cmd);
      rc = await session.getReturnCode();
      ok = ReturnCode.isSuccess(rc);
    }
    if (!ok && !ReturnCode.isCancel(rc)) {
      var stripped = cmd.replaceAll('$_kHdrFallback,', '');
      for (final c in _usedHdrChains) {
        stripped = stripped.replaceAll('$c,', '');
      }
      if (stripped != cmd) {
        Diag.note('HDR 轉換鏈跑不動，剝掉重跑（顏色會偏）');
        session = await FFmpegKit.execute(stripped);
        rc = await session.getReturnCode();
        ok = ReturnCode.isSuccess(rc);
      }
    }
    if (!ok && !ReturnCode.isCancel(rc) && cmd.contains(_hwEncoder())) {
      Diag.note('硬體編碼器不能用，退軟體編碼（很慢、檔案大）');
      final soft = cmd
          .replaceFirst('-c:v ${_hwEncoder()}', '-c:v mpeg4 -q:v 3')
          .replaceFirst('-pix_fmt nv12', '-pix_fmt yuv420p');
      session = await FFmpegKit.execute(soft);
      rc = await session.getReturnCode();
      ok = ReturnCode.isSuccess(rc);
    }
    return (ok: ok, session: session, rc: rc);
  }

  final total = math.max(0.01, spec.outputDuration);

  /// 進度：分段時每段各自從 0 開始回報自己的秒數，這裡累加成整支的。
  /// [from]~[to] 是這一趟在整條進度條上佔的區間——串接與配音留最後
  /// 8%，不留的話畫面會停在 100% 一陣子（看起來像當掉）
  void trackProgress(double doneSec, double spanSec, double from, double to) {
    FFmpegKitConfig.enableStatisticsCallback((stats) {
      if (onProgress == null) return;
      final done = spanSec <= 0
          ? 1.0
          : ((doneSec + stats.getTime() / 1000.0) / spanSec).clamp(0.0, 1.0);
      onProgress((from + (to - from) * done).clamp(0.0, 1.0));
    });
  }

  final bounds = _segmentBounds(spec);
  var ok = false;
  dynamic rc;
  FFmpegSession? session;

  Diag.note('匯出：切成 ${bounds.length - 1} 段');
  if (bounds.length <= 2) {
    // 只有一段：照舊一次做完（聲音也在同一趟），不必多開暫存檔
    trackProgress(0, total, 0, 1);
    await Diag.mark('匯出：單段', data: {'長度': total.round()});
    final r = await runFF(
      await _buildCommand(spec, wmPath, overlayFiles, outPath),
    );
    ok = r.ok;
    rc = r.rc;
    session = r.session;
  } else {
    // 分段：一段一段做成無聲的畫面檔，串起來，最後一次配音
    final segFiles = <String>[];
    var done = 0.0;
    for (var i = 0; i < bounds.length - 1; i++) {
      final segPath =
          '${dir.path}${Platform.pathSeparator}seg_${ts}_$i.mp4';
      final cmd = await _buildCommand(
        spec,
        wmPath,
        overlayFiles,
        segPath,
        winStart: bounds[i],
        winEnd: bounds[i + 1],
        videoOnly: true,
      );
      trackProgress(done, total, 0, 0.92);
      // 每一段開始前更新現場：死在第幾段、當下多少記憶體都留得下來
      await Diag.mark(
        '匯出：第 ${i + 1}/${bounds.length - 1} 段',
        data: {'秒數': (bounds[i + 1] - bounds[i]).toStringAsFixed(1)},
      );
      final r = await runFF(cmd);
      ok = r.ok;
      rc = r.rc;
      session = r.session;
      if (!ok) break;
      segFiles.add(segPath);
      segTemps.add(segPath);
      done += bounds[i + 1] - bounds[i];
    }

    if (ok) {
      // 串接：每一段的編碼參數完全一樣，可以直接 copy 不重編碼
      final listPath =
          '${dir.path}${Platform.pathSeparator}seg_$ts.txt';
      await File(listPath).writeAsString(
        segFiles
            .map((p) => "file '${p.replaceAll("'", r"'\''")}'")
            .join('\n'),
      );
      segTemps.add(listPath);
      final joined =
          '${dir.path}${Platform.pathSeparator}joined_$ts.mp4';
      trackProgress(0, total, 0.92, 0.94);
      await Diag.mark('匯出：串接');
      final r = await runFF(
        '-y -f concat -safe 0 -i "$listPath" -c copy "$joined"',
      );
      ok = r.ok;
      rc = r.rc;
      session = r.session;
      if (ok) segTemps.add(joined);

      if (ok) {
        final aCmd = await _buildAudioMux(spec, joined, outPath);
        if (aCmd == null) {
          // 整支都沒有聲音：串好的就是成品
          try {
            File(joined).renameSync(outPath);
            segTemps.remove(joined);
          } catch (_) {
            ok = false;
          }
        } else {
          trackProgress(0, total, 0.94, 1);
          await Diag.mark('匯出：配音');
          final ra = await runFF(aCmd);
          ok = ra.ok;
          rc = ra.rc;
          session = ra.session;
        }
      }
    }
  }
  FFmpegKitConfig.enableStatisticsCallback(null);
  Diag.stopSampling();
  // 走到這裡就代表 FFmpeg 沒把 App 帶走，現場可以擦了
  await Diag.clearMark();
  Diag.note('匯出結束：${ok ? '成功' : '失敗'}（峰值 ${Diag.peakMb} MB）');

  // 逐檔各自 try：第一個刪不掉（例如輸出檔根本沒生出來）
  // 不該讓後面的浮水印／疊圖 PNG 全部漏掉
  void cleanupTemp() {
    void del(String p) {
      try {
        File(p).deleteSync();
      } catch (_) {}
    }

    del(outPath);
    if (wmPath != null) del(wmPath);
    for (final p in overlayFiles.values) {
      del(p);
    }
    for (final p in revTemps) {
      del(p); // 倒轉用的分段暫存檔
    }
    for (final p in segTemps) {
      del(p); // 分段渲染的每一段畫面、串接清單、串好的無聲影片
    }
  }

  if (ReturnCode.isCancel(rc)) {
    cleanupTemp();
    return (ok: false, message: '已取消匯出', cancelled: true);
  }

  if (!ok) {
    var log = await session?.getAllLogsAsString() ?? '';
    final lines = log.trim().split('\n');
    log = lines.skip(math.max(0, lines.length - 15)).join('\n');
    cleanupTemp();
    // 帶上峰值記憶體：匯出失敗最常見的原因就是記憶體撞上限，
    // 使用者截這張圖給我，第一眼就分得出是不是那個問題
    return (
      ok: false,
      message: '匯出失敗（記憶體峰值 ${Diag.peakMb} MB）\n$log',
      cancelled: false,
    );
  }

  final saved = spec.gif ? await saveAsGif() : await saveToGallery();
  // 存相簿失敗也要把暫存清掉，不然每失敗一次就漏一組檔案
  cleanupTemp();
  return saved;
}

/// 產生時間軸縮圖（height 可調：filmstrip 用 200、批次預覽用 720）
/// 抽縮圖。抽不出來就回空清單——呼叫端全都處理得了「沒有縮圖」，
/// 但處理不了例外：這些多半是射後不理的背景工作，例外跑出去就變成
/// 沒人接的錯誤（FFmpeg 起不來、拿不到暫存目錄都會走到這裡）
Future<List<Uint8List>> makeThumbnails(
  String inputPath,
  double durationSec,
  int count, {
  int height = 200,
  bool longSide = false,
  double startAt = 0,
  bool fastDecode = false,
}) async {
  try {
    return await _makeThumbnails(
      inputPath,
      durationSec,
      count,
      height: height,
      longSide: longSide,
      startAt: startAt,
      fastDecode: fastDecode,
    );
  } catch (_) {
    return const [];
  }
}

Future<List<Uint8List>> _makeThumbnails(
  String inputPath,
  double durationSec,
  int count, {
  int height = 200,
  bool longSide = false,
  double startAt = 0,
  bool fastDecode = false,
}) async {
  if (durationSec <= 0) return [];
  final dir = await getTemporaryDirectory();
  final ts = DateTime.now().millisecondsSinceEpoch;
  final pattern = '${dir.path}${Platform.pathSeparator}mkthumb_${ts}_%02d.jpg';
  final fps = count / durationSec;
  // longSide＝把「長邊」縮到 height（直式影片才不會糊）。
  // 色彩要明確轉成 JPEG 的規格（bt601＋full range）：
  // 手機影片是 bt709 limited，不轉的話快取幀跟播放畫面
  // 顏色不一樣，拖曳時畫面會「變色」
  const jpegColor =
      ':in_range=auto:out_range=jpeg'
      ':in_color_matrix=auto:out_color_matrix=bt601';
  final scale = longSide
      ? 'scale=$height:$height:force_original_aspect_ratio=decrease$jpegColor'
      : 'scale=-2:$height$jpegColor';
  // startAt：-ss 放在 -i 前面＝關鍵幀快轉，只解碼需要的段落
  final seek = startAt > 0.001
      ? '-ss ${startAt.toStringAsFixed(3)} -t ${durationSec.toStringAsFixed(3)} '
      : '';
  // fastDecode＝只解關鍵幀（fps 濾鏡會把稀疏的關鍵幀鋪滿格子）。
  // 手機 FFmpeg 是軟體解碼，4K HEVC 全幀解會把 CPU 吃滿好幾分鐘、
  // 整個 App 卡死；關鍵幀解快 50~100 倍，拖曳預覽夠用
  final skip = fastDecode ? '-skip_frame nokey ' : '';
  // HDR 素材先轉 SDR 再縮圖：不轉的話快取幀／時間軸縮圖整片
  // 灰白，拖曳預覽跟播放畫面顏色對不上（也就是「拖曳會退色」）
  final p0 = await _probe(inputPath);
  // HDR 縮圖：把「縮小」摺進轉換鏈的第一步。
  //
  // 色調映射是 32 位元浮點運算，成本跟像素數成正比。原本是先轉再縮，
  // 等於拿 4K 的每一個像素去跑浮點——一支 4K HDR 素材光是背景抽
  // 拖曳快取幀就能把 CPU 吃滿，播放和預覽跟著卡。
  //
  // 縮小這一步必須由 zscale 自己做、不能用 scale：swscale 會把畫格的
  // 色彩標記換掉，換掉之後 zscale 就不知道來源是 HLG/PQ 了（這正是
  // 之前匯出退色的成因）。zscale 縮完再轉，像素少 16 倍、標記也還在
  final hdrFix =
      p0.hdr ? '${await _hdrChainFor(p0.trc, scaleH: height)},' : '';
  // 旋轉不用自己處理：FFmpeg 預設就會依 display matrix 自動轉正
  //（本機用 ffmpeg 8.1 實測：3840x2160＋rotation=-90 的素材，
  // 不加任何 transpose 抽出來就是直的）。自己再加一次是轉兩次
  final cmd =
      '-y $skip$seek-i "$inputPath" '
      '-vf "fps=${fps.toStringAsFixed(6)},$hdrFix$scale" '
      '-frames:v $count -q:v 4 "$pattern"';
  var session = await FFmpegKit.execute(cmd);
  var rc = await session.getReturnCode();
  // 保底：colorspace 濾鏡不能用就退回不轉色重抽
  if (!ReturnCode.isSuccess(rc) && hdrFix.isNotEmpty) {
    session = await FFmpegKit.execute(cmd.replaceFirst(hdrFix, ''));
    rc = await session.getReturnCode();
  }
  if (!ReturnCode.isSuccess(rc)) return [];
  final result = <Uint8List>[];
  for (var i = 1; i <= count; i++) {
    final f = File(
      '${dir.path}${Platform.pathSeparator}mkthumb_${ts}_${i.toString().padLeft(2, '0')}.jpg',
    );
    if (f.existsSync()) {
      result.add(await f.readAsBytes());
      try {
        f.deleteSync();
      } catch (_) {}
    }
  }
  return result;
}
