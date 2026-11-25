import Foundation

// MARK: - Modelle

public struct FanReading {
    public let index: Int
    public let actual: Double?
    public let minRPM: Double?
    public let maxRPM: Double?
    public let target: Double?
    /// 0 = automatisch (SMC-Regelung), 1 = manuell
    public let mode: Int?
    /// F0Dc, 0…1
    public let duty: Double?

    public var name: String { "Lüfter \(index + 1)" }

    /// Auslastung zwischen min und max (0…1). `nil`, wenn die Grenzen fehlen.
    public var load: Double? {
        guard let a = actual, let lo = minRPM, let hi = maxRPM, hi > lo else { return nil }
        return max(0, min(1, (a - lo) / (hi - lo)))
    }
}

public struct SensorReading {
    public let key: String
    public let celsius: Double
}

public struct SensorGroup {
    public let name: String
    public let readings: [SensorReading]
}

public struct Snapshot {
    public init() {}

    public var cpu: Double?
    public var cpuProximity: Double?
    public var cpuCores: [SensorReading] = []
    public var gpu: Double?
    public var gpuProximity: Double?
    public var gpuSensors: [SensorReading] = []
    public var cpuPower: Double?
    public var gpuPower: Double?
    /// Gesamtleistung des Rechners (`PSTR`). Auf Apple Silicon gibt es keine
    /// getrennten CPU-/GPU-Leistungswerte im SMC, nur diesen Summenwert.
    public var systemPower: Double?
    /// Höchste überhaupt gefundene Temperatur.
    public var hottest: Double?
    public var fans: [FanReading] = []
    public var groups: [SensorGroup] = []

    public var maxFanRPM: Double? { fans.compactMap(\.actual).max() }
}

// MARK: - Leser

public final class Machine {
    public static let shared = Machine()

    private let smc = SMC.shared
    private let lock = NSLock()

    private var tempKeys: [String] = []
    private var didDiscover = false

    /// `flt ` fehlt auf Intel-Macs fast überall, ist auf Apple Silicon aber der
    /// Standardtyp für Temperatursensoren. Ohne ihn findet die Suche dort
    /// keinen einzigen Sensor.
    private static let tempTypes: Set<String> = [
        "sp78", "sp87", "spa5", "sp4b", "sp5a", "sppc", "sp69", "sp5b", "flt ",
    ]

    /// Sensor-Gruppen in Anzeigereihenfolge.
    ///
    /// Die Schlüssel sind case-sensitive: Intel schreibt `TC`/`TG`, Apple
    /// Silicon `Tp`/`Tg`. Beide Schreibweisen müssen hier stehen.
    private static let groupRules: [(String, (String) -> Bool)] = [
        ("CPU", { $0.hasPrefix("TC") || $0.hasPrefix("Tp") || $0.hasPrefix("Te") }),
        ("GPU", { $0.hasPrefix("TG") || $0.hasPrefix("Tg") || $0.hasPrefix("TRD") }),
        ("Umgebung / Gehäuse", {
            $0.hasPrefix("TA") || $0.hasPrefix("Ta") || $0.hasPrefix("Th") || $0.hasPrefix("Tb")
        }),
        ("Display", { $0.hasPrefix("TL") || $0.hasPrefix("TVD") || $0.hasPrefix("TDe") }),
        ("Mainboard / Speicher", {
            $0.hasPrefix("TM") || $0.hasPrefix("Tm") || $0.hasPrefix("TI")
                || $0.hasPrefix("TP") || $0.hasPrefix("Ts")
        }),
        ("Stromversorgung", { $0.hasPrefix("TS") || $0.hasPrefix("TV") }),
        ("Sonstige", { _ in true }),
    ]

    private init() {}

    // MARK: Gerät

