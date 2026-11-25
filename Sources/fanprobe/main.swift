import Foundation
import SMCCore

// Kleines Diagnose-Tool: zeigt, welche SMC-Keys dieser Mac wirklich hat.

let smc: SMC
do {
    smc = try SMC()
} catch {
    FileHandle.standardError.write("FEHLER: \(error)\n".data(using: .utf8)!)
    exit(1)
}

let args = Set(CommandLine.arguments.dropFirst())

func pad(_ s: String, _ n: Int) -> String {
    s.count >= n ? s : s + String(repeating: " ", count: n - s.count)
}

let keys = smc.allKeys()
print("Modell: \(Machine.shared.displayName) · \(Machine.shared.architectureName)")
print("SMC-Keys gesamt: \(keys.count)")

print("\n=== Bildschirme ===")
let displays = Diagnostics.displays()
for (i, d) in displays.enumerated() {
    print("  \(i + 1). \(d.isMain ? "[Haupt] " : "")\(d.isBuiltin ? "[intern] " : "[extern] ")\(d.shortText)")
    print("       sichtbar \(d.logicalWidth)×\(d.logicalHeight) Punkte, "
          + "Framebuffer \(d.megapixels.formatted(.number.precision(.fractionLength(1)))) MP, "
          + "\(Int(d.refreshRate.rounded())) Hz")
}
print("  Summe Framebuffer: "
      + String(format: "%.1f", Diagnostics.totalMegapixels()) + " MP")
print("  Skalierte Bildschirme: \(Diagnostics.scaledDisplayCount()) von \(displays.count)")

let interesting = keys.filter { $0.hasPrefix("F") || $0.hasPrefix("#") }
print("\n=== Lüfter-/Steuer-Keys ===")
for k in interesting.sorted() {
    if let v = try? smc.read(k) {
        let num = v.doubleValue.map { String(format: "%.2f", $0) } ?? "-"
        print("\(pad(k, 6)) \(pad(v.dataType, 5)) \(pad("\(v.bytes.count)B", 4)) \(num)")
    }
}

// Alle Temperatursensoren: Datentyp sp78/sp87/spa5/sp4b/sp5a/sp69 oder Key beginnt mit T
let tempTypes: Set<String> = ["sp78", "sp87", "spa5", "sp4b", "sp5a", "sppc", "sp69", "sp5b", "flt "]
var temps: [(String, String, Double)] = []
for k in keys where k.hasPrefix("T") || k.hasPrefix("V") {
    guard let v = try? smc.read(k), tempTypes.contains(v.dataType),
          let d = v.doubleValue, d > -40, d < 150 else { continue }
    temps.append((k, v.dataType, d))
}

if args.contains("--all") {
    print("\n=== ALLE KEYS ===")
    for k in keys.sorted() {
        guard let v = try? smc.read(k) else { continue }
        let hex = v.bytes.map { String(format: "%02x", $0) }.joined()
        let num = v.doubleValue.map { String(format: "%.3f", $0) } ?? ""
        print("\(pad(k, 8)) \(pad(v.dataType, 5)) \(pad(hex, 20)) \(num)")
    }
}

if args.contains("--raw") {
    print("\n=== Alle Temperatursensoren (roh) ===")
    for (k, t, d) in temps.sorted(by: { $0.0 < $1.0 }) {
        print("\(pad(k, 6)) \(pad(t, 5)) \(String(format: "%7.2f", d))")
    }
} else {
    print("\n=== Temperatursensoren (heuristisch gruppiert) ===")
    let groups: [(String, (String) -> Bool)] = [
        ("CPU", { $0.hasPrefix("TC") || $0.hasPrefix("Tp") || $0.hasPrefix("Te") }),
        ("GPU", { $0.hasPrefix("TG") || $0.hasPrefix("Tg") || $0.hasPrefix("TRD") }),
        ("Ambient/Gehäuse", {
            $0.hasPrefix("TA") || $0.hasPrefix("Ta") || $0.hasPrefix("Th") || $0.hasPrefix("TB")
        }),
        ("Sonstige", { _ in true }),
    ]
    var shown = Set<String>()
    for (name, match) in groups {
        let sel = temps.filter { match($0.0) && !shown.contains($0.0) }
        guard !sel.isEmpty else { continue }
        print("\n-- \(name) --")
        for (k, t, d) in sel.sorted(by: { $0.2 > $1.2 }) {
            shown.insert(k)
            print("\(pad(k, 6)) \(pad(t, 5)) \(String(format: "%7.2f", d)) °C")
        }
    }
}

print("\n=== Lüfter (F0..F3) ===")
for i in 0...3 {
    let base = "F\(i)"
    guard let actual = smc.number(base + "Ac") else { continue }
    let minRPM = smc.number(base + "Mn")
    let maxRPM = smc.number(base + "Mx")
    let target = smc.number(base + "Tg")
    // Intel: F0Md, Apple Silicon: F0md (kleines d).
    let mode = smc.number(base + "Md") ?? smc.number(base + "md")
    let id = (try? smc.read(base + "ID"))?.bytes ?? []
    let idText = String(bytes: id, encoding: .ascii)?
        .trimmingCharacters(in: .whitespaces) ?? ""
    let name = idText.isEmpty ? "Lüfter \(i + 1)" : idText
    print("F\(i): \(Int(actual)) rpm"
        + "  min=\(minRPM.map { String(Int($0)) } ?? "?")"
        + "  max=\(maxRPM.map { String(Int($0)) } ?? "?")"
        + "  target=\(target.map { String(Int($0)) } ?? "?")"
        + "  mode=\(mode.map { String(Int($0)) } ?? "?")"
        + "  id=\(name)")
}
