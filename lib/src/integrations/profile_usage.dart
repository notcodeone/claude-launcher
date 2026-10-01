import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// Проценты из истории самого Claude, а не оценка по токенам сессий.
class UsageLimit {
  const UsageLimit({
    required this.label,
    required this.usedPercent,
    this.resetDescription,
  });

  final String label;
  final double usedPercent;

  /// Время сброса, показанное самим Claude. Из истории его не вычисляем.
  final String? resetDescription;

  double get remainingPercent => (100 - usedPercent).clamp(0, 100);
}

class ProfileUsage {
  const ProfileUsage({required this.updatedAt, required this.limits});

  final DateTime updatedAt;
  final List<UsageLimit> limits;
  bool isStale(DateTime now) =>
      now.difference(updatedAt) > const Duration(minutes: 15);

  /// Claude хранит только использованные проценты, без времени сброса.
  /// Берём один последний снимок целиком: не смешиваем организации и периоды.
  static ProfileUsage? fromHistory(Object? json) {
    if (json is! Map || !const [1, 2].contains(json['version'])) {
      throw const FormatException('Неизвестный формат истории лимитов');
    }
    final samples = json['samples'];
    if (samples is! List) {
      throw const FormatException('Нет истории лимитов');
    }
    Map? latest;
    for (final sample in samples) {
      if (sample is! Map || sample['t'] is! num) continue;
      final timestamp = sample['t'] as num;
      if (!timestamp.isFinite ||
          timestamp <= 0 ||
          timestamp > 8640000000000000) {
        continue;
      }
      if (latest == null || timestamp > (latest['t'] as num)) latest = sample;
    }
    if (latest == null) return null;
    final values = json['version'] == 1 ? latest : latest['u'];
    if (values is! Map) {
      throw const FormatException('Нет значений лимитов');
    }
    const labels = {
      'fh': 'За 5 часов',
      'sd': 'За неделю · все модели',
      'so': 'За неделю · Opus',
      'sn': 'За неделю · Sonnet',
      'oa': 'За неделю · приложения',
      'cw': 'За неделю · Cowork',
      'om': 'За неделю · Claude Design',
      'op': 'Бонус · Claude Design',
      'xu': 'Дополнительное использование',
    };
    final limits = <UsageLimit>[];
    for (final entry in labels.entries) {
      final value = values[entry.key];
      if (value is num && value.isFinite && value >= 0) {
        limits.add(
          UsageLimit(label: entry.value, usedPercent: value.toDouble()),
        );
      }
    }
    if (limits.isEmpty) return null;
    return ProfileUsage(
      updatedAt: DateTime.fromMillisecondsSinceEpoch(
        (latest['t'] as num).toInt(),
      ),
      limits: limits,
    );
  }
}

/// Читает только папки выбранного профиля. Не использует общий вход CLI,
/// не читает cookies и не меняет файлы Claude.
class ProfileUsageReader {
  const ProfileUsageReader();

  Future<ProfileUsage?> read(List<String> dataDirs) async {
    ProfileUsage? latest;
    Object? failure;
    for (final dir in dataDirs) {
      final file = File(p.join(dir, 'plan-usage-history.json'));
      try {
        if (!await file.exists()) continue;
        final usage = ProfileUsage.fromHistory(
          jsonDecode(await file.readAsString()),
        );
        if (usage != null &&
            (latest == null || usage.updatedAt.isAfter(latest.updatedAt))) {
          latest = usage;
        }
      } on FormatException catch (error) {
        failure = error;
      } on FileSystemException catch (error) {
        failure = error;
      }
    }
    if (latest == null && failure != null) throw failure;
    return latest;
  }
}
