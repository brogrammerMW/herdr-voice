/// The AI-model entries of the orb's right-click menu: every provider in menu order, the current one checked,
/// ones without an API key shown but disabled (so it's clear why they can't be picked).
public enum ModelMenu {
    public struct Entry: Equatable {
        public let provider: Provider
        public let title: String
        public let checked: Bool
        public let enabled: Bool
    }

    public static func entries(current: Provider, hasKey: (Provider) -> Bool) -> [Entry] {
        Provider.menuOrder.map { provider in
            let available = !provider.requiresAPIKey || hasKey(provider)
            return Entry(provider: provider, title: provider.menuTitle + (available ? "" : " (no key)"),
                         checked: provider == current, enabled: available)
        }
    }
}
