import SwiftUI
import Charts
import Darwin
import IOKit
import ServiceManagement

// MARK: - App

/// Set by `--render-docs <folder>`: render the README images there instead of running normally.
let docsFolder: URL? = CommandLine.arguments.firstIndex(of: "--render-docs").flatMap { i in
    CommandLine.arguments.indices.contains(i + 1) ? URL(fileURLWithPath: CommandLine.arguments[i + 1]) : nil
}

@main
struct VitalsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var monitor = Monitor()

    init() {
        if CommandLine.arguments.contains("--selftest") { selfTest() }
        guard docsFolder == nil else { return }
        if !Bundle.main.bundlePath.contains("/Applications/") { installAndRelaunch() }
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
        if others.contains(where: { $0 != NSRunningApplication.current && $0.bundleURL?.path.contains("/Applications/") == true }) {
            exit(0)   // already running
        }
        LoginItem.enableOnFirstLaunch()
    }

    var body: some Scene {
        MenuBarExtra {
            PanelView(monitor: monitor)
        } label: {
            Image(nsImage: MenuBarLabel.image(
                cpu: monitor.cpuPercent, memory: monitor.ramPercent, disk: monitor.diskPercent,
                down: monitor.netIn, up: monitor.netOut
            ))
            .accessibilityLabel(
                "CPU \(monitor.cpuPercent)%, memory \(monitor.ramPercent)%, disk \(monitor.diskPercent)% full, "
                    + "download \(monitor.netIn), upload \(monitor.netOut)"
            )
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Just installed: open the panel so it's obvious where Vitals went.
        if CommandLine.arguments.contains("--show") {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1))
                showPanel()
            }
        }
    }

    /// Opening Vitals while it's running (Finder, Spotlight, Launchpad) shows its panel instead of doing nothing.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        showPanel()
        return false
    }
}

/// Clicks Vitals' own menu bar item. If macOS has hidden it because the menu bar is full, says so instead.
@MainActor func showPanel() {
    let button = NSApp.windows
        .filter { $0.className == "NSStatusBarWindow" && $0.occlusionState.contains(.visible) }
        .lazy.compactMap { statusButton(in: $0.contentView) }.first
    if let button {
        button.performClick(nil)
        return
    }
    NSApp.activate()
    let alert = NSAlert()
    alert.messageText = "Vitals is running, but your menu bar is full"
    alert.informativeText = "Make room by holding ⌘ and dragging other icons out of the menu bar, "
        + "or turn some off in System Settings › Menu Bar."
    alert.runModal()
}

private func statusButton(in view: NSView?) -> NSStatusBarButton? {
    guard let view else { return nil }
    if let button = view as? NSStatusBarButton { return button }
    return view.subviews.lazy.compactMap { statusButton(in: $0) }.first
}

/// Run from Xcode (or a download), the app copies itself into Applications, starts that copy and quits,
/// so it never needs Xcode again. If the copy fails it just keeps running from where it is.
func installAndRelaunch() {
    let fm = FileManager.default
    var folder = URL(fileURLWithPath: "/Applications")
    if !fm.isWritableFile(atPath: folder.path) { folder = fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications") }
    let target = folder.appendingPathComponent("Vitals.app")

    // Quit the installed copy first, so it can be replaced.
    let old = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
        .filter { $0 != NSRunningApplication.current }
    old.forEach { $0.terminate() }
    for _ in 0..<30 where old.contains(where: { !$0.isTerminated }) { Thread.sleep(forTimeInterval: 0.1) }
    old.filter { !$0.isTerminated }.forEach { $0.forceTerminate() }

    do {
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
        try fm.copyItem(at: Bundle.main.bundleURL, to: target)
    } catch {
        print("Vitals: could not install into \(folder.path): \(error.localizedDescription)")
        return
    }
    let open = Process()
    open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    open.arguments = [target.path, "--args", "--show"]
    try? open.run()
    open.waitUntilExit()
    exit(0)
}

enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func set(_ on: Bool) {
        if on { try? SMAppService.mainApp.register() } else { try? SMAppService.mainApp.unregister() }
    }

    /// Starts at login by default, once. After that the ⋯ menu is in charge.
    static func enableOnFirstLaunch() {
        let key = "didSetUpLoginItem"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        set(true)
    }
}

// MARK: - Sampling

struct Battery {
    var percent = 0
    var charging = false
    var pluggedIn = false
    var cycles = 0
    var health = 0
}

struct Stats {
    var cpuUser = 0.0
    var cpuSystem = 0.0
    var gpu = 0.0
    var ramUsed: UInt64 = 0
    var diskFree: Int64 = 0
    var diskTotal: Int64 = 0
    var netDown = 0.0
    var netUp = 0.0
    var downHistory: [Double] = []
    var upHistory: [Double] = []
    var battery: Battery?
    var uptime: TimeInterval = 0
    var thermal = ProcessInfo.ThermalState.nominal

    var cpu: Double { cpuUser + cpuSystem }
    var diskUsed: Double { diskTotal > 0 ? 1 - Double(diskFree) / Double(diskTotal) : 0 }
}

@MainActor @Observable
final class Monitor {
    static let historyLength = 60
    static let interval = 2.0

