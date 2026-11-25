import Foundation

// fananalyze - wertet eine fanlog-CSV aus.
//
// Mittelwerte sind hier irreführend: eine einzige Hintergrundlast von ein paar
// Minuten verschiebt den Mittelwert einer ganzen Phase. Deshalb arbeitet dieses
// Werkzeug mit Median und Perzentilen und vergleicht zusätzlich nur die
// Messwerte, die ohne nennenswerte Hintergrundlast entstanden sind.
//
// Phasen werden nach dem Bildschirm-Aufbau getrennt, nicht nur nach der Anzahl:
// ein skalierter Modus kostet die GPU deutlich mehr als ein nativer, auch wenn
// die Anzahl der Bildschirme gleich bleibt.

// MARK: - Spalten

struct Column {
    let key: String
    let label: String
    let unit: String
    let decimals: Int
}

let columns: [Column] = [
    Column(key: "fb_mp", label: "Framebuffer", unit: "MP", decimals: 1),
    Column(key: "cpu_c", label: "CPU-Temperatur", unit: "°C", decimals: 1),
    Column(key: "gpu_c", label: "GPU-Temperatur", unit: "°C", decimals: 1),
    Column(key: "cpu_w", label: "CPU-Leistung", unit: "W", decimals: 1),
    Column(key: "gpu_w", label: "GPU-Leistung", unit: "W", decimals: 1),
    Column(key: "gpu_gesamt_w", label: "GPU gesamt", unit: "W", decimals: 1),
    Column(key: "gpu_prozent", label: "GPU-Auslastung", unit: "%", decimals: 0),
    Column(key: "luefter_1", label: "Lüfter 1", unit: "rpm", decimals: 0),
    Column(key: "luefter_2", label: "Lüfter 2", unit: "rpm", decimals: 0),
    Column(key: "system_cpu", label: "System-CPU", unit: "%", decimals: 1),
    Column(key: "windowserver", label: "WindowServer", unit: "%", decimals: 1),
    Column(key: "kernel_task", label: "kernel_task", unit: "%", decimals: 1),
]

func de(_ v: Double, _ decimals: Int) -> String {
    String(format: "%.\(decimals)f", v).replacingOccurrences(of: ".", with: ",")
}

func de(_ v: Double?, _ decimals: Int) -> String {
    v.map { de($0, decimals) } ?? "–"
}

func mmss(_ s: Double) -> String {
    String(format: "%d:%02d", Int(s) / 60, Int(s) % 60)
}

func pad(_ s: String, _ n: Int) -> String {
    s.count >= n ? s : s + String(repeating: " ", count: n - s.count)
}

// MARK: - Argumente

let args = Array(CommandLine.arguments.dropFirst())
guard let path = args.first, !path.hasPrefix("--") else {
    FileHandle.standardError.write("Aufruf: fananalyze messung.csv [--ruhig 3]\n".data(using: .utf8)!)
    exit(1)
}
var quietLimit = 3.0
if let i = args.firstIndex(of: "--ruhig"), i + 1 < args.count, let d = Double(args[i + 1]) {
    quietLimit = d
}

// MARK: - Einlesen

guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
    FileHandle.standardError.write("Kann \(path) nicht lesen\n".data(using: .utf8)!)
    exit(1)
}

var lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
guard !lines.isEmpty else { exit(1) }
let header = lines.removeFirst().split(separator: ";").map(String.init)
let hasLayout = header.contains("aufbau")

struct Row {
    var t: Double
    var displays: Int
    var layout: String = ""
    var megapixels: Double = 0
    var scaled: Int = 0
    var values: [String: Double] = [:]

    /// Schlüssel, nach dem Phasen getrennt werden.
    var phaseKey: String {
        layout.isEmpty ? "d\(displays)" : layout
    }

    /// Kurze, lesbare Beschreibung des Aufbaus.
    var shortLabel: String {
        var s = "\(displays)×"
        if megapixels > 0 { s += " · \(de(megapixels, 1)) MP" }
        if scaled > 0 { s += " (skaliert)" }
        return s
    }
}

var rows: [Row] = []
for line in lines {
    let parts = line.split(separator: ";", omittingEmptySubsequences: false).map(String.init)
    guard parts.count >= 3, let t = Double(parts[0]), let disp = Int(parts[2]) else { continue }
    var row = Row(t: t, displays: disp)
    for (i, name) in header.enumerated() where i < parts.count {
        if let d = Double(parts[i]) { row.values[name] = d }
    }
    if let i = header.firstIndex(of: "aufbau"), i < parts.count { row.layout = parts[i] }
    row.megapixels = row.values["fb_mp"] ?? 0
    row.scaled = Int(row.values["skaliert"] ?? 0)
    rows.append(row)
}

guard !rows.isEmpty else {
    print("Keine Daten.")
    exit(1)
}

// MARK: - Phasen

struct Phase {
    var key: String
    var label: String
    var displays: Int
    var start: Double
    var end: Double
    var rows: [Row]
}

var phases: [Phase] = []
for row in rows {
    if phases.isEmpty || phases[phases.count - 1].key != row.phaseKey {
        phases.append(Phase(key: row.phaseKey, label: row.shortLabel, displays: row.displays,
                            start: row.t, end: row.t, rows: [row]))
    } else {
        phases[phases.count - 1].end = row.t
        phases[phases.count - 1].rows.append(row)
    }
}

// MARK: - Statistik

func sortedValues(_ rows: [Row], _ key: String) -> [Double] {
    rows.compactMap { $0.values[key] }.sorted()
}

