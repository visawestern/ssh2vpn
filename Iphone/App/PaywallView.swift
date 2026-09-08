import SwiftUI

/// Full-screen paywall shown when the user taps the Unlimited buy button.
///
/// Double-offer flow (persisted across launches):
///  - `.full`   : one-time price ($5) — dismiss escalates to `.discount`.
///  - `.discount`: one-time $3 offer. Its close button is locked for 3s to
///    hold attention; dismissing it marks the discount as declined forever,
///    so only the full price is ever offered again on this device.
struct PaywallView: View {
    @EnvironmentObject private var model: AppModel
    @State private var closeAllowedAt = Date.distantPast
    @State private var showUnavailable = false

    private var isDiscount: Bool { model.paywallStage == .discount }

    /// The price shown in the UI: always round dollars, no cents. $5 full,
    /// $3 discount. App Store Connect must use the $5.00 price point so the
    /// Apple sheet matches exactly.
    private var displayPrice: String? {
        isDiscount ? "$3" : "$5"
    }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.07, green: 0.13, blue: 0.23), Color(red: 0.10, green: 0.20, blue: 0.36)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            // Decorative glow orbs
            Circle()
                .fill(Color.prim50.opacity(0.16))
                .frame(width: 260, height: 260)
                .blur(radius: 60)
                .offset(x: -120, y: -220)
            Circle()
                .fill(Color(red: 0.85, green: 0.55, blue: 0.15).opacity(0.14))
                .frame(width: 220, height: 220)
                .blur(radius: 50)
                .offset(x: 130, y: 240)

            VStack(spacing: 0) {
                header
                Spacer(minLength: 12)
                hero
                Spacer(minLength: 20)
                features
                Spacer(minLength: 24)
                pricing
                buyButton
                restoreButton
            }
            .padding(.horizontal, 24)
            .padding(.top, 16)
            .padding(.bottom, 24)
        }
        .preferredColorScheme(.dark)
        .onAppear { armClose(after: isDiscount ? 3 : 0) }
        .onChange(of: model.isPaywallPresented) { presented in
            if presented { armClose(after: isDiscount ? 3 : 0) }
        }
        .onChange(of: model.paywallStage) { _ in
            // Escalating full -> discount re-locks the close button for 3s.
            armClose(after: isDiscount ? 3 : 0)
        }
        .alert(model.copy.text(.purchaseUnavailable), isPresented: $showUnavailable) {
            Button(model.copy.text(.ok), role: .cancel) {}
        }
    }

    // MARK: - Header (close button)

    private var header: some View {
        HStack {
            HStack(spacing: 8) {
                Image(systemName: "infinity")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Color.prim50)
                Text("SSH2VPN+")
                    .font(.openSans(15, weight: .semibold))
                    .foregroundStyle(.white)
            }
            Spacer()
            Button {
                model.dismissPaywall()
            } label: {
                Group {
                    if isDiscount && Date() < closeAllowedAt {
                        Text("\(max(1, Int(ceil(closeAllowedAt.timeIntervalSinceNow))))")
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                    } else {
                        Image(systemName: "xmark")
                            .font(.system(size: 13, weight: .semibold))
                    }
                }
                .foregroundStyle(.white.opacity(0.85))
                .frame(width: 34, height: 34)
                .background(.white.opacity(0.10), in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(isDiscount && Date() < closeAllowedAt)
            .accessibilityLabel(model.copy.text(.cancel))
        }
    }

    // MARK: - Hero

    private var hero: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [Color(red: 0.35, green: 0.90, blue: 0.64), Color(red: 0.16, green: 0.66, blue: 0.48)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 92, height: 92)
                    .shadow(color: Color.prim50.opacity(0.35), radius: 20, y: 8)
                Image(systemName: "infinity")
                    .font(.system(size: 40, weight: .bold))
                    .foregroundStyle(.white)
            }
            .padding(.bottom, 2)

            Text(model.copy.text(isDiscount ? .paywallDiscountTitle : .paywallTitle, price: displayPrice))
                .font(.openSans(28, weight: .bold))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)

            Text(model.copy.text(isDiscount ? .paywallDiscountSubtitle : .paywallSubtitle))
                .font(.openSans(14))
                .foregroundStyle(.white.opacity(0.72))
                .multilineTextAlignment(.center)
        }
    }

    // MARK: - Features

    private var features: some View {
        VStack(spacing: 12) {
            featureRow(icon: "bolt.fill", color: Color(red: 0.95, green: 0.78, blue: 0.25), text: model.copy.text(.paywallFeatureUnlimited))
            featureRow(icon: "megaphone.fill", color: Color(red: 0.95, green: 0.55, blue: 0.35), text: model.copy.text(.paywallFeatureNoAds))
        }
        .padding(18)
        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 20))
    }

    private func featureRow(icon: String, color: Color, text: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 28, height: 28)
                .background(color.opacity(0.16), in: Circle())
            Text(text)
                .font(.openSans(14, weight: .medium))
                .foregroundStyle(.white)
            Spacer(minLength: 0)
        }
    }

    // MARK: - Pricing + Buy

    private var pricing: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if isDiscount {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.copy.text(.paywallDiscountTag, price: displayPrice))
                        .font(.openSans(11, weight: .bold))
                        .foregroundStyle(Color(red: 1.0, green: 0.72, blue: 0.30))
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(displayPrice ?? model.copy.text(.paywallFullPriceFallback))
                            .font(.system(size: 34, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                    }
                }
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(displayPrice ?? model.copy.text(.paywallFullPriceFallback))
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                }
            }
            Spacer()
            Text(model.copy.text(.paywallOneTime))
                .font(.openSans(12, weight: .medium))
                .foregroundStyle(.white.opacity(0.65))
        }
        .padding(18)
        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 20))
    }

    private var buyButton: some View {
        Button {
            Task { await buy() }
        } label: {
            HStack(spacing: 8) {
                if model.store.isPurchasing {
                    ProgressView()
                        .scaleEffect(0.8)
                        .tint(.white)
                } else {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 13, weight: .semibold))
                }
                Text(model.store.isPurchasing
                     ? model.copy.text(.purchasing)
                     : (isDiscount ? model.copy.text(.paywallBuyDiscount, price: displayPrice) : model.copy.text(.buyUnlimited, price: displayPrice)))
                    .font(.openSans(16, weight: .bold))
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 54)
            .background(
                LinearGradient(
                    colors: isDiscount
                        ? [Color(red: 0.95, green: 0.62, blue: 0.18), Color(red: 0.85, green: 0.42, blue: 0.12)]
                        : [Color(red: 0.35, green: 0.90, blue: 0.64), Color(red: 0.14, green: 0.70, blue: 0.46)],
                    startPoint: .leading,
                    endPoint: .trailing
                ),
                in: RoundedRectangle(cornerRadius: 16)
            )
            .shadow(color: (isDiscount ? Color(red: 0.95, green: 0.62, blue: 0.18) : Color.prim50).opacity(0.35),
                    radius: 14, y: 6)
        }
        .buttonStyle(.plain)
        .disabled(model.store.isPurchasing)
        .padding(.top, 14)
    }

    private var restoreButton: some View {
        Button {
            Task { await model.restorePurchase() }
        } label: {
            Text(model.copy.text(.restorePurchase))
                .font(.openSans(13))
                .foregroundStyle(.white.opacity(0.6))
        }
        .buttonStyle(.plain)
        .padding(.top, 16)
    }

    // MARK: - Actions

    private func buy() async {
        // The discount stage must buy the dedicated $3 product; the full stage
        // buys the regular one. Guard on the specific product so a missing
        // ASC-side product surfaces as "unavailable" instead of a wrong buy.
        guard isDiscount ? model.store.discountProduct != nil : model.store.product != nil else {
            showUnavailable = true
            return
        }
        switch await model.buyUnlimited(discount: isDiscount) {
        case .success:
            model.paywallPaid()
        case .failure:
            showUnavailable = true
        case .userCancelled, .pending:
            break // keep the paywall open; user can retry or dismiss
        }
    }

    /// Locks the close button for `seconds` (e.g. forced attention on the
    /// discount offer). 0 = immediately allowed.
    private func armClose(after seconds: Int) {
        closeAllowedAt = Date().addingTimeInterval(TimeInterval(max(0, seconds)))
    }
}