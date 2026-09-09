import XCTest
@testable import VPNCore

/// The hardcoded provider catalog: own VPS + 8 affiliate partners + 3
/// "Other" providers (collapsed accordion), layered ordering, unique ids,
/// valid URLs, no empty display fields.
final class VPSSupplierTests: XCTestCase {

    func testCatalogContainsExactlyElevenEntries() {
        XCTAssertEqual(VPSSupplierCatalog.all.count, 11)
    }

    func testFirstEntryIsOwnVPSSoUsersDoNotGetConfused() {
        XCTAssertEqual(VPSSupplierCatalog.all.first?.kind, .ownServer)
    }

    func testIdsAreUnique() {
        let ids = VPSSupplierCatalog.all.map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count, "duplicate supplier ids")
    }

    func testAllPartnerAndOtherEntriesHaveValidHTTPSURL() throws {
        for s in VPSSupplierCatalog.all where s.kind != .ownServer {
            let url = try XCTUnwrap(URL(string: s.refURL), "\(s.id): bad URL")
            XCTAssertEqual(url.scheme, "https", "\(s.id): must be https")
            XCTAssertNotNil(url.host, "\(s.id): no host")
        }
    }

    func testEveryPartnerEntryHasNonEmptyDisplayFields() {
        for s in VPSSupplierCatalog.all where s.kind != .ownServer {
            XCTAssertFalse(s.name.isEmpty, "\(s.id): empty name")
            XCTAssertFalse(s.price.isEmpty, "\(s.id): empty price")
        }
    }

    func testRecommendedPartnersAdvertiseAUserBonus() {
        for s in VPSSupplierCatalog.all where s.badge != nil {
            XCTAssertFalse(s.userBonus.isEmpty, "\(s.id): recommended but no user bonus")
            // Bonus/badge/own-labels are CopyKey names resolved by the app layer.
            for field in [s.userBonus, s.badge ?? "", s.kind == .ownServer ? s.name : ""] {
                if !field.isEmpty {
                    XCTAssertEqual(field.prefix(3), "vps", "\(s.id): '\(field)' should be a vps* copy key")
                }
            }
        }
    }

    func testLayerOrderingOwnFirstThenRecommendedThenOthers() {
        let kinds = VPSSupplierCatalog.all.map(\.kind)
        XCTAssertEqual(kinds.first, .ownServer)
        // All .recommended before plain .partner entries, and every
        // .partner before .other (accordion tail).
        let partners = VPSSupplierCatalog.all.dropFirst(1)
        let recommended = partners.filter { $0.badge != nil }.count
        XCTAssertTrue(
            partners.prefix(recommended).allSatisfy { $0.badge != nil },
            "recommended suppliers must come before non-recommended"
        )
        let firstOther = kinds.firstIndex(of: .other)
        let lastPartner = kinds.lastIndex(of: .partner)
        if let fo = firstOther, let lp = lastPartner {
            XCTAssertLessThan(lp, fo, "all affiliate partners must precede the Other accordion")
        }
    }

    func testRecommendedBadgeOnlyOnPartners() {
        for s in VPSSupplierCatalog.all {
            if s.badge != nil { XCTAssertEqual(s.kind, .partner) }
        }
    }

    func testExactlySevenPartnersAndThreeOthers() {
        XCTAssertEqual(VPSSupplierCatalog.all.filter { $0.kind == .partner }.count, 7)
        XCTAssertEqual(VPSSupplierCatalog.all.filter { $0.kind == .other }.count, 3)
    }

    /// Partner URLs must go straight to a signup/registration/order page —
    /// not a marketing homepage the user has to hunt through.
    func testPartnerURLsPointAtSignupPages() {
        let expected: [String: String] = [
            "digitalocean": "https://cloud.digitalocean.com/registrations/new",
            "vultr": "https://my.vultr.com/signup/",
            "hostinger": "https://www.hostinger.com/signup",
            "contabo": "https://contabo.com/en/register/email/",
            "interserver": "https://my.interserver.net/signup.php",
            "racknerd": "https://my.racknerd.com/register.php",
            "cloudways": "https://www.cloudways.com/en/signup.php",
        ]
        for s in VPSSupplierCatalog.all where s.kind == .partner {
            XCTAssertEqual(s.refURL, expected[s.id], "\(s.id): signup URL drifted")
        }
    }
}