    // Menu bar: only reassigned when the shown text changes, so the label redraws as little as possible.
    private(set) var cpuPercent = 0
    private(set) var ramPercent = 0
    private(set) var diskPercent = 0
    private(set) var netIn = "0B"
    private(set) var netOut = "0B"

    // Panel: refreshed only while it's open, so a closed panel costs nothing to redraw.
    private(set) var panel = Stats()
    @ObservationIgnored var panelOpen = false {
        didSet { if panelOpen { panel = live } }
    }

    let model = productName()
    let chip = sysctlString("machdep.cpu.brand_string")
    let ramTotal = ProcessInfo.processInfo.physicalMemory
    let gpuCores = gpuCoreCount()
    let os: String
    let cores: String

    @ObservationIgnored private var live = Stats()
    @ObservationIgnored private var lastTicks = cpuTicks()
    @ObservationIgnored private var lastNet = networkBytes()
    @ObservationIgnored private var lastUptime = ProcessInfo.processInfo.systemUptime
    @ObservationIgnored private var tick = 0

    init() {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        os = "macOS \(v.majorVersion).\(v.minorVersion)" + (v.patchVersion > 0 ? ".\(v.patchVersion)" : "")

        let p = sysctlInt("hw.perflevel0.physicalcpu"), e = sysctlInt("hw.perflevel1.physicalcpu")
        cores = e > 0 ? "\(p)P + \(e)E" : "\(ProcessInfo.processInfo.activeProcessorCount) cores"

        Task {
            while true {
                // Tolerance lets macOS batch our wake-ups with others, which saves power.
                try? await Task.sleep(for: .seconds(Monitor.interval), tolerance: .seconds(0.5))
                self.sample()
            }
        }
        if let docsFolder { Task { await renderDocs(self, to: docsFolder) } }
    }

    private func sample() {
        let now = ProcessInfo.processInfo.systemUptime
        let elapsed = max(now - lastUptime, 0.001)
        lastUptime = now

        let t = cpuTicks()
        let user = Double((t.user &- lastTicks.user) &+ (t.nice &- lastTicks.nice))
        let system = Double(t.system &- lastTicks.system)
        let idle = Double(t.idle &- lastTicks.idle)
        lastTicks = t
        let total = max(user + system + idle, 1)
        live.cpuUser = user / total * 100
        live.cpuSystem = system / total * 100

        live.gpu = gpuUsage()
        live.ramUsed = memoryUsed()

        let net = networkBytes()
        live.netDown = counterDelta(net.received, lastNet.received) / elapsed
        live.netUp = counterDelta(net.sent, lastNet.sent) / elapsed
        lastNet = net
        push(live.netDown, to: &live.downHistory)
        push(live.netUp, to: &live.upHistory)

        // The capacity lookup works out purgeable space, so once a minute is plenty.
        if tick % 30 == 0 { readDisk() }
        tick += 1

        live.battery = battery()
        live.uptime = now
        live.thermal = ProcessInfo.processInfo.thermalState
        publish()
    }

    /// After clearing space: shows the new free space now, not at the next once-a-minute check.
    func refreshDisk() {
        readDisk()
        publish()
    }

    private func readDisk() {
        let values = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey,
        ])
        live.diskFree = values?.volumeAvailableCapacityForImportantUsage ?? 0
        live.diskTotal = Int64(values?.volumeTotalCapacity ?? 0)
    }

    private func publish() {
        let c = Int(live.cpu.rounded())
        let r = Int((Double(live.ramUsed) / Double(ramTotal) * 100).rounded())
        let d = Int((live.diskUsed * 100).rounded())
        let i = Format.compactRate(live.netDown), o = Format.compactRate(live.netUp)
        if c != cpuPercent { cpuPercent = c }
        if r != ramPercent { ramPercent = r }
        if d != diskPercent { diskPercent = d }
        if i != netIn { netIn = i }
        if o != netOut { netOut = o }

        if panelOpen { panel = live }
    }

    private func push(_ value: Double, to history: inout [Double]) {
        history.append(value)
        if history.count > Self.historyLength { history.removeFirst() }
    }
}

/// Counter difference. A counter that went backwards (Wi-Fi reset, 32-bit wrap) counts as 0.
func counterDelta<T: UnsignedInteger>(_ new: T, _ old: T) -> Double {
    new >= old ? Double(new - old) : 0
}

// MARK: - Mach / IOKit / sysctl

// Cached: every mach_host_self() call adds a port reference, which leaks in a long-running app.
private let host = mach_host_self()
private let pageSize = UInt64(vm_kernel_page_size)

func cpuTicks() -> (user: UInt32, system: UInt32, idle: UInt32, nice: UInt32) {
    var info = host_cpu_load_info()
    var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
    let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            host_statistics(host, HOST_CPU_LOAD_INFO, $0, &count)
        }
    }
    guard result == KERN_SUCCESS else { return (0, 0, 0, 0) }
    let t = info.cpu_ticks
    return (t.0, t.1, t.2, t.3)
}

/// Matches Activity Monitor's "Memory Used": app memory + wired + compressed.
func memoryUsed() -> UInt64 {
    var stats = vm_statistics64()
    var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
    let result = withUnsafeMutablePointer(to: &stats) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            host_statistics64(host, HOST_VM_INFO64, $0, &count)
        }
    }
    guard result == KERN_SUCCESS else { return 0 }
    let app = UInt64(stats.internal_page_count) - UInt64(stats.purgeable_count)
    return (app + UInt64(stats.wire_count) + UInt64(stats.compressor_page_count)) * pageSize
}

