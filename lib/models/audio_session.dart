import 'package:flutter/foundation.dart';

enum SessionDirection { output, input }

@immutable
class AudioSession {
  const AudioSession({
    required this.sessionId,
    required this.displayName,
    required this.processId,
    required this.direction,
    required this.volume,
    required this.isMuted,
    required this.iconPath,
    required this.deviceId,
  });

  final String sessionId;
  final String displayName;
  final int processId;
  final SessionDirection direction;
  final double volume;
  final bool isMuted;
  final String iconPath;
  final String deviceId;

  AudioSession copyWith({
    double? volume,
    bool? isMuted,
    String? deviceId,
  }) {
    return AudioSession(
      sessionId: sessionId,
      displayName: displayName,
      processId: processId,
      direction: direction,
      volume: volume ?? this.volume,
      isMuted: isMuted ?? this.isMuted,
      iconPath: iconPath,
      deviceId: deviceId ?? this.deviceId,
    );
  }
}
