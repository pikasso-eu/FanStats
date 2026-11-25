# FanStats

Menüleisten-Monitor für Lüfter, Temperaturen und Leistungsaufnahme auf **Intel-
und Apple-Silicon-Macs**. Liest direkt über den `AppleSMC`-Userclient (IOKit) –
ohne Kernel-Extension, ohne root.

Entstanden für einen iMac Pro (iMacPro1,1), auf dem die Lüfter mit einem zweiten
Monitor sporadisch hochdrehen. Erster Schritt ist die Mesßbarkeit: **was** wird
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
> Sandbox — etwa über die DSH-Oberfläche — ist das Ausführen setuid-rooter
> Programme gesperrt, dann greift automatisch die native Quelle. Die erfasst
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

### Warum die Auswertung mit Medianen arbeitet

Der erste Durchlauf auf diesem iMac Pro hat genau gezeigt, warum Mittelwerte
hier nutzlos sind. Über 15:31 min mit den Phasen 1× → 2× → 1× Bildschirm kamen
zwei völlig unterschiedliche Dinge zusammen:

| | Phase 1 (1×) | Phase 2 (2×) | Phase 3 (1×) |
|---|---|---|---|
| CPU-Leistung **Median** | 18,3 W | **44,3 W** | 37,4 W |
| CPU-Temperatur Median | 64,5 °C | **80,3 °C** | 77,1 °C |
| Lüfter Median | 1300 rpm | 1414 rpm | **2160 rpm** |
| Zeitanteil > 30 W | 10,3 % | 62,6 % | 76,5 % |
| Spitze CPU-Leistung | **122 W** | 113 W | 64 W |

Die Mittelwerte suggerieren „der zweite Monitor heizt ein". Der Blick auf die
Spitzen zeigt das Gegenteil: Der **größte Ausschlag der ganzen Messung (122 W,
96 °C, 66 % System-CPU) passierte in Phase 1, also ohne zweiten Monitor**. Und
die Dauerlast in Phase 2/3 begann erst 160 s nach dem Anstecken und lief noch
230 s nach dem Abziehen weiter — sie korreliert nicht mit dem Monitor.

Deshalb filtert `analyze.sh` alle Werte mit nennenswerter Hintergrundlast
(Standard: System-CPU < 3 %) heraus und vergleicht erst dann:

```
=== Vergleich nach Bildschirmzahl, nur Werte mit System-CPU < 3,0 % ===
  Grundlage: 359 Werte mit 1 Bildschirm, 109 mit 2

  Kennzahl           1 Bildschirm  2 Bildschirme Differenz
  CPU-Temperatur     64,7 °C       66,2 °C       +1,5 °C
  GPU-Temperatur     65,8 °C       66,4 °C       +0,6 °C
  CPU-Leistung       18,3 W        21,9 W        +3,6 W
  GPU-Leistung       11,6 W        12,5 W        +0,9 W
  GPU gesamt         17,7 W        19,0 W        +1,4 W
  GPU-Auslastung     0 %           0 %           +0 %
  Lüfter 1           1354 rpm      1404 rpm      +50 rpm
```

