import SwiftUI
import SafariServices
import VPNCore

/// The "Add Server" chooser shown FIRST whenever the user taps Add Server.
/// Eight cards: own VPS (first, so existing users never get confused) plus
/// 7 affiliate partners ordered by user benefit. Partner taps open Safari
/// so affiliate cookies live in the user's browser, not in the app.
struct AddServerChooserView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    /// Set when the user picks "own VPS" — the parent swaps to the manual
    /// AddServerView form.
    var onOwnServer: () -> Void
    /// Set when the user comes back from Safari holding credentials.
    var onImportCredentials: () -> Void

    @State private var safariURL: IdentifiableURL?

    private struct IdentifiableURL: Identifiable {
        let id = UUID()
        let url: URL
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    header
                    ownCard
                    partnersSection
                    footer
                }
                .padding(16)
            }
            .adaptiveCenterColumn()
            .background(Color.appBg)
            .navigationTitle(model.copy.text(.vpsChooseTitle))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(model.copy.text(.cancel)) { dismiss() }
                        .foregroundStyle(Color.sec50)
                }
            }
            .sheet(item: $safariURL) { item in
                SafariSheet(url: item.url)
                    .ignoresSafeArea()
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    // MARK: - Sections

    private var header: some View {
        Text(model.copy.text(.vpsChooseSubtitle))
            .font(.openSans(13))
            .foregroundStyle(Color.octGray60)
            .multilineTextAlignment(.center)
            .padding(.top, 4)
    }

    private var ownCard: some View {
        Button {
            dismiss()
            onOwnServer()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "server.rack")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(Color.prim50)
                    .frame(width: 44, height: 44)
                    .background(Color.prim50.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))

                VStack(alignment: .leading, spacing: 2) {
                    Text(model.copy.text(.vpsOwnServer))
                        .font(.openSans(15, weight: .semibold))
                        .foregroundStyle(Color.octGray100)
                    Text(model.copy.text(.vpsOwnServerDesc))
                        .font(.openSans(12))
                        .foregroundStyle(Color.octGray60)
                        .multilineTextAlignment(.leading)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.octGray40)
            }
            .padding(14)
            .background(Color.octGray0, in: RoundedRectangle(cornerRadius: 16))
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(Color.prim50.opacity(0.35), lineWidth: 1)
            )
            .contentShape(.rect)
        }
        .buttonStyle(PressableCardStyle())
    }

    private var partnersSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(partners) { supplier in
                    PartnerCard(supplier: supplier) { url in
                        safariURL = IdentifiableURL(url: url)
                    }
                    if supplier.id != partners.last?.id {
                        Divider().padding(.leading, 68)
                    }
                }
            }
            .padding(.vertical, 6)
            .background(Color.octGray0, in: RoundedRectangle(cornerRadius: 16))

            otherProvidersSection
        }
    }

    // MARK: - "Other providers" accordion (hosts without an affiliate
    // program — collapsed by default so partners stay the focus).

    @State private var otherExpanded = false

    private var others: [VPSSupplier] {
        VPSSupplierCatalog.all.filter { $0.kind == .other }
    }

    private var otherProvidersSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.spring(response: 0.35, dampingFraction: 1.0)) {
                    otherExpanded.toggle()
                }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.octGray60)
                        .frame(width: 44, height: 44)
                        .background(Color.octGray0, in: RoundedRectangle(cornerRadius: 12))

                    Text(model.copy.text(.vpsOtherProviders))
                        .font(.openSans(14, weight: .semibold))
                        .foregroundStyle(Color.octGray60)
                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.octGray40)
                        .rotationEffect(.degrees(otherExpanded ? 180 : 0))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .contentShape(.rect)
            }
            .buttonStyle(PressableCardStyle())
            .accessibilityLabel(Text(model.copy.text(.vpsOtherProviders)))
            .accessibilityValue(Text(otherExpanded ? model.copy.text(.cancel) : ""))

            if otherExpanded {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(others) { supplier in
                        PartnerCard(supplier: supplier) { url in
                            safariURL = IdentifiableURL(url: url)
                        }
                        if supplier.id != others.last?.id {
                            Divider().padding(.leading, 68)
                        }
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.vertical, 6)
        .background(Color.octGray0.opacity(otherExpanded ? 1 : 0.6), in: RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color.octGray40.opacity(0.25), lineWidth: 1)
        )
    }

    private var partners: [VPSSupplier] {
        VPSSupplierCatalog.all.filter { $0.kind == .partner }
    }

    private var footer: some View {
        VStack(spacing: 10) {
            Button {
                dismiss()
                onImportCredentials()
            } label: {
                Text(model.copy.text(.vpsHaveCredentials))
                    .font(.openSans(13, weight: .semibold))
                    .foregroundStyle(Color.sec50)
            }
            .buttonStyle(.plain)
            .accessibilityHint(Text("opens the paste parser"))

            Text(model.copy.text(.vpsPartnersFooter))
                .font(.openSans(11))
                .foregroundStyle(Color.octGray40)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 8)
        }
        .padding(.top, 2)
    }
}

