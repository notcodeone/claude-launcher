import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;

import 'claude_code_events.dart';

enum CodeSessionState {
  /// Claude выполняет задачу.
  working,

  /// Ожидает: нужно разрешение (оранжевый).
  needsPermission,

  /// Ожидает: нужен ответ (синий).
  needsAnswer,

  /// Задача выполнена.
  done,
}

/// Сессия Claude Code в открытом профиле.
class CodeSession {
  CodeSession({
    required this.id,
    required this.profileId,
    required this.startedAt,
  }) : updatedAt = startedAt;

  final String id;
  final String profileId;

  /// Сессия в приложении Claude (`local_…`); пусто для терминала.
  String hostSessionId = '';
  String cwd = '';
  String transcriptPath = '';

  CodeSessionState state = CodeSessionState.working;

  /// Начало текущей задачи.
  DateTime startedAt;

  /// Последнее событие.
  DateTime updatedAt;

  /// Текст уведомления, пока сессия ожидает.
  String message = '';

  /// Выходные токены текущей задачи — как «↓ N tokens» в самом Claude Code.
  int outputTokens = 0;

  String? _customTitle;
  String? _aiTitle;

  /// Ссылка, которой приложение Claude открывает свою сессию извне (такую же
  /// оно выдаёт само). У сессий из терминала её нет.
  Uri? get link => _hostIdPattern.hasMatch(hostSessionId)
      ? Uri.parse('claude://claude.ai/epitaxy/$hostSessionId')
      : null;

  static final _hostIdPattern = RegExp(r'^local_[A-Za-z0-9-]+$');

  /// Название из боковой панели Claude, иначе — папка проекта.
  String get name =>
      _customTitle ?? _aiTitle ?? (cwd.isEmpty ? 'Сессия' : p.basename(cwd));

  // Чтение файла переписки по мере роста.
  int _offset = 0;
  List<int> _carry = const [];
  final Map<String, int> _tokensById = {};
  bool _titleScanned = false;
}

/// Сессии Claude Code по событиям хуков.
class ClaudeCodeSessions {
  /// Сколько держать строку «Готово».
  static const doneLifetime = Duration(hours: 1);

  final Map<String, CodeSession> _sessions = {};

