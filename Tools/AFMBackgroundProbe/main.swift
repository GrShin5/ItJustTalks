import AppKit
import Foundation

@MainActor
final class ProbeAppDelegate: NSObject, NSApplicationDelegate {
    let options: ProbeOptions

    init(options: ProbeOptions) {
        self.options = options
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let runner = ProbeRunner(options: options)
        Task { @MainActor in
            await runner.run()
        }
    }
}

let (parsed, parseError) = ProbeOptions.parse(Array(CommandLine.arguments.dropFirst()))
guard let options = parsed else {
    FileHandle.standardError.write(Data("argument error: \(parseError ?? "unknown")\n".utf8))
    exit(2)
}

let app = NSApplication.shared
app.setActivationPolicy(options.policy == .regular ? .regular : .accessory)
let delegate = ProbeAppDelegate(options: options)
app.delegate = delegate
// Never calls activate: the probe must stay in the background.
app.run()
