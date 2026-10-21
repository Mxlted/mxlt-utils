# Changelog

## Unreleased

- Harden Accessibility revocation cleanup: detach the scrolling input filter from a background watchdog, cancel queued work, preserve feature choices, and explicitly allow hardware input during generated events.
- Make middle scrolling accelerate progressively with distance from the anchor, with finer control nearby and more speed available farther away. Retain the speed slider and immediate stops.
- Fix middle clicks being discarded in bookmark-folder menus and other elevated app windows while Middle scrolling is enabled. Keep replay pinned to the original window, bounds and level.

## 0.3.0

- Introduce the Fold app icon with a mint geometric mark on charcoal.
- Extend middle scroll speed to 10× with a continuous slider free of crowded tick marks. Smooth scrolling uses its default response.
- Align smooth middle scrolling with the anchor display's refresh rate, including high-refresh displays.
- Keep scroll speed steadier when target validation skips a frame, with bounded travel after delays and immediate stops.

## 0.2.0

- Add optional smooth middle scrolling, enabled by default, with eased speed changes and a 60 Hz output timer. Dead-zone return, release, and cancellation still stop immediately.
- Preserve the smoothing preference across feature toggles and relaunches; keep ordinary wheel and trackpad input unchanged.
- Refresh the README and repository presentation to reflect an expanding collection of independent Mac utilities.

## 0.1.0

- New native menu bar app with independent feature switches, global pause, compact settings, Accessibility recovery, optional launch at login, and session-only diagnostics.
- CallQuits integration preserves verified red-button, native tab-close, and Command-W behavior, graceful quit safeguards, editable exceptions, and explicit Shift-click force quit.
- Middle-button hold scrolling adds continuous vertical/horizontal/diagonal movement, sensitivity/dead-zone/direction settings, target pinning, short-click preservation, Escape cancellation, and app exceptions.
- Original icon and MIT-licensed, dependency-free Swift package foundation with behavior tests and unsigned CI builds.
