import AppKit

let app = NSApplication.shared

let arguments = CommandLine.arguments
if let index = arguments.firstIndex(of: "--snapshot"), arguments.indices.contains(index + 1) {
    SnapshotRenderer.render(into: URL(fileURLWithPath: arguments[index + 1], isDirectory: true))
    exit(0)
}

// Compiles every AppleScript without running it (nothing is sent to Spotify or Music).
if arguments.contains("--check-scripts") {
    var failures = 0
    for (name, source) in MusicScripts.all {
        var info: NSDictionary?
        let ok = NSAppleScript(source: source)?.compileAndReturnError(&info) ?? false
        if !ok { failures += 1 }
        print(ok ? "ok    \(name)" : "FAIL  \(name): \(ScriptError(info).message)")
    }
    exit(failures == 0 ? 0 : 1)
}

let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
