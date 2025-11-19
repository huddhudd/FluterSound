import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';

import '../models/audio_device.dart';
import '../models/audio_session.dart';

const _clsidMMDeviceEnumerator = '{BCDE0395-E52F-467C-8E3D-C4579291692E}';
const _iidIMMDeviceEnumerator = '{A95664D2-9614-4F35-A746-DE8DB63617E6}';
const _iidIAudioEndpointVolume = '{5CDF2C82-841E-4546-9722-0CF74078229A}';
const _iidIAudioSessionManager2 = '{77AA99A0-1BD6-484F-8BC7-2C654C9A9B6F}';
const _iidIAudioSessionEnumerator = '{E2F5BB11-0570-40CA-ACDD-3AA01277DEE8}';
const _iidIAudioSessionControl2 = '{BFB7FF88-7239-4FC9-8FA2-07C950BE9C6D}';
const _iidISimpleAudioVolume = '{87CE5498-68D6-44E5-9215-6DA47EF883D8}';
const _clsidPolicyConfig = '{870AF99C-171D-4F9E-AF0D-E63DF40C2BC9}';
const _iidIPolicyConfig = '{F8679F50-850A-41CF-9C72-430F290290C8}';
const _clsidAudioPolicyConfigFactory = '{294935CE-F637-4E7C-A41B-AB255460B862}';
const _iidIAudioPolicyConfigFactory = '{CB3AB3A0-52DD-488D-96E8-DA4DD253C4F0}';

const PROPERTYKEY _pkeyDeviceFriendlyName = PROPERTYKEY(
  GUID(0xA45C254E, 0xDF1C, 0x4EFD, [0x80, 0x20, 0x67, 0xD1, 0x46, 0xA8, 0x50, 0xE0]),
  14,
);

class WindowsAudioService {
  const WindowsAudioService();

  bool get isSupported => Platform.isWindows;

  Future<List<AudioDevice>> enumerateDevices(AudioDeviceType type) async {
    _ensureWindows();
    return _runCom<List<AudioDevice>>(() {
      final enumerator = _createEnumerator();
      final devices = <AudioDevice>[];
      final collectionPtr = calloc<Pointer<COMObject>>();
      final flow = type == AudioDeviceType.playback ? EDataFlow.eRender : EDataFlow.eCapture;
      final hr = enumerator.EnumAudioEndpoints(flow, DEVICE_STATE_ACTIVE, collectionPtr);
      _throwIfFailed(hr, 'EnumAudioEndpoints failed');
      final collection = IMMDeviceCollection(collectionPtr.value);
      final countPtr = calloc<Uint32>();
      _throwIfFailed(collection.GetCount(countPtr), 'GetCount failed');
      final count = countPtr.value;
      for (var i = 0; i < count; i++) {
        final devicePtr = calloc<Pointer<COMObject>>();
        final hrGet = collection.Item(i, devicePtr);
        if (FAILED(hrGet)) {
          calloc.free(devicePtr);
          continue;
        }
        final device = IMMDevice(devicePtr.value);
        final id = _getDeviceId(device);
        final name = _getDeviceName(device);
        final isDefault = _isDefaultDevice(device, flow);
        final volume = _getEndpointVolume(device);
        devices.add(AudioDevice(
          id: id,
          name: name,
          type: type,
          isDefault: isDefault,
          volume: volume.$1,
          isMuted: volume.$2,
        ));
        device.Release();
        calloc.free(devicePtr);
      }
        enumerator.Release();
        collection.Release();
        calloc.free(collectionPtr);
        calloc.free(countPtr);
      return devices;
    });
  }

  Future<void> setDefaultDevice(String deviceId, AudioRole role) async {
    _ensureWindows();
    return _runCom<void>(() {
      final policy = _createPolicyConfig();
      final deviceIdPtr = deviceId.toNativeUtf16();
      final hr = policy.SetDefaultEndpoint(deviceIdPtr, _roleToNative(role));
      calloc.free(deviceIdPtr);
      policy.Release();
      _throwIfFailed(hr, 'SetDefaultEndpoint failed');
    });
  }

