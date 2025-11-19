# FluterSound

Flutter 桌面应用示例，用于在 Windows 平台上列出录音/播放设备、切换默认设备、调整系统及每个程序的音量，并为具体程序指定输出/输入设备。

## 主要功能
- 查看所有可用的播放、录音设备，以及默认状态和当前音量。
- 直接通过 Windows Core Audio API 设置设备默认角色、音量与静音。
- 列出所有音频会话（输出与输入），针对每个程序设置音量、静音状态以及首选的设备。

## 运行方式
由于环境中未预装 Flutter SDK，需要在本地 Windows 设备上安装 Flutter 3.19+ 并启用 Windows 桌面支持：

```powershell
flutter config --enable-windows-desktop
flutter pub get
flutter run -d windows
```

应用仅能在 Windows 上运行；其他系统将抛出 `UnsupportedError`。
