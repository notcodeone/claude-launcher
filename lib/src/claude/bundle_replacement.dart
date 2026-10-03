/// Tracks whether cleanup would destroy the only surviving application copy.
class BundleReplacement {
  BundleReplacement({
    required this.current,
    required this.fresh,
    required this.backup,
    required this.move,
  });

  final String current;
  final String fresh;
  final String backup;
  final Future<void> Function(String from, String to) move;
  bool backupPending = false;

  Future<void> replace() async {
    await move(current, backup);
    backupPending = true;
    try {
      await move(fresh, current);
      backupPending = false;
    } catch (_) {
      try {
        await move(backup, current);
        backupPending = false;
      } catch (_) {
        throw StateError(
          'Не удалось восстановить Claude. Резервная копия сохранена: $backup',
        );
      }
      rethrow;
    }
  }
}
