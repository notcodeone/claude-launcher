import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;

import 'claude_code_events.dart';

enum CodeSessionState {
  /// Restored reference; no hook has confirmed the current task state yet.
  unknown,

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

  /// Токены, которые Claude написал за текущую задачу, — как «↓ N tokens»
  /// в самом Claude Code: каждый ответ модели — по его `usage.output_tokens`
  /// (со скрытыми рассуждениями, которых в переписке нет), а если их нет —
  /// по длине ответа (символы / 4).
  ///
  /// Claude Code растит своё число по ходу печати, а лаунчер видит ответ, только
  /// когда тот записан в переписку, — поэтому здесь число растёт ступеньками.
  int tokens = 0;

  String? _customTitle;
  String? _aiTitle;

  /// Ссылка, которой приложение Claude открывает свою сессию извне (такую же
  /// оно выдаёт само). У сессий из терминала её нет.
  Uri? get link => linkFor(hostSessionId);

  /// Ссылка на сессию приложения Claude по её id (`local_…`).
  static Uri? linkFor(String hostSessionId) =>
      _hostIdPattern.hasMatch(hostSessionId)
      ? Uri.parse('claude://claude.ai/epitaxy/$hostSessionId')
      : null;

  static final _hostIdPattern = RegExp(r'^local_[A-Za-z0-9_-]{1,160}$');

  /// Название из боковой панели Claude, иначе — папка проекта.
  String get name =>
      _customTitle ?? _aiTitle ?? (cwd.isEmpty ? 'Сессия' : p.basename(cwd));

  // Чтение файла переписки по мере роста.
  int _offset = 0;
  List<int> _carry = const [];

  /// Строки ответа в переписке (у каждой свой uuid): к какому ответу модели
  /// относится и сколько в ней символов.
  final Map<String, ({String message, int chars})> _answerLines = {};

  /// `usage.output_tokens` ответов модели по их id.
  final Map<String, int> _outputTokens = {};

  void _resetTokens() {
    tokens = 0;
    _answerLines.clear();
    _outputTokens.clear();
  }

  bool _titleScanned = false;

  /// С сессией познакомились посреди задачи — начало ищем в переписке.
  bool _findTaskStart = false;
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

  Iterable<CodeSession> get all => _sessions.values;

  CodeSession? byId(String sessionId) => _sessions[sessionId];

  bool get anyWorking => _sessions.values.any(
    (session) => session.state == CodeSessionState.working,
  );

  bool get isEmpty => _sessions.isEmpty;

  void clear() => _sessions.clear();

  /// Restore only a verified reference. No transcript reads or notifications;
  /// a new hook is required before claiming that the task works or waits.
  void restore({
    required String id,
    required String hostSessionId,
    required String profileId,
    required DateTime startedAt,
    required DateTime updatedAt,
  }) {
    _sessions.putIfAbsent(
      id,
      () => CodeSession(id: id, profileId: profileId, startedAt: startedAt)
        ..hostSessionId = hostSessionId
        ..updatedAt = updatedAt
        ..state = CodeSessionState.unknown,
    );
  }

