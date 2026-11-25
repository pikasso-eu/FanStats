# FanStats

Menüleisten-Monitor für Lüfter, Temperaturen und Leistungsaufnahme auf **Intel-
und Apple-Silicon-Macs**. Liest direkt über den `AppleSMC`-Userclient (IOKit) –
ohne Kernel-Extension, ohne root.

Entstanden für einen iMac Pro (iMacPro1,1), auf dem die Lüfter mit einem zweiten
Monitor sporadisch hochdrehen. Erster Schritt ist die Messbarkeit: **was** wird
eigentlich heiß, **bevor** man an der Lüfterkurve dreht.

Die App wird als Universal-Binary gebaut und läuft nativ auf beiden
Architekturen. Die Sensor-Keys unterscheiden sich allerdings – siehe
[Apple Silicon](#apple-silicon).

> Aktueller Stand: **nur Anzeige.** Lüfter lassen sich noch nicht steuern (siehe unten).

## Was in der Menüleiste steht

```
C 72°  G 70°  1884 rpm
```

Konfigurierbar im Menü unter *In der Menüleiste zeigen*: CPU-Temperatur,
GPU-Temperatur, Lüfter-Drehzahl, CPU-Leistung, Beschriftung, Rotfärbung ab 85 °C.

Im aufgeklappten Menü stehen zusätzlich:

| Zeile | Bedeutung |
|---|---|
| `CPU (PECI)` | `TCXc` – heißester CPU-Kern (PECI-Schnittstelle) |
| `CPU Proximity (TC0P)` | Sensor direkt am CPU-Sockel |
| `Leistung: CPU … W · GPU … W` | `PC0C` / `PG0C` – **die eigentliche Hitzequelle** |
| `Lüfter n` | `F<n>Ac` mit Auslastung zwischen min und max |
| Untermenü Lüfter | Modus (auto/manuell), Zielwert `F<n>Tg`, Bereich `F<n>Mn`/`F<n>Mx`, PWM `F<n>Dc` |
| `Alle Sensoren` | alle gefundenen Temperatursensoren, nach Zone gruppiert |

## Bauen und starten

Voraussetzungen: Intel- oder Apple-Silicon-Mac, macOS 13 oder neuer, Xcode
(oder nur Command Line Tools).

```bash
./build_app.sh          # baut dist/FanStats.app (arm64 + x86_64)
open dist/FanStats.app   # startet in der Menüleiste, kein Dock-Symbol
```

`build_app.sh` baut **beide** Architekturen und fügt sie mit `lipo` zu einem
Universal-Binary zusammen. Das geht auf jedem Host, egal ob Intel oder Apple
Silicon – die macOS-SDK enthält beide Slice-Typen:

```bash
lipo -archs dist/FanStats.app/Contents/MacOS/FanStats   # x86_64 arm64
```

Die Build-Caches liegen getrennt unter `.build/arm64` und `.build/x86_64`.
Nach einem Wechsel des Rechners reicht ein erneutes `./build_app.sh`.

Die App läuft ohne Apple-Developer-Account (Ad-hoc-signiert). Beim ersten Start
fragt macOS nicht nach Sonderrechten, weil nur gelesen wird.

**Autostart:** Systemeinstellungen → Allgemein → Anmeldeobjekte → `FanStats.app`
hinzufügen. (Alternativ die App nach `/Applications` kopieren und von dort starten.)

**Beenden:** Menü → *FanStats beenden*.

## Messung: zweiter Monitor und Lüfter

`fanlog` protokolliert Temperaturen, Leistungsaufnahme, GPU-Last, Lüfterdrehzahl
**und den jeweils stärksten Prozess** und erkennt von selbst, wenn ein Bildschirm
dazukommt oder weggeht.

```bash
./measure.sh              # 1 Wert pro Sekunde, CSV im Projektordner
./measure.sh -i 2         # alle 2 Sekunden
./measure.sh -o lauf.csv  # eigener Dateiname

./analyze.sh lauf.csv     # Auswertung (Median, lastbereinigt, Spitzen)
```

> **Zur Prozessmessung.** `fanlog` nutzt zwei Quellen: `/bin/ps` (alle Prozesse,
> aber setuid root) und `proc_pid_rusage` (nativ, ohne Sonderrechte). In einer
> Sandbox ist das Ausführen setuid-rooter Programme gesperrt, dann greift
> automatisch die native Quelle. Die erfasst
> alle Prozesse **deines Benutzers**, aber keine root-Prozesse wie
> `WindowServer`, `mds_stores` oder `backupd`. Für die volle Abdeckung daher
> **in Terminal.app** messen; `fanlog` sagt am Ende, welche Quelle lief und wie
> viele Prozesse gesperrt waren.

Ablauf:

1. Mac 10 Minuten in Ruhe lassen, nichts starten. Bildschirmschoner und
   Ruhezustand für die Dauer der Messung abschalten.
2. `./measure.sh` starten.
3. **5 Minuten** nur mit internem Display laufen lassen.
4. Zweiten Monitor anstecken, **5 Minuten** warten — nichts anderes tun.
5. Monitor wieder abziehen, **5 Minuten** warten.
6. `Ctrl-C`. Am Ende listet `fanlog` die Prozesse nach mittlerer CPU-Last auf.
7. `./analyze.sh <csv>` für die vollständige Auswertung.

### Was die Auswertung leisten kann: eine Fallstudie

Wie eine Messung mit `fanlog` und `analyze.sh` zur Antwort führt, zeigt eine
ausführliche Fallstudie im Repo:
**[Zweiter Monitor und Lüfter – warum dreht er wirklich hoch?](docs/messungen.md)**.
Kurz gefasst: Die Lüfterausschläge kamen von Hintergrundlast (Video-Wallpaper,
Rechenprozesse) — nicht vom Monitor selbst. Ohne medianbasierte, lastbereinigte
Auswertung wäre das nicht sichtbar geworden.

### Framebuffer gegen Panel: was „skaliert" überhaupt heißt

Ein **heruntergerechneter** Modus ist etwas anderes als ein nativer: macOS
rendert dann in einen Framebuffer, der **größer ist als das Panel**, und rechnet
das Bild anschließend herunter. Die GPU beschreibt also mehr Pixel, als das
Display überhaupt anzeigen kann.

Tückisch daran: In den Systemeinstellungen steht nur „sieht aus wie 2560 × 1440".
Ob das nativ ist, hoch- oder heruntergerechnet wird, verrät die Beschriftung
nicht. `fanprobe` und das Menüleisten-Menü zeigen es deshalb explizit:

```
  1. [Haupt] [intern] 2560×1440 (Framebuffer 5120×2880, Faktor 2,00, Panel 14,7 MP)  → nativ
```

Verglichen wird der aktuelle Framebuffer mit dem **größten Modus im Modus-Angebot
der Karte** — und das ist die native Auflösung des Panels. (Geprüft: für das
interne 5K-Panel liefert `CGDisplayCopyAllDisplayModes` 20 Modi, der größte ist
5120 × 2880 = 14,75 MP; der aktive HiDPI-Modus steht gar nicht in der Liste,
weshalb der Vergleich überhaupt aussagekräftig ist.)

| Fall | Framebuffer | Panel | Bewertung |
|---|---|---|---|
| intern 5K, „sieht aus wie 2560×1440" | 5120×2880 | 5120×2880 | nativ, 14,7 MP |
| 4K extern, nativ | 3840×2160 | 3840×2160 | nativ, 8,3 MP |
| 4K extern, „sieht aus wie 2560×1440" | **5120×2880** | 3840×2160 | **heruntergerechnet, 14,7 MP** |

> **Nachtrag nach der Messung vom 12.10.:** Dieser dritte Fall ist in der
> Praxis **nicht** aufgetreten — in allen Phasen stand `skaliert = 0`. Die
> Messung hat stattdessen das Gegenteil gezeigt: nicht die *größere*
> Pixelmenge kostet, sondern jede Abweichung vom nativen Modus. Siehe
> [Auflösungsvergleich](docs/messungen.md#auflösungsvergleich-messung-vom-1210).
> Die Tabelle bleibt als Nachschlagehilfe stehen, die Vermutung dahinter hat
> sich so nicht bestätigt.

### Wohin die Auswertung schaut

- **GPU-Leistung steigt deutlich** → der Monitor belastet den Grafikchip
  (mehr Pixel, mehr Display-Engine). Dann hilft nur eine eigene Lüfterkurve.
- **CPU-Leistung und System-CPU steigen** → es arbeitet ein Prozess. Der
  Prozess-Ranking am Ende von `fanlog` und die Spalte `top_prozess` in der CSV
  benennen ihn.
- **Alles flach, Lüfter drehen trotzdem hoch** → die SMC-Regelung reagiert auf
  einen Sensor, der noch nicht im Blick ist. Dann im Menüleisten-Menü unter
  *Alle Sensoren* nachsehen, während der Monitor angesteckt ist.

Die Rohdaten liegen als CSV mit `;`-Trennung und **Punkt als Dezimaltrennzeichen**
vor. Spalten: `sekunden`, `zeit`, `bildschirme`, `cpu_c`, `gpu_c`, `cpu_w`,
`gpu_w`, `gpu_gesamt_w`, `gpu_prozent`, `vram_mb`, `luefter_1`, `luefter_2`,
`luefter_ziel`, `modus`, `system_cpu`, `windowserver`, `kernel_task`,
`top_prozess`, `top_prozent`, `schoner`, `fb_mp`, `skaliert`, `aufbau`.

`fb_mp` ist die gesamte Framebuffer-Fläche in Megapixeln, `skaliert` die Anzahl
der Bildschirme, die heruntergerechnet werden, und `aufbau` der vollständige
Aufbau-Schlüssel (z. B. `*2560x1440@2.00/5120x2880 + 1920x1080@1.00/1920x1080`).
`analyze.sh` trennt die Phasen anhand von `aufbau`, nicht anhand der
Bildschirmzahl — sonst bliebe ein Auflösungswechsel bei gleichbleibender
Bildschirmzahl unbemerkt.

## Diagnose-Werkzeug

Drei Kommandozeilen-Programme, alle ohne Xcode-Projekt baubar:

| Werkzeug | Zweck |
|---|---|
| `fanprobe` | rohe SMC-Werte anzeigen, neue Mac-Modelle erschließen |
| `fanlog` | Messreihe aufzeichnen (siehe oben), über `./measure.sh` |
| `fananalyze` | Messreihe auswerten, über `./analyze.sh` |

`fanprobe` ist nützlich, um die Key-Tabelle zu prüfen:

```bash
swift build --product fanprobe        # Binary unter .build/debug/fanprobe
./.build/debug/fanprobe               # Gruppen + Lüfter
./.build/debug/fanprobe --raw         # alle Temperatursensoren
./.build/debug/fanprobe --all         # jeder SMC-Key mit Typ, Hex und Wert
```

Ein vollständiger Dump dieses iMac Pro liegt in [`docs/smc-keys.txt`](docs/smc-keys.txt)
(933 Keys, 800 laut `#KEY`).

Die App kann ihre Live-Werte auch auf stderr schreiben:

```bash
FANSTATS_LOG=1 ./dist/FanStats.app/Contents/MacOS/FanStats
```

## Technik

Der Zugriff läuft über `IOServiceOpen("AppleSMC")` und `IOConnectCallStructMethod`
mit der 80-Byte-Struktur `SMCKeyData_t`:

| Offset | Feld |
|---|---|
| 0 | `key` (FourCC, z. B. `TCXc`) |
| 28 / 32 | `keyInfo.dataSize` / `dataType` |
| 42 | Kommando (`5` = Bytes lesen, `9` = Key-Info) |
| 44 | `data32` (Index) |
| 48 | `bytes[32]` (Nutzdaten) |

Dekodiert werden die auf beiden Architekturen vorkommenden Typen: `sp78`
(Temperatur, Signed 8.8), `fpe2`, `flt ` (**Little-Endian!**), `ui8/16/32`,
`si8/16`.

Der `flt `-Little-Endian-Punkt ist die klassische Stolperfalle: `F0Mn`/`F0Mx`
liefern nur dann 1100 / 2784 rpm statt 0, wenn man die vier Bytes als
Little-Endian-Float liest.

Beim Start sucht die App einmalig alle Temperatursensoren (alle Keys mit
Präfix `T`, plausibler Wert zwischen 5 und 125 °C). Dadurch funktioniert sie
auf anderen Mac-Modellen, ohne Key-Tabellen zu pflegen.

## Apple Silicon

Die SMC-Schnittstelle selbst ist auf beiden Architekturen dieselbe: derselbe
`AppleSMC`-Dienst, dieselbe 80-Byte-Struktur, derselbe Userclient-Index. Auch
ein x86_64-Prozess unter Rosetta darf lesen. Unterschiedlich sind nur die
**Keys** – und ein Datentyp, der alles entscheidet.

`SMCCore` erkennt den Unterbau über `sysctl hw.optional.arm64` (das ist auch
unter Rosetta gesetzt) und wählt die passenden Keys:

| Größe | Intel | Apple Silicon |
|---|---|---|
| CPU-Temperatur | `TCXc` (PECI-Maximum) | `TCMz`/`TCMb` (CPU-Die), sonst heißester `Tp…` |
| GPU-Temperatur | `TG0D` | `TRDX` (GPU-Die), sonst heißester `Tg…` |
| CPU-/GPU-Leistung | `PC0C` / `PG0C` | nicht getrennt vorhanden |
| Gesamtleistung | – | `PSTR` (Total Board Power) |
| Lüftermodus | `F0Md` | `F0md` (kleines `d`) |
| Temperatur-Datentyp | `sp78` u. a. | fast immer `flt ` |

**Der `flt `-Typ ist der entscheidende Punkt.** Die Sensor-Suche filtert auf
bekannte Datentypen. Solange `flt ` fehlte, fand sie auf Apple Silicon keinen
einzigen Temperatursensor: Die App zeigte nur die Lüfterdrehzahl, CPU und GPU
blieben bei „–", „Alle Sensoren" bei 0. Genau das war der Fehler auf dem M5 Max.

Die Schlüssel sind außerdem case-sensitive: Intel schreibt `TC`/`TG`/`F0Md`,
Apple Silicon `Tp`/`Tg`/`TRD`/`F0md`. Beide Schreibweisen stehen jetzt als
Fallback in `Machine.swift`.

Gemessen auf einem M5 Max (Mac17,14), einmal im Leerlauf und einmal mit acht
Kernen unter `yes`-Last:

| Größe | Leerlauf | 8 Kerne |
|---|---|---|
| CPU-Die (`TCMb`) | 43 °C | 54 °C |
| CPU-Cluster (`Tp0C`) | 31 °C | 46 °C |
| GPU (`TRDX`) | 32 °C | 32 °C |
| Systemleistung (`PSTR`) | 10 W | 33 W |
| Lüfter | 1000 rpm | 1000 rpm |

In diesem kurzen Test blieben die Lüfter auf ihrem Minimum (1000 rpm, Maximum
3625 rpm): Die Regelung reagierte träge. Für die Ursachensuche ist das günstig
– die Temperatur- und Leistungswerte steigen, lange bevor der Lüfter hörbar
wird. Ein Langzeittest mit mehreren Minuten Last steht noch aus.

`fanlog` protokolliert auf Apple Silicon Temperaturen, Lüfter und GPU-Last wie
gewohnt. Die Spalten `cpu_w`, `gpu_w` und `gpu_gesamt_w` bleiben dort leer,
weil die Intel-Keys (`PC0C`, `PG0C`, `PGTR`) fehlen. Die Gesamtleistung
(`PSTR`) zeigt stattdessen das Menü der App.

Ein vollständiger Key-Dump dieses M5 Max liegt in
[`docs/smc-keys-m5-max.txt`](docs/smc-keys-m5-max.txt) (2263 Keys).

## Gemessen auf diesem iMac Pro (Intel-Referenz)

| Größe | Key | Beobachtet |
|---|---|---|
| CPU-Kerne | `TCXc`, `TC0c`…`TC7c` | 70 °C idle, 92 °C unter Kompilierlast |
| GPU Die | `TG0D` | 66–70 °C |
| GPU Hotspot | `TG1F`, `TG3d` | bis ~70 °C |
| CPU-Leistung | `PC0C` | ~55 W |
| GPU-Leistung | `PG0C` | ~13 W |
| Lüfter 1 / 2 | `F0Ac` / `F1Ac` | 1500 rpm idle → 1913 rpm unter Last |
| Lüfter-Bereich | `F0Mn` / `F0Mx` | 1100 … 2784 rpm |
| Lüfter-Modus | `F0Md` | 0 = automatisch |

**Auffällig:** `FNum` = 2, beide Lüfter laufen praktisch synchron, und die
SMC-Regelung fährt schon bei ~70 °C CPU auf über 1800 rpm hoch. Das ist der
Grund, warum ein zweiter Monitor (mehr Pixel → mehr GPU-Leistung → mehr
Abwärme) die Lüfter hörbar macht.

## Nächster Schritt: Lüfter steuern

Technisch ist der Weg klar, er ist nur nicht mehr schreibgeschützt:

1. `F<n>Md` = `1` setzen (manueller Modus), dann `F<n>Tg` auf die Wunschdrehzahl.
   Vorher `F<n>Mn`/`F<n>Mx` als sichere Grenzen lesen und **niemals** außerhalb
   schreiben.
2. Schreiben auf den SMC verlangt **root** – eine normale App darf das nicht.
   Übliche Lösung:
   - **Privilegierter Helper** per `SMAppService` (macOS 13+) oder `SMJobBless`,
     der als root läuft und über XPC nur „setze Lüfter n auf rpm x" entgegennimmt,
     plus
   - eine **Watchdog**-Funktion im Helper: fällt die App aus oder wird sie beendet,
     schaltet der Helper den Lüfter nach ~10 s auf `F<n>Md = 0` (automatisch) zurück.
     Ohne so einen Rückfall bleibt der Mac sonst mit falsch gesetzter Drehzahl zurück.
3. Alle Schreibversuche protokollieren und mit `F<n>Ac` gegenprüfen, ob der Wert
   tatsächlich angenommen wurde – die SMC-Regelung überschreibt manche Keys.

Auf Apple Silicon heißt der Modus-Key `F<n>md` (kleines `d`). Ob der
Schreibzugriff dort überhaupt möglich ist, ist **ungetestet**: Apple beschränkt
den SMC-Schreibzugriff auf neueren Geräten zusätzlich, vermutlich über eine
Entitlement-Prüfung im Treiber. Die Anzeige funktioniert unabhängig davon.
