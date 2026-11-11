import Foundation
import Observation

@Observable
final class AppSettings {
    var showSongBesideNotch: Bool {
        didSet { UserDefaults.standard.set(showSongBesideNotch, forKey: Keys.showSongBesideNotch) }
    }

    var showMenuBarIcon: Bool {
        didSet { UserDefaults.standard.set(showMenuBarIcon, forKey: Keys.showMenuBarIcon) }
    }

    private enum Keys {
        static let showSongBesideNotch = "showSongBesideNotch"
        static let showMenuBarIcon = "showMenuBarIcon"
    }

    init() {
        let defaults = UserDefaults.standard
        defaults.register(defaults: [Keys.showSongBesideNotch: true, Keys.showMenuBarIcon: true])
        showSongBesideNotch = defaults.bool(forKey: Keys.showSongBesideNotch)
        showMenuBarIcon = defaults.bool(forKey: Keys.showMenuBarIcon)
    }
}
