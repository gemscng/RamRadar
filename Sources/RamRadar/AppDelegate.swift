import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model: AppModel
    private var statusItem: StatusItemController?

    init(demo: Bool) {
        model = AppModel(demo: demo)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = StatusItemController(model: model)
        model.start()
    }
}
