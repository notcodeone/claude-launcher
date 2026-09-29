/// Профиль — одна папка данных Claude (а значит, один вход в аккаунт).
class Profile {
  const Profile({
    required this.id,
    required this.name,
    this.email = '',
    this.note = '',
    this.marker = defaultMarker,
    this.folderName,
    this.lastLaunchedAt,
  });

  /// Цветные метки: видны и в меню трея, и в строке меню macOS.
  static const markers = ['🟢', '🔵', '🟣', '🔴', '🟠', '🟡', '🟤', '⚫', '⚪'];
  static const defaultMarker = '🟢';

  final String id;
  final String name;
  final String email;
  final String note;
  final String marker;

  /// Имя папки данных рядом со стандартной папкой Claude.
  /// `null` — стандартная папка самого Claude (обычный запуск приложения).
  final String? folderName;

  /// Когда профиль запускали через лаунчер; `null` — ни разу (нужен первый вход).
  final DateTime? lastLaunchedAt;

  bool get usesDefaultFolder => folderName == null;

  String get title => '$marker $name';

  Profile copyWith({
    String? name,
    String? email,
    String? note,
    String? marker,
    DateTime? lastLaunchedAt,
  }) {
    return Profile(
      id: id,
      name: name ?? this.name,
      email: email ?? this.email,
      note: note ?? this.note,
      marker: marker ?? this.marker,
      folderName: folderName,
      lastLaunchedAt: lastLaunchedAt ?? this.lastLaunchedAt,
    );
  }

  Map<String, Object?> toJson() => {
        'id': id,
        'name': name,
        'email': email,
        'note': note,
        'marker': marker,
        'folderName': folderName,
        'lastLaunchedAt': lastLaunchedAt?.toIso8601String(),
      };

  factory Profile.fromJson(Map<String, Object?> json) {
    final lastLaunched = json['lastLaunchedAt'] as String?;
    return Profile(
      id: json['id'] as String,
      name: json['name'] as String,
      email: json['email'] as String? ?? '',
      note: json['note'] as String? ?? '',
      marker: json['marker'] as String? ?? defaultMarker,
      folderName: json['folderName'] as String?,
      lastLaunchedAt: lastLaunched == null ? null : DateTime.parse(lastLaunched),
    );
  }
}

const _translit = {
  'а': 'a', 'б': 'b', 'в': 'v', 'г': 'g', 'д': 'd', 'е': 'e', 'ё': 'e',
  'ж': 'zh', 'з': 'z', 'и': 'i', 'й': 'y', 'к': 'k', 'л': 'l', 'м': 'm',
  'н': 'n', 'о': 'o', 'п': 'p', 'р': 'r', 'с': 's', 'т': 't', 'у': 'u',
  'ф': 'f', 'х': 'h', 'ц': 'ts', 'ч': 'ch', 'ш': 'sh', 'щ': 'sch', 'ъ': '',
  'ы': 'y', 'ь': '', 'э': 'e', 'ю': 'yu', 'я': 'ya',
};

/// Имя папки для нового профиля: `Claude-<латиница из имени>`, уникальное среди [taken].
///
/// Только латиница и цифры: на Windows папка попадает в пути виртуальной машины Cowork,
/// там не-ASCII символы лучше не рисковать.
String folderNameFor(String profileName, Iterable<String> taken) {
  final buffer = StringBuffer();
  for (final rune in profileName.toLowerCase().runes) {
    final char = String.fromCharCode(rune);
    final mapped = _translit[char] ?? char;
    buffer.write(RegExp(r'^[a-z0-9]+$').hasMatch(mapped) ? mapped : '-');
  }
  var slug = buffer.toString().replaceAll(RegExp('-+'), '-');
  slug = slug.replaceAll(RegExp(r'^-|-$'), '');
  if (slug.isEmpty) slug = 'profile';
  final base = 'Claude-${slug[0].toUpperCase()}${slug.substring(1)}';

  final takenLower = {for (final name in taken) name.toLowerCase(), 'claude'};
  var candidate = base;
  for (var i = 2; takenLower.contains(candidate.toLowerCase()); i++) {
    candidate = '$base-$i';
  }
  return candidate;
}
