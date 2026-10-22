# ChatLoom

ChatLoom to prywatny klient Beepera dla Androida i macOS. Opis produktu, aktualne screeny i język wizualny: [README.md](README.md). Logo i ikony generuje `scripts/render-chatloom-logo.py`.

## Android i macOS na jednej gałęzi

Obie wersje rozwijamy w jednym projekcie Flutter na `main`. Wspólne ekrany,
Matrix/E2EE, SQLCipher, outbox i logika produktu pozostają w `lib/` i `packages/`.
Kod natywny i narzędzia budowania mają osobne katalogi:

| Zakres | Android | macOS |
|---|---|---|
| Projekt natywny i konfiguracja | [`android/`](android/README.personal.md) | [`macos/`](macos/README.personal.md) |
| Budowanie i kontrola artefaktów | `scripts/android/build.py` | `scripts/macos/build.py` |
| Natywne narzędzia pomocnicze | `scripts/android/` | `scripts/macos/` |
| Testy natywne macOS | — | `integration_test/macos/` |
| GitHub Actions z `main` | `personal-checks.yml` | `personal-macos.yml` |

Wspólne testy komponentów i adapterów są w `test/`. Skrypty kolejki, analizy
i weryfikacji wspólnego kodu pozostają w `scripts/`. Dotychczasowe komendy
`scripts/build-personal-release.py` i `scripts/build-personal-macos.py` działają
jako wejścia zgodności. Nie kopiujemy całej aplikacji dla każdej platformy.
macOS działa bez powiadomień systemowych; konfiguracja push Androida pozostaje osobna.

Prywatny fork FluffyChat v2.10.0 dla Androida i macOS, z zachowanym transportem Matrix. Źródła upstream i ich licencje pozostają w repo; nasze moduły używają AGPL-3.0-or-later. To lokalna implementacja do odbioru, nie potwierdzony zamiennik oficjalnego Beepera.

## Uruchomienie

Flutter 3.47.4 / Dart3.13.3. `flutter pub get`, następnie build według instrukcji [Androida](android/README.personal.md) lub [macOS](macos/README.personal.md). Własne application/bundle ID: `pl.personal.chat`. SDK vendored w `packages/matrix`, pin i poprawki w `UPSTREAM-PIN.md`; nie aktualizować do `main` bez ponowienia bramek E2EE/storage/read/send.

Android release ma własny podpis, bez upstream dummykeystore. Klucz i hasło są poza Git (zob. [środowisko deweloperskie](docs/DEVELOPMENT.md)); lokalny `android/key.properties` jest ignorowany. Zrób niezależny prywatny backup klucza przed regularnym użyciem; utrata klucza uniemożliwi upgrade tej instalacji. APKdebug i release są podpisane różnymi kluczami. Nie usuwać instalacji z danymi w celu obejścia signaturemismatch.

macOS wymaga pełnego Xcode, wybranej wersji SDK i własnego signing. CommandLineTools nie wystarczają do buildu Flutter macOS. Web służy do transportu/publiccompile; personal native SQLCipher nie używa web plaintextfallback.

## Funkcje

Aktualny `client/` łączy Notion dark v2, funkcje Personal, FCM/startup i Androidowe kółeczka Telegrama. Stary Skiff pozostaje materiałem referencyjnym. „Send Later” zachowuje źródłową odpowiedź i wątek dla tekstu i mediów; podczas edycji jest niedostępne. Anulowanie transkrypcji usuwa wyłącznie zlecenie, którego publikacja jeszcze nie ruszyła; później zapisuje trwałą prośbę o anulowanie. Worker chroni nową ręczną próbę przed spóźnionym wynikiem starej. Niepoprawne metadane grup pozostają zapisane i nie blokują pozostałych rozmów.

Nowe instalacje zaczynają w Incognito; ustawienie jest per-device i można je jawnie wyłączyć. Ostateczny filtr HTTP blokuje automatyczne read/private-read/fully-read/typing/presence, również przy opóźnionym requestcie; ręczny odczyt dostaje zgodę wyłącznie na konkretny pokój/event.

Settings zbiera wszystkie kategorie na pełnych podstronach, bez ukrytego menu. Prywatność, powiadomienia, wygląd, organizacja oraz Sync & transcriptions mają własne miejsca. Sekcja Tools prowadzi bezpośrednio do zakładek, przypomnień i zaplanowanych wiadomości. Audio ma osobny przycisk transkrypcji; bez kliknięcia nie powstaje job. Tekst/transkrypt/metadane nie są wysyłane rozmówcy. Composer i zaplanowane zadanie pokazują utrwaloną sieć; reply/media/actions zachowują źródło.

