import Foundation
import HerdrVoiceCore

/// `herdr-voice setup`: asks for the provider's API key with hidden input and saves it in the login Keychain.
/// Returns whether a key was saved.
func setupKey(for provider: Provider) -> Bool {
    print("""
    Set up \(provider.menuTitle) for herdr-voice.
      1. Create an API key at \(provider.keyPage)
      2. Paste it below. Typing is hidden; it goes straight into your macOS Keychain as \(provider.keyEnv).

    """)
    var buffer = [CChar](repeating: 0, count: 1024)
    guard readpassphrase("\(provider.menuTitle) API key: ", &buffer, buffer.count, RPP_REQUIRE_TTY) != nil else {
        print("✖ couldn't read from the terminal; run this in an interactive terminal")
        return false
    }
    let raw = String(cString: buffer)
    buffer.withUnsafeMutableBytes { $0.initializeMemory(as: UInt8.self, repeating: 0) } // don't leave the key around
    guard let key = Keychain.cleanKey(raw) else {
        print("✖ that doesn't look like an API key (empty, or it has spaces or other characters keys don't use); nothing saved")
        return false
    }
    if !key.hasPrefix(provider.keyPrefix) {
        print("⚠ \(provider.menuTitle) keys start with \"\(provider.keyPrefix)\" and this one doesn't. Save it anyway? [y/N] ", terminator: "")
        guard readLine()?.lowercased().hasPrefix("y") == true else {
            print("nothing saved")
            return false
        }
    }
    guard Keychain.store(service: provider.keyEnv, value: key) else {
        print("✖ couldn't save it in the Keychain; set \(provider.keyEnv) in the environment instead")
        return false
    }
    print("✓ saved \(provider.keyEnv) in your login Keychain. Replace it any time with: herdr-voice setup \(provider.rawValue)\n")
    return true
}
