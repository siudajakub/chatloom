# Personal Chat

Prywatny fork FluffyChat v2.10.0 dla Androida i macOS, z zachowanym transportem Matrix. Źródła upstream i ich licencje pozostają w repo; nasze moduły używają AGPL-3.0-or-later. To lokalna implementacja do odbioru, nie potwierdzony zamiennik oficjalnego Beepera.

## Uruchomienie

Flutter 3.47.4 / Dart3.13.3. `flutter pub get`, następnie build Android/macOS zgodnie z upstream. Własne application/bundle ID: `pl.personal.chat`. SDK vendored w `packages/matrix`, pin i poprawki w `UPSTREAM-PIN.md`; nie aktualizować do `main` bez ponowienia bramek E2EE/storage/read/send.

Android release ma własny podpis, bez upstream dummykeystore. Lokalny klucz i hasło są poza Git w `~/.local/share/personal-chat/signing/`, uprawnienia700/600; lokalny `android/key.properties` jest ignorowany. Zrób niezależny prywatny backup klucza przed regularnym użyciem; utrata klucza uniemożliwi upgrade tej instalacji. APKdebug i release są podpisane różnymi kluczami. Nie usuwać instalacji z danymi w celu obejścia signaturemismatch.

macOS wymaga pełnego Xcode, wybranej wersji SDK i własnego signing. CommandLineTools nie wystarczają do buildu Flutter macOS. Web służy do transportu/publiccompile; personal native SQLCipher nie używa web plaintextfallback.

## Funkcje

Aktualny `client/` łączy Notion dark v2, funkcje Personal, FCM/startup i Androidowe kółeczka Telegrama. Stary Skiff pozostaje materiałem referencyjnym. „Send Later” zachowuje źródłową odpowiedź i wątek dla tekstu i mediów; podczas edycji jest niedostępne. Anulowanie transkrypcji usuwa wyłącznie zlecenie, którego publikacja jeszcze nie ruszyła; później zapisuje trwałą prośbę o anulowanie. Worker chroni nową ręczną próbę przed spóźnionym wynikiem starej. Niepoprawne metadane grup pozostają zapisane i nie blokują pozostałych rozmów.

Nowe instalacje zaczynają w Incognito; ustawienie jest per-device i można je jawnie wyłączyć. Ostateczny filtr HTTP blokuje automatyczne read/private-read/fully-read/typing/presence, również przy opóźnionym requestcie; ręczny odczyt dostaje zgodę wyłącznie na konkretny pokój/event.

Hub osobistych funkcji w liście rozmów: prywatna synchronizacja, incognito, merge, organizacja, prywatne szkice i konflikty, bookmarks, schedules/reminders. Audio ma osobny przycisk transkrypcji; bez kliknięcia nie powstaje job. Tekst/transkrypt/metadane nie są wysyłane rozmówcy. Composer i zaplanowane zadanie pokazują utrwaloną sieć; reply/media/actions zachowują źródło.

Przed używaniem sync/zadań: połącz prywatny E2EEjournal, zweryfikuj własne sesje, skonfiguruj worker według [worker/README.md](worker/README.md). WorkerOnline oznacza aktualny heartbeat; czekanie na sync nie oznacza trwałego ACK. Dane i konflikty zachowują się lokalnie przy awarii; wyświetlane błędy nie kasują bazy/kluczy.

## Konfiguracja push

Pełna instrukcja: [push-gateway/README.md](push-gateway/README.md). Potrzebne własny Firebaseproject dla `pl.personal.chat`, właściwy google-services.json, buildFCM i HTTPSendpoint event_id_only. Chroniony gatewayconfig musi mieć dokładny appId/device token/nonce. Appnonce jest w securestorage, nigdy w URL. Nie stosujemy domyślnie cudzej bramyFluffyChat.

Reminders: standard Synapse nie wysyła push własnego nadawcy. Worker opcjonalnie wysyła content-free wake do chronionego loopback /internal/reminder, a urządzenie synchronizuje i weryfikuje prywatny wynik. Włącz relay według instrukcji i sprawdź FCMruntime. Google widzi token/opaqueMatrixroutingIDs/czas, bez treści/nazw. FCM acceptance nie gwarantuje dostarczenia w Doze/force-stop.

