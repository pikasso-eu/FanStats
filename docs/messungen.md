# Fallstudie: zweiter Monitor und Lüfter

Diese Messreihe (iMac Pro, Oktober 2026) ist der Grund, warum es `fanlog` und
`analyze.sh` gibt: Die Lüfter drehten sporadisch hoch, wenn ein zweiter Monitor
angesteckt war — und die Ursache war alles andere als offensichtlich.
Aufgezeichnet mit `./measure.sh`, ausgewertet mit `./analyze.sh`. Die Rohdaten
(CSV) sind nicht im Repo; eine lastbereinigte Baseline ohne Monitor liegt in
[`baseline-ohne-monitor.txt`](baseline-ohne-monitor.txt).

## Warum die Auswertung mit Medianen arbeitet

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

## Experiment: nativ gegen heruntergerechnet

Um zu prüfen, ob nicht die *Art* des Modus (nativ vs. skaliert, siehe
[Framebuffer gegen Panel](../README.md#framebuffer-gegen-panel-was-skaliert-überhaupt-heißt)
im README) den Ausschlag gibt:

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

## Auflösungsvergleich (Messung vom 12.10.)

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

## Die Ursache (Messung vom 12.10., 19:39)

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

**2. Video-Dekodierung — und sie halbiert sich, wenn der zweite Monitor weggeht.**
Zum Zeitpunkt t=304/305 wurde der externe Monitor abgezogen:

```
t=293s  2 Bildschirme   VTDecoderXPCServ  91 %
t=298s  2 Bildschirme   VTDecoderXPCServ  91 %
t=303s  2 Bildschirme   VTDecoderXPCServ  92 %
t=305s  1 Bildschirm    --- Monitor abgezogen ---
t=308s  1 Bildschirm    VTDecoderXPCServ  44 %
t=313s  1 Bildschirm    VTDecoderXPCServ  44 %
```

Jeder Bildschirm dekodiert sein **eigenes** Video. Ursache war die
Wallpaper-Konfiguration des Geräts: durchlaufende **Aerial-Video-Wallpaper**
(`com.apple.wallpaper.choice.aerials`) — aktiv auf jedem Bildschirm einzeln.
`WallpaperVideoExtension` und `WallpaperAgent` liefen während der Messung
dauerhaft. Das ist eine Last, die im Leerlauf nie verschwindet.

**3. Die stärksten Lüfterausschläge kamen von zwei anderen Prozessen.**

| Zeit | Prozess | CPU | CPU-Paket | CPU-Temp | Lüfter |
|---|---|---|---|---|---|
| 128–138 s | lokaler LLM-Server | **880–1070 %** | 120 W | **99 °C** | 1727 → 2294 rpm |
| 0–60 s | `contactsd` | 72–74 % | 61–66 W | 82–85 °C | 1567–1643 rpm |
| durchgehend | `VTDecoderXPCServ` | 44–99 % | — | — | — |

Der LLM-Server allein hatte 10 der 16 Threads belegt und die CPU auf 99 °C
getrieben.

> **Einschränkung:** Nach dem erneuten Anstecken bei t=413 blieb die
> Dekodierung bei 44 % statt wieder auf 91 % zu steigen. Die Verdopplung trat
> also nicht bei jedem Anstecken auf. Der Sprung 91 → 44 beim Abziehen ist
> aber eindeutig und fällt exakt auf die Sekunde des Monitorwechsels.

## Was daraus folgt

1. **Statisches Wandbild setzen** (Systemeinstellungen → Wandbild), und zwar für
   **beide** Bildschirme. Das entfernt die dauerhafte Video-Dekodierung — laut
   Messung bis zu 99 % eines Kerns, die sich mit zwei Bildschirmen verdoppelt.
2. **`contactsd` prüfen** (Kontakte-/iCloud-Abgleich) — mit 74 % der
   zweitgrößte Posten.
3. **Eigene Rechenlast** — bei dieser Messung ein lokal laufender LLM-Server —
   erklärt 99 °C und volle Lüfter, wenn sie unerwartet läuft.

**Das erklärt auch die ursprüngliche Beobachtung:** Ein zweiter Monitor bringt
ein zweites Video-Wallpaper mit, die Dekodierlast verdoppelt sich, die Lüfter
drehen hoch. Nur eben nicht wegen der Pixel, sondern wegen des Videos.