/// Runs `body` on every IOKit service of the given class.
func forEachService(_ className: String, _ body: (io_object_t) -> Void) {
    var iterator: io_iterator_t = 0
    guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(className), &iterator) == KERN_SUCCESS
    else { return }
    defer { IOObjectRelease(iterator) }
    var service = IOIteratorNext(iterator)
    while service != 0 {
        body(service)
        IOObjectRelease(service)
        service = IOIteratorNext(iterator)
    }
}

func property(_ service: io_object_t, _ key: String) -> Any? {
    IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
}

/// "MacBook Air (13-inch, M3, 2024)" on Apple silicon, nil on Macs that don't report it.
func productName() -> String? {
    let entry = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/product")
    guard entry != 0 else { return nil }
    defer { IOObjectRelease(entry) }
    guard let data = property(entry, "product-name") as? Data else { return nil }
    let name = String(decoding: data.prefix { $0 != 0 }, as: UTF8.self)
    return name.isEmpty ? nil : name
}

func gpuCoreCount() -> Int {
    var cores = 0
    forEachService("IOAccelerator") { cores = max(cores, (property($0, "gpu-core-count") as? NSNumber)?.intValue ?? 0) }
    return cores
}

/// GPU busy percentage, as reported by the graphics driver.
func gpuUsage() -> Double {
    var usage = 0.0
    forEachService("IOAccelerator") { service in
        let stats = property(service, "PerformanceStatistics") as? [String: Any]
        usage = max(usage, (stats?["Device Utilization %"] as? NSNumber)?.doubleValue ?? 0)
    }
    return usage
}

/// nil on Macs without a battery.
func battery() -> Battery? {
    var result: Battery?
    forEachService("AppleSmartBattery") { service in
        func int(_ key: String) -> Int { (property(service, key) as? NSNumber)?.intValue ?? 0 }
        // Apple silicon reports CurrentCapacity as a percentage; Intel reports mAh against MaxCapacity.
        let current = int("CurrentCapacity"), full = int("MaxCapacity"), design = int("DesignCapacity")
        let rawFull = int("AppleRawMaxCapacity") > 0 ? int("AppleRawMaxCapacity") : full
        result = Battery(
            percent: full > 100 ? current * 100 / full : current,
            charging: int("IsCharging") != 0,
            pluggedIn: int("ExternalConnected") != 0,
            cycles: int("CycleCount"),
            health: design > 0 ? rawFull * 100 / design : 0
        )
    }
    return result
}

/// Bytes received/sent since boot. 32-bit counters, so they wrap every 4 GB; `counterDelta` handles that.
func networkBytes() -> (received: UInt32, sent: UInt32) {
    var list: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&list) == 0, let first = list else { return (0, 0) }
    defer { freeifaddrs(list) }

    var received: UInt32 = 0, sent: UInt32 = 0
    for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
        let interface = pointer.pointee
        // Physical "en" interfaces only (Wi-Fi, Ethernet), so VPN tunnels aren't counted twice.
        guard interface.ifa_addr?.pointee.sa_family == UInt8(AF_LINK),
              String(cString: interface.ifa_name).hasPrefix("en"),
              let data = interface.ifa_data?.assumingMemoryBound(to: if_data.self).pointee
        else { continue }
        received &+= data.ifi_ibytes
        sent &+= data.ifi_obytes
    }
    return (received, sent)
}

func sysctlString(_ name: String) -> String {
    var size = 0
    guard sysctlbyname(name, nil, &size, nil, 0) == 0 else { return "" }
    var buffer = [CChar](repeating: 0, count: size)
    sysctlbyname(name, &buffer, &size, nil, 0)
    return String(cString: buffer)
}

func sysctlInt(_ name: String) -> Int {
    var value: Int32 = 0
    var size = MemoryLayout<Int32>.size
    sysctlbyname(name, &value, &size, nil, 0)
    return Int(value)
}

// MARK: - Formatting

enum Format {
    static let uptime: DateComponentsFormatter = {
        let f = DateComponentsFormatter()
        f.allowedUnits = [.day, .hour, .minute]
        f.unitsStyle = .abbreviated
        f.maximumUnitCount = 2
        return f
    }()

    static func percent(_ value: Double) -> String { "\(Int(value.rounded()))%" }

    /// Short numbers for the ring captions: "9.5", "22", "343".
    static func number(_ value: Double) -> String {
        value < 9.95 ? String(format: "%.1f", value) : String(Int(value.rounded()))
    }

    static func size(_ gigabytes: Double) -> String {
        gigabytes >= 999.5 ? number(gigabytes / 1000) + " TB" : number(gigabytes) + " GB"
    }

    /// Splits bytes per second into a short number and a unit step: ("1.2", 1) for 1,234.
    private static func scaled(_ value: Double) -> (number: String, unit: Int) {
        var v = value, i = 0
        while v >= 999.5, i < 3 {
            v /= 1000
            i += 1
        }
        return (i > 0 && v < 9.95 ? String(format: "%.1f", v) : String(Int(v.rounded())), i)
    }

