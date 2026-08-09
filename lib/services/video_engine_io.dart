import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:ffmpeg_kit_flutter_new_min/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new_min/ffmpeg_kit_config.dart';
import 'package:ffmpeg_kit_flutter_new_min/ffprobe_kit.dart';
import 'package:ffmpeg_kit_flutter_new_min/return_code.dart';
import 'package:gal/gal.dart';
import 'package:path_provider/path_provider.dart';

import '../models/timeline.dart';
import '../models/watermark_settings.dart';
import 'video_processor.dart';

/// 這個平台是否支援影片匯出
const bool videoExportSupported = true;

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
  const _SourceProbe(this.hasAudio, this.fps);
}

Future<_SourceProbe> _probe(String path) async {
  try {
    final session = await FFprobeKit.getMediaInformation(path);
    final info = session.getMediaInformation();
    final streams = info?.getStreams() ?? [];
    final hasAudio = streams.any((s) => s.getType() == 'audio');
    double fps = 0;
    for (final s in streams) {
      if (s.getType() == 'video') {
        final r = s.getAverageFrameRate() ?? '';
        final parts = r.split('/');
        if (parts.length == 2) {
          final num = double.tryParse(parts[0]) ?? 0;
          final den = double.tryParse(parts[1]) ?? 1;
          if (den > 0) fps = num / den;
        } else {
          fps = double.tryParse(r) ?? 0;
        }
        break;
      }
    }
    return _SourceProbe(hasAudio, fps);
  } catch (_) {
    return _SourceProbe(true, 0);
  }
}

String _f(double v) => v.toStringAsFixed(3);

/// setpts 的除數要更準：0.25×0.25 這種組合用 3 位小數
/// （0.063 vs 0.0625）會累積出可感知的影音不同步
String _f6(double v) => v.toStringAsFixed(6);

/// 片段調色 → FFmpeg 濾鏡（沒調過回空字串）
String _eq(TimelineClip c) => c.color.ffmpeg;

