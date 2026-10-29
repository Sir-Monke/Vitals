import SwiftUI
import Charts
import Darwin
import IOKit
import ServiceManagement
import CoreServices

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
        (live.diskFree, live.diskTotal) = diskCapacity()
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

/// Height of a rate on the network graph, 0...1 of `peak`. Logarithmic, bending from about 1 KB/s, so a
/// 50 MB/s download still leaves 500 KB/s of browsing over half way up.
func graphLevel(_ rate: Double, peak: Double) -> Double {
    log1p(max(rate, 0) / 1_000) / log1p(peak / 1_000)
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

/// Upload and download, with a two-minute graph that follows the arrows: blue upload rises, amber download hangs below.
struct NetworkRow: View {
    let stats: Stats

    var body: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                rate("arrow.up", stats.netUp, uploadColour)
                rate("arrow.down", stats.netDown, accent)
            }
            .frame(width: 92, alignment: .leading)

            Chart {
                direction("Up", stats.upHistory, uploadColour, above: true)
                direction("Down", stats.downHistory, accent, above: false)
            }
            .chartXScale(domain: 0...(Monitor.historyLength - 1))
            .chartYScale(domain: -1...1)
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .chartLegend(.hidden)
            .frame(height: 44)
        }
    }

    /// One direction on its own log scale, so a quiet upload still shows next to a busy download and a
    /// big download doesn't flatten everything else. Upload rises from the middle, download hangs below it.
    @ChartContentBuilder
    private func direction(_ name: String, _ history: [Double], _ colour: Color, above: Bool) -> some ChartContent {
        let peak = max((history.max() ?? 0) * 1.1, 100_000)   // floor: background chatter stays low
        let sign = above ? 1.0 : -1.0
        ForEach(Array(history.enumerated()), id: \.offset) { point in
            let time = x(point.offset, history), level = sign * graphLevel(point.element, peak: peak)
            AreaMark(x: .value("Time", time), yStart: .value("Rate", 0), yEnd: .value("Rate", level),
                     series: .value("Direction", name))
                .foregroundStyle(LinearGradient(colors: [colour.opacity(0.3), colour.opacity(0.02)],
                                                startPoint: above ? .top : .bottom, endPoint: .center))
                .interpolationMethod(.catmullRom)
            LineMark(x: .value("Time", time), y: .value("Rate", level), series: .value("Direction", name))
                .foregroundStyle(colour)
                .lineStyle(StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
                .interpolationMethod(.catmullRom)
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
// The approach follows ClearDisk and BlitzClean (both MIT): rebuildable caches are deleted outright, your own files
// go to the Bin, and anything in use or changed in the last hour is left alone.

/// A folder of things that rebuild themselves, so clearing it is safe.
struct CacheFolder: Identifiable {
    let name: String
    let symbol: String
    let folder: URL
    let about: String   // shown on hover
    var id: String { name }

    private static let home = FileManager.default.homeDirectoryForCurrentUser

    /// The ones this Mac has.
    static let all = [
        CacheFolder(name: "App caches", symbol: "shippingbox", folder: home.appending(path: "Library/Caches"),
                    about: "Files apps keep to load faster. They rebuild what they need."),
        CacheFolder(name: "Xcode build files", symbol: "hammer",
                    folder: home.appending(path: "Library/Developer/Xcode/DerivedData"),
                    about: "Build products and indexes. Xcode rebuilds them on the next build."),
        CacheFolder(name: "Xcode device support", symbol: "iphone",
                    folder: home.appending(path: "Library/Developer/Xcode/iOS DeviceSupport"),
                    about: "Symbols for iPhones you've connected. Xcode downloads them again when one connects."),
        CacheFolder(name: "npm cache", symbol: "cube.box", folder: home.appending(path: ".npm/_cacache"),
                    about: "Packages npm has downloaded. It downloads them again when needed."),
    ].filter { FileManager.default.fileExists(atPath: $0.folder.path) }
}

enum Places {
    static let downloads = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Downloads")
    static let bin = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".Trash")
}

/// Free and total space on the startup disk. Free includes space macOS can purge, as Finder shows it.
func diskCapacity() -> (free: Int64, total: Int64) {
    let values = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [
        .volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey,
    ])
    return (values?.volumeAvailableCapacityForImportantUsage ?? 0, Int64(values?.volumeTotalCapacity ?? 0))
}

/// Bytes on disk taken by `url` and everything in it. A hard-linked file counts once across its links (npm, pnpm
/// and Cargo stores are full of them). Skips what macOS won't let Vitals read.
func allocatedSize(_ url: URL) -> Int64 {
    let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .linkCountKey]
    func size(_ file: URL) -> Int64 {
        let values = try? file.resourceValues(forKeys: keys)
        return Int64(values?.totalFileAllocatedSize ?? 0) / Int64(max(values?.linkCount ?? 1, 1))
    }
    var total = size(url)
    let files = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys), errorHandler: { _, _ in true })
    while let file = files?.nextObject() as? URL { total += size(file) }
    return total
}

