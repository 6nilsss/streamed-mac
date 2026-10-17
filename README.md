# Streamed für Mac

Multistream-Player für Live-Fußball auf macOS (nur Apple Silicon, macOS 13+). Blockt Werbung und Popups, wählt automatisch den besten Stream und wechselt bei Lag.

## Download

Rechts unter **Releases** die Datei `Streamed.zip` laden.

## Installieren

1. ZIP öffnen und `Streamed.app` in den Ordner **Programme** ziehen.
2. Erster Start: Rechtsklick auf die App → **Öffnen** → **Öffnen**. Oder Systemeinstellungen → Datenschutz & Sicherheit → **Trotzdem öffnen**.
3. Meldet macOS „beschädigt“, einmal im Terminal ausführen:
   `xattr -dr com.apple.quarantine /Applications/Streamed.app`

## Bedienung

| Taste | Funktion |
|---|---|
| Doppelklick | Spiel öffnen |
| ▦ Multistream | mehrere Spiele gleichzeitig (bis 6) |
| Klick auf Kachel | Ton dieses Spiels |
| F / Doppelklick | Vollbild, Esc raus |
| ← → | 10 s zurück / vor, L = Live |
| [ ] | anderen Stream, A = Automatisch |
| G | Raster oder Fokus-Ansicht |

## Selbst bauen

Braucht nur die Xcode Command Line Tools: `./build.sh` (installiert nach `~/Applications`).