  /// Сессии профиля, последние сверху.
  List<CodeSession> of(String profileId) => [
    for (final session in _sessions.values)
      if (session.profileId == profileId) session,
  ]..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));

  bool get anyWorking => _sessions.values.any(
    (session) => session.state == CodeSessionState.working,
  );

  bool get isEmpty => _sessions.isEmpty;

  void clear() => _sessions.clear();

  /// Применяет событие к сессии открытого профиля [profileId].
  void handle(ClaudeCodeEvent event, String profileId) {
    if (event.sessionId.isEmpty) return;
    if (event.kind == ClaudeCodeEventKind.sessionEnded) {
      _sessions.remove(event.sessionId);
      return;
    }
    final isNew = !_sessions.containsKey(event.sessionId);
    final session = _sessions.putIfAbsent(
      event.sessionId,
      () => CodeSession(
        id: event.sessionId,
        profileId: profileId,
        startedAt: event.time,
      ),
    );
    if (event.cwd.isNotEmpty) session.cwd = event.cwd;
    if (event.hostSessionId.isNotEmpty) {
      session.hostSessionId = event.hostSessionId;
    }
    if (event.transcriptPath.isNotEmpty &&
        event.transcriptPath != session.transcriptPath) {
      session
        ..transcriptPath = event.transcriptPath
        .._offset = 0
        .._carry = const [];
    }
    // С сессией знакомимся посреди работы: прошлые задачи в файле не считаем.
    if (isNew) session._offset = _lengthOf(session.transcriptPath);
    session.updatedAt = event.time;

    switch (event.kind) {
      case ClaudeCodeEventKind.promptSubmitted:
        _startTask(session, event.time);
      case ClaudeCodeEventKind.toolUsed:
        // После разрешения или ответа продолжается та же задача; после
        // «Готово» (или если начало задачи не пришло) — это уже новая.
        if (session.state == CodeSessionState.done) {
          _startTask(session, event.time);
        }
        session.state = CodeSessionState.working;
        session.message = '';
      case ClaudeCodeEventKind.needsPermission:
        session
          ..state = CodeSessionState.needsPermission
          ..message = event.message;
      case ClaudeCodeEventKind.needsAnswer:
        session
          ..state = CodeSessionState.needsAnswer
          ..message = event.message;
      case ClaudeCodeEventKind.finished:
        session
          ..state = CodeSessionState.done
          ..message = '';
      case ClaudeCodeEventKind.sessionEnded:
        break;
    }
  }

  void _startTask(CodeSession session, DateTime time) {
    session
      ..state = CodeSessionState.working
      ..startedAt = time
      ..message = ''
      ..outputTokens = 0
      .._tokensById.clear()
      // Токены считаем с этого места: всё раньше — прошлые задачи.
      .._offset = _lengthOf(session.transcriptPath)
      .._carry = const [];
  }

  /// Дочитывает файлы переписки: название сессии и токены текущей задачи.
  /// Возвращает, изменилось ли что-нибудь.
  Future<bool> readTranscripts() async {
    var changed = false;
    for (final session in _sessions.values) {
      if (session.transcriptPath.isEmpty) continue;
      final nameBefore = session.name;
      final tokensBefore = session.outputTokens;
      await _scanTitle(session);
      await _readNew(session);
      changed |=
          session.name != nameBefore || session.outputTokens != tokensBefore;
    }
    return changed;
  }

  /// Убирает сессии закрытых профилей и давно выполненные задачи.
  bool prune({required Set<String> runningProfileIds, required DateTime now}) {
    final before = _sessions.length;
    _sessions.removeWhere(
      (_, session) =>
          !runningProfileIds.contains(session.profileId) ||
          (session.state == CodeSessionState.done &&
              now.difference(session.updatedAt) > doneLifetime),
    );
    return _sessions.length != before;
  }

  /// Название есть в строках `custom-title` / `ai-title`; они повторяются по всему
  /// файлу, поэтому при первом знакомстве с сессией достаточно конца файла.
  Future<void> _scanTitle(CodeSession session) async {
    if (session._titleScanned) return;
    session._titleScanned = true;
    final file = File(session.transcriptPath);
    if (!await file.exists()) return;
    final length = await file.length();
    final from = max(0, length - 512 * 1024);
    final bytes = await _readRange(file, from, length);
    for (final line in _lines(bytes)) {
      _applyTitle(session, line);
    }
  }

  Future<void> _readNew(CodeSession session) async {
    final file = File(session.transcriptPath);
    if (!await file.exists()) return;
    final length = await file.length();
    if (length < session._offset) {
      session
        .._offset = 0
        .._carry = const [];
    }
    if (length == session._offset) return;
    final bytes = [
      ...session._carry,
      ...await _readRange(file, session._offset, length),
    ];
    session._offset = length;
    // Последняя строка может быть дописана не до конца — оставляем на потом.
    final lastNewline = bytes.lastIndexOf(0x0A);
    session._carry = bytes.sublist(lastNewline + 1);
    if (lastNewline < 0) return;
    for (final line in _lines(bytes.sublist(0, lastNewline))) {
      _applyTitle(session, line);
      _applyUsage(session, line);
    }
    session.outputTokens = session._tokensById.values.fold(0, (a, b) => a + b);
  }

  static void _applyTitle(CodeSession session, Map<String, Object?> line) {
    switch (line['type']) {
      case 'custom-title':
        if (line['customTitle'] case final String title when title.isNotEmpty) {
          session._customTitle = title;
        }
      case 'ai-title':
        if ((line['aiTitle'] ?? line['title']) case final String title
            when title.isNotEmpty) {
          session._aiTitle = title;
        }
    }
  }

  /// Один ответ записывается несколькими строками с одинаковым расходом —
  /// считаем по уникальному id ответа.
  static void _applyUsage(CodeSession session, Map<String, Object?> line) {
    if (line['type'] != 'assistant') return;
    final message = line['message'];
    if (message is! Map) return;
    final id = message['id'];
    final usage = message['usage'];
    if (id is! String || usage is! Map) return;
    final output = usage['output_tokens'];
    if (output is! int) return;
    session._tokensById[id] = max(session._tokensById[id] ?? 0, output);
  }

  static Iterable<Map<String, Object?>> _lines(List<int> bytes) sync* {
    for (final text in const LineSplitter().convert(
      utf8.decode(bytes, allowMalformed: true),
    )) {
      if (text.isEmpty) continue;
      try {
        final json = jsonDecode(text);
        if (json is Map<String, Object?>) yield json;
      } on FormatException {
        // Повреждённая строка — пропускаем.
      }
    }
  }

  static Future<List<int>> _readRange(File file, int from, int to) async {
    final handle = await file.open();
    try {
      await handle.setPosition(from);
      return await handle.read(to - from);
    } finally {
      await handle.close();
    }
  }

  static int _lengthOf(String path) {
    if (path.isEmpty) return 0;
    try {
      return File(path).lengthSync();
    } on FileSystemException {
      return 0;
    }
  }
}