/// What clearing a folder would remove, and what stays because it's in use.
struct ClearPlan: Sendable {
    var items: [URL] = []
    var size: Int64 = 0   // what clearing frees
    var kept: Int64 = 0   // in use: an open app's cache, or being written right now
}

/// Splits what's inside `folder` into what's safe to delete and what's in use: anything named in `keeping` (the
/// caches of open apps) or changed since `cutoff`. Measuring and clearing both use this, so the size shown is what
/// Clear removes.
func clearPlan(_ folder: URL, keeping: Set<String> = [], changedBefore cutoff: Date = .now.addingTimeInterval(-300)) -> ClearPlan {
    var plan = ClearPlan()
    let key = URLResourceKey.contentModificationDateKey
    for item in (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [key])) ?? [] {
        // ponytail: a folder's date moves only when its own entries change. BlitzClean also asks lsof which files
        // are open; add that if a cleared cache ever upsets a running app.
        let changed = (try? item.resourceValues(forKeys: [key]))?.contentModificationDate ?? .distantFuture
        let size = allocatedSize(item)
        if changed < cutoff && !keeping.contains(item.lastPathComponent) {
            plan.items.append(item)
            plan.size += size
        } else {
            plan.kept += size
        }
    }
    return plan
}

/// Deletes what the plan found safe to delete. Returns the names macOS wouldn't let go, so they count as in use.
func removePlanned(_ plan: ClearPlan) -> Set<String> {
    Set(plan.items.filter { (try? FileManager.default.removeItem(at: $0)) == nil }.map(\.lastPathComponent))
}

struct Download: Identifiable {
    let url: URL
    let size: Int64
    var id: URL { url }
}

/// What in Downloads you haven't added, changed or opened for 30 days, biggest first. Leaves half-finished
/// downloads alone. Throws if macOS hasn't allowed access to Downloads.
func oldDownloads() throws -> [Download] {
    let cutoff = Date.now.addingTimeInterval(-30 * 86_400)
    let keys: Set<URLResourceKey> = [.addedToDirectoryDateKey, .contentModificationDateKey]
    let unfinished: Set<String> = ["crdownload", "download", "part"]
    return try FileManager.default
        .contentsOfDirectory(at: Places.downloads, includingPropertiesForKeys: Array(keys), options: .skipsHiddenFiles)
        .compactMap { url in
            guard !unfinished.contains(url.pathExtension.lowercased()) else { return nil }
            let values = try? url.resourceValues(forKeys: keys)
            let dates = [values?.addedToDirectoryDate, values?.contentModificationDate, lastOpened(url)].compactMap { $0 }
            guard let latest = dates.max(), latest < cutoff else { return nil }
            return Download(url: url, size: allocatedSize(url))
        }
        .sorted { $0.size > $1.size }
}

/// When it was last opened, as Spotlight records it.
func lastOpened(_ url: URL) -> Date? {
    MDItemCreateWithURL(nil, url as CFURL).flatMap { MDItemCopyAttribute($0, kMDItemLastUsedDate) as? Date }
}

/// The Bin's size, or nil when macOS keeps Vitals out (looking inside needs Full Disk Access).
func binSize() -> Int64? {
    (try? FileManager.default.contentsOfDirectory(atPath: Places.bin.path)) == nil ? nil : allocatedSize(Places.bin)
}

/// Asks Finder to empty the Bin, which works without Full Disk Access. macOS asks once whether that's OK.
func emptyBin() -> Bool {
    let script = Process()
    script.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    script.arguments = ["-e", "with timeout of 600 seconds", "-e", "tell application \"Finder\" to empty trash", "-e", "end timeout"]
    guard (try? script.run()) != nil else { return false }
    script.waitUntilExit()
    return script.terminationStatus == 0
}

/// Opened from the Disk ring: how much is safe to clear, each cache on its own, old downloads to pick from, the Bin.
struct FreeUpSpace: View {
    let monitor: Monitor
    let back: () -> Void

