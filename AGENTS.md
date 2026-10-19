# client/ — reguły dla agentów

Najpierw przeczytaj `../AGENTS.md` (granice produktu, `rtk`, izolowany toolchain, brak commitów bez zlecenia).

## UI

Każda zmiana UI w `client/` przestrzega [`DESIGN.md`](DESIGN.md) (Notion dark v2).

- Importuj `package:fluffychat/ui/notion/notion.dart`. Kolory i typografia z `context.notion`, odstępy/promienie/rozmiary z `NotionSpace`, `NotionRadius`, `NotionSize`, `NotionType`.
- Nowe ekrany składaj z prymitywów: `NotionScaffold`, `NotionSectionHeader`, `NotionListRow`, `NotionButton`, `showNotionDialog`, `showNotionSheet`, `NotionEmptyState`, `NotionTextField`. Mapowanie "zamiast X użyj Y" jest w DESIGN.md.
- Bez `Color(0x…)`, `Colors.*` (poza `transparent`), liczbowych `fontSize`/`EdgeInsets`/`circular()` poza `lib/ui/notion/`. Brakujący token albo prymityw dodaj w `lib/ui/notion/` z goldenem, nie lokalnie w ekranie.
- Szkło (blur) tylko na nagłówku, pływającym docku i composerze, wyłącznie przez `NotionGlassSurface`/`NotionGlassBar`; nigdy surowy `BackdropFilter`, nigdy na wierszach, bąblach, kartach i dialogach.
- Brak stylu komponentu Material naprawiaj w `lib/ui/notion/notion_theme.dart`, nie inline.
- Nie przepisuj masowo starych ekranów FluffyChat przy okazji innej zmiany.

## Ruch (motion)

Pełne API i przykłady: sekcja "Motion" w [`DESIGN.md`](DESIGN.md).

- Tokeny czasu i krzywych tylko z `NotionMotion` (`instant/quick/short/medium/long`, `standard/emphasized/exitFast`, sprężyny `snappy/smooth/bouncy`); bez `Duration(milliseconds: …)` w argumentach `duration:` (lint `motion-duration`).
- Ekrany nie importują `flutter_animate` ani `skeletonizer` (lint `motion-import`); używają prymitywów: `NotionPressable`, `NotionEntrance` + `NotionEntranceScope`, `NotionFadeThrough`, `NotionMorphSwitcher`, `NotionAnimatedCount`, `NotionSizeReveal`, `NotionPop`, `NotionRowHighlight`, `NotionSkeleton`, `NotionDelayedSpinner`, `NotionTypingDots`, `NotionPulse`, `showNotionCustomDialog`, `showNotionPopover`, `showNotionSheet`.
- Tylko transform i opacity; bez animowanego bluru i szkła; brak animacji elementów budowanych przy przewijaniu (stagger tylko pierwszego ekranu, maks. 10).
- Każda animacja jednorazowa kończy się tożsamością; pętle stają przy `TickerMode` off i reduced motion; reduced motion sprawdzaj wyłącznie przez `NotionMotion.reduced(context)`.
- Sprężystość (bounce) tylko na badge'ach, reakcjach, przycisku wysyłania i ikonach pustych stanów. Haptyka tylko przez `NotionHaptics.send()`/`.longPress()`.
- Brak timerów w animacjach (`Future.delayed`, `Timer`, `Animate(delay:)`): psują testy (pending timers).

## Przed oddaniem zmiany UI

```sh
rtk python3 scripts/check-design-tokens.py
rtk python3 scripts/flutter-queue.py analyze lib
rtk python3 scripts/verify-notion-ui.py --capture-dir /tmp/notion-captures
```

Linie `NEW` z lintu to Twój nowy dług; usuń je. Zmieniony golden to zmiana wizualna: obejrzyj PNG i opisz ją w raporcie.
