import SwiftUI

/// Full-screen paywall shown when the user taps the Unlimited buy button.
///
/// Double-offer flow (persisted across launches):
///  - `.full`   : one-time price ($10) — dismiss escalates to `.discount`.
///  - `.discount`: one-time $6 offer. Dismissing it marks the discount as
///    declined forever, so only the full price is ever offered again on
///    this device.
///
/// Review compliance: NO countdown timer, NO locked close button, NO fake
/// urgency — the close is always enabled and the discount is a plain
/// second-chance offer, not a pressured flash sale.
struct PaywallView: View {
    @EnvironmentObject private var model: AppModel
    @State private var showUnavailable = false
    /// Drives the "hot offer" breathing animation on the discount CTA.
    @State private var pulse = false

    private var isDiscount: Bool { model.paywallStage == .discount }

    /// The price shown in the UI comes from StoreKit (localized). Falls
    /// back to round US dollars only until the products load.
    private var displayPrice: String {
        isDiscount ? model.discountPriceString : model.fullPriceString
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
            // The close is ALWAYS enabled — no lock, no countdown. Forcing
            // attention on a paid offer is a dark pattern (Guideline 5.6).
            Button {
                model.dismissPaywall()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(width: 34, height: 34)
                    .background(.white.opacity(0.10), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(model.copy.text(.cancel))
        }
    }

    // MARK: - Hero

    private var hero: some View {
        VStack(spacing: 14) {
            if isDiscount {
                // Pulsing exclusivity badge — the first thing the eye lands on.
                HStack(spacing: 6) {
                    Image(systemName: "flame.fill")
                        .font(.system(size: 12, weight: .black))
                    Text(model.copy.text(.paywallDiscountTag))
                        .font(.openSans(12, weight: .black))
                        .tracking(1.2)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(
                    Capsule().fill(
                        LinearGradient(colors: [Color(red: 1.0, green: 0.45, blue: 0.10), Color(red: 0.95, green: 0.15, blue: 0.12)],
                                       startPoint: .leading, endPoint: .trailing)
                    )
                )
                .shadow(color: Color(red: 1.0, green: 0.35, blue: 0.10).opacity(pulse ? 0.7 : 0.35), radius: pulse ? 16 : 9, y: 3)
                .scaleEffect(pulse ? 1.04 : 1.0)
            }

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
        Group {
            if isDiscount {
                discountPricing
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(displayPrice)
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                    Spacer()
                    Text(model.copy.text(.paywallOneTime))
                        .font(.openSans(12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.65))
                }
                .padding(18)
                .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 20))
            }
        }
    }

    /// The $6 second-chance block: crossed-out $10 anchor, $6, "−40%"
    /// capsule. No countdown, no expiry theatrics — a plain offer the user
    /// can take or leave (Guideline 5.6: no pressured flash-sale UX).
    private var discountPricing: some View {
        VStack(spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(model.fullPriceString)
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                    .strikethrough(true, color: .white.opacity(0.55))
                    .foregroundStyle(.white.opacity(0.45))
                Text(displayPrice)
                    .font(.system(size: 58, weight: .heavy, design: .rounded))
                    .foregroundStyle(
                        LinearGradient(colors: [Color(red: 1.0, green: 0.85, blue: 0.35), Color(red: 1.0, green: 0.60, blue: 0.15)],
                                       startPoint: .top, endPoint: .bottom)
                    )
                    .shadow(color: Color(red: 1.0, green: 0.65, blue: 0.15).opacity(0.55), radius: 14, y: 3)
                Text("−40%")
                    .font(.system(size: 14, weight: .black, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(Color(red: 0.10, green: 0.75, blue: 0.45), in: Capsule())
                    .rotationEffect(.degrees(-6))
            }
            .frame(maxWidth: .infinity)
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(.white.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 20)
                        .stroke(
                            LinearGradient(colors: [Color(red: 1.0, green: 0.75, blue: 0.25).opacity(0.85), Color(red: 1.0, green: 0.45, blue: 0.15).opacity(0.85)],
                                           startPoint: .topLeading, endPoint: .bottomTrailing),
                            lineWidth: 1.5
                        )
                )
        )
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
                    Image(systemName: isDiscount ? "flame.fill" : "lock.fill")
                        .font(.system(size: 13, weight: .semibold))
                }
                Text(model.store.isPurchasing
                     ? model.copy.text(.purchasing)
                     : (isDiscount ? model.copy.text(.paywallBuyDiscount, price: displayPrice) : model.copy.text(.buyUnlimited, price: displayPrice)))
                    .font(.openSans(16, weight: .bold))
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 56)
            .background(
                LinearGradient(
                    colors: isDiscount
                        ? [Color(red: 1.0, green: 0.72, blue: 0.16), Color(red: 0.95, green: 0.35, blue: 0.08)]
                        : [Color(red: 0.35, green: 0.90, blue: 0.64), Color(red: 0.14, green: 0.70, blue: 0.46)],
                    startPoint: .leading,
                    endPoint: .trailing
                ),
                in: RoundedRectangle(cornerRadius: 16)
            )
            .shadow(color: (isDiscount ? Color(red: 1.0, green: 0.55, blue: 0.12) : Color.prim50).opacity(pulse ? 0.65 : 0.35),
                    radius: pulse ? 18 : 12, y: 6)
            .scaleEffect(isDiscount && pulse ? 1.02 : 1.0)
        }
        .buttonStyle(.plain)
        .disabled(model.store.isPurchasing)
        .padding(.top, 14)
        // "Hot purchase" pulse: the CTA breathes so the eye lands on it
        // first. Runs only on the discount stage.
        .onAppear {
            guard isDiscount else { return }
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
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
        // The discount stage must buy the dedicated $6 product; the full stage
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
}