import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'widgets.dart';

Future<void> showParallelReport(
  BuildContext context,
  Future<String> Function() capture,
) => showDialog<void>(
  context: context,
  builder: (_) => _ReportDialog(capture: capture),
);

class _ReportDialog extends StatefulWidget {
  const _ReportDialog({required this.capture});
  final Future<String> Function() capture;
  @override
  State<_ReportDialog> createState() => _ReportDialogState();
}

class _ReportDialogState extends State<_ReportDialog> {
  late final Future<String> report = widget.capture();
  bool copied = false;
  @override
  Widget build(BuildContext context) => AppDialogFrame(
    children: [
      Text(
        'Отчёт параллельных профилей',
        style: Theme.of(context).textTheme.titleLarge,
      ),
      const SizedBox(height: 12),
      const Text(
        'Профили обозначены номерами в порядке списка. Отчёт содержит PID и состояния, без имён, путей и переписки. Ничего не отправляется автоматически.',
      ),
      const SizedBox(height: 12),
      FutureBuilder<String>(
        future: report,
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return const Text(
              'Не удалось подготовить отчёт. Закройте окно и попробуйте снова.',
            );
          }
          final text = snapshot.data;
          if (text == null) {
            return const Padding(
              padding: EdgeInsets.all(24),
              child: Center(child: CircularProgressIndicator()),
            );
          }
          return Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                height: 230,
                child: SingleChildScrollView(
                  child: SelectableText(
                    text,
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 11,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              AppButton(
                label: copied ? 'Скопировано' : 'Копировать отчёт',
                onPressed: () async {
                  await Clipboard.setData(ClipboardData(text: text));
                  if (mounted) setState(() => copied = true);
                },
              ),
            ],
          );
        },
      ),
      const SizedBox(height: 12),
      AppButton(
        label: 'Закрыть',
        kind: AppButtonKind.secondary,
        onPressed: () => Navigator.of(context).pop(),
      ),
    ],
  );
}
