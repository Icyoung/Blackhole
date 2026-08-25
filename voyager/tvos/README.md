# Voyager tvOS

This directory is the experimental Apple TV target for Voyager.

Voyager's tvOS build uses the community `flutter-tvos` toolchain because the
standard Flutter SDK does not build tvOS apps. The app runs with
`BH_TARGET_TVOS=true`, which disables native VPN, desktop drag/drop, desktop
window title integration, and other non-tvOS affordances.

## Commands

```bash
cd voyager
./tool/tvos.sh discover
PATH="/Users/icy/Development/flutter-tvos/bin:$PATH" ./tool/tvos.sh doctor
PATH="/Users/icy/Development/flutter-tvos/bin:$PATH" ./tool/tvos.sh devices
PATH="/Users/icy/Development/flutter-tvos/bin:$PATH" ./tool/tvos.sh run -d <simulator-or-device-id>
PATH="/Users/icy/Development/flutter-tvos/bin:$PATH" ./tool/tvos.sh build --release
```

Install `flutter-tvos` if `./tool/tvos.sh doctor` reports that it is missing:

```bash
git clone https://github.com/fluttertv/flutter-tvos.git
export PATH="$PATH:/path/to/flutter-tvos/bin"
flutter-tvos precache
flutter-tvos doctor
```

Xcode must also have the tvOS platform installed under Settings > Components.

Use `./tool/tvos.sh discover` to distinguish LAN discovery from deployability:
AirPlay/companion Bonjour entries only prove the Apple TV is on the network;
Xcode deployment requires the device to appear in `devicectl` or `xcdevice`
after pairing with Xcode.
