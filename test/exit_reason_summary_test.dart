// 上次怎麼死的：原生 MCExitRecorder 的快照（nativePrepDiagnostic 的 exit）
// 寫成報告最上面那幾行。以前報告只能寫「無法判定是記憶體、看門狗還是
// 例外」——每一輪修正都是在不知道死因的情況下猜的
import 'package:flutter_test/flutter_test.dart';

import 'package:markcut/services/diagnostics.dart';

void main() {
  test('沒有任何紀錄＝不加任何一行', () {
    expect(Diag.exitReasonSummary(null), isNull);
    expect(Diag.exitReasonSummary(const <String, Object?>{}), isNull);
    expect(Diag.exitReasonSummary('not a map'), isNull);
  });

  test('上一趟當場寫下的程式例外排第一行，名字和原因都要在', () {
    final text = Diag.exitReasonSummary({
      'previousException': {
        'name': 'NSInvalidArgumentException',
        'reason': 'AVPlayerItem cannot service a seek request',
      },
    });
    expect(
      text,
      '上次閃退：程式例外 NSInvalidArgumentException：'
      'AVPlayerItem cannot service a seek request',
    );
  });

  test('MetricKit：取最新一筆當機報告與前景離開統計', () {
    final text = Diag.exitReasonSummary({
      'crashes': [
        {'build': '210', 'signal': 11},
        {
          'build': '215',
          'objcException': 'NSInvalidArgumentException: bad settings',
          'exceptionType': 1,
        },
      ],
      'foregroundExits': [
        {'build': '214', 'memoryLimit': 1},
        {
          'build': '215',
          'memoryLimit': 3,
          'watchdog': 0,
          'badAccess': 1,
          'illegalInstruction': 0,
          'abnormal': 2,
          'normal': 9,
        },
      ],
    })!;
    final lines = text.split('\n');
    expect(lines, hasLength(2));
    expect(
      lines[0],
      '系統當機報告（build 215）：'
      'NSInvalidArgumentException: bad settings／exception type 1',
    );
    expect(
      lines[1],
      '系統統計的前景離開（build 215）：記憶體上限 3／看門狗 0／'
      '記憶體存取錯誤 1／非法指令 0／其他異常 2／正常 9',
    );
  });

  test('欄位缺漏不丟例外', () {
    final text = Diag.exitReasonSummary({
      'crashes': [<String, Object?>{}],
      'foregroundExits': [<String, Object?>{}],
      'previousException': <String, Object?>{},
    })!;
    expect(text, contains('上次閃退：程式例外 ?：'));
    expect(text, contains('系統當機報告（build ?）：沒有細節'));
    expect(text, contains('記憶體上限 0'));
  });
}
