import 'claude_code_events.dart';

/// Short-lived, memory-only replay. Notifications are never replayed.
class PendingCodeEvents {
  PendingCodeEvents({
    this.lifetime = const Duration(minutes: 2),
    this.capacity = 256,
  });

  final Duration lifetime;
  final int capacity;
  final _entries = <PendingCodeEvent>[];

  bool get isEmpty => _entries.isEmpty;
  void clear() => _entries.clear();

  void add(ClaudeCodeEvent event, Map<String, Set<int>> owners, DateTime now) {
    if (event.sessionId.isEmpty ||
        !RegExp(
          r'^local_[A-Za-z0-9_-]{1,160}$',
        ).hasMatch(event.hostSessionId)) {
      return;
    }
    expire(now);
    if (owners.isEmpty) return;
    while (_entries.length >= capacity && _entries.isNotEmpty) {
      _entries.removeAt(0);
    }
    if (capacity <= 0) return;
    _entries.add(
      PendingCodeEvent(event, {
        for (final entry in owners.entries) entry.key: Set.of(entry.value),
      }, now.add(lifetime)),
    );
  }

  void expire(DateTime now) =>
      _entries.removeWhere((entry) => !entry.expiresAt.isAfter(now));

  List<PendingCodeEvent> get entries => List.unmodifiable(_entries);

  List<PendingCodeEvent> take(String sessionId, String hostSessionId) {
    final found = _entries
        .where(
          (entry) =>
              entry.event.sessionId == sessionId &&
              entry.event.hostSessionId == hostSessionId,
        )
        .toList();
    _entries.removeWhere(found.contains);
    return found;
  }
}

class PendingCodeEvent {
  const PendingCodeEvent(this.event, this.owners, this.expiresAt);
  final ClaudeCodeEvent event;
  final Map<String, Set<int>> owners;
  final DateTime expiresAt;

  bool accepts(String profileId, Set<int> runningPids) =>
      owners[profileId]?.any(runningPids.contains) ?? false;
}