    /// Four characters at most, for the menu bar: "512B", "1.2K", "34M", "1.1G".
    static func compactRate(_ value: Double) -> String {
        let s = scaled(value)
        return s.number + ["B", "K", "M", "G"][s.unit]
    }

    /// The same number, spelt out for the panel: "512 B/s", "1.2 KB/s".
    static func rate(_ value: Double) -> String {
        let s = scaled(value)
        return s.number + " " + ["B", "KB", "MB", "GB"][s.unit] + "/s"
    }

    static func thermal(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: "Normal"
        case .fair: "Warm"
        case .serious: "Hot"
        case .critical: "Critical"
        @unknown default: "Unknown"
        }
    }

    /// "2.1 GB", "180 MB": the same units Finder uses.
    static func bytes(_ count: Int64) -> String { ByteCountFormatter.string(fromByteCount: count, countStyle: .file) }

    static func power(_ battery: Battery) -> String {
        battery.charging ? "Charging" : battery.pluggedIn ? "Plugged in" : "On battery"
    }
}

// MARK: - Menu bar

/// One row of icon + value sections split by faint dividers, drawn as a template image so macOS
/// tints it for light/dark menu bars. Plain AppKit drawing: far lighter than SwiftUI's ImageRenderer.
enum MenuBarLabel {
    private enum Item {
        case stat(NSImage, String, slot: CGFloat)
        case ring(Int)  // percent filled, shown next to it
    }

    private static let height: CGFloat = 22
    private static let iconGap: CGFloat = 3     // icon → its value
    private static let pairGap: CGFloat = 5     // ↓ value → ↑ inside the network section
    private static let dividerPad: CGFloat = 5  // either side of a divider
    private static let ringSize: CGFloat = 13
    private static let ringWidth: CGFloat = 2.2

