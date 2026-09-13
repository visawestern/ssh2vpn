import SwiftUI
import VPNCore

/// Own-promo fallback shown INSTEAD of the "No ads right now" dead-end
/// when the rewarded networks return no fill. Plays for 30 seconds as an
/// animated, paywall-styled promo in full rewarded-ad UX:
///
///  - Top-right close shows a live "Reward in Ns" countdown, exactly like
///    a rewarded ad's skip control.
///  - While it counts down, the close is INERT (taps bounce off) — the
///    user must watch to the end; nothing closes and nothing credits.
///  - When the countdown reaches 0 the X unlocks and the same button tap
///    both closes the promo AND credits the +3h (proof-of-watch: the only
///    way out is through the X, so the tap itself proves the watch).
///  - The CTA opens the real paywall at any time (early exit = no credit,
///    same as closing a real ad early).
///
/// Deliberately NOT a GIF asset: a live SwiftUI composition stays sharp on
/// every device, weighs nothing, localizes itself, and can't go stale
/// relative to the real PaywallView (same colors, same copy family).
struct PromoFallbackView: View {
    @EnvironmentObject private var model: AppModel

    /// Total promo duration the close button stays locked for. After it
    /// elapses the X becomes the single close-and-earn control.
    static let duration: TimeInterval = 30

    @State private var startedAt = Date()
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
                // Rewarded-style header: live "Reward in Ns" countdown next
                // to the X. The X stays disabled (dimmed, taps ignored)
                // until the countdown hits 0 — then the same tap closes
                // the promo AND credits +3h. The tap on the unlocked X is
                // the proof the user actually watched to the end.
                TimelineView(.periodic(from: .now, by: 0.25)) { context in
                    let remaining = max(0, Self.duration - context.date.timeIntervalSince(startedAt))
                    HStack {
                        Spacer()
                        HStack(spacing: 8) {
                            if remaining > 0 {
                                // Reward countdown chip — ticks down like a
                                // real rewarded ad's skip timer.
                                HStack(spacing: 5) {
                                    Circle()
                                        .trim(from: 0, to: max(0.02, remaining / Self.duration))
                                        .stroke(Color.prim50, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                                        .rotationEffect(.degrees(-90))
                                        .frame(width: 14, height: 14)
                                    Text(String(format: model.copy.text(.promoFallbackRewardIn), Int(ceil(remaining))))
                                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                                        .monospacedDigit()
                                }
                                .foregroundStyle(.white.opacity(0.85))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(.white.opacity(0.10), in: Capsule())
                                .transition(.opacity)
                            }
                            // The X: inert + dimmed while the reward chip
                            // counts, fully alive afterwards. One control,
                            // one meaning: unlock = close & earn.
                            Button {
                                guard remaining <= 0 else { return }
                                end(.earned)
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(remaining > 0 ? .white.opacity(0.35) : .white.opacity(0.85))
                                    .frame(width: 34, height: 34)
                                    .background(.white.opacity(remaining > 0 ? 0.06 : 0.10), in: Circle())
                            }
                            .buttonStyle(.plain)
                            .disabled(remaining > 0)
                            .animation(.easeInOut(duration: 0.3), value: remaining <= 0)
                            .accessibilityLabel(remaining > 0
                                ? model.copy.text(.promoFallbackRewardIn)
                                : model.copy.text(.promoFallbackClose))
                        }
                    }
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
                // Tap-through to the paywall at any time; leaving early
                // forfeits the +3h exactly like abandoning a real ad.
                Button {
                    end(.skipped, openPaywall: true)
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
            startedAt = Date()
            pulse = true
            orbA = true
            orbB = true
            spin = true
            ConsoleLogStore.shared.log(level: .info, tag: "ADS", message: "no-fill fallback: own promo playing (reward-in-30s close, X tap after countdown credits +3h)")
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

    /// Why the promo ended. `.earned` = the countdown ran out and the user
    /// tapped the unlocked X (proof-of-watch) — the model credits +3h
    /// exactly like a completed rewarded ad. `.skipped` = the user left
    /// via the CTA before the countdown finished: no credit, same as an ad
    /// abandoned early.
    enum PromoOutcome {
        case earned
        case skipped
    }

    /// Single exit point: closes the promo and reports the outcome once.
    /// `openPaywall` escalates into the real paywall (tap-through
    /// monetization).
    private func end(_ outcome: PromoOutcome, openPaywall: Bool = false) {
        guard !finished else { return }
        finished = true
        if outcome == .earned {
            model.promoFallbackWatchedToEarn()
        } else {
            model.promoFallbackFinished()
        }
        if openPaywall {
            model.showPaywall()
        }
    }
}
