import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../services/quality_diagnostics.dart';

class QualityDiagnosticsSheet extends StatefulWidget {
  const QualityDiagnosticsSheet({
    super.key,
    required this.diagnostics,
    required this.buildTag,
    required this.refresh,
    required this.position,
  });
  final QualityDiagnostics diagnostics;
  final String buildTag;
  final Future<void> Function() refresh;
  final double Function() position;
  @override
  State<QualityDiagnosticsSheet> createState() =>
      _QualityDiagnosticsSheetState();
}

class _QualityDiagnosticsSheetState extends State<QualityDiagnosticsSheet> {
  bool busy = false;
  String? notice;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) refresh();
    });
  }

  Future<void> refresh() async {
    if (busy) return;
    setState(() => busy = true);
    try {
      await widget.refresh().timeout(const Duration(seconds: 3));
    } catch (_) {
      notice = '環境資料未完整取得；缺失項不判定通過。';
    }
    if (mounted) setState(() => busy = false);
  }

  Future<void> copy(bool json) async {
    try {
      await Clipboard.setData(
        ClipboardData(
          text: json
              ? widget.diagnostics.jsonReport()
              : widget.diagnostics.report(),
        ),
      );
      if (mounted) {
        setState(() => notice = '已複製${json ? ' JSON' : '報告'}，可貼回來分析。');
      }
    } catch (_) {
      if (mounted) setState(() => notice = '複製失敗，請重試。');
    }
  }

  @override
  Widget build(BuildContext context) {
    final d = widget.diagnostics;
    return SafeArea(
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * .85,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  const Text(
                    '品質診斷器',
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                  ),
                  const Text('本機記錄，不上傳素材。不會自動改畫質或切換引擎。'),
                  const Text('先做下列操作，再回來標記；「未測」不算通過。'),
                  Wrap(
                    spacing: 8,
                    children: [
                      TextButton(
                        onPressed: busy
                            ? null
                            : () {
                                d.start(buildTag: widget.buildTag);
                                Navigator.pop(context);
                              },
                        child: const Text('開始新一輪'),
                      ),
                      TextButton(
                        onPressed: () => setState(d.stop),
                        child: const Text('停止記錄'),
                      ),
                      TextButton(
                        onPressed: busy ? null : refresh,
                        child: Text(busy ? '讀取中…' : '更新資料'),
                      ),
                    ],
                  ),
                  if (notice != null) Text(notice!),
                ],
              ),
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                children: [
                  for (final s in QualityScenario.values)
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              s.label,
                              style: const TextStyle(
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            Text(s.instructions),
                            Wrap(
                              spacing: 8,
                              children: [
                                for (final choice in QualityObservation.values)
                                  ChoiceChip(
                                    label: Text(switch (choice) {
                                      QualityObservation.untested => '未測',
                                      QualityObservation.acceptable => '可接受',
                                      QualityObservation.problem => '有問題',
                                    }),
                                    selected:
                                        (d.observations[s] ??
                                            QualityObservation.untested) ==
                                        choice,
                                    onSelected: (_) => setState(
                                      () => d.observe(
                                        s,
                                        choice,
                                        position: widget.position(),
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                  SelectableText(
                    d.report(),
                    style: const TextStyle(fontSize: 11),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(12),
              child: Wrap(
                spacing: 12,
                children: [
                  FilledButton(
                    onPressed: busy ? null : () => copy(false),
                    child: const Text('複製驗收報告'),
                  ),
                  OutlinedButton(
                    onPressed: busy ? null : () => copy(true),
                    child: const Text('複製 JSON'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