  Future<void> setDeviceVolume(String deviceId, double value, {bool? mute}) async {
    _ensureWindows();
    return _runCom<void>(() {
      final enumerator = _createEnumerator();
      final devicePtr = calloc<Pointer<COMObject>>();
      final idPtr = deviceId.toNativeUtf16();
      final hrDevice = enumerator.GetDevice(idPtr, devicePtr);
      calloc.free(idPtr);
      _throwIfFailed(hrDevice, 'GetDevice failed');
      final device = IMMDevice(devicePtr.value);
      final endpoint = _activateEndpointVolume(device);
      final volume = value.clamp(0, 1);
      _throwIfFailed(endpoint.SetMasterVolumeLevelScalar(volume, nullptr), 'SetMasterVolumeLevelScalar failed');
      if (mute != null) {
        _throwIfFailed(endpoint.SetMute(mute ? 1 : 0, nullptr), 'SetMute failed');
      }
      endpoint.Release();
      device.Release();
      calloc.free(devicePtr);
      enumerator.Release();
    });
  }

  Future<List<AudioSession>> enumerateSessions(SessionDirection direction) async {
    _ensureWindows();
    return _runCom<List<AudioSession>>(() {
      final enumerator = _createEnumerator();
      final flow = direction == SessionDirection.output ? EDataFlow.eRender : EDataFlow.eCapture;
      final defaultDevicePtr = calloc<Pointer<COMObject>>();
      _throwIfFailed(
        enumerator.GetDefaultAudioEndpoint(flow, ERole.eMultimedia, defaultDevicePtr),
        'GetDefaultAudioEndpoint failed',
      );
      final device = IMMDevice(defaultDevicePtr.value);
      final sessions = _loadSessions(device, direction);
        device.Release();
        enumerator.Release();
        calloc.free(defaultDevicePtr);
      return sessions;
    });
  }

  Future<void> setSessionVolume(String sessionId, double volume, {bool? mute}) async {
    _ensureWindows();
    return _runCom<void>(() {
      final session = _resolveSession(sessionId);
      if (session == null) {
        throw StateError('session not found: $sessionId');
      }
      final control = session.$1;
      final simpleVolume = session.$2;
      try {
        _throwIfFailed(simpleVolume.SetMasterVolume(volume.clamp(0, 1), nullptr), 'SetMasterVolume failed');
        if (mute != null) {
          _throwIfFailed(simpleVolume.SetMute(mute ? 1 : 0, nullptr), 'SetMute failed');
        }
      } finally {
        simpleVolume.Release();
        control.Release();
      }
    });
  }

  Future<void> setSessionDevice(String sessionId, String deviceId, SessionDirection direction) async {
    _ensureWindows();
    return _runCom<void>(() {
      final session = _resolveSession(sessionId);
      if (session == null) {
        throw StateError('session not found: $sessionId');
      }
      final policy = _createAudioPolicyFactory();
      final pid = session.$3;
      final devPtr = deviceId.toNativeUtf16();
      final flow = direction == SessionDirection.output ? EDataFlow.eRender : EDataFlow.eCapture;
      try {
        final hr = policy.SetPersistedDefaultAudioEndpoint(pid, flow, ERole.eMultimedia, devPtr);
        _throwIfFailed(hr, 'SetPersistedDefaultAudioEndpoint failed');
      } finally {
        calloc.free(devPtr);
        policy.Release();
        session.$2.Release();
        session.$1.Release();
      }
    });
  }

  Future<void> refreshSystemDefault(SessionDirection direction, String deviceId) async {
    final role = AudioRole.multimedia;
    if (direction == SessionDirection.output) {
      return setDefaultDevice(deviceId, role);
    }
    return setDefaultDevice(deviceId, role);
  }

  IMMDeviceEnumerator _createEnumerator() {
    final clsid = GUID.fromString(_clsidMMDeviceEnumerator);
    final iid = GUID.fromString(_iidIMMDeviceEnumerator);
    final ptr = calloc<COMObject>();
    final hr = CoCreateInstance(
      clsid.addressOf,
      nullptr,
      CLSCTX_ALL,
      iid.addressOf,
      ptr.cast(),
    );
    _throwIfFailed(hr, 'CoCreateInstance IMMDeviceEnumerator failed');
    return IMMDeviceEnumerator(ptr);
  }