    private static let textStyle: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
        .foregroundColor: NSColor.black,
    ]

    private static let cpuIcon = symbol("cpu")
    private static let memoryIcon = symbol("memorychip")
    private static let downIcon = symbol("arrow.down")
    private static let upIcon = symbol("arrow.up")

    // Minimum slot per value so the item doesn't shuffle sideways every tick; "100%" just grows it.
    private static let percentSlot = textWidth("88%")
    private static let rateSlot = ["999K", "9.9M", "999B"].map(textWidth).max() ?? 26

    private static func symbol(_ name: String) -> NSImage {
        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config) ?? NSImage()
    }

    private static func textWidth(_ text: String) -> CGFloat {
        ceil((text as NSString).size(withAttributes: textStyle).width)
    }

    private static func width(_ item: Item) -> CGFloat {
        switch item {
        case let .stat(icon, text, slot): icon.size.width + iconGap + max(slot, textWidth(text))
        case let .ring(percent): ringSize + iconGap + max(percentSlot, textWidth("\(percent)%"))
        }
    }

    static func image(cpu: Int, memory: Int, disk: Int, down: String, up: String) -> NSImage {
        let sections: [[Item]] = [
            [.stat(cpuIcon, "\(cpu)%", slot: percentSlot)],
            [.stat(memoryIcon, "\(memory)%", slot: percentSlot)],
            [.ring(disk)],
            [.stat(downIcon, down, slot: rateSlot), .stat(upIcon, up, slot: rateSlot)],
        ]
        let contentWidth = sections.flatMap { $0 }.map(width).reduce(0, +)
            + pairGap * CGFloat(sections.map { $0.count - 1 }.reduce(0, +))
            + (dividerPad * 2 + 1) * CGFloat(sections.count - 1)

        let image = NSImage(size: NSSize(width: ceil(contentWidth), height: height), flipped: false) { _ in
            var x: CGFloat = 0
            for (i, section) in sections.enumerated() {
                if i > 0 {
                    x += dividerPad
                    NSColor.black.withAlphaComponent(0.25).setFill()
                    NSRect(x: x, y: 5, width: 1, height: 12).fill(using: .sourceOver)
                    x += 1 + dividerPad
                }
                for (j, item) in section.enumerated() {
                    if j > 0 { x += pairGap }
                    draw(item, at: x)
                    x += width(item)
                }
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    private static func draw(_ item: Item, at x: CGFloat) {
        switch item {
        case let .stat(icon, text, _):
            let size = icon.size
            icon.draw(in: NSRect(x: x, y: (height - size.height) / 2, width: size.width, height: size.height))
            drawText(text, at: x + size.width + iconGap)

        case let .ring(percent):
            drawText("\(percent)%", at: x + ringSize + iconGap)
            // Faint full track, solid arc for the used part, clockwise from 12 o'clock.
            let centre = NSPoint(x: x + ringSize / 2, y: height / 2)
            let radius = (ringSize - ringWidth) / 2
            let track = NSBezierPath()
            track.appendArc(withCenter: centre, radius: radius, startAngle: 0, endAngle: 360)
            track.lineWidth = ringWidth
            NSColor.black.withAlphaComponent(0.3).setStroke()
            track.stroke()

            let used = NSBezierPath()
            used.appendArc(withCenter: centre, radius: radius, startAngle: 90,
                           endAngle: 90 - 360 * min(max(Double(percent) / 100, 0), 1), clockwise: true)
            used.lineWidth = ringWidth
            used.lineCapStyle = .round
            NSColor.black.setStroke()
            used.stroke()
        }
    }

    private static func drawText(_ text: String, at x: CGFloat) {
        let size = (text as NSString).size(withAttributes: textStyle)
        (text as NSString).draw(at: NSPoint(x: x, y: (height - size.height) / 2), withAttributes: textStyle)
    }
}

// MARK: - Panel

let accent = Color(red: 0.839, green: 0.580, blue: 0.239)   // #D6943D, also download
let uploadColour = Color(red: 0.420, green: 0.620, blue: 0.859)   // #6B9EDB: tells apart from amber, colour-blind too
private let gibibyte = 1_073_741_824.0   // memory is counted in binary units, like Activity Monitor

struct PanelView: View {
    let monitor: Monitor
    @State private var freeingSpace = false

    var body: some View {
        Group {
            if freeingSpace {
                FreeUpSpace(monitor: monitor) { freeingSpace = false }
            } else {
                overview
            }
        }
        .padding(18)
        .frame(width: 320)
        .onAppear { monitor.panelOpen = true }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            monitor.panelOpen = true
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in
            monitor.panelOpen = false
            freeingSpace = false   // reopening starts on the overview, with fresh numbers
        }
    }

    private var overview: some View {
        let s = monitor.panel
        return VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 2) {
                Text(monitor.model ?? "Mac").font(.system(size: 13, weight: .semibold))
                Text("\(monitor.chip) · \(monitor.os)").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .lineLimit(1)

            HStack(alignment: .top, spacing: 0) {
                Ring(value: s.cpu / 100, title: "CPU", symbol: "cpu", detail: monitor.cores)
                    .help("\(Format.percent(s.cpuUser)) user · \(Format.percent(s.cpuSystem)) system")
                Ring(
                    value: Double(s.ramUsed) / Double(monitor.ramTotal), title: "Memory", symbol: "memorychip",
                    detail: "\(Format.number(Double(s.ramUsed) / gibibyte)) / \(Format.size(Double(monitor.ramTotal) / gibibyte))"
                )
                Button { freeingSpace = true } label: {
                    Ring(value: s.diskUsed, title: "Disk", symbol: "internaldrive",
                         detail: "\(Format.size(Double(s.diskFree) / 1e9)) free", opensPage: true)
                }
                .buttonStyle(HoverHighlight())
                .help("Free up space")
                Ring(value: s.gpu / 100, title: "GPU", symbol: "cube.transparent",
                     detail: monitor.gpuCores > 0 ? "\(monitor.gpuCores) cores" : "Graphics")
            }

            NetworkRow(stats: s)

            HStack(spacing: 14) {
                if let b = s.battery {
                    Fact(symbol: b.pluggedIn ? "battery.100.bolt" : batterySymbol(b.percent), text: "\(b.percent)%")
                        .help("\(Format.power(b)) · \(b.health)% health · \(b.cycles) cycles")
                }
                Fact(symbol: "clock", text: Format.uptime.string(from: s.uptime) ?? "").help("Uptime")
                Fact(symbol: "thermometer.medium", text: Format.thermal(s.thermal)).help("Temperature")
                Spacer()
                if docsFolder == nil {
                    MoreMenu()
                } else {
                    Image(systemName: "ellipsis").foregroundStyle(.secondary)   // menus can't be rendered to an image
                }
            }
            .padding(.top, 12)
            .overlay(alignment: .top) { Rectangle().fill(.primary.opacity(0.08)).frame(height: 1) }
        }
    }

    private func batterySymbol(_ percent: Int) -> String {
        switch percent {
        case ..<13: "battery.0"
        case ..<38: "battery.25"
        case ..<63: "battery.50"
        case ..<88: "battery.75"
        default: "battery.100"
        }
    }
}

/// A usage ring like the menu bar's disk ring, with its name and one line of detail.
struct Ring: View {
    let value: Double   // 0...1
    let title: String
    let symbol: String
    let detail: String
    var opensPage = false   // shows the detail as a tinted pill with a chevron, so the ring reads as a button

