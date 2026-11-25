import Foundation
import SMCCore

// fanlog - protokolliert Temperaturen, Leistung, GPU-Last und Lüfterdrehzahl.
// Erkennt automatisch, wenn ein Bildschirm dazukommt oder weggeht, und wertet
// die Phasen am Ende aus.

// MARK: - Argumente

var interval = 1.0
var outputPath: String?
var runArgs = Array(CommandLine.arguments.dropFirst())
while !runArgs.isEmpty {
    let a = runArgs.removeFirst()
    switch a {
    case "--interval", "-i":
        if let v = runArgs.first, let d = Double(v) { interval = max(0.2, d); runArgs.removeFirst() }
    case "--out", "-o":
        if let v = runArgs.first { outputPath = v; runArgs.removeFirst() }
    default:
        outputPath = a
    }
}

// MARK: - Aufbau

print("FanStats-Messung")
guard Machine.shared.smcAvailable else {
    print("FEHLER: AppleSMC nicht erreichbar.")
    exit(1)
}
print("  Modell:       \(Machine.shared.displayName)")
print("  Architektur:  \(Machine.shared.architectureName)")
print("  Temperatur-:  Sensoren werden gesucht …")
Machine.shared.discoverSensors()

let displayCount = Diagnostics.activeDisplayCount()
let initialSignature = Diagnostics.displaySignature()
print(String(format: "  Bildschirme:  %d aktiv, %.1f MP Framebuffer",
             displayCount, Diagnostics.totalMegapixels()))
for d in Diagnostics.displays() {
    print("                \(d.isMain ? "[Haupt] " : "")\(d.isBuiltin ? "[intern] " : "[extern] ")\(d.shortText)")
}
print("  Intervall:    \(interval) s")

if outputPath == nil {
    let stamp = ISO8601DateFormatter().string(from: Date())
        .replacingOccurrences(of: ":", with: "-")
    outputPath = FileManager.default.currentDirectoryPath + "/fanstats-messung-\(stamp).csv"
}
let csvPath = outputPath!
FileManager.default.createFile(atPath: csvPath, contents: nil)
guard let csvHandle = FileHandle(forWritingAtPath: csvPath) else {
    print("FEHLER: kann \(csvPath) nicht schreiben")
    exit(1)
}

let start = Date()
var phase: [(displays: Int, signature: String, start: Double)] = [(displayCount, initialSignature, 0)]

print("  CSV:          \(csvPath)")
print("")
print("  Ablauf: jetzt läuft die Ausgangsmessung. Steck den zweiten Monitor an,")
print("  warte ein bis zwei Minuten, zieh ihn wieder ab. Der Bildschirmwechsel")
print("  wird automatisch markiert. Beenden mit Ctrl-C — dann kommt die Auswertung.")
print("")

var header = "sekunden;zeit;bildschirme;cpu_c;gpu_c;cpu_w;gpu_w;gpu_gesamt_w;gpu_prozent;"
header += "vram_mb;luefter_1;luefter_2;luefter_ziel;modus;system_cpu;windowserver;kernel_task;"
header += "top_prozess;top_prozent;schoner;fb_mp;skaliert;aufbau\n"
csvHandle.write(header.data(using: .utf8)!)

// MARK: - Messwert

struct Sample {
    var elapsed: Double = 0
    var displays: Int = 0
    var cpuTemp: Double?
    var gpuTemp: Double?
    var cpuPower: Double?
    var gpuPower: Double?
    var gpuTotalPower: Double?
    var gpuUtil: Double?
    var vramMB: Double?
    var fanRPM: [Double] = []
    var fanTarget: [Double] = []
    var fanMode: [Int] = []
    var systemCPU: Double?
    var windowServer: Double?
    var kernelTask: Double?
    var topProcess: String?
    var topProcessCPU: Double?
    var screensaver: Bool = false
    var megapixels: Double = 0
    var scaledDisplays: Int = 0
    var phaseIndex: Int = 0
}

var samples: [Sample] = []
let sysCPU = Diagnostics.SystemCPU()
var tick = 0

