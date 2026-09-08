import XCTest
@testable import VPNCore

/// The hardcoded provider catalog: 8 entries (own VPS + 7 partners), layered
/// ordering, unique ids, valid URLs, no empty display fields.
final class VPSSupplierTests: XCTestCase {

    func testCatalogContainsExactlyEightEntries() {
        XCTAssertEqual(VPSSupplierCatalog.all.count, 8)
    }

    func testFirstEntryIsOwnVPSSoUsersDoNotGetConfused() {
        XCTAssertEqual(VPSSupplierCatalog.all.first?.kind, .ownServer)
    }

    func testIdsAreUnique() {
        let ids = VPSSupplierCatalog.all.map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count, "duplicate supplier ids")
    }

    func testAllPartnerEntriesHaveValidHTTPSURL() throws {
        for s in VPSSupplierCatalog.all where s.kind == .partner {
            let url = try XCTUnwrap(URL(string: s.refURL), "\(s.id): bad URL")
            XCTAssertEqual(url.scheme, "https", "\(s.id): must be https")
            XCTAssertNotNil(url.host, "\(s.id): no host")
        }
    }

    func testEveryPartnerEntryHasNonEmptyDisplayFields() {
        for s in VPSSupplierCatalog.all where s.kind == .partner {
            XCTAssertFalse(s.name.isEmpty, "\(s.id): empty name")
            // Price is a bare amount ("$4"); the "/mo" wording lives in the
            // localized vpsPriceFrom/vpsSub* copy templates.
            XCTAssertFalse(s.price.isEmpty, "\(s.id): empty price")
            XCTAssertFalse(s.price.contains("/"), "\(s.id): price must be a bare amount, got \(s.price)")
            XCTAssertTrue(s.subtitle.hasPrefix("vpsSub"), "\(s.id): subtitle must be a vpsSub* copy key")
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
        // All .recommended before plain .partner entries.
        let recIdx = VPSSupplierCatalog.all.firstIndex(where: { $0.badge != nil }) ?? 0
        let partnersAfter = VPSSupplierCatalog.all.dropFirst(1)
        let recommended = partnersAfter.filter { $0.badge != nil }.count
        let badgedInPlace = VPSSupplierCatalog.all.dropFirst(1).prefix(recommended).allSatisfy { $0.badge != nil }
        XCTAssertTrue(badgedInPlace, "recommended suppliers must come before non-recommended")
        _ = recIdx
    }

    func testRecommendedBadgeOnlyOnPartners() {
        for s in VPSSupplierCatalog.all {
            if s.badge != nil { XCTAssertEqual(s.kind, .partner) }
        }
    }

    func testExactlySevenPartners() {
        XCTAssertEqual(VPSSupplierCatalog.all.filter { $0.kind == .partner }.count, 7)
    }
}
