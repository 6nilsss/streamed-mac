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
| Spielstand + Tor-Alarm | nur für Spiele, die du gerade NICHT schaust (keine Spoiler), mit Spoiler-Schutz (Ansicht → Spoiler-Schutz, Standard 45 s) |

## Automatische Updates

Ab Version 1.5 schaut Streamed bei jedem Start auf GitHub nach einer neuen Version, lädt sie und startet neu. Läuft gerade ein Spiel, wird erst beim Beenden installiert. Die App muss dafür im Programme-Ordner liegen.

## Watch-Party

Mit einem Freund synchron schauen: Links unten **Party starten**, den Code schicken. Der Freund klickt **Beitreten…** und gibt den Code ein. Spiel, Stream, Pause und Spulen gelten dann für beide, dazu Chat und Emoji-Reaktionen. Läuft über den öffentlichen Test-Server test.mosquitto.org (ohne Anmeldung).

## Selbst bauen

Braucht nur die Xcode Command Line Tools: `./build.sh` (installiert nach `~/Applications`).