    @State private var plans: [String: ClearPlan] = [:]   // by cache name; missing while measuring
    @State private var stuck: Set<String> = []            // what macOS wouldn't let Vitals delete
    @State private var freed: Int64 = 0
    @State private var downloads: [Download]?
    @State private var downloadsBlocked = false
    @State private var picked: Set<URL> = []
    @State private var binBytes: Int64?
    @State private var binChecked = false
    @State private var binNote: String?
    @State private var confirmBin = false
    @State private var working: String?               // the button whose work is running

    var body: some View {
        let measuring = plans.count < CacheFolder.all.count
        let total = plans.values.map(\.size).reduce(0, +)
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

            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(measuring ? "Measuring…" : Format.bytes(total))
                        .font(.system(size: 22, weight: .semibold).monospacedDigit())
                        .contentTransition(.numericText())
                    Text(freed > 0 ? "Freed \(Format.bytes(freed))" : "safe to clear")
                        .font(.system(size: 11)).foregroundStyle(freed > 0 ? accent : .secondary)
                }
                Spacer()
                button("Clear all", id: "all") { await clear(CacheFolder.all.filter { plans[$0.name]?.size ?? 0 > 0 }, id: "all") }
                    .buttonStyle(.borderedProminent)
                    .tint(accent)
                    .disabled(measuring || total == 0)
            }
            .animation(.smooth, value: total)

            VStack(alignment: .leading, spacing: 12) {
                ForEach(CacheFolder.all) { cache in
                    CleanRow(title: cache.name, symbol: cache.symbol, detail: detail(plans[cache.name])) {
                        button("Clear", id: cache.name) { await clear([cache], id: cache.name) }
                            .disabled(plans[cache.name]?.size ?? 0 == 0)
                    }
                    .help(cache.about)
                }
                CleanRow(title: "Old downloads", symbol: "arrow.down.circle", detail: downloadsDetail) {
                    button("Move to Bin", id: "downloads") { await binDownloads() }
                        .disabled(picked.isEmpty)
                }
                .help("Things you haven't opened or changed for 30 days. They go to the Bin, so you can still get them back.")
                if let downloads, !downloads.isEmpty { downloadList(downloads) }
                CleanRow(title: "Bin", symbol: "trash", detail: binDetail) { binButton }
            }

            Text("Leaves the caches of open apps, and anything changed in the last 5 minutes.")
                .font(.system(size: 10)).foregroundStyle(.tertiary)
        }
        .controlSize(.small)
        .task {
            let keep = inUse
            await withTaskGroup(of: (String, ClearPlan).self) { group in
                for cache in CacheFolder.all { group.addTask { (cache.name, clearPlan(cache.folder, keeping: keep)) } }
                for await (name, plan) in group { plans[name] = plan }
            }
        }
        .task { await loadDownloads() }
        .task { await measureBin() }
    }

    private var downloadsDetail: String? {
        guard let downloads else { return nil }
        if downloadsBlocked { return "Allow Downloads in System Settings › Privacy & Security › Files & Folders" }
        if downloads.isEmpty { return "Nothing unused for 30 days" }
        let chosen = downloads.filter { picked.contains($0.url) }
        return chosen.isEmpty
            ? "\(downloads.count) unused for 30 days · \(Format.bytes(downloads.map(\.size).reduce(0, +)))"
            : "\(chosen.count) chosen · \(Format.bytes(chosen.map(\.size).reduce(0, +)))"
    }

    private var binDetail: String? {
        if confirmBin { return "This can't be undone" }
        if let binNote { return binNote }
        guard binChecked else { return nil }
        return binBytes.map(Format.bytes) ?? "Erases what's in it for good"
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
        if confirmBin {
            Button("Erase") {
                confirmBin = false
                Task { await emptyTheBin() }
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
        } else {
            button("Empty", id: "bin") {
                confirmBin = true
                try? await Task.sleep(for: .seconds(4))
                confirmBin = false
            }
            .disabled(binBytes == 0)
        }
    }

    /// A button that turns into a spinner while its work runs, and waits while another button's work runs.
    @ViewBuilder private func button(_ title: String, id: String, _ action: @escaping () async -> Void) -> some View {
        if working == id {
            ProgressView().controlSize(.small)
        } else {
            Button(title) { Task { await action() } }.disabled(working != nil)
        }
    }

    /// Runs `work` off the main thread, marking `id` as busy, then shows the new free space.
    private func run<T: Sendable>(_ id: String, _ work: @escaping @Sendable () -> T) async -> T {
        working = id
        let result = await Task.detached(priority: .userInitiated) { work() }.value
        working = nil
        monitor.refreshDisk()
        return result
    }

    /// Names that stay: the caches of open apps, and whatever macOS wouldn't let Vitals delete before.
    private var inUse: Set<String> { Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)).union(stuck) }

    /// "12 MB", or "12 MB · 140 MB in use" when some of it has to stay.
    private func detail(_ plan: ClearPlan?) -> String? {
        guard let plan else { return nil }
        guard plan.kept >= 1_000_000 else { return Format.bytes(plan.size) }
        let kept = "\(Format.bytes(plan.kept)) in use"
        return plan.size == 0 ? kept : "\(Format.bytes(plan.size)) · \(kept)"
    }

    /// Plans afresh (things may have changed since measuring), clears, then measures again: "freed" is what
    /// really went, and anything macOS refused counts as in use from then on.
    private func clear(_ caches: [CacheFolder], id: String) async {
        let keep = inUse
        let outcomes = await run(id) {
            caches.map { cache -> (plan: ClearPlan, refused: Set<String>, freed: Int64) in
                let before = clearPlan(cache.folder, keeping: keep)
                let refused = removePlanned(before)
                let after = clearPlan(cache.folder, keeping: keep.union(refused))
                return (after, refused, max(before.size + before.kept - after.size - after.kept, 0))
            }
        }
        for (cache, outcome) in zip(caches, outcomes) {
            plans[cache.name] = outcome.plan
            stuck.formUnion(outcome.refused)
            freed += outcome.freed
        }
    }

    private func binDownloads() async {
        await run("downloads") { [picked] in
            picked.forEach { try? FileManager.default.trashItem(at: $0, resultingItemURL: nil) }
        }
        picked = []
        binNote = nil
        await loadDownloads()   // anything that didn't move shows up again
        await measureBin()
    }

    /// Finder empties the Bin, so the space freed is measured from the disk's free space before and after.
    private func emptyTheBin() async {
        let before = diskCapacity().free
        let emptied = await run("bin") { emptyBin() }
        try? await Task.sleep(for: .seconds(2))   // free space settles a moment after the files go
        let gained = diskCapacity().free - before
        binNote = !emptied ? "Allow Vitals to control Finder in System Settings › Privacy & Security › Automation"
            : gained >= 100_000_000 ? "Freed \(Format.bytes(gained))" : "Emptied"
        monitor.refreshDisk()
        await measureBin()
    }

    private func measureBin() async {
        binBytes = await Task.detached(priority: .utility) { binSize() }.value
        binChecked = true
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
    precondition(graphLevel(0, peak: 1e6) == 0 && graphLevel(1e6, peak: 1e6) == 1, "graph spans its height")
    precondition(graphLevel(500_000, peak: 50_000_000) > 0.5, "a big download doesn't flatten normal traffic")
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
    let size = allocatedSize(scratch)
    precondition(size >= 20_000, "folder sizes count what's inside")
    try? FileManager.default.linkItem(at: scratch.appending(path: "inner/file"), to: scratch.appending(path: "inner/link"))
    precondition(abs(allocatedSize(scratch) - size) < 4096, "a hard-linked file counts once")
    let fresh = clearPlan(scratch)
    precondition(fresh.items.isEmpty && fresh.kept >= 20_000, "anything changed in the last 5 minutes stays")
    let later = Date.now.addingTimeInterval(60)
    precondition(clearPlan(scratch, keeping: ["inner"], changedBefore: later).items.isEmpty, "open apps' caches stay")
    let plan = clearPlan(scratch, changedBefore: later)
    precondition(plan.size >= 20_000 && plan.kept == 0, "the size shown is what Clear removes")
    precondition(removePlanned(plan).isEmpty, "clearing deletes what was planned")
    precondition(FileManager.default.fileExists(atPath: scratch.path)
                 && (try? FileManager.default.contentsOfDirectory(atPath: scratch.path))?.isEmpty == true,
                 "clearing empties a folder but keeps it")
    try? FileManager.default.removeItem(at: scratch)

    print("\(productName() ?? "Mac"), \(sysctlString("machdep.cpu.brand_string")), \(Format.size(Double(used) / gibibyte)) used, GPU \(gpuUsage())%, network \(networkBytes())")
    print("selftest ok")
    exit(0)
}