    var body: some View {
        let clamped = min(max(value, 0), 1)
        VStack(spacing: 8) {
            ZStack {
                Circle().stroke(accent.opacity(0.16), lineWidth: 5)
                Circle()
                    .trim(from: 0, to: clamped)
                    .stroke(accent, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text("\(Int((clamped * 100).rounded()))%")
                    .font(.system(size: 13, weight: .semibold).monospacedDigit())
                    .contentTransition(.numericText(value: clamped))
            }
            .frame(width: 54, height: 54)
            .animation(.smooth(duration: 0.6), value: clamped)

            VStack(spacing: 2) {
                HStack(spacing: 3) {
                    Image(systemName: symbol).font(.system(size: 10, weight: .medium))
                    Text(title).font(.system(size: 11, weight: .medium))
                }
                if opensPage {
                    HStack(spacing: 3) {
                        Text(detail)
                        Image(systemName: "chevron.right").font(.system(size: 7, weight: .bold)).foregroundStyle(accent)
                    }
                    .font(.system(size: 10, weight: .medium))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(accent.opacity(0.18), in: Capsule())
                    .fixedSize()   // a little wider than its column is fine; truncating isn't
                } else {
                    Text(detail).font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
            .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
    }
}

/// Download and upload, with a two-minute graph: amber for download, blue for upload.
struct NetworkRow: View {
    let stats: Stats

    var body: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                rate("arrow.down", stats.netDown, accent)
                rate("arrow.up", stats.netUp, uploadColour)
            }
            .frame(width: 92, alignment: .leading)

            Chart {
                ForEach(Array(stats.downHistory.enumerated()), id: \.offset) { point in
                    AreaMark(x: .value("Time", x(point.offset, stats.downHistory)), y: .value("Rate", point.element),
                             series: .value("Direction", "Down"))
                        .foregroundStyle(LinearGradient(colors: [accent.opacity(0.28), accent.opacity(0)],
                                                        startPoint: .top, endPoint: .bottom))
                        .interpolationMethod(.catmullRom)
                    LineMark(x: .value("Time", x(point.offset, stats.downHistory)), y: .value("Rate", point.element),
                             series: .value("Direction", "Down"))
                        .foregroundStyle(accent)
                        .lineStyle(StrokeStyle(lineWidth: 1.75, lineCap: .round, lineJoin: .round))
                        .interpolationMethod(.catmullRom)
                }
                ForEach(Array(stats.upHistory.enumerated()), id: \.offset) { point in
                    LineMark(x: .value("Time", x(point.offset, stats.upHistory)), y: .value("Rate", point.element),
                             series: .value("Direction", "Up"))
                        .foregroundStyle(uploadColour)
                        .lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                        .interpolationMethod(.catmullRom)
                }
            }
            .chartXScale(domain: 0...(Monitor.historyLength - 1))
            .chartYScale(domain: 0...max(((stats.downHistory + stats.upHistory).max() ?? 0) * 1.15, 8_000))
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .chartLegend(.hidden)
            .frame(height: 36)
        }
    }

    /// Newest point on the right edge, so a fresh graph fills in from the right.
    private func x(_ index: Int, _ history: [Double]) -> Int { index + Monitor.historyLength - history.count }

    private func rate(_ symbol: String, _ value: Double, _ colour: Color) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).font(.system(size: 10, weight: .bold)).foregroundStyle(colour)
            Text(Format.rate(value)).font(.system(size: 12, weight: .medium).monospacedDigit())
        }
    }
}

struct Fact: View {
    let symbol: String
    let text: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: symbol).font(.system(size: 11)).foregroundStyle(.secondary)
            Text(text).font(.system(size: 11, weight: .medium)).monospacedDigit()
        }
    }
}

struct MoreMenu: View {
    @State private var openAtLogin = LoginItem.isEnabled

    var body: some View {
        Menu {
            Toggle("Open at Login", isOn: $openAtLogin)
            Divider()
            Button("Quit Vitals") { NSApp.terminate(nil) }
        } label: {
            Image(systemName: "ellipsis")
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .foregroundStyle(.secondary)
        .fixedSize()
        .onChange(of: openAtLogin) { _, on in LoginItem.set(on) }
    }
}

/// Faint highlight on hover, so the Disk ring reads as something you can click.
struct HoverHighlight: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { Highlighted(configuration: configuration) }

    private struct Highlighted: View {
        let configuration: ButtonStyleConfiguration
        @State private var hovering = false

        var body: some View {
            configuration.label
                .contentShape(Rectangle())
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(.primary.opacity(configuration.isPressed ? 0.1 : hovering ? 0.05 : 0))
                        .padding(-5)
                )
                .onHover { hovering = $0 }
        }
    }
}

// MARK: - Free up space

enum Junk {
    static let home = FileManager.default.homeDirectoryForCurrentUser
    static let caches = home.appending(path: "Library/Caches")
    static let xcode = home.appending(path: "Library/Developer/Xcode/DerivedData")
    static let downloads = home.appending(path: "Downloads")
}

/// Bytes on disk taken by `url` and everything in it. Skips what macOS won't let Vitals read.
func allocatedSize(_ url: URL) -> Int64 {
    let key = URLResourceKey.totalFileAllocatedSizeKey
    func size(_ file: URL) -> Int64 { Int64((try? file.resourceValues(forKeys: [key]))?.totalFileAllocatedSize ?? 0) }
    var total = size(url)
    let files = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [key], errorHandler: { _, _ in true })
    while let file = files?.nextObject() as? URL { total += size(file) }
    return total
}