macOS po Quit nie ma aktywnego Matrixsync; APNsbackground po Quit nie jest zaimplementowane. Osobny wynik odbioru; działający worker wykonuje zaakceptowane zadania niezależnie od okna.

## Testy

`rtk python3 scripts/verify-personal.py --dart /pełna/ścieżka/dart` uruchamia 98 testów core i izolowane SQLCipher/storage/media/outbox/capabilities. Worker: `rtk dart test` w worker (nativeSQLCipher/vodozemac według README); source-only disposableSynapse na loopback do integracji. Gateway: `rtk python3 -W error::ResourceWarning -m unittest discover -s push-gateway/tests -v`. Nie wymaga rzeczywistegoOpenAI/Google/Beeper.

Notion: `rtk python3 scripts/verify-notion-ui.py --flutter /pełna/ścieżka/flutter`; kółeczka: `rtk python3 scripts/verify-round-widgets.py --flutter /pełna/ścieżka/flutter` i `rtk python3 scripts/verify-round-player.py --flutter /pełna/ścieżka/flutter`. Harnessy kopiują i sprawdzają hashe produkcyjnych źródeł, używając fikcyjnych danych. Są dowodem testów komponentów, nie odbioru telefonu ani konta.

Regresje kwalifikacji powiadomień oraz kontekstu harmonogramu korzystają z konfiguracji pakietów pure Dart workera: `rtk /pełna/ścieżka/dart --packages=worker/.dart_tool/package_config.json test/personal/integration/notification_eligibility_test.dart` oraz analogicznie `scheduled_composer_test.dart`. Najpierw rozwiąż zależności workera z jego lockfile. Testy nie pobierają historii ani nie wysyłają wiadomości.

[Specyfikacja](docs/personal/prds/beeper-personal-client-v1-spec.md), [plan](docs/personal/beeper-personal-client-plan-2026-10-03.md), [raport dowodów i NOTRUN](docs/personal/fluffychat-compatibility-spike-2026-10-03.md). Każda sieć/platforma osobno; czytelna historia nie dowodzi push/send/media/receipts.

## Przełączenie starej transkrypcji

Nie aktywuj nowego workera równolegle ze starym automatem do Note to self. Najpierw enrollment/recovery/nativecrypto/test, spójny prywatny backup, rozwiązane miejsce na VPS; dopiero stop/disable starej usługi i potwierdzenie, następnie nowy worker. Nie opróżniaj legacy kolejki. Nie zmieniaj AI drafts/mostów. Nie importuj legacy wyników bez pewnego mapowaniaeventIDs.

Release buduj z włączonym pub (`flutter build apk --release --target-platform android-arm64`), nie `--no-pub` po analizie/testach. W Flutter3.47.4 `--no-pub` pomija regenerację platformowego registranta i może zostawić odniesienie do dev-only IntegrationTestPlugin, którego Gradle słusznie nie kompiluje w release. Lockfile pozostaje punktem kontroli; nie usuwaj zależności testowej ani nie edytuj GeneratedPluginRegistrant ręcznie.

Powtarzalny personal release: `rtk python3 scripts/build-personal-release.py --preflight-only`, następnie `rtk python3 scripts/build-personal-release.py`, po zakończeniu edycji i kolejki Flutter. Wrapper używa istniejących ignorowanych konfiguracji i izolowanego toolchaina, zachowuje poprzednie APK oraz sprawdza hashe źródeł przed i po buildzie. Publikuje nowy katalog artefaktu dopiero po kontroli podpisu, pakietu i arm64. Nie instaluje aplikacji ani nie zmienia VPS. Pełny cold build może potrzebować większego zapasu miejsca niż zachowany build przyrostowy.

Analyzer plugin pinned `dart_code_linter`4.4.0: upstream value `latest` is not a valid SemVer constraint in Dart3.13. [Plugin configuration](https://pub.dev/packages/dart_code_linter).