func percentile(_ sorted: [Double], _ p: Double) -> Double? {
    guard !sorted.isEmpty else { return nil }
    if sorted.count == 1 { return sorted[0] }
    let pos = p / 100 * Double(sorted.count - 1)
    let lo = Int(pos.rounded(.down)), hi = Int(pos.rounded(.up))
    if lo == hi { return sorted[lo] }
    let frac = pos - Double(lo)
    return sorted[lo] * (1 - frac) + sorted[hi] * frac
}

func median(_ rows: [Row], _ key: String) -> Double? {
    percentile(sortedValues(rows, key), 50)
}

// MARK: - Kopf

print("Datei:  \(path)")
let interval = rows.count > 1 ? (rows[rows.count - 1].t - rows[0].t) / Double(rows.count - 1) : 0
print(String(format: "Werte:  %d   Dauer: %@   Abstand: %@ s",
             rows.count, mmss(rows[rows.count - 1].t), de(interval, 1)))
if !hasLayout {
    print("Hinweis: diese CSV enthält keine Spalte 'aufbau' (ältere fanlog-Version).")
    print("         Phasen werden nur nach Bildschirmzahl getrennt.")
}
var phaseDesc: [String] = []
for (i, p) in phases.enumerated() {
    phaseDesc.append("\(i + 1): \(p.label) (\(mmss(p.start))–\(mmss(p.end)), \(p.rows.count))")
}
print("Phasen: " + phaseDesc.joined(separator: "   "))
print("")

// MARK: - Pro Phase

for (i, p) in phases.enumerated() {
    print("Phase \(i + 1): \(p.label), \(mmss(p.start)) bis \(mmss(p.end)), \(p.rows.count) Werte")
    if !p.key.isEmpty && hasLayout { print("  Aufbau: \(p.key)") }
    print("  \(pad("Kennzahl", 18)) \(pad("Median", 10)) \(pad("P10", 9)) \(pad("P90", 9)) \(pad("max", 9))")
    for c in columns {
        let s = sortedValues(p.rows, c.key)
        guard let med = percentile(s, 50) else { continue }
        print("  " + pad(c.label, 18)
              + pad("\(de(med, c.decimals)) \(c.unit)", 10)
              + pad(de(percentile(s, 10), c.decimals), 9)
              + pad(de(percentile(s, 90), c.decimals), 9)
              + pad(de(s.last, c.decimals), 9))
    }
    print("")
}

// MARK: - Lastbereinigter Vergleich nach Aufbau

print("=== Vergleich nach Aufbau, nur Werte mit System-CPU < \(de(quietLimit, 1)) % ===")
print("    (blendet Hintergrundlast aus, die mit dem Monitor nichts zu tun hat)")
print("")

let quietRows = rows.filter { ($0.values["system_cpu"] ?? 0) < quietLimit }

var groups: [(key: String, label: String, rows: [Row])] = []
for row in quietRows {
    if let i = groups.firstIndex(where: { $0.key == row.phaseKey }) {
        groups[i].rows.append(row)
    } else {
        groups.append((key: row.phaseKey, label: row.shortLabel, rows: [row]))
    }
}

if groups.count < 2 {
    print("  Zu wenig unterschiedliche Aufbauten mit ruhigen Werten")
    print("  (\(quietRows.count) ruhige Werte, \(groups.count) Aufbau/Gruppen).")
    print("  Grenze mit --ruhig <Prozent> anpassen.")
} else {
    let labelWidth = 18, colWidth = 15
    var head = "  " + pad("Kennzahl", labelWidth)
    for g in groups { head += pad(g.label, colWidth) }
    head += "Differenz"
    print(head)
    var countLine = "  " + pad("(Werte)", labelWidth)
    for g in groups { countLine += pad("\(g.rows.count)", colWidth) }
    print(countLine)
    print("  " + String(repeating: "-", count: labelWidth + colWidth * groups.count + 9))

    for c in columns where c.key != "system_cpu" {
        guard let first = median(groups[0].rows, c.key) else { continue }
        var line = "  " + pad(c.label, labelWidth)
        var medians: [Double] = []
        for g in groups {
            let m = median(g.rows, c.key)
            medians.append(m ?? .nan)
            line += pad(m.map { "\(de($0, c.decimals)) \(c.unit)" } ?? "–", colWidth)
        }
        // Differenz: letzte gegen erste Gruppe
        if let last = medians.last, !last.isNaN {
            let d = last - first
            line += (d >= 0 ? "+" : "") + de(d, c.decimals) + " " + c.unit
        }
        print(line)
    }
}
print("")

// MARK: - Spitzen

print("=== Größte Ausschläge der CPU-Leistung ===")
let spikes = rows
    .compactMap { row -> (Row, Double)? in
        guard let w = row.values["cpu_w"] else { return nil }
        return (row, w)
    }
    .sorted { $0.1 > $1.1 }
    .prefix(10)

for (row, w) in spikes {
    print("  \(mmss(row.t))  \(pad(row.shortLabel, 20)  )CPU \(de(w, 0)) W   "
          + "System-CPU \(de(row.values["system_cpu"], 1)) %   "
          + "CPU \(de(row.values["cpu_c"], 0)) °C   "
          + "Lüfter \(de(row.values["luefter_1"], 0)) rpm")
}

print("")
print("=== Zeitanteil mit CPU-Leistung über 30 W ===")
for (i, p) in phases.enumerated() {
    let over = p.rows.filter { ($0.values["cpu_w"] ?? 0) > 30 }.count
    let pct = Double(over) / Double(p.rows.count) * 100
    print("  Phase \(i + 1) (\(p.label)): \(over) von \(p.rows.count) Werten (\(de(pct, 1)) %)")
}