/// Deletes everything inside `folder` but keeps the folder. Skips what macOS won't let Vitals delete.
func clearContents(of folder: URL) {
    let fm = FileManager.default
    for item in (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [] {
        try? fm.removeItem(at: item)
    }
}

struct Download: Identifiable {
    let url: URL
    let size: Int64
    var id: URL { url }
}

/// What landed in Downloads over 30 days ago, biggest first. Throws if macOS hasn't allowed access.
func oldDownloads() throws -> [Download] {
    let cutoff = Date.now.addingTimeInterval(-30 * 86_400)
    let keys: Set<URLResourceKey> = [.addedToDirectoryDateKey, .creationDateKey]
    return try FileManager.default
        .contentsOfDirectory(at: Junk.downloads, includingPropertiesForKeys: Array(keys), options: .skipsHiddenFiles)
        .compactMap { url in
            let values = try? url.resourceValues(forKeys: keys)
            guard let added = values?.addedToDirectoryDate ?? values?.creationDate, added < cutoff else { return nil }
            return Download(url: url, size: allocatedSize(url))
        }
        .sorted { $0.size > $1.size }
}

/// Asks Finder to empty the Bin (Vitals can't see inside it itself). macOS asks once whether that's OK.
func emptyBin() -> Bool {
    let script = Process()
    script.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    script.arguments = ["-e", "with timeout of 600 seconds", "-e", "tell application \"Finder\" to empty trash", "-e", "end timeout"]
    guard (try? script.run()) != nil else { return false }
    script.waitUntilExit()
    return script.terminationStatus == 0
}

/// Opened from the Disk ring: what's safe to clear and how much each frees, plus old downloads to pick from.
struct FreeUpSpace: View {
    let monitor: Monitor
    let back: () -> Void

    @State private var caches: Int64?           // nil while measuring
    @State private var xcode: Int64?
    @State private var downloads: [Download]?
    @State private var downloadsBlocked = false
    @State private var picked: Set<URL> = []
    @State private var working: String?         // the row whose clear-up is running
    @State private var confirmBin = false
    @State private var binNote = "Erases what's in it for good"
    private var hasXcode: Bool { FileManager.default.fileExists(atPath: Junk.xcode.path) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Button(action: back) {
                    Label("Free up space", systemImage: "chevron.left").font(.system(size: 13, weight: .semibold))
                }
                .buttonStyle(.plain)
                Spacer()
                Text("\(Format.size(Double(monitor.panel.diskFree) / 1e9)) free")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 14) {
                CleanRow(title: "App caches", symbol: "shippingbox", detail: caches.map(Format.bytes)) {
                    action("caches", "Clear", work: { clearContents(of: Junk.caches) },
                           then: { caches = await measure(Junk.caches) })
                }
                if hasXcode {
                    CleanRow(title: "Xcode build files", symbol: "hammer", detail: xcode.map(Format.bytes)) {
                        action("xcode", "Clear", work: { clearContents(of: Junk.xcode) },
                               then: { xcode = await measure(Junk.xcode) })
                    }
                }
                CleanRow(title: "Old downloads", symbol: "arrow.down.circle", detail: downloadsDetail) {
                    action("downloads", "Move to Bin",
                           work: { [picked] in picked.forEach { try? FileManager.default.trashItem(at: $0, resultingItemURL: nil) } },
                           then: {
                               picked = []
                               binNote = "Empty it to free that space"
                               await loadDownloads()
                           })
                        .disabled(picked.isEmpty)
                }
                if let downloads, !downloads.isEmpty { downloadList(downloads) }
                CleanRow(title: "Bin", symbol: "trash", detail: confirmBin ? "This can't be undone" : binNote) { binButton }
            }
            .controlSize(.small)
        }
        .task { caches = await measure(Junk.caches) }
        .task { if hasXcode { xcode = await measure(Junk.xcode) } }
        .task { await loadDownloads() }
    }

    private var downloadsDetail: String? {
        guard let downloads else { return nil }
        if downloadsBlocked { return "Allow Downloads in System Settings › Privacy & Security › Files & Folders" }
        if downloads.isEmpty { return "Nothing over 30 days old" }
        let chosen = downloads.filter { picked.contains($0.url) }
        return chosen.isEmpty
            ? "\(downloads.count) over 30 days old · \(Format.bytes(downloads.map(\.size).reduce(0, +)))"
            : "\(chosen.count) chosen · \(Format.bytes(chosen.map(\.size).reduce(0, +)))"
    }

    private func downloadList(_ items: [Download]) -> some View {
        let list = VStack(alignment: .leading, spacing: 6) {
            ForEach(items) { item in
                Toggle(isOn: Binding(
                    get: { picked.contains(item.url) },
                    set: { _ in picked.formSymmetricDifference([item.url]) }   // ticks or unticks it
                )) {
                    HStack {
                        Text(item.url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 8)
                        Text(Format.bytes(item.size)).foregroundStyle(.secondary).monospacedDigit()
                    }
                    .font(.system(size: 11))
                }
                .toggleStyle(.checkbox)
            }
        }
        .padding(.leading, 28)
        return Group {
            if items.count <= 6 { list } else { ScrollView { list }.frame(height: 150) }
        }
    }

    /// Erasing is permanent, so the first click only arms it: the button turns red for a few seconds.
    @ViewBuilder private var binButton: some View {
        if working == "bin" {
            ProgressView().controlSize(.small)
        } else if confirmBin {
            Button("Erase") {
                confirmBin = false
                Task {
                    let emptied = await run("bin") { emptyBin() }
                    binNote = emptied ? "Emptied" : "Allow Vitals to control Finder in System Settings › Privacy & Security › Automation"
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
        } else {
            Button("Empty") {
                confirmBin = true
                Task {
                    try? await Task.sleep(for: .seconds(4))
                    confirmBin = false
                }
            }
            .disabled(working != nil)
        }
    }

    /// A row's button. Its work runs off the main thread with a spinner in the button's place.
    private func action(_ id: String, _ title: String, work: @escaping @Sendable () -> Void,
                        then: @escaping @MainActor () async -> Void) -> some View {
        Group {
            if working == id {
                ProgressView().controlSize(.small)
            } else {
                Button(title) {
                    Task {
                        await run(id, work)
                        await then()
                    }
                }
                .disabled(working != nil)
            }
        }
    }

    private func run<T: Sendable>(_ id: String, _ work: @escaping @Sendable () -> T) async -> T {
        working = id
        let result = await Task.detached(priority: .userInitiated) { work() }.value
        working = nil
        monitor.refreshDisk()
        return result
    }

    private func measure(_ folder: URL) async -> Int64 {
        await Task.detached(priority: .utility) { allocatedSize(folder) }.value
    }

    private func loadDownloads() async {
        do {
            downloads = try await Task.detached(priority: .utility) { try oldDownloads() }.value
        } catch {
            downloadsBlocked = true
            downloads = []
        }
    }
}

/// Icon, name and a line of detail on the left, a button on the right.
private struct CleanRow<Trailing: View>: View {
    let title: String
    let symbol: String
    let detail: String?   // nil while measuring
    @ViewBuilder let trailing: Trailing

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 14))
                .foregroundStyle(accent)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 12, weight: .medium))
                Text(detail ?? "Measuring…")
                    .font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            trailing
        }
    }
}