  /// Применяет событие к сессии открытого профиля [profileId].
  void handle(ClaudeCodeEvent event, String profileId) {
    if (event.sessionId.isEmpty) return;
    if (event.kind == ClaudeCodeEventKind.sessionEnded) {
      if (_sessions[event.sessionId]?.profileId == profileId) {
        _sessions.remove(event.sessionId);
      }
      return;
    }
    // Never mutate a row belonging to another profile after ownership changes.
    final prior = _sessions[event.sessionId];
    if (prior != null && prior.profileId != profileId) {
      _sessions.remove(event.sessionId);
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
    // С сессией знакомимся посреди работы (например, лаунчер перезапустили):
    // пока считаем с этого места, а начало задачи найдём в переписке.
    if (isNew || session.state == CodeSessionState.unknown) {
      session
        .._offset = _lengthOf(session.transcriptPath)
        .._findTaskStart = event.kind != ClaudeCodeEventKind.promptSubmitted;
    }
    session.updatedAt = event.time;

    switch (event.kind) {
      case ClaudeCodeEventKind.promptSubmitted:
        // Этот хук срабатывает и на сообщения, отправленные посреди работы:
        // своё, отчёт фонового агента, уведомление фоновой задачи. Задачу они
        // продолжают, а не начинают, и ожидание разрешения не снимают. Если же
        // работу прервали (тогда Stop не приходит) и дали новую, её начало
        // найдётся в переписке.
        if (isNew || !_inProgress(session.state)) {
          _startTask(session, event.time);
        }
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

  /// Задача ещё идёт: работает или ждёт разрешения посреди работы.
  static bool _inProgress(CodeSessionState state) =>
      state == CodeSessionState.working ||
      state == CodeSessionState.needsPermission;

  void _startTask(CodeSession session, DateTime time) {
    session
      ..state = CodeSessionState.working
      ..startedAt = time
      ..message = ''
      .._resetTokens()
      // Токены считаем с этого места: всё раньше — прошлые задачи.
      .._offset = _lengthOf(session.transcriptPath)
      .._carry = const []
      .._findTaskStart = false;
  }

  /// Дочитывает файлы переписки: название сессии и токены текущей задачи.
  /// [where] — только эти сессии. Возвращает, изменилось ли что-нибудь.
  Future<bool> readTranscripts({bool Function(CodeSession)? where}) async {
    var changed = false;
    for (final session in _sessions.values.toList()) {
      if (session.transcriptPath.isEmpty) continue;
      if (where != null && !where(session)) continue;
      final nameBefore = session.name;
      final tokensBefore = session.tokens;
      await _scanTitle(session);
      if (session._findTaskStart) await _findStart(session);
      await _readNew(session);
      changed |= session.name != nameBefore || session.tokens != tokensBefore;
    }
    return changed;
  }

  /// Убирает сессии закрытых профилей и давно выполненные задачи.
  bool prune({required Set<String> runningProfileIds, required DateTime now}) {
    final before = _sessions.length;
    _sessions.removeWhere(
      (_, session) =>
          !runningProfileIds.contains(session.profileId) ||
          ((session.state == CodeSessionState.done ||
                  session.state == CodeSessionState.unknown) &&
              now.difference(session.updatedAt) > doneLifetime),
    );
    return _sessions.length != before;
  }

  /// Название есть в строках `custom-title` / `ai-title`; они повторяются по всему
  /// файлу, поэтому при первом знакомстве с сессией достаточно конца файла.
  Future<void> _scanTitle(CodeSession session) async {
    if (session._titleScanned) return;
    session._titleScanned = true;
    for (final line in await _tailLines(session.transcriptPath)) {
      _applyTitle(session, line);
    }
  }

  /// Название сессии по её переписке [transcriptPath] — для сессий, которые
  /// не показываются на карточке (например, из терминала без открытого Claude).
  static Future<String?> titleOf(String transcriptPath) async {
    final session = CodeSession(id: '', profileId: '', startedAt: DateTime(0));
    try {
      for (final line in await _tailLines(transcriptPath)) {
        _applyTitle(session, line);
      }
    } on FileSystemException {
      return null;
    }
    return session._customTitle ?? session._aiTitle;
  }

  static Future<Iterable<Map<String, Object?>>> _tailLines(String path) async {
    if (path.isEmpty) return const [];
    final file = File(path);
    if (!await file.exists()) return const [];
    final length = await file.length();
    final from = max(0, length - 512 * 1024);
    return _lines(await _readRange(file, from, length));
  }

  /// Сколько с конца переписки просматривать в поисках начала задачи:
  /// сначала немного, потом больше — ответы инструментов бывают большими.
  static const _taskSearchSizes = [
    256 * 1024,
    4 * 1024 * 1024,
    16 * 1024 * 1024,
  ];

  /// Начало текущей задачи — последнее сообщение пользователя в переписке.
  /// С него считаем время и токены, как если бы видели задачу с начала.
  Future<void> _findStart(CodeSession session) async {
    session._findTaskStart = false;
    if (session.state == CodeSessionState.done) return;
    final file = File(session.transcriptPath);
    if (!await file.exists()) return;
    final length = await file.length();
    for (final size in _taskSearchSizes) {
      final from = max(0, length - size);
      final bytes = await _readRange(file, from, length);
      // С конца: строка за строкой, пока не встретим сообщение пользователя.
      var end = bytes.lastIndexOf(0x0A);
      while (end > 0) {
        final start = bytes.lastIndexOf(0x0A, end - 1) + 1;
        // Первая строка куска может быть обрезана — возьмём кусок побольше.
        if (start == 0 && from > 0) break;
        final line = _lines(bytes.sublist(start, end)).firstOrNull;
        if (line != null && _isPrompt(line)) {
          final time = DateTime.tryParse(line['timestamp'] as String? ?? '');
          session
            ..startedAt = time?.toLocal() ?? session.startedAt
            .._resetTokens()
            .._offset = from + end + 1
            .._carry = const [];
          return;
        }
        end = start - 1;
      }
      if (from == 0) return;
    }
  }

  static void _restartAt(CodeSession session, Map<String, Object?> line) {
    final time = DateTime.tryParse(line['timestamp'] as String? ?? '');
    if (time != null) session.startedAt = time.toLocal();
    session._resetTokens();
  }

  /// Сообщение пользователя, с которого начинается задача: текст, а не
  /// результат инструмента. Сообщения, отправленные во время работы, пишутся
  /// в переписку иначе (`queue-operation`, `queued_command`) — задачу они не
  /// начинают. Не начинают её и отметка о прерывании, и пересказ разговора
  /// после сжатия контекста.
  static bool _isPrompt(Map<String, Object?> line) {
    if (line['type'] != 'user' ||
        line['isMeta'] == true ||
        line['isSidechain'] == true ||
        line['isCompactSummary'] == true) {
      return false;
    }
    final message = line['message'];
    if (message is! Map) return false;
    final content = message['content'];
    if (content is String) return _isPromptText(content);
    if (content is! List) return false;
    var hasText = false;
    for (final block in content) {
      if (block is! Map) continue;
      if (block['type'] == 'tool_result') return false;
      if (block['type'] == 'text' && _isPromptText(block['text'])) {
        hasText = true;
      }
    }
    return hasText;
  }

  static bool _isPromptText(Object? text) {
    if (text is! String) return false;
    final trimmed = text.trim();
    return trimmed.isNotEmpty &&
        !trimmed.startsWith('[Request interrupted by user');
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
      // Новое сообщение пользователя — новая задача. Хуки об этом сообщают не
      // всегда: после прерывания задача для них так и не закончилась.
      if (_isPrompt(line)) _restartAt(session, line);
      _applyAnswer(session, line);
    }
    session.tokens = _countTokens(session);
  }

  /// Как Claude Code: ответ модели — не меньше его `output_tokens`, а пока их
  /// нет — по длине записанного (символы / 4).
  static int _countTokens(CodeSession session) {
    final chars = <String, int>{};
    for (final line in session._answerLines.values) {
      chars[line.message] = (chars[line.message] ?? 0) + line.chars;
    }
    var total = 0.0;
    for (final MapEntry(key: message, value: count) in chars.entries) {
      total += max(count / 4, session._outputTokens[message] ?? 0);
    }
    return total.round();
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

  /// Ответ записывается по строке на блок: текст, рассуждения (если их видно),
  /// вызов инструмента; в каждой строке — `usage` всего ответа. Строки
  /// субагентов — не ответ самой сессии: их Claude Code в своё число не берёт.
  static void _applyAnswer(CodeSession session, Map<String, Object?> line) {
    if (line['type'] != 'assistant' || line['isSidechain'] == true) return;
    final message = line['message'];
    if (message is! Map) return;
    final content = message['content'];
    if (content is! List) return;
    var chars = 0;
    for (final block in content) {
      if (block is! Map) continue;
      chars += switch (block['type']) {
        'text' => (block['text'] as String? ?? '').length,
        'thinking' => (block['thinking'] as String? ?? '').length,
        'tool_use' => jsonEncode(block['input'] ?? const {}).length,
        _ => 0,
      };
    }
    // Если строку перезапишут, по uuid она не посчитается дважды.
    final key = line['uuid'] as String? ?? '#${session._answerLines.length}';
    final id = message['id'] as String? ?? key;
    session._answerLines[key] = (message: id, chars: chars);
    if (message['usage'] case {'output_tokens': final int output}) {
      session._outputTokens[id] = max(session._outputTokens[id] ?? 0, output);
    }
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
