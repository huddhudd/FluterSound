import 'package:flutter/foundation.dart';

enum AudioDeviceType { playback, recording }

enum AudioRole { console, multimedia, communications }

@immutable
class AudioDevice {
  const AudioDevice({
    required this.id,
    required this.name,
    required this.type,
    required this.isDefault,
    required this.volume,
    required this.isMuted,
  });

  final String id;
  final String name;
  final AudioDeviceType type;
  final bool isDefault;
  final double volume;
  final bool isMuted;

  AudioDevice copyWith({
    String? id,
    String? name,
    AudioDeviceType? type,
    bool? isDefault,
    double? volume,
    bool? isMuted,
  }) {
    return AudioDevice(
      id: id ?? this.id,
      name: name ?? this.name,
      type: type ?? this.type,
      isDefault: isDefault ?? this.isDefault,
      volume: volume ?? this.volume,
      isMuted: isMuted ?? this.isMuted,
    );
  }
}
