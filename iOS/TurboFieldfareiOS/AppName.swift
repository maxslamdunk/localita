import Foundation

/// The name the user sees under the app icon, set once by
/// `INFOPLIST_KEY_CFBundleDisplayName` in the project. User-facing text reads it
/// from here, so a rename is one build setting (plus the privacy policy page).
enum AppName {
    static let display = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName")
        as? String ?? "Localita"
}
