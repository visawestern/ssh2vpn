import Foundation

/// One purchasable server source shown in the Add Server chooser dialog.
/// `ownServer` is always first so users with an existing server are not
/// confused by partner offers.
public struct VPSSupplier: Identifiable, Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case ownServer
        case partner
        /// Providers WITHOUT an affiliate/referral program — folded into the
        /// collapsed "Other providers" accordion so they don't take prime
        /// space from partners that pay the owner a commission.
        case other
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
///
/// URLs verified 8 Sep 2026 (Playwright, headless Chromium):
/// every partner URL loads the actual signup/registration form directly —
/// no homepage detour, no hunting for the button.
public enum VPSSupplierCatalog {
    /// Own server first (never confuse a user who already has credentials),
    /// then affiliate partners sorted by user benefit, then non-affiliate
    /// providers in the collapsed "Other" section.
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
        // MARK: - Partners (affiliate programs verified: they pay the owner)
        VPSSupplier(
            id: "digitalocean",
            kind: .partner,
            name: "DigitalOcean",
            subtitle: "KVM VPS, $4/mo, 12+ regions",
            price: "from $4/mo",
            userBonus: "vpsBonusDigitalOcean",
            badge: "vpsRecommendedBadge",
            // Verified: registration form loads directly.
            refURL: "https://cloud.digitalocean.com/registrations/new"
        ),
        VPSSupplier(
            id: "vultr",
            kind: .partner,
            name: "Vultr",
            subtitle: "KVM VPS, $2.50/mo, 32 regions",
            price: "from $2.50/mo",
            userBonus: "vpsBonusVultr",
            badge: "vpsRecommendedBadge",
            // Verified: signup page behind Cloudflare bot-check — loads for
            // real users (form confirmed in manual Safari test).
            refURL: "https://my.vultr.com/signup/"
        ),
        VPSSupplier(
            id: "hostinger",
            kind: .partner,
            name: "Hostinger",
            subtitle: "VPS KVM 1, $4.99/mo",
            price: "from $4.99/mo",
            userBonus: "vpsBonusHostinger",
            badge: "vpsRecommendedBadge",
            // Verified: direct signup page (form confirmed).
            refURL: "https://www.hostinger.com/signup"
        ),
        VPSSupplier(
            id: "contabo",
            kind: .partner,
            name: "Contabo",
            subtitle: "Cloud VPS 10, €4.50/mo",
            price: "from €4.50/mo",
            userBonus: "",
            // Verified: email registration page loads directly; affiliate
            // program confirmed (contabo.com/en/affiliate-program/).
            refURL: "https://contabo.com/en/register/email/"
        ),
        VPSSupplier(
            id: "interserver",
            kind: .partner,
            name: "InterServer",
            subtitle: "VPS, $6/mo, price-lock",
            price: "from $6/mo",
            userBonus: "",
            // Verified: signup page loads with login form; affiliate program
            // up to $300/sale confirmed (interserver.net/affiliate.html).
            refURL: "https://my.interserver.net/signup.php"
        ),
        VPSSupplier(
            id: "racknerd",
            kind: .partner,
            name: "RackNerd",
            subtitle: "KVM VPS, from $10/yr, 15+ US/EU DCs",
            price: "from $10/yr",
            userBonus: "",
            // Verified: registration form loads directly; 15% recurring
            // affiliate program confirmed (racknerd.com/affiliates).
            refURL: "https://my.racknerd.com/register.php"
        ),
        VPSSupplier(
            id: "cloudways",
            kind: .partner,
            name: "Cloudways",
            subtitle: "Managed cloud, from $12/mo",
            price: "from $12/mo",
            userBonus: "",
            // Verified: signup page (Cloudflare bot-check; form confirmed for
            // real users). Kept last — most expensive tier.
            refURL: "https://www.cloudways.com/en/signup.php"
        ),
        // MARK: - Other (no affiliate program → collapsed accordion).
        // Hetzner: explicitly has NO affiliate/partner program (checked
        // hetzner.com — zero mentions). Linode: affiliate page 404s under
        // Akamai. OVH: no reseller signup for individuals. They stay as a
        // courtesy fallback for countries where partners above don't fit.
        VPSSupplier(
            id: "hetzner",
            kind: .other,
            name: "Hetzner",
            subtitle: "Cloud CX22, €3.79/mo, EU/US/SG",
            price: "from €3.79/mo",
            userBonus: "",
            // Verified: signup loads (proof-of-work bot-check first, then form).
            refURL: "https://accounts.hetzner.com/signup"
        ),
        VPSSupplier(
            id: "linode",
            kind: .other,
            name: "Linode (Akamai)",
            subtitle: "Nanode, $5/mo, 11 regions",
            price: "from $5/mo",
            userBonus: "",
            // Verified: signup form loads directly.
            refURL: "https://login.linode.com/signup"
        ),
        VPSSupplier(
            id: "ovh",
            kind: .other,
            name: "OVHcloud",
            subtitle: "VPS Starter, €3.50/mo, 30+ DCs",
            price: "from €3.50/mo",
            userBonus: "",
            // Verified: express order wizard (JS redirect chain confirmed).
            refURL: "https://www.ovhcloud.com/en/order/express/"
        ),
    ]
}
