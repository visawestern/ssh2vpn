import Foundation

/// One purchasable server source shown in the Add Server chooser dialog.
/// `ownServer` is always first so users with an existing server are not
/// confused by partner offers.
public struct VPSSupplier: Identifiable, Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case ownServer
        case partner
    }

    public let id: String
    public let kind: Kind
    public let name: String
    /// Short subtitle: "KVM VPS, $4/mo, 12+ regions".
    public let subtitle: String
    /// Display price: "from $4/mo".
    public let price: String
    /// Bonus the USER gets by signing up through the link (credits/discount).
    public let userBonus: String
    /// Badge text ("Recommended"); nil for own server and plain partners.
    public let badge: String?
    /// Affiliate URL. Placeholder until the owner registers real links —
    /// always https, opened in SFSafariViewController so tracking cookies live
    /// in Safari and the app never sees the session.
    public let refURL: String

    public init(id: String, kind: Kind, name: String, subtitle: String,
                price: String, userBonus: String, badge: String? = nil, refURL: String) {
        self.id = id
        self.kind = kind
        self.name = name
        self.subtitle = subtitle
        self.price = price
        self.userBonus = userBonus
        self.badge = badge
        self.refURL = refURL
    }
}

/// Hardcoded on purpose: updates ship as an App Store release (owner decision).
public enum VPSSupplierCatalog {
    /// Own server first (never confuse a user who already has credentials),
    /// then the 7 affiliate partners sorted by user benefit.
    public static let all: [VPSSupplier] = [
        VPSSupplier(
            id: "own-vps",
            kind: .ownServer,
            name: "vpsOwnServer",
            subtitle: "vpsOwnServerDesc",
            price: "",
            userBonus: "",
            refURL: ""
        ),
        VPSSupplier(
            id: "digitalocean",
            kind: .partner,
            name: "DigitalOcean",
            subtitle: "KVM VPS, $4/mo, 12+ regions",
            price: "from $4/mo",
            userBonus: "vpsBonusDigitalOcean",
            badge: "vpsRecommendedBadge",
            refURL: "https://m.do.co/c/placeholder"
        ),
        VPSSupplier(
            id: "vultr",
            kind: .partner,
            name: "Vultr",
            subtitle: "KVM VPS, $2.50/mo, 32 regions",
            price: "from $2.50/mo",
            userBonus: "vpsBonusVultr",
            badge: "vpsRecommendedBadge",
            refURL: "https://www.vultr.com/?ref=placeholder"
        ),
        VPSSupplier(
            id: "hostinger",
            kind: .partner,
            name: "Hostinger",
            subtitle: "VPS KVM 1, $4.99/mo",
            price: "from $4.99/mo",
            userBonus: "vpsBonusHostinger",
            badge: "vpsRecommendedBadge",
            refURL: "https://hostinger.com?REF=placeholder"
        ),
        VPSSupplier(
            id: "contabo",
            kind: .partner,
            name: "Contabo",
            subtitle: "Cloud VPS 10, €4.50/mo",
            price: "from €4.50/mo",
            userBonus: "",
            refURL: "https://contabo.com/?ref=placeholder"
        ),
        VPSSupplier(
            id: "linode",
            kind: .partner,
            name: "Linode",
            subtitle: "Nanode, $5/mo, 11 regions",
            price: "from $5/mo",
            userBonus: "",
            refURL: "https://www.linode.com/?ref=placeholder"
        ),
        VPSSupplier(
            id: "interserver",
            kind: .partner,
            name: "InterServer",
            subtitle: "VPS, $6/mo, price-lock",
            price: "from $6/mo",
            userBonus: "",
            refURL: "https://www.interserver.net/?ref=placeholder"
        ),
        VPSSupplier(
            id: "cloudways",
            kind: .partner,
            name: "Cloudways",
            subtitle: "Managed cloud, from $12/mo",
            price: "from $12/mo",
            userBonus: "",
            refURL: "https://www.cloudways.com/en/pricing.php?ref=placeholder"
        ),
    ]
}