Filtry w dolnym pasku rozdzielają kategorię rozmów od komunikatora. Telegram domyślnie przenosi grupy do Groups; Ignored ukrywa rozmowy i całkowicie wycisza je w ChatLoom, a Technical przechowuje rozpoznane rozmowy botów mostów. Settings → Chats & organization → Networks & chat rules udostępnia trwałe reguły dla obecnych i nowych grup. Szczegóły rozmowy → Visibility & notifications pozwalają je nadpisać. Tryby All messages / Mentions only / Muted dotyczą ChatLoom; ograniczenia powiadomień konta Matrix nadal obowiązują. Trwałe preferencje wymagają istniejącego prywatnego szyfrowanego magazynu i synchronizacji na Androidzie/macOS. [Opis i weryfikacja](docs/personal/chat-rules-2026-10-16.md).

Przed używaniem sync/zadań: połącz prywatny E2EEjournal, zweryfikuj własne sesje, skonfiguruj worker według [worker/README.md](worker/README.md). WorkerOnline oznacza aktualny heartbeat; czekanie na sync nie oznacza trwałego ACK. Dane i konflikty zachowują się lokalnie przy awarii; wyświetlane błędy nie kasują bazy/kluczy.

## Konfiguracja push

Adres bramy podaje się przy buildzie: `--dart-define=CHATLOOM_PUSH_GATEWAY=https://push.example.org` (origin bez ścieżki; brak wartości domyślnej). Build bez tej wartości nie ma automatycznej konfiguracji push; bramę można wtedy wpisać ręcznie w Settings → Developer. Android z tak zbudowaną aplikacją po zalogowaniu automatycznie konfiguruje bramę: generuje klucz urządzenia w secure storage, pobiera krótkotrwałe potwierdzenie OpenID z Matrix, rejestruje telefon w bramie, a następnie ustawia pusher `event_id_only`. Użytkownik akceptuje wyłącznie systemową zgodę na powiadomienia. Główny token sesji Matrix nie trafia do bramy. Puste ustawienie ze starszej instalacji również wybiera konfigurację automatyczną; własne inne adresy i wcześniej wybrany UnifiedPush pozostają zachowane.

Zmiana tokena FCM automatycznie zastępuje rejestrację poprzedniego tokena i aktualizuje pusher. Po błędzie przejściowym klient podejmuje do pięciu ponowień (30/60/120/240/300 sekund) tylko na pierwszym planie; przejście w tło zatrzymuje timer, a powrót zachowuje licznik prób. Po wyczerpaniu prób potrzebna jest widoczna ponowna konfiguracja; restart aplikacji lub rotacja tokena rozpoczyna nową serię. Brak autoryzacji konta wymaga poprawienia konfiguracji usługi albo ponownej próby. Settings → Notifications → Push setup & registration pozwala ponowić automatyczny setup; ręczne pola i kopiowanie sekretów są w Advanced notification settings. Rejestracja i zgoda systemowa mają osobny stan; żaden z nich nie dowodzi dostawy na ekran.

**Wymagane jednorazowe wdrożenie operatora:** nowy gateway i ścieżka rejestracji HTTPS, przypięty serwer/origin OpenID oraz skrót SHA-256 własnego dozwolonego konta w prywatnej konfiguracji. Pusta allowlista wyłącza rejestrację. Kod lokalny nie oznacza aktualizacji VPS ani telefonu. Pełna instrukcja i dotychczasowa ręczna konfiguracja: [push-gateway/README.md](push-gateway/README.md). Nadal potrzebne są własny Firebase, build FCM i istniejący podpis aplikacji. Automatyczna rejestracja obsługuje obecnie jedno zalogowane konto Matrix na telefonie.

Sync & transcriptions pokazuje osobno aktualność uwierzytelnionego heartbeat, stan połączenia, transkrypcję, reminder relay i liczby oczekujących zadań. Worker wysyła heartbeat co pięć minut, a po zmianie stanu najwyżej raz na minutę. Nieznane pola, starszy payload i heartbeat starszy niż 11 minut nie potwierdzają gotowości usług. `blocked_codec_sandbox` pozostaje jawną blokadą transkrypcji.