/// 組出通用圖層的 FFmpeg 指令：
/// 黑色畫布 → 由下層往上把每個影片片段 overlay 上去（各自只在自己的時間區間顯示）
/// → 疊浮水印；所有帶聲音的片段 delay 對位後 amix 混成一軌。
/// 高畫質策略：libx264 CRF 17 + lanczos 縮放。
Future<String> _buildCommand(
  ExportSpec spec,
  String? wmPath,
  Map<int, String> overlayFiles,
  String outPath,
) async {
  final probes = <int, _SourceProbe>{};
  for (var i = 0; i < spec.sources.length; i++) {
    final s = spec.sources[i];
    probes[i] = (s.kind == ClipKind.video || s.kind == ClipKind.audio)
        ? await _probe(s.path)
        : const _SourceProbe(false, 0);
  }

  final sp = spec.speed;
  final outDur = spec.outputDuration;

  // 畫布幀率取素材中最高者
  var fps = 0.0;
  for (var i = 0; i < spec.sources.length; i++) {
    if (spec.sources[i].isVideo && probes[i]!.fps > fps) fps = probes[i]!.fps;
  }
  if (fps <= 0 || fps > 120) fps = 30;

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

  for (final c in spec.clips) {
    final k = spec.sources[c.sourceIndex].kind;
    // 文字有自己的輸入，不佔來源的 v 串流
    if (k == ClipKind.video || k == ClipKind.image) {
      vNeed[c.sourceIndex] = (vNeed[c.sourceIndex] ?? 0) + 1;
    }
    if (clipHasAudio(c.sourceIndex)) {
      aNeed[c.sourceIndex] = (aNeed[c.sourceIndex] ?? 0) + 1;
    }
  }

  // 圖片素材用 -loop 輸入，長度取該素材所有片段的最大需求
  final stillNeed = <int, double>{};
  for (final c in spec.clips) {
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
  final srcIn = <int, int>{};
  var nextInput = 0;
  for (var i = 0; i < spec.sources.length; i++) {
    if (!isPngClip(spec.sources[i].kind)) srcIn[i] = nextInput++;
  }
  final textClipInput = <int, int>{}; // clip id → input index
  for (final c in spec.clips) {
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
    'r=${fps.toStringAsFixed(3)}:d=${_f(outDur)}[base];',
  );

  // 疊放順序：track 大的是下層先疊；同一層時，清單裡較後面的疊在上面
  final clipOrder = <int, int>{};
  for (var i = 0; i < spec.clips.length; i++) {
    clipOrder[spec.clips[i].id] = i;
  }
  int cmpLayer(TimelineClip a, TimelineClip b) {
    final t = b.track.compareTo(a.track);
    return t != 0 ? t : (clipOrder[a.id] ?? 0).compareTo(clipOrder[b.id] ?? 0);
  }

  final videoClips =
      spec.clips.where((c) => spec.sources[c.sourceIndex].isVideo).toList()
        ..sort(cmpLayer);
  // 圖片/文字永遠疊在影片上面（跟預覽一致）
  final stillClips =
      spec.clips.where((c) => spec.sources[c.sourceIndex].isOverlay).toList()
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

  // 畫面淡入淡出（時間用輸出秒）
  String vFades(TimelineClip c) {
    final start = c.offset / sp;
    final end = c.end / sp;
    final fi = c.fadeIn / sp;
    final fo = c.fadeOut / sp;
    var out = '';
    if (fi > 0.01 || fo > 0.01) out += ',format=yuva420p';
    if (fi > 0.01) out += ',fade=t=in:st=${_f(start)}:d=${_f(fi)}:alpha=1';
    if (fo > 0.01) {
      out += ',fade=t=out:st=${_f(end - fo)}:d=${_f(fo)}:alpha=1';
    }
    return out;
  }

  var cur = 'base';
  var layerN = 0;
  for (final c in videoClips) {
    final k = layerN++;
    final src = spec.sources[c.sourceIndex];
    final label = vPool[c.sourceIndex]!.removeLast();
    final start = c.offset / sp;
    final end = c.end / sp;
    final (w2, h2, x, y) = layerBox(c, src.aspect);
    fc.write(
      '[$label]'
      'trim=start=${_f(c.trimStart)}:end=${_f(c.trimEnd)},'
      // 全域速度 × 每片段速度一起壓進 PTS
      //（速度 clamp 到跟 TimelineClip.length 同一個範圍，
      // 兩邊算出來的時間才對得上）
      'setpts=(PTS-STARTPTS)/${_f6(sp * c.speed.clamp(0.1, 16.0))}'
      '+${_f(start)}/TB,'
      'scale=$w2:$h2:flags=lanczos'
      '${_eq(c)}'
      '${vFades(c)}'
      '[lv$k];',
    );
    fc.write(
      '[$cur][lv$k]overlay=$x:$y:'
      'enable=between(t\\,${_f(start)}\\,${_f(end)}):'
      'eof_action=pass[ov$k];',
    );
    cur = 'ov$k';
  }
  for (final c in stillClips) {
    final k = layerN++;
    final src = spec.sources[c.sourceIndex];
    final start = c.offset / sp;
    final end = c.end / sp;
    if (src.kind == ClipKind.image) {
      final label = vPool[c.sourceIndex]!.removeLast();
      final (w2, h2, x, y) = layerBox(c, src.aspect);
      fc.write(
        '[$label]'
        'scale=$w2:$h2:flags=lanczos'
        '${_eq(c)}'
        ',format=rgba,'
        'setpts=PTS-STARTPTS+${_f(start)}/TB'
        '${vFades(c)}'
        '[lv$k];',
      );
      fc.write(
        '[$cur][lv$k]overlay=$x:$y:'
        'enable=between(t\\,${_f(start)}\\,${_f(end)}):'
        'eof_action=pass[ov$k];',
      );
    } else {
      // 文字／浮水印：整版透明 PNG（位置/縮放已烘進圖），每片段一個輸入
      final inputIdx = textClipInput[c.id]!;
      fc.write(
        '[$inputIdx:v]'
        'setpts=PTS-STARTPTS+${_f(start)}/TB'
        '${vFades(c)}'
        '[lv$k];',
      );
      // 浮水印素材的動畫跟全域浮水印同一套 overlay 時間運算式：
      // 閃爍＝enable 週期開關；飄移/跑馬燈＝x,y 隨 t 變化
      var enable = 'between(t\\,${_f(start)}\\,${_f(end)})';
      var pos = '0:0';
      var evalFrame = '';
      final wmSt = src.kind == ClipKind.wm ? src.wmStyle : null;
      if (wmSt != null && wmSt.animation != WmAnimation.none) {
        evalFrame = 'eval=frame:';
        // 動畫週期是「時間軸秒」；輸出時間 t 要乘回全域速度，
        // 不然 2 倍速匯出時動畫會慢一半、跟預覽對不上
        final ts = sp == 1.0 ? 't' : '(t*${_f(sp)})';
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
        'eof_action=pass[ov$k];',
      );
    }
    cur = 'ov$k';
  }

  // 浮水印疊最上面（只在它的時間範圍內顯示）
  // 動畫用 overlay 的時間運算式做，不必逐格產圖：
  // 閃爍＝enable 週期開關；飄移/跑馬燈＝x,y 隨 t 變化（整版 PNG 一起位移）
  final hasWm = wmPath != null;
  if (hasWm) {
    final ws = (spec.wmStart / sp).clamp(0.0, outDur);
    final we = (spec.wmEnd / sp).clamp(0.0, outDur);
    var enable = 'between(t\\,${_f(ws)}\\,${_f(we)})';
    var pos = 'x=0:y=0';
    // 動畫週期是「時間軸秒」；輸出時間 t 要乘回全域速度
    final ts = sp == 1.0 ? 't' : '(t*${_f(sp)})';
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
  final audioLabels = <String>[];
  for (var k = 0; k < spec.clips.length; k++) {
    final c = spec.clips[k];
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
    switch (s.kind) {
      case ClipKind.video || ClipKind.audio:
        cmd.write('-i "${s.path}" ');
      case ClipKind.image:
        cmd.write(
          '-loop 1 -framerate ${fps.toStringAsFixed(3)} '
          '-t ${_f(stillNeed[i] ?? 1)} -i "${s.path}" ',
        );
      case ClipKind.text || ClipKind.wm:
        break; // 每個片段一張 PNG，在下面接續
    }
  }
  for (final c in spec.clips) {
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
    ..write('-t ${_f(outDur)} ')
    // LGPL 版沒有 x264：H.264 用手機的硬體編碼器（更快、更省電），
    // 畫質用位元率控制（硬體編碼器不吃 CRF）
    ..write(
      '-c:v ${_hwEncoder()} -b:v ${_kbpsFor(spec)}k '
      '-maxrate ${(_kbpsFor(spec) * 1.4).round()}k '
      '-bufsize ${_kbpsFor(spec) * 2}k -pix_fmt nv12 ',
    )
    ..write('-movflags +faststart ')
    ..write('"$outPath"');
  return cmd.toString();
}

/// 平台對應的 H.264 硬體編碼器
String _hwEncoder() => (Platform.isIOS || Platform.isMacOS)
    ? 'h264_videotoolbox'
    : 'h264_mediacodec';

/// 畫質檔位 → 位元率（依解析度換算；沿用 spec.crf 當檔位訊號：
/// 17=標準、12=極高、0=最高）
int _kbpsFor(ExportSpec spec) {
  final px = spec.outW * spec.outH;
  final bpp = spec.crf <= 0 ? 0.60 : (spec.crf <= 12 ? 0.28 : 0.15);
  return (px * 30 * bpp / 1000).round().clamp(1500, 120000);
}

/// 取消正在進行的匯出（FFmpeg 一次只跑一個 session，全取消即可）
Future<void> cancelExport() async {
  await FFmpegKit.cancel();
}

/// 執行匯出並存到相簿。onProgress 回傳 0~1。
Future<({bool ok, String message, bool cancelled})> exportVideoToGallery(
  ExportSpec spec, {
  void Function(double progress)? onProgress,
}) async {
  final dir = await getTemporaryDirectory();
  final ts = DateTime.now().millisecondsSinceEpoch;
  final outPath = '${dir.path}${Platform.pathSeparator}markcut_$ts.mp4';

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

  final cmd = await _buildCommand(spec, wmPath, overlayFiles, outPath);

  final outDurMs = spec.outputDuration * 1000;
  FFmpegKitConfig.enableStatisticsCallback((stats) {
    final t = stats.getTime();
    if (onProgress != null && outDurMs > 0) {
      onProgress((t / outDurMs).clamp(0.0, 1.0));
    }
  });

  var session = await FFmpegKit.execute(cmd);
  var rc = await session.getReturnCode();
  var ok = ReturnCode.isSuccess(rc);

  // 保底：這台機器的硬體編碼器不能用（少數機型/模擬器）就退
  // LGPL 軟體編碼器 mpeg4 重跑一次，匯出不能整個死掉
  if (!ok && !ReturnCode.isCancel(rc) && cmd.contains(_hwEncoder())) {
    final soft = cmd
        .replaceFirst('-c:v ${_hwEncoder()}', '-c:v mpeg4 -q:v 3')
        .replaceFirst('-pix_fmt nv12', '-pix_fmt yuv420p');
    session = await FFmpegKit.execute(soft);
    rc = await session.getReturnCode();
    ok = ReturnCode.isSuccess(rc);
  }
  FFmpegKitConfig.enableStatisticsCallback(null);

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
  }

  if (ReturnCode.isCancel(rc)) {
    cleanupTemp();
    return (ok: false, message: '已取消匯出', cancelled: true);
  }

  if (!ok) {
    var log = await session.getAllLogsAsString() ?? '';
    final lines = log.trim().split('\n');
    log = lines.skip(math.max(0, lines.length - 15)).join('\n');
    cleanupTemp();
    return (ok: false, message: '匯出失敗\n$log', cancelled: false);
  }

  if (!await Gal.hasAccess(toAlbum: true)) {
    final granted = await Gal.requestAccess(toAlbum: true);
    if (!granted) {
      cleanupTemp();
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
    // 存相簿失敗也要把暫存清掉，不然每失敗一次就漏一組檔案
    cleanupTemp();
    return (ok: false, message: '存到相簿失敗：$e', cancelled: false);
  }
  cleanupTemp();
  return (ok: true, message: '完成！影片已儲存到相簿（浮水印 相簿）', cancelled: false);
}

/// 產生時間軸縮圖（height 可調：filmstrip 用 200、批次預覽用 720）
Future<List<Uint8List>> makeThumbnails(
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
  // longSide＝把「長邊」縮到 height（直式影片才不會糊）
  final scale = longSide
      ? 'scale=$height:$height:force_original_aspect_ratio=decrease'
      : 'scale=-2:$height';
  // startAt：-ss 放在 -i 前面＝關鍵幀快轉，只解碼需要的段落
  final seek = startAt > 0.001
      ? '-ss ${startAt.toStringAsFixed(3)} -t ${durationSec.toStringAsFixed(3)} '
      : '';
  // fastDecode＝只解關鍵幀（fps 濾鏡會把稀疏的關鍵幀鋪滿格子）。
  // 手機 FFmpeg 是軟體解碼，4K HEVC 全幀解會把 CPU 吃滿好幾分鐘、
  // 整個 App 卡死；關鍵幀解快 50~100 倍，拖曳預覽夠用
  final skip = fastDecode ? '-skip_frame nokey ' : '';
  final cmd =
      '-y $skip$seek-i "$inputPath" -vf "fps=${fps.toStringAsFixed(6)},$scale" '
      '-frames:v $count -q:v 4 "$pattern"';
  final session = await FFmpegKit.execute(cmd);
  final rc = await session.getReturnCode();
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
