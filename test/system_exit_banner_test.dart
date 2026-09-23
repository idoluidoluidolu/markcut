// 被系統因記憶體砍掉的那一刻什麼程式都跑不了，只有 MetricKit 事後回報，
// 而且是開 App 之後才陸續送到。這裡釘住：
//   1. 新的異常結束跳首頁橫幅，同一份只跳一次；只有正常離開不跳
//   2. 已經有橫幅（處理到一半中斷）就補進那份報告，不另外蓋掉
//   3. 開 App 那份報告已經帶著的統計，補查時不再接一次
//   4. 橫幅標題照死因講：程式例外／系統因記憶體關閉／其他異常／處理中斷
//   5. 品質診斷器看得到、複製出去的報告與 JSON 都帶著上次結束原因
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:markcut/services/diagnostics.dart';
import 'package:markcut/services/quality_diagnostics.dart';
import 'package:markcut/widgets/interrupted_run_notice.dart';
import 'package:markcut/widgets/quality_diagnostics_sheet.dart';

Map<String, Object?> _exits(String window, {int memoryLimit = 0}) => {
  'foregroundExits': [
    {
      'window': window,
      'build': '216',
      'memoryLimit': memoryLimit,
      'watchdog': 0,
      'badAccess': 0,
      'illegalInstruction': 0,
      'abnormal': 0,
      'normal': 4,
    },
  ],
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const diagCh = MethodChannel('markcut/diag');
  late Directory dir;

  /// 假的原生端：nativePrepDiagnostic 回這份 exit 快照
  void nativeExit(Object? exit, {Map<String, Object?>? previous}) {
    messenger.setMockMethodCallHandler(diagCh, (call) async {
      if (call.method != 'nativePrepDiagnostic') return null;
      return <String, Object?>{
        'launch': {'process': 'test'},
        'previous': ?previous,
        'exit': ?exit,
      };
    });
  }

  setUp(() {
    dir = Directory.systemTemp.createTempSync('markcut_exit_banner_');
    Diag.crumbDirOverride = dir;
    Diag.crumbFromLastRun = null;
    Diag.nativePrepDiagnostic = null;
    Diag.exitSummary = null;
    Diag.recoveredReport.value = null;
  });

  tearDown(() {
    Diag.recoveredReport.value = null;
    Diag.exitSummary = null;
    messenger.setMockMethodCallHandler(diagCh, null);
    Diag.crumbDirOverride = null;
    dir.deleteSync(recursive: true);
  });

  test('指紋：只有正常離開不算異常；時間窗或次數變了就是新的一份', () {
    expect(Diag.abnormalExitSignature(null), isNull);
    expect(Diag.abnormalExitSignature(_exits('d1')), isNull);
    final a = Diag.abnormalExitSignature(_exits('d1', memoryLimit: 1));
    expect(a, isNotNull);
    expect(Diag.abnormalExitSignature(_exits('d1', memoryLimit: 1)), a);
    expect(Diag.abnormalExitSignature(_exits('d2', memoryLimit: 1)), isNot(a));
    expect(Diag.abnormalExitSignature(_exits('d1', memoryLimit: 2)), isNot(a));
    expect(
      Diag.abnormalExitSignature({
        'crashes': [
          {'window': 'd1', 'build': '216', 'signal': 6},
        ],
      }),
      isNotNull,
      reason: '系統當機報告本身就是異常',
    );
  });

  test('橫幅標題照死因講', () {
    expect(Diag.recoveredHeadline('停在：HDR 代理：轉檔中'), '上次素材處理未完成，已保留中斷前的紀錄。');
    expect(
      Diag.recoveredHeadline('上次閃退：程式例外 NSInvalidArgumentException：x'),
      '上次 App 閃退了（程式例外），已保留報告。',
    );
    expect(
      Diag.recoveredHeadline('${Diag.systemExitReportTitle}\n…記憶體上限 2／看門狗 0'),
      '系統回報：App 曾因記憶體不足被系統關閉，已保留報告。',
    );
    expect(
      Diag.recoveredHeadline('${Diag.systemExitReportTitle}\n…記憶體上限 0／看門狗 1'),
      '系統回報：App 曾被異常關閉，已保留報告。',
    );
  });

  test('新的異常結束跳一次；關掉之後同一份不再跳，換一天的新統計才再跳', () async {
    nativeExit(_exits('d1', memoryLimit: 2));
    await Diag.checkSystemExitReports();
    final report = Diag.recoveredReport.value;
    expect(report, startsWith(Diag.systemExitReportTitle));
    expect(report, contains('記憶體上限 2'));
    expect(Diag.exitSummary, contains('記憶體上限 2'));
    expect(
      Diag.recoveredHeadline(report!),
      '系統回報：App 曾因記憶體不足被系統關閉，已保留報告。',
    );
    expect(
      File('${dir.path}${Platform.pathSeparator}recovery_report.txt')
          .readAsStringSync(),
      report,
      reason: '重開 App 前沒按關閉，報告要還在',
    );

    await Diag.dismissRecoveredReport();
    await Diag.checkSystemExitReports();
    expect(Diag.recoveredReport.value, isNull, reason: '同一份不能再跳');

    nativeExit(_exits('d2', memoryLimit: 1));
    await Diag.checkSystemExitReports();
    expect(Diag.recoveredReport.value, contains('記憶體上限 1'));
  });

  test('只有正常離開：更新摘要但不跳橫幅', () async {
    nativeExit(_exits('d1'));
    await Diag.checkSystemExitReports();
    expect(Diag.recoveredReport.value, isNull);
    expect(Diag.exitSummary, contains('記憶體上限 0'));
  });

  test('已經有中斷橫幅：系統回報補進那份報告，不另外蓋掉', () async {
    Diag.recoveredReport.value = '=== 上次未完成的素材處理 ===\n停在：HDR 代理：轉檔中';
    nativeExit(_exits('d1', memoryLimit: 1));
    await Diag.checkSystemExitReports();
    final report = Diag.recoveredReport.value!;
    expect(report, startsWith('=== 上次未完成的素材處理 ==='));
    expect(report, contains('${Diag.systemExitReportTitle}\n'));
    expect(report, contains('記憶體上限 1'));
    expect(
      Diag.recoveredHeadline(report),
      '系統回報：App 曾因記憶體不足被系統關閉，已保留報告。',
      reason: '知道是記憶體就講記憶體',
    );
  });

  test('開 App 那份中斷報告已經帶著的統計，補查時不再接一次', () async {
    nativeExit(
      _exits('d1', memoryLimit: 1),
      previous: {'status': 'running', 'lanes': <String, Object?>{}},
    );
    await Diag.loadLastRun();
    final first = Diag.recoveredReport.value;
    expect(first, contains('記憶體上限 1'));
    await Diag.checkSystemExitReports();
    expect(Diag.recoveredReport.value, first);
  });

  testWidgets('首頁橫幅用死因標題', (t) async {
    await t.pumpWidget(
      const MaterialApp(home: Scaffold(body: InterruptedRunNotice())),
    );
    Diag.recoveredReport.value =
        '${Diag.systemExitReportTitle}\n系統統計的前景離開（build 216）：記憶體上限 3';
    await t.pump();
    expect(
      find.text('系統回報：App 曾因記憶體不足被系統關閉，已保留報告。'),
      findsOneWidget,
    );
    expect(find.text('查看報告'), findsOneWidget);
  });

  testWidgets('品質診斷器：看得到上次結束原因，複製的報告與 JSON 都帶著', (t) async {
    nativeExit(_exits('d1', memoryLimit: 2));
    final d = QualityDiagnostics()..start(buildTag: 'test');
    String? copied;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        copied = (call.arguments as Map)['text'] as String;
      }
      return null;
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
    );
    await t.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: QualityDiagnosticsSheet(
            diagnostics: d,
            buildTag: 'test',
            position: () => 0,
            refresh: () async {},
          ),
        ),
      ),
    );
    await t.pumpAndSettle();
    expect(find.text('上次結束原因'), findsOneWidget);
    expect(find.textContaining('記憶體上限 2'), findsWidgets);

    await t.tap(find.text('複製驗收報告'));
    await t.pumpAndSettle();
    expect(copied, startsWith('=== 上次結束原因 ===\n'));
    expect(copied, contains('記憶體上限 2'));

    await t.tap(find.text('複製 JSON'));
    await t.pumpAndSettle();
    final json = jsonDecode(copied!) as Map<String, dynamic>;
    expect(json['exitReason'], contains('記憶體上限 2'));
    expect(json['schemaVersion'], 2, reason: '原本的欄位照舊');
  });
}
