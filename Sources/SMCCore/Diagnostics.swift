import Foundation
import IOKit
import CoreGraphics
import Darwin

/// `proc_pid_rusage` aus libproc - dafür gibt es kein Swift-Modul.
@_silgen_name("proc_pid_rusage")
private func smc_proc_pid_rusage(_ pid: Int32, _ flavor: Int32,
                                 _ buffer: UnsafeMutableRawPointer) -> Int32

// MARK: - GPU-Auslastung

public struct GPULoad {
    public var utilization: Double?     // "Device Utilization %"
    public var vramUsedMB: Double?
    public var name: String?
}

public enum Diagnostics {

    /// Auslastung des Grafikbeschleunigers über die IOAccelerator-Statistiken.
    public static func gpuLoad() -> GPULoad {
        var result = GPULoad()
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault,
                                           IOServiceMatching("IOAccelerator"),
                                           &iterator) == KERN_SUCCESS else { return result }
        defer { IOObjectRelease(iterator) }

        var service = IOIteratorNext(iterator)
        while service != 0 {
            defer {
                IOObjectRelease(service)
                service = IOIteratorNext(iterator)
            }
            var props: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                  let dict = props?.takeRetainedValue() as? [String: Any],
                  let perf = dict["PerformanceStatistics"] as? [String: Any] else { continue }

            if result.name == nil { result.name = dict["IOClass"] as? String }
            if let u = perf["Device Utilization %"] as? Int { result.utilization = Double(u) }
            if let v = perf["vramUsedBytes"] as? Int {
                result.vramUsedMB = Double(v) / 1_048_576
            } else if let v = perf["In use system memory"] as? Int {
                // Apple Silicon (AGXAccelerator) meldet den belegten
                // Unified-Memory-Anteil unter diesem Schlüssel.
                result.vramUsedMB = Double(v) / 1_048_576
            }
            if result.utilization != nil { return result }
        }
        return result
    }

    /// Anzahl aktiver Bildschirme (angeschlossen und eingeschaltet).
    public static func activeDisplayCount() -> Int {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success else { return 0 }
        return Int(count)
    }

    // MARK: - Bildschirmmodi

    /// Ein aktiver Bildschirm mit seinem aktuellen Modus.
    ///
    /// Entscheidend ist der Unterschied zwischen logischer Größe (Punkte) und
    /// Framebuffer-Größe (Pixel): Bei einem **skalierten** Modus ist der
    /// Framebuffer größer als die Panel-Auflösung, und die GPU muss ihn
    /// herunterrechnen. Das kostet deutlich mehr Leistung als ein nativer Modus.
    public struct DisplayInfo {
        public var id: UInt32 = 0
        public var logicalWidth = 0
        public var logicalHeight = 0
        public var pixelWidth = 0
        public var pixelHeight = 0
        public var refreshRate = 0.0
        public var isMain = false
        public var isBuiltin = false
        /// Größter Modus im Modus-Angebot = native Auflösung des Panels.
        public var nativePixelWidth = 0
        public var nativePixelHeight = 0

        /// 2,0 = HiDPI-nativ, 1,0 = nicht-Retina.
        public var scale: Double {
            logicalWidth > 0 ? Double(pixelWidth) / Double(logicalWidth) : 0
        }

        /// Fläche, die die GPU tatsächlich beschreiben muss.
        public var megapixels: Double {
            Double(pixelWidth * pixelHeight) / 1_000_000
        }

        public var nativeMegapixels: Double {
            Double(nativePixelWidth * nativePixelHeight) / 1_000_000
        }

        /// Die GPU rendert **mehr** Pixel als das Panel hat und rechnet sie
        /// herunter. Das ist der teure Fall - er kostet Leistung, obwohl das
        /// Bild nicht schärfer wird.
        public var isDownscaled: Bool {
            guard nativeMegapixels > 0 else { return false }
            return megapixels > nativeMegapixels * 1.01
        }

        /// Weniger Pixel als das Panel, also hochskaliert: für die GPU billig.
        public var isUpscaled: Bool {
            guard nativeMegapixels > 0 else { return false }
            return megapixels < nativeMegapixels * 0.99
        }

        public var modeText: String {
            if isDownscaled { return "heruntergerechnet (teuer)" }
            if isUpscaled { return "hochskaliert (billig)" }
            return "nativ"
        }

        public var shortText: String {
            let scaleText = String(format: "%.2f", scale).replacingOccurrences(of: ".", with: ",")
            var s = "\(logicalWidth)×\(logicalHeight) (Framebuffer \(pixelWidth)×\(pixelHeight), "
            s += "Faktor \(scaleText)"
            if nativeMegapixels > 0 {
                let native = String(format: "%.1f", nativeMegapixels)
                    .replacingOccurrences(of: ".", with: ",")
                s += ", Panel \(native) MP"
            }
            return s + ")  → \(modeText)"
        }
    }

    public static func displays() -> [DisplayInfo] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        var real: UInt32 = 0
        guard CGGetActiveDisplayList(count, &ids, &real) == .success else { return [] }

        var result: [DisplayInfo] = []
        for id in ids.prefix(Int(real)) {
            var info = DisplayInfo()
            info.id = id
            info.isMain = CGDisplayIsMain(id) != 0
            info.isBuiltin = CGDisplayIsBuiltin(id) != 0

            // Nativen Modus aus dem Modus-Angebot bestimmen: der mit der
            // größten Framebuffer-Fläche.
            var bestArea = 0
            if let modes = CGDisplayCopyAllDisplayModes(id, nil) as? [CGDisplayMode] {
                for m in modes {
                    let area = m.pixelWidth * m.pixelHeight
                    if area > bestArea {
                        bestArea = area
                        info.nativePixelWidth = m.pixelWidth
                        info.nativePixelHeight = m.pixelHeight
                    }
                }
            }

            if let mode = CGDisplayCopyDisplayMode(id) {
                info.logicalWidth = mode.width
                info.logicalHeight = mode.height
                info.pixelWidth = mode.pixelWidth
                info.pixelHeight = mode.pixelHeight
                info.refreshRate = mode.refreshRate
            } else {
                info.logicalWidth = CGDisplayPixelsWide(id)
                info.logicalHeight = CGDisplayPixelsHigh(id)
                info.pixelWidth = info.logicalWidth
                info.pixelHeight = info.logicalHeight
            }
            result.append(info)
        }
        return result
    }

    /// Kurzzeichen des aktuellen Bildschirm-Aufbaus. Ändert sich, sobald ein
    /// Bildschirm dazukommt, weggeht **oder die Auflösung wechselt**.
    public static func displaySignature() -> String {
        let list = displays()
        guard !list.isEmpty else { return "keine" }
        return list.map { d in
            let mark = d.isMain ? "*" : ""
            let scaleText = String(format: "%.2f", d.scale)
            var s = "\(mark)\(d.logicalWidth)x\(d.logicalHeight)"
            s += "@\(scaleText)/\(d.pixelWidth)x\(d.pixelHeight)"
            if d.isDownscaled { s += "!runter" }
            if d.isUpscaled { s += "!hoch" }
            return s
        }.joined(separator: " + ")
    }

    /// Summe der Framebuffer-Flächen aller aktiven Bildschirme in Megapixeln.
    public static func totalMegapixels() -> Double {
        displays().reduce(0) { $0 + $1.megapixels }
    }

    /// Anzahl der Bildschirme, deren Framebuffer größer ist als ihr Panel -
    /// also die, für die die GPU zusätzlich herunterrechnen muss.
    public static func scaledDisplayCount() -> Int {
        displays().filter(\.isDownscaled).count
    }

    /// Auflösungen aller aktiven Bildschirme als Text, z. B. "5120x2880".
    public static func displayDescriptions() -> [String] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        var real: UInt32 = 0
        guard CGGetActiveDisplayList(count, &ids, &real) == .success else { return [] }
        return ids.prefix(Int(real)).map {
            "\(CGDisplayPixelsWide($0))x\(CGDisplayPixelsHigh($0))"
        }
    }

    /// CPU-Gesamtauslastung in Prozent, benötigt zwei Aufrufe im Abstand.
    public final class SystemCPU {
        private var previous: (busy: Double, total: Double)?
        private let host = mach_host_self()

        public init() {}

        public func usage() -> Double? {
            var size = mach_msg_type_number_t(
                MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
            var info = host_cpu_load_info_data_t()
            let kr = withUnsafeMutablePointer(to: &info) { ptr in
                ptr.withMemoryRebound(to: integer_t.self, capacity: Int(size)) {
                    host_statistics(host, HOST_CPU_LOAD_INFO, $0, &size)
                }
            }
            guard kr == KERN_SUCCESS else { return nil }

            // cpu_ticks-Reihenfolge: 0 = user, 1 = system, 2 = idle, 3 = nice
            let user = Double(info.cpu_ticks.0)
            let system = Double(info.cpu_ticks.1)
            let idle = Double(info.cpu_ticks.2)
            let nice = Double(info.cpu_ticks.3)
            let busy = user + system + nice
            let total = busy + idle

            defer { previous = (busy, total) }
            guard let prev = previous else { return nil }
            let dBusy = busy - prev.busy
            let dTotal = total - prev.total
            guard dTotal > 0 else { return nil }
            return max(0, min(100, dBusy / dTotal * 100))
        }
    }

    /// Ergebnis einer Prozessabfrage über /bin/ps.
    public struct ProcessSample {
        /// CPU-Prozent je Prozessname (summiert, falls ein Name mehrfach läuft).
        public var byName: [String: Double] = [:]
        /// Grund, falls die Abfrage fehlschlug.
        public var error: String?

        public var top: [(name: String, cpu: Double)] {
            byName.map { (name: $0.key, cpu: $0.value) }
                .sorted { $0.cpu > $1.cpu }
        }

        public func cpu(_ name: String) -> Double? { byName[name] }

        /// Läuft gerade ein Bildschirmschoner?
        public var screensaverRunning: Bool {
            byName.keys.contains { $0.lowercased().contains("screensaver") }
        }
    }

    /// CPU-Anteil aller Prozesse. /bin/ps ist setuid root, funktioniert also
    /// ohne Zusatzrechte - aber nicht in einer Sandbox (dort kommt ein Fehler).
    public static func processCPUSample() -> ProcessSample {
        var result = ProcessSample()

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        task.arguments = ["-A", "-o", "%cpu=,comm="]
        let outPipe = Pipe(), errPipe = Pipe()
        task.standardOutput = outPipe
        task.standardError = errPipe

        do {
            try task.run()
        } catch {
            result.error = "/bin/ps nicht startbar: \(error.localizedDescription)"
            return result
        }

        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()

        if task.terminationStatus != 0 {
            let msg = String(data: errData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            result.error = "/bin/ps endete mit Status \(task.terminationStatus)"
                + (msg.isEmpty ? "" : ": \(msg)")
            return result
        }

        guard let text = String(data: data, encoding: .utf8), !text.isEmpty else {
            result.error = "/bin/ps lieferte keine Ausgabe"
            return result
        }

        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let space = trimmed.firstIndex(of: " ") else { continue }
            guard let value = Double(trimmed[trimmed.startIndex..<space]) else { continue }
            let command = String(trimmed[trimmed.index(after: space)...])
            let name = (command as NSString).lastPathComponent
            guard !name.isEmpty else { continue }
            result.byName[name, default: 0] += value
        }

        if result.byName.isEmpty {
            result.error = "/bin/ps lieferte keine verwertbaren Zeilen"
        }
        return result
    }

    /// Nur die üblicherweise interessanten Prozesse.
    public static func processCPU() -> [String: Double] {
        let sample = processCPUSample()
        var result: [String: Double] = [:]
        for watch in ["WindowServer", "kernel_task", "FanStats"] {
            if let v = sample.cpu(watch) { result[watch] = v }
        }
        return result
    }

    // MARK: - Prozess-CPU nativ
    //
    // /bin/ps und /usr/bin/top sind setuid root. In einer Sandbox ist das
    // Ausführen setuid-rooter Programme gesperrt - dort fällt die Messung
    // ersatzlos aus. `proc_pid_rusage` braucht kein setuid und liest alle
    // Prozesse des eigenen Benutzers; nur fremde (root-)Prozesse verweigern
    // mit EPERM. Das ist die deutlich robustere Quelle.

    public final class NativeProcessSampler {
        private struct Times {
            var user: UInt64
            var system: UInt64
        }

        private var previous: [Int32: Times] = [:]
        private var previousWall: UInt64 = 0

        /// Prozesse, die gelesen werden konnten.
        public private(set) var readable = 0
        /// Prozesse, die EPERM geliefert haben (fremde Benutzer, meist root).
        public private(set) var unreadable = 0
        /// Läuft gerade ein Bildschirmschoner?
        public private(set) var sawScreensaver = false

        public init() {}

        private func now() -> UInt64 { clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW) }

        /// Alle Prozesse als (pid, Name) über sysctl - dafür braucht es keine
        /// besonderen Rechte.
        private func processList() -> [(pid: Int32, name: String)] {
            var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
            var size = 0
            // Zwei Versuche: die Liste kann zwischen den Aufrufen wachsen.
            for _ in 0..<2 {
                guard sysctl(&mib, 4, nil, &size, nil, 0) == 0, size > 0 else { return [] }
                var buffer = [UInt8](repeating: 0, count: size)
                if sysctl(&mib, 4, &buffer, &size, nil, 0) == 0 {
                    let strideSize = MemoryLayout<kinfo_proc>.size
                    var result: [(Int32, String)] = []
                    buffer.withUnsafeBytes { raw in
                        for i in 0..<(size / strideSize) {
                            let p = raw.baseAddress!
                                .advanced(by: i * strideSize)
                                .assumingMemoryBound(to: kinfo_proc.self)
                            let pid = p.pointee.kp_proc.p_pid
                            guard pid > 0 else { continue }
                            let name = withUnsafeBytes(of: p.pointee.kp_proc.p_comm) {
                                String(cString: $0.baseAddress!.assumingMemoryBound(to: CChar.self))
                            }
                            result.append((pid, name))
                        }
                    }
                    return result
                }
            }
            return []
        }

        /// CPU-Prozent je Prozessname. 100 % = ein voll ausgelasteter Kern.
        /// Der erste Aufruf liefert ein leeres Ergebnis (kein Vergleichswert).
        public func sample() -> [String: Double] {
            let wall = now()
            let dt = previousWall == 0 ? 0.0 : Double(wall - previousWall)

            let buffer = UnsafeMutableRawPointer.allocate(byteCount: 4096, alignment: 8)
            defer { buffer.deallocate() }

            var current: [Int32: Times] = [:]
            var result: [String: Double] = [:]
            var ok = 0, failed = 0
            var screensaver = false

            for proc in processList() {
                if proc.name.lowercased().contains("screensaver") { screensaver = true }
                memset(buffer, 0, 4096)
                guard smc_proc_pid_rusage(proc.pid, 4, buffer) == 0 else {
                    failed += 1
                    continue
                }
                ok += 1
                let info = buffer.assumingMemoryBound(to: rusage_info_v4.self).pointee
                let times = Times(user: info.ri_user_time, system: info.ri_system_time)
                current[proc.pid] = times

                guard dt > 0, let prev = previous[proc.pid] else { continue }
                let du = times.user >= prev.user ? times.user - prev.user : 0
                let ds = times.system >= prev.system ? times.system - prev.system : 0
                let percent = (Double(du) + Double(ds)) / dt * 100.0
                if percent > 0.01 {
                    result[proc.name, default: 0] += percent
                }
            }

            previous = current
            previousWall = wall
            readable = ok
            unreadable = failed
            sawScreensaver = screensaver
            return result
        }
    }
}
