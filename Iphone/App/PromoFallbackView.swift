import SwiftUI
import VPNCore

/// Own-promo fallback shown when the rewarded networks return no fill.
///
/// App Review compliance (Guideline 5.6): this screen is HONEST own
/// promotion, not a rewarded-ad simulation —
///  - it never mimics ad UX (no "Reward in Ns" countdown, no skip timer);
///  - the close button is ALWAYS enabled — the user can leave instantly;
///  - closing it grants NO time credit. Free-time credit comes ONLY from
///    a completed real rewarded ad (see AppModel.creditAdView) or a
///    purchase. The CTA opens the real paywall; leaving via any path
///    simply closes the promo.
///
/// Deliberately NOT a GIF asset: a live SwiftUI composition stays sharp on
/// every device, weighs nothing, localizes itself, and can't go stale
/// relative to the real PaywallView (same colors, same copy family).
struct PromoFallbackView: View {
    @EnvironmentObject private var model: AppModel

    @State private var pulse = false
    @State private var orbA = false
    @State private var orbB = false
    @State private var spin = false
    @State private var finished = false

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.07, green: 0.13, blue: 0.23), Color(red: 0.10, green: 0.20, blue: 0.36)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            // Decorative glow orbs — same treatment as the paywall hero,
            // but slowly drifting so the screen never looks static.
            Circle()
                .fill(Color.prim50.opacity(0.16))
                .frame(width: 260, height: 260)
                .blur(radius: 60)
                .offset(x: orbA ? -100 : -140, y: orbA ? -200 : -240)
                .animation(.easeInOut(duration: 6).repeatForever(autoreverses: true), value: orbA)
            Circle()
                .fill(Color(red: 0.85, green: 0.55, blue: 0.15).opacity(0.14))
                .frame(width: 220, height: 220)
                .blur(radius: 50)
                .offset(x: orbB ? 150 : 110, y: orbB ? 220 : 260)
                .animation(.easeInOut(duration: 7).repeatForever(autoreverses: true), value: orbB)

            VStack(spacing: 0) {
                // Plain header: an always-enabled close button. No countdown,
                // no locked state — this is our own promo, it must never look
                // or behave like a rewarded ad.
                HStack {
                    Spacer()
                    Button {
                        end(openPaywall: false)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.85))
                            .frame(width: 34, height: 34)
                            .background(.white.opacity(0.10), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(model.copy.text(.promoFallbackClose))
                }

                Spacer(minLength: 0)

                // Pulsing hero — the paywall's infinity mark, breathing.
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [Color(red: 0.35, green: 0.90, blue: 0.64), Color(red: 0.16, green: 0.66, blue: 0.48)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 100, height: 100)
                        .shadow(color: Color.prim50.opacity(pulse ? 0.55 : 0.30), radius: pulse ? 26 : 16, y: 8)
                        .scaleEffect(pulse ? 1.05 : 0.98)
                    Image(systemName: "infinity")
                        .font(.system(size: 44, weight: .bold))
                        .foregroundStyle(.white)
                        .rotationEffect(.degrees(spin ? 360 : 0))
                }
                .animation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true), value: pulse)
                .animation(.linear(duration: 24).repeatForever(autoreverses: false), value: spin)
                .padding(.bottom, 18)

                Text(model.copy.text(.promoFallbackHeadline))
                    .font(.openSans(24, weight: .bold))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                Text(model.copy.text(.promoFallbackSub))
                    .font(.openSans(14))
                    .foregroundStyle(.white.opacity(0.72))
                    .multilineTextAlignment(.center)
                    .padding(.top, 6)

                Spacer(minLength: 0)

                // Feature rows — same visual grammar as the paywall card.
                VStack(spacing: 12) {
                    featureRow(icon: "bolt.fill", color: Color(red: 0.95, green: 0.78, blue: 0.25), text: model.copy.text(.promoFallbackTimeUnlimited))
                    featureRow(icon: "megaphone.fill", color: Color(red: 0.95, green: 0.55, blue: 0.35), text: model.copy.text(.promoFallbackNoAds))
                }
                .padding(18)
                .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 20))

                Spacer(minLength: 0)

                // CTA — mirrors the paywall buy button (full-price styling).
                // Tap-through to the paywall at any time. No path through
                // this screen credits free time: rewards come only from a
                // completed real rewarded ad.
                Button {
                    end(openPaywall: true)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "infinity")
                            .font(.system(size: 15, weight: .semibold))
                        Text(model.copy.text(.promoFallbackCTA))
                            .font(.openSans(16, weight: .bold))
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 56)
                    .background(
                        LinearGradient(
                            colors: [Color(red: 0.35, green: 0.90, blue: 0.64), Color(red: 0.14, green: 0.70, blue: 0.46)],
                            startPoint: .leading,
                            endPoint: .trailing
                        ),
                        in: RoundedRectangle(cornerRadius: 16)
                    )
                    .shadow(color: Color.prim50.opacity(pulse ? 0.6 : 0.35), radius: pulse ? 18 : 12, y: 6)
                    .scaleEffect(pulse ? 1.02 : 1.0)
                }
                .buttonStyle(.plain)
                .padding(.top, 24)
            }
            .padding(.horizontal, 24)
            .padding(.top, 16)
            .padding(.bottom, 24)
        }
        .preferredColorScheme(.dark)
        .onAppear {
            pulse = true
            orbA = true
            orbB = true
            spin = true
            ConsoleLogStore.shared.log(level: .info, tag: "ADS", message: "no-fill fallback: own promo shown (instant close, no reward)")
        }
    }

    // MARK: - Pieces

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

    /// Single exit point: closes the promo and reports the outcome once.
    /// `openPaywall` escalates into the real paywall. Neither path credits
    /// free time — this screen is promotion only, never a reward source.
    private func end(openPaywall: Bool = false) {
        guard !finished else { return }
        finished = true
        model.promoFallbackFinished()
        if openPaywall {
            model.showPaywall()
        }
    }
}
