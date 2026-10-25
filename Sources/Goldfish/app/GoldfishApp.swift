import AppKit

@main struct GoldfishApp {
  private static let appDelegate = AppDelegate()

  static func main() {
    let application = NSApplication.shared
    application.setActivationPolicy(.accessory)
    do { try GoldfishMigration.prepare() } catch {
      let alert = NSAlert()
      alert.messageText = "Goldfish could not migrate saved data"
      alert.informativeText =
        "Your original files are untouched. Quit older copies of the app, unlock the login Keychain, and try again. "
        + error.localizedDescription
      alert.runModal()
      return
    }
    application.delegate = appDelegate
    application.activate(ignoringOtherApps: true)
    application.run()
  }
}
