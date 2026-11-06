# Rolki i nagrania w wiadomościach — plan

Status: klient beta wdraża odtwarzanie inline, klikalne opisy i lifecycle.
Aktualny kontrakt i ograniczenia: [instagram-link-media.md](instagram-link-media.md).
Rozszerzenie opisów mostka jest dostarczone jako patch do wdrożenia przez operatora.
Poniższy plan zachowuje docelowe wymagania, w tym dalszy resolver gołych linków Facebook.

## Docelowe zachowanie

- Rolka udostępniona jako link wygląda jak wiadomość wideo: proporcjonalny
  kadr, miniatura i Play. Dotknięcie uruchamia odtwarzanie w wiadomości;
  dostępne są pauza, przewijanie, dźwięk i przejście na pełny ekran.
- Pod kadrem jest **opis autora rolki**, a cały ten opis jest odnośnikiem
  do oryginału. Dotknięcie opisu otwiera rolkę w aplikacji/stronie źródłowej.
  Opis nie przechwytuje dotknięć sterowania filmem.
- Nie pokazujemy obok drugiej karty tego samego linka ani surowego URL pod
  opisem. Oryginalna treść wiadomości pozostaje w Matrix; zmienia się tylko
  prezentacja rozpoznanego odnośnika. Własny komentarz nadawcy i inne linki
  pozostają widoczne.
- Brak opisu: klikalne „Open reel in Instagram” (odpowiednio Facebook), bez
  wymyślonego opisu. Brak dostępu do filmu: miniatura, jeśli dostępna,
  wyjaśnienie, Retry i otwarcie oryginału. Zwykły link pozostaje użyteczny,
  gdy nie ma zgodnego mostka.
- Zwykłe załączniki wideo, wiadomości głosowe i okrągłe nagrania zachowują
  swój istniejący renderer; nie zamieniamy ich w odnośniki do rolek.

## Zakres i wykorzystanie istniejącego kodu

1. Pierwszy etap: rolki Instagram wysłane w **dowolnej sieci** (również w
   WhatsApp i Messengerze). Rozpoznawanie już istnieje w
   `lib/personal/instagram_share.dart`, a karta i transport w
   `lib/pages/chat/events/instagram_share_preview.dart`.
2. Wiadomość, w której mostek już dostarczył plik filmu i metadane oryginalnej
   rolki, wykorzystuje te dane bez ponownego pobierania filmu z Instagrama.
3. Drugi etap: linki do rolek Facebook/Messenger. Osobny parser i kontrakt
   mostka Meta; nie obiecujemy obsługi takich linków przez endpoint Instagrama.
4. Odtwarzanie opieramy na istniejących kontrolerach/playerach i pełnoekranowym
   viewerze. Dziś karta Instagram po dotknięciu pobiera media i otwiera viewer;
   odtwarzanie wewnątrz wiadomości wymaga rozszerzenia tej ścieżki.

## Etap 1 — metadane i kontrakt mostka

Rozszerzyć istniejący uwierzytelniony `POST /v3/chatloom/link_media`
(opisany w `instagram-link-media.md`) o opcjonalne pola:

```json
{
  "canonical_url": "https://www.instagram.com/reel/FICTIONAL/",
  "caption": "Przykładowy opis autora rolki",
  "author": "fictional_author",
  "assets": [{"type": "video", "width": 1080, "height": 1920, "duration_ms": 12000}]
}
```

To projekt kontraktu, nie potwierdzenie, że uruchomiony mostek zwraca te pola.
Miniatura potrzebuje oddzielnego, uwierzytelnionego pobrania lub zasobu MXC;
nie pobieramy całego filmu do wyświetlenia plakatu. Ustalić wersjonowanie/
capability, limity długości tekstu i rozmiaru, ważność cache oraz zakres konta.
Starsza odpowiedź bez opisu nadal działa. Kolejność albumów pozostaje stabilna.

Opis jest zwykłym tekstem, bez wykonywania HTML. Canonical URL przechodzi
walidację schematu i hosta; przekierowania i zasoby pobiera mostek z kontrolą
SSRF. Dane sesji Instagram/Meta i podpisane adresy CDN nie trafiają do klienta
ani do logów. Zmiany forka mostka trzeba przygotować i przetestować oddzielnie;
sam klient nie doda opisów, których serwer nie udostępnia.

## Etap 2 — karta i odtwarzanie

- Model metadanych oraz cache opisu/plakatu oddzielić od pobranego filmu.
  Poster/metadata mogą ładować się dla widocznej karty zgodnie z ustawieniem
  podglądów linków; film dopiero po Play. Bez automatycznego odtwarzania dźwięku.
- Stany karty: miniatura/loading → Play → pobieranie → odtwarzanie/pauza →
  koniec/replay; osobno niedostępne media i ponowienie.
- Jeden aktywny odtwarzacz. Przewinięcie poza ekran, zmiana czatu/konta,
  blokada telefonu i przejście w tło zatrzymują odtwarzanie i zwalniają dekoder.
  Pełny ekran zachowuje pozycję i nie uruchamia drugiej kopii dźwięku.
- Opis pod kadrem ma wygląd caption, wyraźną semantykę linku i etykietę
  dostępności. Długi opis może być skrócony; osobne „Show description” rozwija
  tekst, natomiast dotknięcie samego opisu zawsze otwiera oryginał.
- Użyć tokenów i istniejących elementów Notion. Przewidzieć mobile portrait,
  landscape/tablet/desktop, duży tekst, jasny/ciemny motyw i reduced motion.
- View-once, znikające i usunięte wiadomości nie inicjują pobrań w tle.
  Usunięcie/ukrycie zatrzymuje player. Dane cache pozostają ograniczone i
  przypisane do konta; nie zmienia się szyfrowanie pokoju.

## Etap 3 — testy i odbiór

- Testy parserów i kontraktu: reel/post/album, brak opisu, niedozwolony URL,
  stare odpowiedzi, wygasły dostęp, prywatny lub usunięty materiał, timeout.
- Widgety: jeden renderer linka, własny komentarz zachowany, opis otwiera
  canonical URL, Play nie otwiera linka, długi opis i duży tekst bez overflow.
- Kontrolery: pauza po scroll/background, zwalnianie zasobów, powrót z full
  screen bez restartu i podwójnego audio; zmiana konta nie pokazuje starego cache.
- Regresje: zwykłe wideo, głosówki, okrągłe nagrania, albumy, reply/forward,
  szyfrowane załączniki, usunięcia, view-once i praca offline.
- Odbiór na fizycznym iPhonie w release: rolka udostępniona przez Instagram,
  WhatsApp i Messenger; prawdziwy opis, odtwarzanie i powrót z tła. Osobno
  mostek Meta/Facebook. Wyniki fixture nie zastępują tego odbioru.

Kolejność realizacji: kontrakt i metadane mostka → model/cache → karta i
klikany opis → player inline/lifecycle → testy i odbiór release → Facebook.