  IPolicyConfig _createPolicyConfig() {
    final clsid = GUID.fromString(_clsidPolicyConfig);
    final iid = GUID.fromString(_iidIPolicyConfig);
    final ptr = calloc<COMObject>();
    final hr = CoCreateInstance(clsid.addressOf, nullptr, CLSCTX_ALL, iid.addressOf, ptr.cast());
    _throwIfFailed(hr, 'CoCreateInstance IPolicyConfig failed');
    return IPolicyConfig(ptr);
  }

  IAudioPolicyConfigFactory _createAudioPolicyFactory() {
    final clsid = GUID.fromString(_clsidAudioPolicyConfigFactory);
    final iid = GUID.fromString(_iidIAudioPolicyConfigFactory);
    final ptr = calloc<COMObject>();
    final hr = CoCreateInstance(clsid.addressOf, nullptr, CLSCTX_ALL, iid.addressOf, ptr.cast());
    _throwIfFailed(hr, 'CoCreateInstance IAudioPolicyConfigFactory failed');
    return IAudioPolicyConfigFactory(ptr);
  }

  List<AudioSession> _loadSessions(IMMDevice device, SessionDirection direction) {
    final sessions = <AudioSession>[];
    final managerPtr = calloc<Pointer<COMObject>>();
    final hr = device.Activate(
      GUID.fromString(_iidIAudioSessionManager2).addressOf,
      CLSCTX_ALL,
      nullptr,
      managerPtr,
    );
    if (FAILED(hr)) {
      calloc.free(managerPtr);
      _throwIfFailed(hr, 'Activate IAudioSessionManager2 failed');
    }
    final manager = IAudioSessionManager2(managerPtr.value);
    calloc.free(managerPtr);
    final enumeratorPtr = calloc<Pointer<COMObject>>();
    final enumHr = manager.GetSessionEnumerator(enumeratorPtr);
    if (FAILED(enumHr)) {
      calloc.free(enumeratorPtr);
      _throwIfFailed(enumHr, 'GetSessionEnumerator failed');
    }
    final enumerator = IAudioSessionEnumerator(enumeratorPtr.value);
    calloc.free(enumeratorPtr);
    final countPtr = calloc<Int32>();
    final countHr = enumerator.GetCount(countPtr);
    if (FAILED(countHr)) {
      calloc.free(countPtr);
      _throwIfFailed(countHr, 'GetCount failed');
    }
    final total = countPtr.value;
    for (var i = 0; i < total; i++) {
      final ctlPtr = calloc<Pointer<COMObject>>();
      if (FAILED(enumerator.GetSession(i, ctlPtr))) {
        calloc.free(ctlPtr);
        continue;
      }
      final control = IAudioSessionControl2(ctlPtr.value);
      calloc.free(ctlPtr);
      final sessionId = _getSessionId(control);
      final displayName = _getSessionName(control);
      final pid = _getProcessId(control);
      final simpleVolumePtr = calloc<Pointer<COMObject>>();
      if (FAILED(control.QueryInterface(GUID.fromString(_iidISimpleAudioVolume).addressOf, simpleVolumePtr.cast()))) {
        control.Release();
        calloc.free(simpleVolumePtr);
        continue;
      }
      final simpleVolume = ISimpleAudioVolume(simpleVolumePtr.value);
      calloc.free(simpleVolumePtr);
      final volPtr = calloc<Float>();
      simpleVolume.GetMasterVolume(volPtr);
      final isMutedPtr = calloc<Int32>();
      simpleVolume.GetMute(isMutedPtr);
      sessions.add(
        AudioSession(
          sessionId: sessionId,
          displayName: displayName,
          processId: pid,
          direction: direction,
          volume: volPtr.value,
          isMuted: isMutedPtr.value != 0,
          iconPath: '',
          deviceId: _getDeviceId(device),
        ),
      );
      calloc.free(volPtr);
      calloc.free(isMutedPtr);
      control.Release();
      simpleVolume.Release();
    }
    manager.Release();
    enumerator.Release();
    calloc.free(countPtr);
    return sessions;
  }

  void _throwIfFailed(int hr, String message) {
    if (FAILED(hr)) {
      throw WindowsAudioException(hr, message);
    }
  }

  String _getDeviceName(IMMDevice device) {
    final storePtr = calloc<Pointer<COMObject>>();
    _throwIfFailed(device.OpenPropertyStore(STGM_READ, storePtr), 'OpenPropertyStore failed');
    final store = IPropertyStore(storePtr.value);
    final prop = calloc<PROPVARIANT>();
    _throwIfFailed(store.GetValue(_pkeyDeviceFriendlyName, prop), 'GetValue failed');
    final name = prop.pwszVal.toDartString();
    PropVariantClear(prop);
    store.Release();
    calloc.free(prop);
    calloc.free(storePtr);
    return name;
  }

