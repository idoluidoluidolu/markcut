import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/diagnostics.dart';

/// Visible even when diagnostic loading finishes after the home screen builds.
class InterruptedRunNotice extends StatelessWidget {
  const InterruptedRunNotice({super.key});

  Future<void> _showReport(BuildContext context, String report) =>
      showDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('上次中斷報告'),
          content: SizedBox(
            width: 480,
            child: SingleChildScrollView(child: SelectableText(report)),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('返回'),
            ),
            FilledButton(
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: report));
                if (!dialogContext.mounted) return;
                Navigator.pop(dialogContext);
                if (context.mounted) {
                  ScaffoldMessenger.of(
                    context,
                  ).showSnackBar(const SnackBar(content: Text('報告已複製')));
                }
              },
              child: const Text('複製報告'),
            ),
          ],
        ),
      );

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<String?>(
    valueListenable: Diag.recoveredReport,
    builder: (context, report, _) {
      if (report == null) return const SizedBox.shrink();
      return MaterialBanner(
        // 程式例外／系統因記憶體關閉／處理到一半中斷，各講各的
        content: Text(Diag.recoveredHeadline(report)),
        forceActionsBelow: true,
        actions: [
          TextButton(
            onPressed: Diag.dismissRecoveredReport,
            child: const Text('關閉提示'),
          ),
          FilledButton(
            onPressed: () => _showReport(context, report),
            child: const Text('查看報告'),
          ),
        ],
      );
    },
  );
}
