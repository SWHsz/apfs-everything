import AppKit

@main
@MainActor
struct APFSFindDesktopApp {
  static func main() {
    let app = NSApplication.shared
    let delegate = AppDelegate(); app.delegate = delegate
    withExtendedLifetime(delegate) { app.run() }
  }
}