  (double, bool) _getEndpointVolume(IMMDevice device) {
    final endpoint = _activateEndpointVolume(device);
    final levelPtr = calloc<Float>();
    final mutePtr = calloc<Int32>();
    endpoint.GetMasterVolumeLevelScalar(levelPtr);
    endpoint.GetMute(mutePtr);
    final level = levelPtr.value;
    final muted = mutePtr.value != 0;
    calloc.free(levelPtr);
    calloc.free(mutePtr);
    endpoint.Release();
    return (level, muted);
  }

  IAudioEndpointVolume _activateEndpointVolume(IMMDevice device) {
    final endpointPtr = calloc<Pointer<COMObject>>();
    final hr = device.Activate(
      GUID.fromString(_iidIAudioEndpointVolume).addressOf,
      CLSCTX_ALL,
      nullptr,
      endpointPtr,
    );
    _throwIfFailed(hr, 'Activate IAudioEndpointVolume failed');
    final endpoint = IAudioEndpointVolume(endpointPtr.value);
    calloc.free(endpointPtr);
    return endpoint;
  }

  bool _isDefaultDevice(IMMDevice device, int flow) {
    final enumerator = _createEnumerator();
    final ptr = calloc<Pointer<COMObject>>();
    final hr = enumerator.GetDefaultAudioEndpoint(flow, ERole.eMultimedia, ptr);
    if (FAILED(hr)) {
      enumerator.Release();
      calloc.free(ptr);
      return false;
    }
    final defaultDevice = IMMDevice(ptr.value);
    final currentId = _getDeviceId(device);
    final defaultId = _getDeviceId(defaultDevice);
    final equals = currentId == defaultId;
    defaultDevice.Release();
    enumerator.Release();
    calloc.free(ptr);
    return equals;
  }

  String _getDeviceId(IMMDevice device) {
    final idPtr = calloc<Pointer<Utf16>>();
    _throwIfFailed(device.GetId(idPtr), 'GetId failed');
    final id = idPtr.value.toDartString();
    CoTaskMemFree(idPtr.value);
    calloc.free(idPtr);
    return id;
  }

  String _getSessionId(IAudioSessionControl2 control) {
    final idPtr = calloc<Pointer<Utf16>>();
    control.GetSessionIdentifier(idPtr);
    final id = idPtr.value.toDartString();
    CoTaskMemFree(idPtr.value);
    calloc.free(idPtr);
    return id;
  }

  String _getSessionName(IAudioSessionControl2 control) {
    final namePtr = calloc<Pointer<Utf16>>();
    control.GetDisplayName(namePtr);
    final name = namePtr.value.address == 0
        ? 'Unknown'
        : namePtr.value.toDartString();
    if (namePtr.value.address != 0) {
      CoTaskMemFree(namePtr.value);
    }
    calloc.free(namePtr);
    return name.isEmpty ? 'System' : name;
  }

  int _getProcessId(IAudioSessionControl2 control) {
    final pidPtr = calloc<Uint32>();
    control.GetProcessId(pidPtr);
    final pid = pidPtr.value;
    calloc.free(pidPtr);
    return pid;
  }

