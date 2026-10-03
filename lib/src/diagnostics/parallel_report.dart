import 'dart:convert';
import 'dart:io';

import '../app_settings.dart';
import '../integrations/claude_code_sessions.dart';
import '../launcher_controller.dart';
import '../location/egress_config.dart';
import '../location/kill_switch.dart';

/// Explicit, local report. Only allowlisted counts, flags and process IDs leave
/// this function; no names, profile/session IDs, paths, errors or account data.
Future<String> parallelReport({
  required String version,
  required LauncherController launcher,
  required AppSettings settings,
  required Iterable<CodeSession> sessions,
  KillSwitch? killSwitch,
  EgressConfig config = const EgressConfig(),
}) async {
  var scanOk = true;
  try {
    await launcher.refresh(strict: true).timeout(const Duration(seconds: 10));
  } catch (_) {
    scanOk = false;
  }
  final profiles = List.of(launcher.profiles);
  final instances = scanOk ? List.of(launcher.instances) : null;
  // Capture states before awaiting filesystem checks.
  final states = [for (final s in sessions) (s.profileId, s.state.name)];
  final port = killSwitch?.gate.port ?? settings.egressPort;
  final rows = <Map<String, Object?>>[];
  for (final (index, profile) in profiles.indexed) {
    bool? matches;
    try {
      matches = await config
          .isPinned(launcher.dataDirOf(profile), port: port)
          .timeout(const Duration(seconds: 2));
    } catch (_) {
      // Preserve unknown; do not export exception text with paths.
    }
    final pids = instances == null
        ? null
        : [
            for (final instance in instances)
              if (launcher.host.samePath(
                launcher.host.dataDirOf(instance),
                launcher.dataDirOf(profile),
              ))
                instance.pid,
          ];
    final counts = <String, int>{};
    for (final (profileId, state) in states) {
      if (profileId == profile.id) {
        counts.update(state, (n) => n + 1, ifAbsent: () => 1);
      }
    }
    rows.add({
      'slot': index + 1,
      'defaultFolder': profile.usesDefaultFolder,
      'startupSelected': settings.startsProfile(profile.id),
      'pids': pids,
      'duplicateProcesses': pids == null ? null : pids.length > 1,
      'codeSessionCounts': counts,
      'proxyConfigMatchesGate': matches,
    });
  }
  return const JsonEncoder.withIndent('  ').convert({
    'schema': 1,
    'launcherVersion': version,
    'platform': Platform.operatingSystem,
    'parallelEnabled': settings.parallelLaunch,
    'processScan': scanOk ? 'ok' : 'failed',
    'runningCount': instances?.length,
    'unknownProcessCount': instances
        ?.where(
          (i) => !profiles.any(
            (p) => launcher.host.samePath(
              launcher.dataDirOf(p),
              launcher.host.dataDirOf(i),
            ),
          ),
        )
        .length,
    'targetedLinks': launcher.host.supportsTargetedLinks,
    'codeEventsEnabled': settings.claudeCodeEvents,
    'killSwitchEnabled': settings.killSwitch,
    'gateListening': killSwitch?.gate.port != null,
    'gateOpen': killSwitch?.open ?? false,
    'restartRequired': killSwitch?.needsRestart ?? false,
    'profiles': rows,
    'runtimeTrafficVerification': 'not_performed',
    'coworkCompatibility': 'unverified',
  });
}
