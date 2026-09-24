import AppKit
import RamRadarCore

let arguments = CommandLine.arguments
let demo = arguments.contains("--demo")

if arguments.contains("--help") || arguments.contains("-h") {
    print(CLI.usage)
    exit(0)
}
if arguments.contains("--dump") {
    CLI.dump(demo: demo)
    exit(0)
}
if let i = arguments.firstIndex(of: "--snapshot"), i + 1 < arguments.count {
    let ok = MainActor.assumeIsolated {
        let detail = arguments.firstIndex(of: "--detail").flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil }
        return CLI.snapshot(to: arguments[i + 1], demo: demo, dark: arguments.contains("--dark"), detail: detail)
    }
    exit(ok ? 0 : 1)
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate(demo: demo)
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