**Ergebnis: der zweite Monitor kostet rund 3,6 W CPU und 1 W GPU — das reicht
nicht, um Lüfter von 1300 auf 2300 rpm zu treiben.** Was in dieser Messung die
Lüfter hochtrieb, war eine Hintergrundlast, die es mit und ohne Monitor gab.

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
> [Auflösungsvergleich](#auflösungsvergleich-messung-vom-1210). Die Tabelle
> bleibt als Nachschlagehilfe stehen, die Vermutung dahinter hat sich so nicht
> bestätigt.

**Experiment:**

```bash
./measure.sh
# 5 min: externer Monitor nativ
# dann in den Systemeinstellungen auf den heruntergerechneten Modus umstellen
# 5 min warten, dann zurückstellen
# Ctrl-C, danach:
./analyze.sh <csv>
```

`fanlog` erkennt den **Auflösungswechsel** selbst — nicht nur das Anstecken — und
legt eine neue Phase an. `analyze.sh` stellt die Aufbauten dann nebeneinander:

```
=== Vergleich nach Aufbau, nur Werte mit System-CPU < 3,0 % ===

  Kennzahl          1× · 14,8 MP   2× · 23,0 MP   2× · 16,8 MP   Differenz
  (Werte)           26            12             30
  -------------------------------------------------------------------------
  GPU-Leistung      8,5 W         9,2 W          10,9 W         +2,4 W
  GPU-Temperatur    63,3 °C       63,4 °C        70,6 °C        +7,3 °C
```

### Auflösungsvergleich (Messung vom 12.10.)

Der externe Monitor ist ein 4K-Panel, und der Rechner wurde in vier Aufbauten
vermessen. Werte = lastbereinigte Mediane (System-CPU < 3 %):

| Aufbau | Framebuffer | GPU-Leistung | GPU-Temp | CPU-Leistung | Lüfter |
|---|---|---|---|---|---|
| nur intern | 14,8 MP | 8,5 W | 63,3 °C | 18,7 W | 1103 rpm |
| + extern **4K nativ** | 23,0 MP | 9,2 W | 63,4 °C | 23,1 W | 1102 rpm |
| + extern 1920×1080 | 16,8 MP | 10,9 W | 70,6 °C | 23,0 W | 1304 rpm |
| + extern 2048×1152 | 17,1 MP | 13,5 W | 72,0 °C | 22,7 W | 1565 rpm |

**Ergebnis: die native 4K-Auflösung ist der günstigste Modus für die GPU** —
9,2 W statt 13,5 W, und die Lüfterdrehzahl bleibt exakt auf dem Niveau des
Einzelbildschirms (1102 gegenüber 1103 rpm). Die *niedrigeren* Auflösungen
kosten 2–4 W **mehr**, obwohl sie weniger Pixel haben: die Display-Engine muss
sie dann auf die 4K-Panel-Auflösung hochrechnen.

Da die Phasen zeitlich hintereinander liegen, ist der Vergleich zusätzlich
durch die Aufwärmung des Gehäuses belastet. Deshalb hier die Fenster direkt um
die Moduswechsel, bei praktisch gleicher Hintergrundlast und GPU-Temperatur —
die stützen das Ergebnis unabhängig von der Drift:

| Fenster | Modus | GPU W | GPU °C | SysCPU |
|---|---|---|---|---|
| t=70–83 s | 4K nativ | 9,4 W | 64,1 °C | 16,6 % |
| t=88–100 s | 1920×1080 | 11,8 W | 65,7 °C | 17,4 % |
| t=190–209 s | 1920×1080 | 10,6 W | 70,5 °C | 3,4 % |
| t=215–240 s | 2048×1152 | 13,2 W | 71,0 °C | 7,5 % |

**Empfehlung: die native Auflösung des externen Monitors verwenden** („Standard
für Display" bzw. 3840 × 2160). Das ist nicht nur die schärfste, sondern auch
die für die GPU billigste Einstellung.

> **Einordnung:** Die Effekte liegen bei 2–4 W. Die Lüfter bewegten sich in
> derselben Messung zwischen 1100 und 1565 rpm, angetrieben von der CPU-Last
> (bis 110 W, 80 % System-CPU), die in **jeder** Phase auftrat — auch ohne
> zweiten Monitor. Die Auflösung ist also ein Feinabstimmer, nicht die Ursache.

> **Nachtrag:** Die Empfehlung „nativ ist am günstigsten" hat sich in der
> [nächsten Messung](#die-ursache-messung-vom-1210-1939) **nicht bestätigt**.
> Dort war die größte Framebuffer-Fläche der Messung (40,1 MP,
> heruntergerechnet) die kühlste Phase, und ein 24,2-MP-Modus die wärmste — es
> gibt keinen belastbaren Zusammenhang zwischen Auflösung und GPU-Leistung. Die
> 2–4 W Unterschiede in dieser Tabelle laufen mit der GPU-Temperatur mit, nicht
> mit dem Modus. Die native Auflösung bleibt die sinnvolle Wahl, aber aus
> Schärfegründen, nicht wegen der Lüfter.

### Die Ursache (Messung vom 12.10., 19:39)

Diese Messung hatte erstmals funktionierende Prozessdaten — damit stand der
Verursacher fest. Der Reihe nach:

**1. Die Auflösung ist es nicht.** Diesmal wurden auch die HiDPI-„sieht aus
wie"-Modi durchgemessen, inklusive des heruntergerechneten Falls mit **40,1 MP**
Framebuffer (6720 × 3780 für ein 4K-Panel). Ergebnis: kein Zusammenhang.

| Aufbau | Framebuffer | GPU-Leistung | GPU-Temp | Lüfter |
|---|---|---|---|---|
| 2× 2048×1152 @2× (heruntergerechnet) | 24,2 MP | 13,8 W | 71,5 °C | 1646 rpm |
| 2× 3360×1890 @2× (heruntergerechnet) | **40,1 MP** | **10,2 W** | 67,7 °C | **1549 rpm** |
| 2× 3840×2160 (nativ) | 23,0 MP | 9,9 W | 66,2 °C | 1654 rpm |
| 1× intern | 14,8 MP | 9,2 W | 67,2 °C | 1790 rpm |

Die **größte** Framebuffer-Fläche der ganzen Messung war die **kühlste** Phase.
Damit ist die Pixelmenge als Erklärung erledigt. (Dass 13,8 W und 10,2 W
auseinanderliegen, läuft mit der GPU-Temperatur mit — das ist Leckstrom, nicht
Rechenlast.)

**2. Video-Dekodierung — und sie halbiert sich, wenn der zweite Monitor
weggeht.** Zum Zeitpunkt t=304/305 wurde der externe Monitor abgezogen:

```
t=293s  2 Bildschirme   VTDecoderXPCServ  91 %
t=298s  2 Bildschirme   VTDecoderXPCServ  91 %
t=303s  2 Bildschirme   VTDecoderXPCServ  92 %
t=305s  1 Bildschirm    --- Monitor abgezogen ---
t=308s  1 Bildschirm    VTDecoderXPCServ  44 %
t=313s  1 Bildschirm    VTDecoderXPCServ  44 %
```

Jeder Bildschirm dekodiert sein **eigenes** Video. Ursache ist die
Wallpaper-Konfiguration dieses Macs:

```
Provider = com.apple.wallpaper.choice.aerials
Type     = continous
```

Also **durchlaufende Aerial-Video-Wallpaper**, und das auf jedem Bildschirm.
`WallpaperVideoExtension` und `WallpaperAgent` liefen während der Messung
dauerhaft. Das ist eine Last, die im Leerlauf nie verschwindet.

**3. Die stärksten Lüfterausschläge kamen von zwei anderen Prozessen.**

| Zeit | Prozess | CPU | CPU-Paket | CPU-Temp | Lüfter |
|---|---|---|---|---|---|
| 128–138 s | `llama-server` | **880–1070 %** | 120 W | **99 °C** | 1727 → 2294 rpm |
| 0–60 s | `contactsd` | 72–74 % | 61–66 W | 82–85 °C | 1567–1643 rpm |
| durchgehend | `VTDecoderXPCServ` | 44–99 % | — | — | — |

`llama-server` allein hat 10 der 16 Threads belegt und die CPU auf 99 °C
getrieben.

> **Einschränkung:** Nach dem erneuten Anstecken bei t=413 blieb die
> Dekodierung bei 44 % statt wieder auf 91 % zu steigen. Die Verdopplung trat
> also nicht bei jedem Anstecken auf. Der Sprung 91 → 44 beim Abziehen ist
> aber eindeutig und fällt exakt auf die Sekunde des Monitorwechsels.

### Was daraus folgt

1. **Statisches Wandbild setzen** (Systemeinstellungen → Wandbild), und zwar für
   **beide** Bildschirme. Das entfernt die dauerhafte Video-Dekodierung — laut
   Messung bis zu 99 % eines Kerns, die sich mit zwei Bildschirmen verdoppelt.
2. **`contactsd` prüfen** (Kontakte-/iCloud-Abgleich) — mit 74 % der
   zweitgrößte Posten.
3. **`llama-server`** ist eigene Last. Wenn er unerwartet läuft, erklärt er
   99 °C und volle Lüfter.

**Das erklärt auch die ursprüngliche Beobachtung:** Ein zweiter Monitor bringt
ein zweites Video-Wallpaper mit, die Dekodierlast verdoppelt sich, die Lüfter
drehen hoch. Nur eben nicht wegen der Pixel, sondern wegen des Videos.

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
