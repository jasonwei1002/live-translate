import Foundation

/// One-time copy of settings from the pre-rename UserDefaults domain
/// (`com.local.LiveTranslate`) into the current one (`com.local.Subtle`),
/// so the product rename does not lose API keys, languages, or styles.
/// Idempotent; existing values in the new domain are never overwritten.
enum LegacyDefaultsMigrator {
  private static let legacyDomain = "com.local.LiveTranslate"
  private static let migratedKey = "didMigrateLegacyDefaults"

  static func migrateIfNeeded() {
    let defaults = UserDefaults.standard
    guard !defaults.bool(forKey: migratedKey) else { return }
    defaults.set(true, forKey: migratedKey)
    guard let legacy = defaults.persistentDomain(forName: legacyDomain) else { return }
    for (key, value) in legacy where defaults.object(forKey: key) == nil {
      defaults.set(value, forKey: key)
    }
  }
}
