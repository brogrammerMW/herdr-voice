/// The AI-model entries of the orb's right-click menu: every provider in menu order, the current one checked,
/// ones without an API key (or Local OpenLive before it's set up) shown but disabled (so it's clear why they can't be picked).
public enum ModelMenu {
    public struct Entry: Equatable {
        public let provider: Provider
        public let title: String
        public let checked: Bool
        public let enabled: Bool
    }

    public static func entries(current: Provider, hasKey: (Provider) -> Bool, localIsBuilt: Bool) -> [Entry] {
        Provider.menuOrder.map { provider in
            let available = provider == .local ? localIsBuilt : !provider.requiresAPIKey || hasKey(provider)
            let reason = provider == .local ? " (not set up)" : " (no key)"
            return Entry(provider: provider, title: provider.menuTitle + (available ? "" : reason),
                         checked: provider == current, enabled: available)
        }
    }
}