// Prozess-CPU über die gesamte Messung aufsummieren, damit am Ende feststeht,
// wer die Last verursacht hat.
var processAccum: [String: Double] = [:]
var processSamples = 0
var warnedAboutPS = false
var processSource = "nativ"
var nativeReadable = 0
var nativeUnreadable = 0
let nativeSampler = Diagnostics.NativeProcessSampler()
/// Eigener Prozessname - wird aus der Rangliste herausgehalten, sonst steht im
/// Leerlauf immer das Messwerkzeug selbst oben und verdeckt den Verursacher.
let selfName = ProcessInfo.processInfo.processName

func de(_ v: Double?, _ decimals: Int = 1, _ suffix: String = "") -> String {
    guard let v else { return "–" }
    return String(format: "%.\(decimals)f", v).replacingOccurrences(of: ".", with: ",") + suffix
}

func sample() {
    let now = Date()
    let elapsed = now.timeIntervalSince(start)
    let displays = Diagnostics.activeDisplayCount()
    let signature = Diagnostics.displaySignature()
    let megapixels = Diagnostics.totalMegapixels()
    let scaled = Diagnostics.scaledDisplayCount()

    if signature != phase.last!.signature {
        let old = phase.last!.displays
        phase.append((displays, signature, elapsed))
        let kind = displays != old ? "Bildschirmwechsel" : "Auflösungswechsel"
        print("")
        print(String(format: "*** %@ nach %d:%02d:  %d -> %d Bildschirm(e), %.1f MP Framebuffer ***",
                     kind as NSString, Int(elapsed) / 60, Int(elapsed) % 60,
                     old, displays, megapixels))
        for d in Diagnostics.displays() {
            print("      \(d.isMain ? "[Haupt] " : "")\(d.isBuiltin ? "[intern] " : "[extern] ")\(d.shortText)")
        }
        if scaled > 0 {
            print("      HINWEIS: \(scaled) Bildschirm(e) laufen skaliert -")
            print("      die GPU muss einen größeren Framebuffer herunterrechnen.")
        }
        print("")
    }

    let snap = Machine.shared.snapshot()
    let load = Diagnostics.gpuLoad()
    let psSample = Diagnostics.processCPUSample()
    // Zusätzlich immer nativ messen: das ist die Quelle, die auch in einer
    // Sandbox trägt (/bin/ps und /usr/bin/top sind setuid root und dort gesperrt).
    let nativeCPU = nativeSampler.sample()

    let psWorks = psSample.error == nil && !psSample.byName.isEmpty
    let procs = psWorks ? psSample.byName : nativeCPU
    processSource = psWorks ? "ps" : "nativ"

    if let err = psSample.error, !warnedAboutPS {
        warnedAboutPS = true
        print("")
        print("  Hinweis: /bin/ps nicht verfügbar (\(err))")
        print("  Messung läuft nativ über proc_pid_rusage. Das erfasst alle Prozesse")
        print("  deines Benutzers, aber keine root-Prozesse (WindowServer,")
        print("  mds_stores, backupd).")
        print("")
    }

    if !procs.isEmpty {
        processSamples += 1
        for (name, cpu) in procs { processAccum[name, default: 0] += cpu }
    }
    nativeReadable = nativeSampler.readable
    nativeUnreadable = nativeSampler.unreadable

    var s = Sample()
    s.elapsed = elapsed
    s.displays = displays
    s.phaseIndex = phase.count - 1
    s.cpuTemp = snap.cpu
    s.gpuTemp = snap.gpu
    s.cpuPower = snap.cpuPower
    s.gpuPower = snap.gpuPower
    s.gpuTotalPower = SMC.shared?.number("PGTR")
    s.gpuUtil = load.utilization
    s.vramMB = load.vramUsedMB
    s.fanRPM = snap.fans.compactMap(\.actual)
    s.fanTarget = snap.fans.compactMap(\.target)
    s.fanMode = snap.fans.compactMap(\.mode)
    s.systemCPU = sysCPU.usage()
    s.windowServer = procs["WindowServer"]
    s.kernelTask = procs["kernel_task"]
    let ranked = procs
        .filter { $0.key != selfName }
        .map { (name: $0.key, cpu: $0.value) }
        .sorted { $0.cpu > $1.cpu }
    s.topProcess = ranked.first?.name
    s.topProcessCPU = ranked.first?.cpu
    s.screensaver = psWorks ? psSample.screensaverRunning : nativeSampler.sawScreensaver
    s.megapixels = megapixels
    s.scaledDisplays = scaled
    samples.append(s)

    // CSV
    var row = String(format: "%.1f;%@;%d;", elapsed, now.formatted(date: .omitted, time: .standard), displays)
    func cell(_ v: Double?, _ d: Int = 2) -> String {
        guard let v else { return "" }
        return String(format: "%.\(d)f", v)
    }
    row += "\(cell(s.cpuTemp));\(cell(s.gpuTemp));"
    row += "\(cell(s.cpuPower));\(cell(s.gpuPower));\(cell(s.gpuTotalPower));"
    row += "\(cell(s.gpuUtil, 0));\(cell(s.vramMB, 0));"
    row += "\(cell(s.fanRPM.first, 0));\(cell(s.fanRPM.dropFirst().first, 0));"
    row += "\(cell(s.fanTarget.first, 0));\(cell(Double(s.fanMode.first ?? 0), 0));"
    row += "\(cell(s.systemCPU));\(cell(s.windowServer));\(cell(s.kernelTask));"
    row += "\(s.topProcess ?? "");\(cell(s.topProcessCPU));\(s.screensaver ? 1 : 0);"
    row += "\(cell(s.megapixels));\(s.scaledDisplays);\(signature)\n"
    csvHandle.write(row.data(using: .utf8)!)
    try? csvHandle.synchronize()

    // Live-Zeile
    if tick % 20 == 0 {
        print("  Zeit  Bildsch.  CPU °C  GPU °C   CPU W   GPU W   GPU %   Lüfter rpm   stärkster Prozess")
    }
    tick += 1
    let fans = s.fanRPM.map { String(Int($0.rounded())) }.joined(separator: "/")
    var top = "–"
    if let name = s.topProcess, let cpu = s.topProcessCPU {
        top = "\(name) \(Int(cpu.rounded()))%"
    }
    if s.screensaver { top = "[Schoner] " + top }
    print(String(format: "  %4d        %d   %6@  %6@  %6@  %6@  %5@   %10@   %@",
                 Int(elapsed), displays,
                 de(s.cpuTemp) as NSString, de(s.gpuTemp) as NSString,
                 de(s.cpuPower) as NSString, de(s.gpuPower) as NSString,
                 (de(s.gpuUtil, 0, "%")) as NSString,
                 (fans.isEmpty ? "–" : fans) as NSString,
                 top as NSString))
    fflush(stdout)
}