Reminders: standard Synapse nie wysyła push własnego nadawcy. Worker opcjonalnie wysyła content-free wake do chronionego loopback /internal/reminder, a urządzenie synchronizuje i weryfikuje prywatny wynik. Włącz relay według instrukcji i sprawdź FCMruntime. Google widzi token/opaqueMatrixroutingIDs/czas, bez treści/nazw. FCM acceptance nie gwarantuje dostarczenia w Doze/force-stop.

macOS po Quit nie ma aktywnego Matrixsync; APNsbackground po Quit nie jest zaimplementowane. Osobny wynik odbioru; działający worker wykonuje zaakceptowane zadania niezależnie od okna.

## Testy

`rtk python3 scripts/verify-personal.py --dart /pełna/ścieżka/dart` uruchamia 98 testów core i izolowane SQLCipher/storage/media/outbox/capabilities. Worker: `rtk dart test` w worker (nativeSQLCipher/vodozemac według README); source-only disposableSynapse na loopback do integracji. Gateway: `rtk python3 -W error::ResourceWarning -m unittest discover -s push-gateway/tests -v`. Nie wymaga rzeczywistegoOpenAI/Google/Beeper.

Notion: `rtk python3 scripts/verify-notion-ui.py --flutter /pełna/ścieżka/flutter`; kółeczka: `rtk python3 scripts/verify-round-widgets.py --flutter /pełna/ścieżka/flutter` i `rtk python3 scripts/verify-round-player.py --flutter /pełna/ścieżka/flutter`. Harnessy kopiują i sprawdzają hashe produkcyjnych źródeł, używając fikcyjnych danych. Są dowodem testów komponentów, nie odbioru telefonu ani konta.

Regresje kwalifikacji powiadomień oraz kontekstu harmonogramu korzystają z konfiguracji pakietów pure Dart workera: `rtk /pełna/ścieżka/dart --packages=worker/.dart_tool/package_config.json test/personal/integration/notification_eligibility_test.dart` oraz analogicznie `scheduled_composer_test.dart`. Najpierw rozwiąż zależności workera z jego lockfile. Testy nie pobierają historii ani nie wysyłają wiadomości.

Każda sieć/platforma osobno; czytelna historia nie dowodzi push/send/media/receipts.

## Przełączenie starej transkrypcji

Nie aktywuj nowego workera równolegle ze starym automatem do Note to self. Najpierw enrollment/recovery/nativecrypto/test, spójny prywatny backup, rozwiązane miejsce na VPS; dopiero stop/disable starej usługi i potwierdzenie, następnie nowy worker. Nie opróżniaj legacy kolejki. Nie zmieniaj AI drafts/mostów. Nie importuj legacy wyników bez pewnego mapowaniaeventIDs.

Release buduj z włączonym pub (`flutter build apk --release --target-platform android-arm64`), nie `--no-pub` po analizie/testach. W Flutter3.47.4 `--no-pub` pomija regenerację platformowego registranta i może zostawić odniesienie do dev-only IntegrationTestPlugin, którego Gradle słusznie nie kompiluje w release. Lockfile pozostaje punktem kontroli; nie usuwaj zależności testowej ani nie edytuj GeneratedPluginRegistrant ręcznie.

Powtarzalny personal release: `rtk python3 scripts/build-personal-release.py --preflight-only`, następnie `rtk python3 scripts/build-personal-release.py`, po zakończeniu edycji i kolejki Flutter. Wrapper używa istniejących ignorowanych konfiguracji i izolowanego toolchaina, zachowuje poprzednie APK oraz sprawdza hashe źródeł przed i po buildzie. Publikuje nowy katalog artefaktu dopiero po kontroli podpisu, pakietu i arm64. Nie instaluje aplikacji ani nie zmienia VPS. Pełny cold build może potrzebować większego zapasu miejsca niż zachowany build przyrostowy.

Analyzer plugin pinned `dart_code_linter`4.4.0: upstream value `latest` is not a valid SemVer constraint in Dart3.13. [Plugin configuration](https://pub.dev/packages/dart_code_linter).

Środowisko, toolchain i konfiguracja buildu: [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md).

Web assets: `scripts/verify-personal-web-assets.py` sprawdza przypięte binaria oraz źródłowy manifest workera. `scripts/build-personal-web-worker.py` kompiluje worker dwukrotnie z ustalonymi flagami; publikacja po backupie wymaga `--publish`. Nowy signed APK i web build nie zamykają przerwanego odbioru zalogowanej sesji.
