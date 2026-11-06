# iOS development port

For a friend building this beta with their own Apple account on a Mac, follow
[the installation guide](../docs/ios-beta-install.md). No shared signing account
or paid Apple membership is required for a local Personal Team device build.

This runner uses the shared ChatLoom application in `lib/`. Its bundle ID is
`pl.chatloom.chatloom`. Signing accounts, keys, profiles and extracted Apple SDKs
belong outside the repository. Do not add another application's App Group.

The first port uses the application's private Library directory for its encrypted
database and its private default Keychain namespace for keys. A missing key for
an existing database fails closed; it does not reset or delete the database.

## Verified before the full-app port

On 2026-11-05, an isolated Flutter probe built from Windows with xcross 2.0.9 ran
on an iPhone 14 Pro Max (iOS 26.5). Taps, hot reload with preserved state, Keychain
read/write, SQLCipher encrypted reopen/unkeyed rejection, Ed25519 verification
and a synthetic Megolm round trip passed. A fresh process also read the saved
key and database without re-creating them. These fixtures do not prove full-app
or real-account encryption behavior. Full ChatLoom build/device acceptance is
recorded separately below; see [the port plan](../docs/windows-ios-port-plan.md).

On 2026-11-06, the full shared ChatLoom app (2.10.0+3568) was built, signed and
installed on that iPhone. The debugger attached and a device screenshot verified
the English welcome screen with `Sign in with Beeper` and `Use another server`.
Real account login, encrypted history, media and lifecycle acceptance remain
pending. This is a development build; iOS push/background delivery is not set up.

## Initial scope

The runner enables mobile navigation, the software keyboard and foreground sync.
APNs/background notifications and incoming iOS sharing remain separate work:
there is no share extension or inherited App Group. Android foreground services
and FCM initialization stay Android-only. Round-video capture remains gated to
its existing Android/macOS native implementations.

Permission descriptions are in `Runner/Info.plist`. Authentication callbacks use
the existing `pl.personal.chat.auth` scheme; ChatLoom and Matrix links use
`pl.personal.chat` and `matrix`. Do not enable broad cleartext networking to make
a server login work.

## Local Windows experiment

The sibling `ios-lab` is an isolated local toolchain, not a dependency shipped
with ChatLoom. With that lab already prepared:

```powershell
Set-Location path\to\chatloom
. ..\ios-lab\Enter-IosLab.ps1
flutter pub get --enforce-lockfile
. ..\ios-lab\Enable-IosCMake.ps1
xcross flutter build --debug --no-pub
```

For a physical device, keep the separately started `xcross tunnel` running and
the iPhone connected and unlocked. Authenticate interactively in your own terminal;
never put Apple credentials in source or chat. For the current test Personal Team:

```powershell
$env:XCROSS_BUNDLE_ID = 'prefixed'
xcross flutter run --debug --no-pub --usb -u DEVICE_UDID
```

`q` ends the debugger session but may leave the device process alive. Stop that
specific application before replacing its build if installation waits for it.
A fresh PowerShell session with only `Enter-IosLab.ps1` is used for host tests;
`Enable-IosCMake.ps1` configures that session specifically for iOS cross builds.
The local CMake adapter also prepares webcrypto's Mach-O install-name before
xcross packages it as a framework. The adapter is installed only in the lab venv.

xcross 2.0.9's Swift registrant uses the QR plugin's Objective-C name, while
qr_code_scanner_plus 2.3.0 declares `SwiftFlutterQrPlusPlugin` in Swift. If the
build reports that `FlutterQrPlusPlugin` is missing, prepare the generated
module using the cache path printed in that error, then rebuild:

```powershell
.\scripts\ios\prepare-xcross-plugins.ps1 -CachePath path\to\xcross\swiftpm\CACHE_ID
```

This adds a Swift type alias in generated build output; hosted package source
and the application lockfile are unchanged.
A signed debug probe does not establish standalone release, TestFlight, background
delivery or App Store readiness. Standard Xcode builds remain unverified here.

## Brand assets

The iOS icons use the original ChatLoom SVG mark and the existing brand generator's
background/placement functions. No Flutter template icon remains. To regenerate
only the iOS catalog, use Python with `resvg_py==0.5.0` and ffmpeg available:

```powershell
python scripts/ios/generate-icons.py
python scripts/ios/generate-icons.py --check
```

This writes RGB PNGs without an alpha channel and does not rewrite Android,
macOS or web assets.
