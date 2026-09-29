import 'dart:convert';
import 'dart:io';

import 'profile.dart';

/// Хранит профили в JSON-файле в папке настроек лаунчера.
class ProfileStore {
  ProfileStore(this.file);

  final File file;

  Future<List<Profile>> load() async {
    if (!await file.exists()) return [];
    final json = jsonDecode(await file.readAsString()) as Map<String, Object?>;
    final items = (json['profiles'] as List<Object?>? ?? const []);
    return [
      for (final item in items) Profile.fromJson(item as Map<String, Object?>),
    ];
  }

  Future<void> save(List<Profile> profiles) async {
    await file.parent.create(recursive: true);
    final json = const JsonEncoder.withIndent('  ').convert({
      'version': 1,
      'profiles': [for (final profile in profiles) profile.toJson()],
    });
    // Пишем во временный файл и переименовываем, чтобы не оставить полузаписанный JSON.
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(json, flush: true);
    await tmp.rename(file.path);
  }
}