// MARK: - Auswertung

func mean(_ values: [Double?]) -> Double? {
    let v = values.compactMap { $0 }
    guard !v.isEmpty else { return nil }
    return v.reduce(0, +) / Double(v.count)
}

func mean(_ values: [Double]) -> Double? {
    guard !values.isEmpty else { return nil }
    return values.reduce(0, +) / Double(values.count)
}

func finish() {
    print("\n\n=== Auswertung ===")

    for (i, p) in phase.enumerated() {
        let end = i + 1 < phase.count ? phase[i + 1].start : (samples.last?.elapsed ?? p.start)
        let sel = samples.filter { $0.phaseIndex == i }
        guard !sel.isEmpty else { continue }

        let mp = sel.compactMap { $0.megapixels }.first ?? 0
        let scaled = sel.compactMap { $0.scaledDisplays }.first ?? 0
        let scalingText = scaled > 0 ? ", \(scaled)× SKALIERT" : ""
        let head = String(format: "Phase %d: %d Bildschirm(e), %.1f MP Framebuffer%@, %d:%02d-%d:%02d  (%d Werte)",
                          i + 1, p.displays, mp, scalingText as NSString,
                          Int(p.start) / 60, Int(p.start) % 60,
                          Int(end) / 60, Int(end) % 60, sel.count)
        print(head)

        let cpuT = de(mean(sel.map { $0.cpuTemp }))
        let gpuT = de(mean(sel.map { $0.gpuTemp }))
        let cpuW = de(mean(sel.map { $0.cpuPower }))
        let gpuW = de(mean(sel.map { $0.gpuPower }))
        let gpuTotW = de(mean(sel.map { $0.gpuTotalPower }))
        print("  CPU \(cpuT) °C   GPU \(gpuT) °C   "
              + "CPU-Leistung \(cpuW) W   GPU-Leistung \(gpuW) W   GPU gesamt \(gpuTotW) W")

        let gpuU = de(mean(sel.map { $0.gpuUtil }), 0)
        let sysU = de(mean(sel.map { $0.systemCPU }))
        let wsU = de(mean(sel.map { $0.windowServer }))
        let ktU = de(mean(sel.map { $0.kernelTask }))
        print("  GPU-Last \(gpuU) %   System-CPU \(sysU) %   "
              + "WindowServer \(wsU) %   kernel_task \(ktU) %")

        let fanMean = de(mean(sel.flatMap { $0.fanRPM }), 0)
        let fanMax = de(sel.flatMap { $0.fanRPM }.max(), 0)
        let modes = Set(sel.flatMap { $0.fanMode }).map(String.init).sorted().joined(separator: "/")
        print("  Lüfter Ø \(fanMean) rpm   max \(fanMax) rpm   Modus \(modes)")
        print("")
    }

    // Direkter Vergleich, wenn es mehrere Phasen gab
    if phase.count >= 2, !samples.isEmpty {
        print("=== Differenz (letzte Phase gegen erste Phase) ===")
        let first = samples.filter { $0.phaseIndex == 0 }
        let lastIdx = samples.last!.phaseIndex
        let last = samples.filter { $0.phaseIndex == lastIdx }

        func delta(_ name: String, _ get: (Sample) -> Double?, _ unit: String, _ decimals: Int = 1) {
            guard let a = mean(first.map(get)), let b = mean(last.map(get)) else { return }
            let d = b - a
            let sign = d >= 0 ? "+" : ""
            let label = name.padding(toLength: 18, withPad: " ", startingAt: 0)
            print("  \(label)\(de(a, decimals)) \(unit)  ->  \(de(b, decimals)) \(unit)"
                  + "   (\(sign)\(de(d, decimals)) \(unit))")
        }
        delta("CPU-Temp", { $0.cpuTemp }, "°C")
        delta("GPU-Temp", { $0.gpuTemp }, "°C")
        delta("CPU-Leistung", { $0.cpuPower }, "W")
        delta("GPU-Leistung", { $0.gpuPower }, "W")
        delta("GPU gesamt", { $0.gpuTotalPower }, "W")
        delta("GPU-Last", { $0.gpuUtil }, "%", 0)
        delta("WindowServer", { $0.windowServer }, "%")
        delta("Lüfter", { $0.fanRPM.first }, "rpm", 0)
        print("")
    }

    // Wer hat die Last verursacht?
    if processSamples > 0 {
        print("=== Prozesse nach mittlerer CPU-Last über die ganze Messung ===")
        print("    Quelle: \(processSource == "ps" ? "/bin/ps (alle Prozesse)" : "proc_pid_rusage (nur eigener Benutzer)")")
        if processSource != "ps" {
            print("    Abdeckung: \(nativeReadable) Prozesse lesbar, "
                  + "\(nativeUnreadable) gesperrt (fremde Benutzer, u. a. root)")
        }
        print("    (\(processSamples) Stichproben, nur Prozesse ab 0,5 %; 100 % = ein Kern)")
        print("")
        let ranking = processAccum
            .filter { $0.key != selfName }
            .map { (name: $0.key, cpu: $0.value / Double(processSamples)) }
            .filter { $0.cpu >= 0.5 }
            .sorted { $0.cpu > $1.cpu }
            .prefix(15)
        for entry in ranking {
            let bar = String(repeating: "#", count: min(40, Int(entry.cpu * 1.5)))
            print(String(format: "  %8.2f %%  %-28@ %@",
                         entry.cpu, entry.name as NSString, bar as NSString))
        }
        if let own = processAccum[selfName] {
            print(String(format: "  %8.2f %%  %@ (das Messwerkzeug selbst)",
                         own / Double(processSamples), selfName as NSString))
        }
        print("")
    }

    print("Rohdaten: \(csvPath)")
    try? csvHandle.close()
    exit(0)
}

signal(SIGINT, SIG_IGN)
let sigSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
sigSource.setEventHandler { finish() }
sigSource.resume()

// MARK: - Start

sample()
let timer = Timer(timeInterval: interval, repeats: true) { _ in sample() }
RunLoop.main.add(timer, forMode: .common)
RunLoop.main.run()