  (IAudioSessionControl2, ISimpleAudioVolume, int)? _resolveSession(String sessionId) {
    final enumerator = _createEnumerator();
    try {
      for (final flow in [EDataFlow.eRender, EDataFlow.eCapture]) {
        final devicePtr = calloc<Pointer<COMObject>>();
        final hrEndpoint = enumerator.GetDefaultAudioEndpoint(flow, ERole.eMultimedia, devicePtr);
        if (FAILED(hrEndpoint)) {
          calloc.free(devicePtr);
          continue;
        }
        final device = IMMDevice(devicePtr.value);
        calloc.free(devicePtr);
        final managerPtr = calloc<Pointer<COMObject>>();
        final hrManager = device.Activate(
          GUID.fromString(_iidIAudioSessionManager2).addressOf,
          CLSCTX_ALL,
          nullptr,
          managerPtr,
        );
          if (FAILED(hrManager)) {
            device.Release();
            calloc.free(managerPtr);
            continue;
          }
        final manager = IAudioSessionManager2(managerPtr.value);
        calloc.free(managerPtr);
        final sessionEnumPtr = calloc<Pointer<COMObject>>();
        if (FAILED(manager.GetSessionEnumerator(sessionEnumPtr))) {
          manager.Release();
          device.Release();
          calloc.free(sessionEnumPtr);
          continue;
        }
        final sessionEnum = IAudioSessionEnumerator(sessionEnumPtr.value);
        calloc.free(sessionEnumPtr);
        final countPtr = calloc<Int32>();
        final countHr = sessionEnum.GetCount(countPtr);
        if (FAILED(countHr)) {
          calloc.free(countPtr);
          sessionEnum.Release();
          manager.Release();
          device.Release();
          _throwIfFailed(countHr, 'GetCount failed');
        }
        final total = countPtr.value;
        for (var i = 0; i < total; i++) {
          final ctlPtr = calloc<Pointer<COMObject>>();
          if (FAILED(sessionEnum.GetSession(i, ctlPtr))) {
            calloc.free(ctlPtr);
            continue;
          }
          final control = IAudioSessionControl2(ctlPtr.value);
          calloc.free(ctlPtr);
          final id = _getSessionId(control);
          if (id == sessionId) {
            final simplePtr = calloc<Pointer<COMObject>>();
            if (FAILED(control.QueryInterface(GUID.fromString(_iidISimpleAudioVolume).addressOf, simplePtr.cast()))) {
              control.Release();
              calloc.free(simplePtr);
              continue;
            }
            final simple = ISimpleAudioVolume(simplePtr.value);
            calloc.free(simplePtr);
            final pid = _getProcessId(control);
            calloc.free(countPtr);
            sessionEnum.Release();
            manager.Release();
            device.Release();
            return (control, simple, pid);
          }
          control.Release();
        }
        calloc.free(countPtr);
        sessionEnum.Release();
        manager.Release();
        device.Release();
      }
    } finally {
      enumerator.Release();
    }
    return null;
  }

  void _ensureWindows() {
    if (!Platform.isWindows) {
      throw UnsupportedError('Windows only feature');
    }
  }

  T _runCom<T>(T Function() action) {
    final hr = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    if (FAILED(hr) && hr != RPC_E_CHANGED_MODE) {
      throw WindowsAudioException(hr, '初始化 COM 失败');
    }
    try {
      return action();
    } finally {
      CoUninitialize();
    }
  }

  int _roleToNative(AudioRole role) {
    switch (role) {
      case AudioRole.console:
        return ERole.eConsole;
      case AudioRole.multimedia:
        return ERole.eMultimedia;
      case AudioRole.communications:
        return ERole.eCommunications;
    }
  }
}

class IPolicyConfig extends IUnknown {
  IPolicyConfig(Pointer<COMObject> ptr) : super(ptr);

  int SetDefaultEndpoint(Pointer<Utf16> deviceId, int role) {
    final ptrSet = ptr.ref.vtable.elementAt(20).value.cast<Pointer<NativeFunction<Int32 Function(Pointer, Pointer<Utf16>, Int32)>>>();
    final func = ptrSet.value.asFunction<int Function(Pointer, Pointer<Utf16>, int)>();
    return func(ptr.ref.lpVtbl, deviceId, role);
  }
}

class IAudioPolicyConfigFactory extends IUnknown {
  IAudioPolicyConfigFactory(Pointer<COMObject> ptr) : super(ptr);

  int SetPersistedDefaultAudioEndpoint(int pid, int flow, int role, Pointer<Utf16> deviceId) {
    final vtableEntry = ptr.ref.vtable.elementAt(13).value.cast<Pointer<NativeFunction<Int32 Function(Pointer, Uint32, Int32, Int32, Pointer<Utf16>)>>>();
    final func = vtableEntry.value.asFunction<int Function(Pointer, int, int, int, Pointer<Utf16>)>();
    return func(ptr.ref.lpVtbl, pid, flow, role, deviceId);
  }
}

class WindowsAudioException implements Exception {
  const WindowsAudioException(this.hr, this.message);

  final int hr;
  final String message;

  @override
  String toString() => 'WindowsAudioException(0x${hr.toRadixString(16)}): $message';
}