// MARK: - Partner card

private struct PartnerCard: View {
    @EnvironmentObject private var model: AppModel
    let supplier: VPSSupplier
    let open: (URL) -> Void

    var body: some View {
        Button {
            if let url = URL(string: supplier.refURL) { open(url) }
        } label: {
            HStack(spacing: 12) {
                SupplierIcon(supplier: supplier)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(supplier.name)
                            .font(.openSans(15, weight: .semibold))
                            .foregroundStyle(Color.octGray100)
                        if let badge = badgeText {
                            Text(badge)
                                .font(.openSans(9, weight: .bold))
                                .foregroundStyle(Color.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.prim50, in: Capsule())
                        }
                        Spacer(minLength: 0)
                    }
                    Text(subtitleText)
                        .font(.openSans(12))
                        .foregroundStyle(Color.octGray60)
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        Text(model.copy.text(.vpsPriceFrom, price: supplier.price))
                            .font(.openSans(12, weight: .medium))
                            .foregroundStyle(Color.sec50)
                        if let bonus = bonusText {
                            Text(bonus)
                                .font(.openSans(11, weight: .semibold))
                                .foregroundStyle(Color.prim50)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                }
                Spacer()
                Image(systemName: "arrow.up.right.square")
                    .font(.system(size: 14))
                    .foregroundStyle(Color.octGray40)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .contentShape(.rect)
        }
        .buttonStyle(PressableCardStyle())
        .accessibilityLabel(Text("\(supplier.name), \(supplier.price)"))
    }

    /// The catalog stores copy-key names; resolve them per supplier id so a
    /// typo in the catalog can never crash the view.
    private var badgeText: String? {
        supplier.badge == nil ? nil : model.copy.text(.vpsRecommendedBadge)
    }

    private var bonusText: String? {
        switch supplier.id {
        case "digitalocean": return model.copy.text(.vpsBonusDigitalOcean)
        case "vultr": return model.copy.text(.vpsBonusVultr)
        case "hostinger": return model.copy.text(.vpsBonusHostinger)
        default: return nil
        }
    }

    /// Catalog subtitles are per-supplier copy keys ({price} template inside).
    private var subtitleText: String {
        let key: CopyKey
        switch supplier.id {
        case "digitalocean": key = .vpsSubDigitalOcean
        case "vultr": key = .vpsSubVultr
        case "hostinger": key = .vpsSubHostinger
        case "contabo": key = .vpsSubContabo
        case "linode": key = .vpsSubLinode
        case "interserver": key = .vpsSubInterServer
        case "cloudways": key = .vpsSubCloudways
        default: return supplier.subtitle
        }
        return model.copy.text(key, price: supplier.price)
    }
}

// MARK: - Supplier icon (colored monogram — no bundled logos needed)

private struct SupplierIcon: View {
    let supplier: VPSSupplier

    private var tint: Color {
        switch supplier.id {
        case "digitalocean": return Color(red: 0.00, green: 0.47, blue: 1.00)
        case "vultr": return Color(red: 0.20, green: 0.20, blue: 0.40)
        case "hostinger": return Color(red: 0.67, green: 0.00, blue: 0.47)
        case "contabo": return Color(red: 0.00, green: 0.53, blue: 0.55)
        case "linode": return Color(red: 0.00, green: 0.62, blue: 0.42)
        case "interserver": return Color(red: 0.85, green: 0.20, blue: 0.10)
        case "cloudways": return Color(red: 0.00, green: 0.60, blue: 0.90)
        case "racknerd": return Color(red: 0.95, green: 0.55, blue: 0.10)
        case "hetzner": return Color(red: 0.90, green: 0.35, blue: 0.30)
        case "ovh": return Color(red: 0.00, green: 0.45, blue: 0.90)
        default: return Color.prim50
        }
    }

    var body: some View {
        Text(String(supplier.name.prefix(1)))
            .font(.openSans(17, weight: .bold))
            .foregroundStyle(Color.white)
            .frame(width: 44, height: 44)
            .background(tint, in: RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - Safari (SFSafariViewController — cookies stay in Safari's store)

private struct SafariSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        let config = SFSafariViewController.Configuration()
        config.entersReaderIfAvailable = false
        let vc = SFSafariViewController(url: url, configuration: config)
        vc.preferredControlTintColor = UIColor(Color.sec50)
        return vc
    }

    func updateUIViewController(_ vc: SFSafariViewController, context: Context) {}
}

// MARK: - Press feedback (highlight on touch-down, appleDesign §1)

struct PressableCardStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .opacity(configuration.isPressed ? 0.9 : 1)
            .animation(.spring(response: 0.3, dampingFraction: 1.0), value: configuration.isPressed)
    }
}
