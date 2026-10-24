#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-or-later
"""Exact app-owned copy translation; protected behavior and data keys unchanged."""
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
COPY = {
 'Nie potwierdzono własnego loginu i możliwości mostu Telegram.': 'Your Telegram login and bridge capabilities have not been verified.',
 'Nie jesteś uczestnikiem tej rozmowy.': 'You are not a member of this conversation.',
 'Wiadomość źródłowa jest niedostępna.': 'The source message is unavailable.',
 'Brak uprawnień do zmiany ustawień tej rozmowy.': 'You do not have permission to change this conversation.',
 'Brak uprawnień do usunięcia tej wiadomości.': 'You do not have permission to delete this message.',
 'Wysyłanie jest zablokowane przez uprawnienia lub klucze Matrix.': 'Sending is blocked by Matrix permissions or encryption keys.',
 'Brak uprawnień do wysłania reakcji Matrix.': 'You do not have permission to send a Matrix reaction.',
 'Brak uprawnień do wysłania naklejki Matrix.': 'You do not have permission to send a Matrix sticker.',
 'Można edytować tylko własną wiadomość.': 'You can only edit your own messages.',
 'Ta wiadomość wideo wygasła.': 'This video message has expired.',
 'Most, uprawnienia lub format kółeczka nie zostały potwierdzone. Nagranie pozostaje w kolejce.': 'The bridge, permissions or round video format are unverified. The recording remains in the queue.',
 'Telegram nie udostępnia edycji wysłanych kółeczek.': 'Telegram does not support editing sent round videos.',
 'Synchronizacja funkcji jest wstrzymana. Sprawdź połączenie i spróbuj ponownie.': 'Private sync is paused. Check your connection and try again.',
 'Nie udało się otworzyć szyfrowanego magazynu funkcji. Dane pozostają zachowane.': 'Could not open encrypted private storage. Your data is preserved.',
 'Synchronizacja wstrzymana: zmienił się skład prywatnego pokoju.': 'Private sync paused: the private room membership changed.',
 'Synchronizacja funkcji wymaga sprawdzenia połączenia, kluczy lub pokoju.': 'Check the connection, encryption keys and private room before syncing.',
 'Chroniona kolejka jest niedostępna. Zapisane nagrania pozostają na tym urządzeniu.': 'The protected queue is unavailable. Saved recordings remain on this device.',
 'Nagranie czeka na chroniony zapis': 'Recording awaiting protected storage',
 'Magazyn odmówił zapisu. Ta kopia nie przetrwa zamknięcia aplikacji.': 'Storage refused this recording. This copy will not survive closing the app.',
 'Zapisz ponownie': 'Retry saving',
 'Usuń niezapisane nagranie': 'Discard unsaved recording',
 'Matrix przyjął kółeczko': 'Matrix accepted the round video',
 'Wynik wysyłki jest nieustalony': 'Send outcome unknown',
 'Kółeczko czeka na ponowienie': 'Round video awaiting retry',
 'Kółeczko zapisane lokalnie': 'Round video saved locally',
 'Telegram potwierdził dostarczenie': 'Telegram confirmed delivery',
 'Telegram: brak potwierdzenia dostarczenia': 'Telegram delivery not confirmed',
 'Ponów tę samą próbę': 'Retry the same send attempt',
 'Usuń lokalny szkic kółeczka': 'Delete local round video draft',
 'Usuń lokalną kopię przyjętego nagrania': 'Delete local copy of accepted recording',
 'Nie udało się potwierdzić operacji. Nagranie pozostaje w chronionej kolejce.': 'The operation was not confirmed. The recording remains in the protected queue.',
 'Usunąć lokalną kopię nagrania?': 'Delete the local recording copy?',
 'Tej kopii nie będzie można odzyskać. Usunięcie lokalnej kopii nie potwierdza dostarczenia w Telegramie.': 'This copy cannot be recovered. Deleting it does not confirm delivery in Telegram.',
 'Usuń lokalną kopię': 'Delete local copy',
 'Anuluj': 'Cancel',
 'Nagraj wiadomość wideo. Przytrzymaj lub stuknij, aby nagrywać z blokadą.': 'Record a video message. Hold to record or tap for hands-free recording.',
 'Przytrzymaj, aby nagrać kółeczko': 'Hold to record a round video',
 'Połącz zaufany most Telegram': 'Trust your Telegram bridge',
 'Potwierdź, że to Twój skonfigurowany most i login Telegram.': 'Confirm this is your configured bridge and Telegram login.',
 'Most nie potwierdza bezpiecznego przekazania tej wiadomości.': 'The bridge has not confirmed safe forwarding for this message.',
 'Przekaż w Telegramie': 'Forward in Telegram',
 'Brak dostępnych rozmów docelowych.': 'No destination conversations available.',
 'Wynik przekazania jest nieustalony. Ponowienie zachowa tę samą próbę.': 'Forwarding outcome unknown. Retrying will keep the same attempt.',
 'Matrix przyjął przekazanie. Potwierdzenie z Telegrama jeszcze nie dotarło.': 'Matrix accepted the forward. Telegram confirmation has not arrived.',
 'Przekazanie nie zostało potwierdzone. Sprawdź most i uprawnienia.': 'Forwarding was not confirmed. Check the bridge and permissions.',
 'Połącz': 'Trust bridge',
 'Nie można zapisać ani udostępnić tej chronionej wiadomości.': 'This protected message cannot be saved or shared.',
 'Otwórz aplikację, aby przeczytać wiadomość.': 'Open the app to read your message.',
 'Nie udało się uruchomić aplikacji. Dane i klucze pozostają zachowane.': 'Could not start the app. Your data and keys are preserved.',
 'Odblokuj urządzenie i otwórz aplikację ponownie. Nie czyść danych aplikacji, jeśli potrzebujesz zachowanych szkiców i kluczy.': 'Unlock your device and reopen the app. Keep app data to preserve your drafts and keys.',
 'Nie udało się wykonać operacji': 'Could not complete this action',
 'Prośba o weryfikację jest wysyłana automatycznie. Zaakceptuj ją w działającym kliencie lub użyj istniejącego klucza odzyskiwania. Lista poniżej nie jest wyborem urządzenia.': 'Verification is requested automatically. Accept it in your existing client or use your existing recovery key. The list below shows your devices; it does not select one.',
}
PATHS = (
 'lib/personal/capabilities.dart', 'lib/personal/privacy.dart', 'lib/personal/personal_client.dart',
 'lib/personal/round_video/round_record_button.dart', 'lib/personal/round_video/telegram_round_service.dart',
 'lib/utils/matrix_sdk_extensions/event_extension.dart', 'lib/utils/push_helper.dart', 'lib/widgets/local_notifications_extension.dart',
 'lib/utils/error_reporter.dart', 'lib/pages/bootstrap/widgets/restore_bootstrap_view.dart',
)
for relative in PATHS:
 path = ROOT / relative
 text = path.read_text()
 for source, target in sorted(COPY.items(), key=lambda item: -len(item[0])):
  text = text.replace(source, target)
 path.write_text(text)
