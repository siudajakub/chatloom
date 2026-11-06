# ChatLoom beta na iPhonie — instalacja z Maca

Gałąź: `feat/ios-reels-thread-preview-beta` w `themeaningW/chatloom`.
To osobna wersja do testów przed merge do `main`; nie jest wydaniem App Store.

## Wymagania

- Mac z Xcode zgodnym z wersją iOS telefonu, uruchomionym przynajmniej raz
  i pobranymi komponentami iOS; Flutter **3.47.4** / Dart 3.13.
- Własne konto Apple w **Xcode → Settings → Accounts**. Darmowy
  **Personal Team** wystarczy do podpisania aplikacji na własnym telefonie.
- iPhone podłączony kablem, odblokowany, z zaakceptowanym **Trust**.
  Na iOS 16+: **Settings → Privacy & Security → Developer Mode**.
- CocoaPods, jeżeli Flutter poprosi o niego dla pluginów bez SwiftPM.
  Projekt Runner używa Swift Package Manager; nie usuwaj jego zależności.

## Pobranie i przygotowanie

```sh
git clone --branch feat/ios-reels-thread-preview-beta --single-branch \
  https://github.com/themeaningW/chatloom.git
cd chatloom
flutter --version
flutter pub get --enforce-lockfile
flutter build ios --release --no-codesign
open ios/Runner.xcworkspace
```

Polecenie build przygotowuje konfigurację Fluttera i pluginy. Nie instaluje
aplikacji i nie dołącza cudzego podpisu. Repo nie zawiera SDK, kont Apple,
certyfikatów, profili ani gotowej IPA podpisanej dla innej osoby.

## W Xcode

1. Wybierz projekt **Runner**, target **Runner → Signing & Capabilities**.
2. Włącz **Automatically manage signing** i wybierz **swój Personal Team**.
3. Ustaw własny, unikalny **Bundle Identifier**, np.
   `com.twojanazwa.chatloom.beta`, jeżeli domyślny jest zajęty.
4. Wybierz swój iPhone jako urządzenie docelowe.
5. W **Product → Scheme → Edit Scheme → Run → Info** ustaw
   **Build Configuration: Release**. Wersja debug wymaga uruchamiania przez
   narzędzia developerskie; Release można później otwierać z ikony.
6. Wybierz **Product → Run**. Jeśli telefon zgłosi brak zaufania, wejdź w
   **Settings → General → VPN & Device Management**, wybierz swój profil
   i zaakceptuj **Trust**.
7. Zamknij aplikację w **App Switcher** i otwórz ponownie z ikony.

Na darmowym koncie profil wygasa po 7 dniach: podłącz telefon i uruchom
Release ponownie z Xcode. Nie usuwaj aplikacji, żeby odnowić podpis — w niej
pozostaje lokalna baza i klucze. Zachowaj klucz odzyskiwania swojego konta Matrix.

## Logowanie i mostki

Każdy tester loguje się do **własnego konta** Beeper/Matrix. Gałąź nie zawiera
czyichś zalogowanych kont WhatsApp/Messenger/Instagram. Mostki muszą działać
na serwerze tego konta, również po wyłączeniu Maca.

Na własnym homeserverze z niestandardowymi botami przygotuj build z właściwymi
publicznymi adresami, np. zamiast powyższego build:

```sh
flutter build ios --release --no-codesign \
  '--dart-define=CHATLOOM_BRIDGE_PROVISIONING_URL=https://matrix.example.org/bridges/{bridge}' \
  '--dart-define=CHATLOOM_BRIDGE_BOTS=@whatsappbot:matrix.example.org,@metabot:matrix.example.org,@instagrambot:matrix.example.org'
```

To przykłady, nie gotowa konfiguracja serwera. Samo wpisanie URL nie uruchamia
mostka ani proxy. Następnie ponownie otwórz workspace i uruchom Release w Xcode.
Sekrety logowania wpisuj tylko w odpowiednich lokalnych ekranach.

## Zakres bety i potwierdzone testy

- Przytrzymanie wątku: przewijanie zapisanej historii z doładowaniem kolejnych
  porcji; bez oznaczania jako przeczytane. Brak starej historii na urządzeniu
  nie jest automatycznie obchodzony pobieraniem jej z sieci w podglądzie.
- Rolki dostarczone jako filmy przez mostek: odtwarzanie inline, transport,
  pełny ekran, opis jako link do oryginału. Zwykłe nagrania zachowują swoją ścieżkę.
- Linki Instagram: wymagają endpointu `POST /v3/chatloom/link_media` we forku
  mostka. Dla opisów z tego endpointu zobacz `scripts/bridges/README.md`.
- Gołe linki Facebook/Threads bez dostarczonego pliku nie mają resolvera filmu.
- Powiadomienia APNs w tle, share extension i rozmowy głosowe/wideo nie są
  częścią tej bety.

Port był budowany i uruchamiany na fizycznym iPhonie z Windows/xcross.
Standardowy build na Macu/Xcode musi zostać potwierdzony przez testera;
nie traktujemy testów widgetów ani unsigned build jako dowodu instalacji.

Zasady podpisywania: [Apple Personal Team](https://developer.apple.com/help/account/basics/about-your-developer-account).