// MARK: - Docs and self-test

/// `--render-docs <folder>`: once the network graph is full, writes the real panel and menu bar, light and
/// dark, every tick for 20 ticks. These frames make the README images.
@MainActor func renderDocs(_ monitor: Monitor, to folder: URL) async {
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    monitor.panelOpen = true
    try? await Task.sleep(for: .seconds(Double(Monitor.historyLength) * Monitor.interval + 1))
    for frame in 0..<20 {
        for dark in [false, true] {
            let name = "\(dark ? "dark" : "light")-\(String(format: "%02d", frame)).png"
            save(
                PanelView(monitor: monitor)
                    .background(dark ? Color(white: 0.165) : Color(red: 0.969, green: 0.957, blue: 0.937))
                    .environment(\.colorScheme, dark ? .dark : .light),
                to: folder.appendingPathComponent("panel-" + name)
            )
            save(
                Image(nsImage: MenuBarLabel.image(
                    cpu: monitor.cpuPercent, memory: monitor.ramPercent, disk: monitor.diskPercent,
                    down: monitor.netIn, up: monitor.netOut
                ))
                .renderingMode(.template)
                .foregroundStyle(dark ? Color.white : Color.black),
                to: folder.appendingPathComponent("menubar-" + name)
            )
        }
        try? await Task.sleep(for: .seconds(Monitor.interval))
    }
    exit(0)
}

@MainActor private func save(_ view: some View, to url: URL) {
    let renderer = ImageRenderer(content: view)
    renderer.scale = 2
    guard let image = renderer.cgImage,
          let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    else { return }
    try? png.write(to: url)
}

/// `--selftest`: checks the maths and that every counter can be read on this Mac, then exits.
func selfTest() -> Never {
    precondition(Format.compactRate(0) == "0B" && Format.compactRate(512) == "512B", "bytes")
    precondition(Format.compactRate(999.6) == "1.0K", "rounds up into the next unit")
    precondition(Format.compactRate(1_234) == "1.2K", "one decimal under 10")
    precondition(Format.compactRate(45_600) == "46K", "whole numbers from 10")
    precondition(Format.compactRate(12_345_678) == "12M", "megabytes")
    precondition(Format.rate(1_234) == "1.2 KB/s" && Format.rate(820) == "820 B/s", "panel rates match the menu bar")
    precondition(Format.size(343.35) == "343 GB" && Format.size(9.46) == "9.5 GB" && Format.size(1234) == "1.2 TB", "sizes")
    precondition(counterDelta(UInt32(5), 3) == 2 && counterDelta(UInt32(3), 5) == 0, "counters going backwards count as 0")
    precondition(cpuTicks().idle > 0, "CPU counters are readable")
    let used = memoryUsed()
    precondition(used > 0 && used < ProcessInfo.processInfo.physicalMemory, "memory used is plausible")
    precondition(!sysctlString("machdep.cpu.brand_string").isEmpty, "chip name is readable")
    _ = MenuBarLabel.image(cpu: 100, memory: 5, disk: 50, down: "1.2K", up: "999M").size

    let scratch = FileManager.default.temporaryDirectory.appending(path: "vitals-selftest-\(getpid())")
    try? FileManager.default.createDirectory(at: scratch.appending(path: "inner"), withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: scratch.appending(path: "inner/file").path,
                                   contents: Data((0..<20_000).map { UInt8($0 % 251) }))
    precondition(allocatedSize(scratch) >= 20_000, "folder sizes count what's inside")
    clearContents(of: scratch)
    precondition(FileManager.default.fileExists(atPath: scratch.path)
                 && (try? FileManager.default.contentsOfDirectory(atPath: scratch.path))?.isEmpty == true,
                 "clearing empties a folder but keeps it")
    try? FileManager.default.removeItem(at: scratch)

    print("\(productName() ?? "Mac"), \(sysctlString("machdep.cpu.brand_string")), \(Format.size(Double(used) / gibibyte)) used, GPU \(gpuUsage())%, network \(networkBytes())")
    print("selftest ok")
    exit(0)
}
