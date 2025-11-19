import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'models/audio_device.dart';
import 'models/audio_session.dart';
import 'services/windows_audio_service.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const SoundManagerApp());
}

class SoundManagerApp extends StatelessWidget {
  const SoundManagerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider(
      create: (_) => AudioViewModel(const WindowsAudioService())..initialize(),
      child: MaterialApp(
        title: 'FluterSound',
        theme: ThemeData(useMaterial3: true, colorSchemeSeed: Colors.blueGrey),
        home: const DefaultTabController(length: 3, child: AudioHomePage()),
      ),
    );
  }
}

class AudioHomePage extends StatelessWidget {
  const AudioHomePage({super.key});

  @override
  Widget build(BuildContext context) {
    final viewModel = context.watch<AudioViewModel>();
    return Scaffold(
      appBar: AppBar(
        title: const Text('音频设备控制'),
        actions: [
          IconButton(
            onPressed: viewModel.refreshing ? null : () => viewModel.initialize(force: true),
            icon: const Icon(Icons.refresh),
            tooltip: '刷新',
          ),
        ],
        bottom: const TabBar(
          tabs: [
            Tab(text: '播放设备'),
            Tab(text: '录音设备'),
            Tab(text: '程序音量'),
          ],
        ),
      ),
      body: TabBarView(
        children: [
          DeviceList(
            devices: viewModel.playbackDevices,
            onSetDefault: viewModel.setDefaultDevice,
            onVolumeChange: viewModel.setDeviceVolume,
          ),
          DeviceList(
            devices: viewModel.recordingDevices,
            onSetDefault: viewModel.setDefaultDevice,
            onVolumeChange: viewModel.setDeviceVolume,
          ),
          SessionList(
            sessions: viewModel.sessions,
            playbackDevices: viewModel.playbackDevices,
            recordingDevices: viewModel.recordingDevices,
            onVolumeChange: viewModel.setSessionVolume,
            onMuteToggle: viewModel.setSessionMute,
            onDeviceChange: viewModel.setSessionDevice,
          ),
        ],
      ),
    );
  }
}

class DeviceList extends StatelessWidget {
  const DeviceList({
    super.key,
    required this.devices,
    required this.onSetDefault,
    required this.onVolumeChange,
  });

  final List<AudioDevice> devices;
  final void Function(AudioDevice device) onSetDefault;
  final void Function(AudioDevice device, double value, {bool? mute}) onVolumeChange;

  @override
  Widget build(BuildContext context) {
    if (devices.isEmpty) {
      return const Center(child: Text('暂无设备'));
    }
    return ListView.separated(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      itemBuilder: (context, index) {
        final device = devices[index];
        return Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        device.name,
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    ),
                    if (device.isDefault)
                      const Chip(label: Text('默认'), backgroundColor: Colors.greenAccent),
                    IconButton(
                      onPressed: () => onSetDefault(device),
                      icon: const Icon(Icons.check_circle_outline),
                      tooltip: '设为默认',
                    ),
                  ],
                ),
                Row(
                  children: [
                    const Icon(Icons.volume_up),
                    Expanded(
                      child: Slider(
                        value: device.volume,
                        onChanged: (v) => onVolumeChange(device, v),
                      ),
                    ),
                    Switch(
                      value: device.isMuted,
                      onChanged: (v) => onVolumeChange(device, device.volume, mute: v),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
      separatorBuilder: (_, __) => const SizedBox(height: 8),
      itemCount: devices.length,
    );
  }
}

class SessionList extends StatelessWidget {
  const SessionList({
    super.key,
    required this.sessions,
    required this.playbackDevices,
    required this.recordingDevices,
    required this.onVolumeChange,
    required this.onMuteToggle,
    required this.onDeviceChange,
  });

  final List<AudioSession> sessions;
  final List<AudioDevice> playbackDevices;
  final List<AudioDevice> recordingDevices;
  final void Function(AudioSession session, double volume) onVolumeChange;
  final void Function(AudioSession session, bool mute) onMuteToggle;
  final void Function(AudioSession session, AudioDevice device) onDeviceChange;