    private func sysctlInt(_ name: String) -> Int? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return Int(value)
    }

    private func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return nil }
        return String(cString: buf)
    }

    /// z. B. "iMacPro1,1"
    public var modelIdentifier: String { sysctlString("hw.model") ?? "Unbekannt" }

    /// z. B. "iMac Pro"
    public var modelName: String {
        let id = modelIdentifier
        let table: [(String, String)] = [
            ("iMacPro", "iMac Pro"), ("MacPro", "Mac Pro"), ("MacBookPro", "MacBook Pro"),
            ("MacBookAir", "MacBook Air"), ("Macmini", "Mac mini"), ("MacBook", "MacBook"),
            ("iMac", "iMac"), ("Xserve", "Xserve"), ("VirtualMac", "Virtueller Mac"),
        ]
        for (prefix, name) in table where id.hasPrefix(prefix) { return name }
        return id
    }

    /// Modellname und Kennung, ohne Dopplung wenn der Name unbekannt ist.
    public var displayName: String {
        let id = modelIdentifier
        return modelName == id ? id : "\(modelName) (\(id))"
    }

    public var cpuName: String { sysctlString("machdep.cpu.brand_string") ?? "CPU" }

    /// `hw.optional.arm64` ist auch unter Rosetta gesetzt. So erkennt die App
    /// den echten Unterbau, obwohl sich ein übersetzter Prozess als x86_64
    /// ausgibt.
    public var isAppleSilicon: Bool { sysctlInt("hw.optional.arm64") == 1 }

    /// Läuft dieser Prozess selbst unter Rosetta?
    public var isRosettaTranslated: Bool { sysctlInt("sysctl.proc_translated") == 1 }

    public var isIntel: Bool {
        !isAppleSilicon && (cpuName.contains("Intel") || cpuName.contains("Xeon"))
    }

    public var architectureName: String {
        if isAppleSilicon {
            return isRosettaTranslated ? "Apple Silicon (arm64, unter Rosetta)"
                                       : "Apple Silicon (arm64)"
        }
        if isIntel { return "Intel (x86_64)" }
        return "unbekannte Architektur"
    }

    public var smcAvailable: Bool { smc != nil }
    public var smcKeyCount: Int { smc?.keyCount ?? 0 }

    // MARK: Discovery

    /// Sucht einmalig alle Temperatursensoren. Kann ~0,2 s dauern.
    public func discoverSensors() {
        lock.lock()
        let alreadyDone = didDiscover
        lock.unlock()
        guard !alreadyDone, let smc else { return }

        var found: [String] = []
        for key in smc.allKeys() where key.hasPrefix("T") {
            guard let v = try? smc.read(key),
                  Machine.tempTypes.contains(v.dataType),
                  let d = v.doubleValue, d > 5, d < 125 else { continue }
            found.append(key)
        }

        lock.lock()
        tempKeys = found.sorted()
        didDiscover = true
        lock.unlock()
    }

    // MARK: Momentaufnahme

    public func snapshot() -> Snapshot {
        guard let smc else { return Snapshot() }
        var snap = Snapshot()

        lock.lock()
        let keys = tempKeys
        lock.unlock()

        // Temperaturen
        var readings: [SensorReading] = []
        for key in keys {
            if let d = smc.number(key) { readings.append(SensorReading(key: key, celsius: d)) }
        }

        for (name, match) in Machine.groupRules {
            let sel = readings.filter { match($0.key) && !$0.key.hasPrefix("#") }
            guard !sel.isEmpty else { continue }
            // bereits zugeordnete Keys nicht doppelt zeigen
            let remaining = sel.filter { r in
                !snap.groups.contains { g in g.readings.contains { $0.key == r.key } }
            }
            guard !remaining.isEmpty else { continue }
            snap.groups.append(SensorGroup(name: name,
                                           readings: remaining.sorted { $0.celsius > $1.celsius }))
        }

        snap.hottest = readings.map(\.celsius).max()
        snap.cpuCores = readings
            .filter { $0.key.range(of: "^TC[0-9]c$", options: .regularExpression) != nil }
            .sorted { $0.key < $1.key }
        snap.cpuProximity = smc.number("TC0P")

        // Intel: PECI-Maximum (TCXc). Apple Silicon: heißester CPU-Die-Sensor
        // (TCMz/TCMb), danach TCDX. Gibt es keinen davon, zählt der heißeste
        // Tp-Sensor (CPU-Cluster).
        snap.cpu = smc.number("TCXc")
            ?? smc.number("TCMz")
            ?? smc.number("TCMb")
            ?? smc.number("TCDX")
            ?? readings.filter { $0.key.hasPrefix("TC") || $0.key.hasPrefix("Tp") }
                .map(\.celsius).max()

        // Intel schreibt TG…, Apple Silicon Tg…/TRD… (case-sensitive).
        snap.gpuSensors = readings
            .filter { $0.key.range(of: "^TG[0-9][dDfFhH]$", options: .regularExpression) != nil }
            .sorted { $0.celsius > $1.celsius }
        // Fallback, solange die Sensor-Suche noch läuft:
        snap.gpu = snap.gpuSensors.map(\.celsius).max()
            ?? smc.number("TG0D")
            ?? smc.number("TRDX")
            ?? readings.filter { $0.key.hasPrefix("Tg") || $0.key.hasPrefix("TG") }
                .map(\.celsius).max()
        snap.gpuProximity = readings
            .filter { $0.key.range(of: "^TG[0-9][pP]$", options: .regularExpression) != nil }
            .map(\.celsius).max()

        // Intel liefert getrennte CPU-/GPU-Leistung, Apple Silicon nur die
        // Gesamtleistung des Rechners (PSTR).
        snap.cpuPower = smc.number("PC0C")
        snap.gpuPower = smc.number("PG0C")
        snap.systemPower = smc.number("PSTR")

        // Lüfter
        let count = Int(smc.number("FNum") ?? 0)
        for i in 0..<max(count, 0) {
            let base = "F\(i)"
            guard let actual = smc.number(base + "Ac") else { continue }
            snap.fans.append(FanReading(
                index: i,
                actual: actual,
                minRPM: smc.number(base + "Mn"),
                maxRPM: smc.number(base + "Mx"),
                target: smc.number(base + "Tg"),
                // Intel: F0Md, Apple Silicon: F0md (kleines d).
                mode: (smc.number(base + "Md") ?? smc.number(base + "md")).map { Int($0) },
                duty: smc.number(base + "Dc")
            ))
        }

        return snap
    }
}