  @override
  Widget build(BuildContext context) {
    if (sessions.isEmpty) {
      return const Center(child: Text('暂无会话'));
    }
    return ListView.builder(
      padding: const EdgeInsets.all(12),
      itemBuilder: (context, index) {
        final session = sessions[index];
        final devices = session.direction == SessionDirection.output ? playbackDevices : recordingDevices;
        return Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(session.displayName, style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 4),
                Text('PID: ${session.processId}'),
                Row(
                  children: [
                    const Icon(Icons.volume_down),
                    Expanded(
                      child: Slider(
                        value: session.volume,
                        onChanged: (v) => onVolumeChange(session, v),
                      ),
                    ),
                    Switch(
                      value: session.isMuted,
                      onChanged: (v) => onMuteToggle(session, v),
                    ),
                  ],
                ),
                DropdownButton<String>(
                  value: devices.any((d) => d.id == session.deviceId) ? session.deviceId : null,
                  hint: const Text('指定设备'),
                  isExpanded: true,
                  items: devices
                      .map(
                        (device) => DropdownMenuItem(
                          value: device.id,
                          child: Text(device.name),
                        ),
                      )
                      .toList(),
                  onChanged: (value) {
                    if (value == null) {
                      return;
                    }
                    final selected = devices.firstWhere((d) => d.id == value);
                    onDeviceChange(session, selected);
                  },
                ),
              ],
            ),
          ),
        );
      },
      itemCount: sessions.length,
    );
  }
}

class AudioViewModel extends ChangeNotifier {
  AudioViewModel(this._service);

  final WindowsAudioService _service;
  bool refreshing = false;
  List<AudioDevice> playbackDevices = [];
  List<AudioDevice> recordingDevices = [];
  List<AudioSession> sessions = [];

  Future<void> initialize({bool force = false}) async {
    if (refreshing && !force) {
      return;
    }
    refreshing = true;
    notifyListeners();
    try {
      final playback = await _service.enumerateDevices(AudioDeviceType.playback);
      final recording = await _service.enumerateDevices(AudioDeviceType.recording);
      final sessionOutput = await _service.enumerateSessions(SessionDirection.output);
      final sessionInput = await _service.enumerateSessions(SessionDirection.input);
      playbackDevices = playback;
      recordingDevices = recording;
      sessions = [...sessionOutput, ...sessionInput];
    } finally {
      refreshing = false;
      notifyListeners();
    }
  }

  void setDefaultDevice(AudioDevice device) {
    _runAsync(() async {
      await _service.setDefaultDevice(device.id, AudioRole.multimedia);
      await initialize(force: true);
    });
  }

  void setDeviceVolume(AudioDevice device, double value, {bool? mute}) {
    _patchDevice(device, volume: value, mute: mute);
    _runAsync(() async {
      await _service.setDeviceVolume(device.id, value, mute: mute);
      await initialize(force: true);
    });
  }

  void setSessionVolume(AudioSession session, double volume) {
    _patchSession(session, volume: volume);
    _runAsync(() async {
      await _service.setSessionVolume(session.sessionId, volume);
      await initialize(force: true);
    });
  }

  void setSessionMute(AudioSession session, bool mute) {
    _patchSession(session, mute: mute);
    _runAsync(() async {
      await _service.setSessionVolume(session.sessionId, session.volume, mute: mute);
      await initialize(force: true);
    });
  }

  void setSessionDevice(AudioSession session, AudioDevice device) {
    _patchSession(session, deviceId: device.id);
    _runAsync(() async {
      await _service.setSessionDevice(session.sessionId, device.id, session.direction);
      await initialize(force: true);
    });
  }

  void _patchDevice(AudioDevice device, {double? volume, bool? mute}) {
    final target = device.type == AudioDeviceType.playback ? playbackDevices : recordingDevices;
    final updated = target
        .map(
          (d) => d.id == device.id
              ? d.copyWith(
                  volume: volume ?? d.volume,
                  isMuted: mute ?? d.isMuted,
                )
              : d,
        )
        .toList();
    if (device.type == AudioDeviceType.playback) {
      playbackDevices = updated;
    } else {
      recordingDevices = updated;
    }
    notifyListeners();
  }

  void _patchSession(AudioSession session, {double? volume, bool? mute, String? deviceId}) {
    sessions = sessions
        .map(
          (s) => s.sessionId == session.sessionId
              ? s.copyWith(
                  volume: volume ?? s.volume,
                  isMuted: mute ?? s.isMuted,
                  deviceId: deviceId ?? s.deviceId,
                )
              : s,
        )
        .toList();
    notifyListeners();
  }

  void _runAsync(Future<void> Function() action) {
    action();
  }
}
