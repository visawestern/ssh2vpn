import SwiftUI
import VPNCore

// MARK: - App Color Theme (matching reference design)

extension Color {
    static let appBg = Color(red: 0.965, green: 0.970, blue: 0.978)               // Clean subtle off-white #F6F7FA
    static let octGray0 = Color.white                                             // Pure white cards #FFFFFF
    static let octGray05 = Color(red: 0.937, green: 0.941, blue: 0.953)          // Soft divider #EFF0F3
    static let octGray40 = Color(red: 0.745, green: 0.757, blue: 0.773)          // #BEC1C5
    static let octGray60 = Color(red: 0.514, green: 0.537, blue: 0.569)          // #838991
    static let octGray80 = Color(red: 0.314, green: 0.337, blue: 0.369)          // #50565E
    static let octGray100 = Color(red: 0.075, green: 0.161, blue: 0.275)         // #132946
    static let prim50 = Color(red: 0.294, green: 0.855, blue: 0.596)             // Emerald mint #4BDB98
    static let prim100 = Color(red: 0.235, green: 0.753, blue: 0.514)            // #3CC083
    static let sec50 = Color(red: 0.090, green: 0.161, blue: 0.275)              // Deep Navy #172946
    static let sec20 = Color(red: 0.271, green: 0.459, blue: 0.627)              // #4575A0
}

extension View {
    /// iPhone keeps the current edge-to-edge layout; iPad gets a centered,
    /// readable column (~720pt) instead of a stretched 1024pt soup.
    @ViewBuilder
    func adaptiveCenterColumn(maxWidth: CGFloat = 720) -> some View {
        self.frame(maxWidth: maxWidth)
            .frame(maxWidth: .infinity)
    }
}

extension Font {
    static func openSans(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        Font.custom("OpenSans-\(weightName(weight))", size: size)
    }
}

private func weightName(_ weight: Font.Weight) -> String {
    switch weight {
    case .bold: return "Bold"
    case .semibold: return "SemiBold"
    case .medium: return "Medium"
    case .light: return "Light"
    default: return "Regular"
    }
}

// MARK: - Tab

enum Tab: Int, CaseIterable {
    case connect, locations, settings
}

// MARK: - Root View

struct RootView: View {
    @EnvironmentObject private var model: AppModel
    @State private var selectedTab: Tab = .connect
    @State private var isConsoleOpen: Bool = false

    var body: some View {
        ZStack(alignment: .trailing) {
            Color.appBg.ignoresSafeArea()

            VStack(spacing: 0) {
                Group {
                    switch selectedTab {
                    case .connect: ConnectView()
                    case .locations: LocationsView()
                    case .settings: SettingsViewNew()
                    }
                }
                .adaptiveCenterColumn()
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                OctohideTabBar(selected: $selectedTab, copy: model.copy)
            }

            // Vuexy-style Floating theCustomizer terminal button — shown only
            // once a connection exists (connecting or connected); no console
            // to read while the VPN is off.
            if model.connection == .connecting || model.connection == .connected {
                VStack {
                    Spacer()
                    FloatingCustomizerButton(
                        isOpen: $isConsoleOpen,
                        isConnecting: model.connection == .connecting
                    )
                    Spacer()
                }
                .ignoresSafeArea(.keyboard, edges: .bottom)
            }

            // Right sliding Hacker Console Sidebar
            HackerConsoleSidebarView(isOpen: $isConsoleOpen)

            if model.needsLanguageSelection {
                LanguageOverlay()
                    .transition(.opacity)
            }
        }
        .preferredColorScheme(.light)
    }
}

// MARK: - Tab Bar (unified Apple Design with labels)

struct OctohideTabBar: View {
    @Binding var selected: Tab
    let copy: AppCopy

    var body: some View {
        HStack(spacing: 0) {
            tabButton(tab: .connect, icon: "wifi", title: copy.text(.connect))
            tabButton(tab: .locations, icon: "globe", title: copy.text(.locations))
            tabButton(tab: .settings, icon: "gearshape.fill", title: copy.text(.settings))
        }
        .padding(.top, 10)
        .padding(.bottom, 8)
        .padding(.horizontal, 8)
        .frame(maxWidth: 500)
        .frame(maxWidth: .infinity)   // centered on iPad instead of a stretched bar
        .background(
            RoundedRectangle(cornerRadius: 32)
                .fill(Color.white)
                .shadow(color: Color.black.opacity(0.06), radius: 12, y: -2)
        )
    }

    private func tabButton(tab: Tab, icon: String, title: String) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) { selected = tab }
        } label: {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 20))
                Text(title)
                    .font(.openSans(11, weight: selected == tab ? .semibold : .regular))
            }
            .foregroundStyle(selected == tab ? Color.sec50 : Color.octGray60)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Connect View

struct ConnectView: View {
    @EnvironmentObject private var model: AppModel
    @State private var timer: Timer?
    @State private var showAddServer = false
    @State private var showLocationsSheet = false
    /// Post-tap cooldown: the power button stays disabled for a fixed window
    /// after every press (connect or disconnect), then re-enables itself.
    @State private var powerCooldown = false

    @Environment(\.verticalSizeClass) private var vSize

    var body: some View {
        // Scrollable so landscape (compact height) shows everything — the
        // compact variants compress, and what still doesn't fit scrolls
        // instead of vanishing behind the edges with no way to reach it.
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 0) {
                // Top Status Card ("Unprotected" / "Protected")
                statusCard
                    .padding(.horizontal, 16)
                    .padding(.top, 8)

                // Upper area with World Map — shrinks in compact height
                // (iPhone landscape / iPad Split View) so the power button
                // never falls off-screen; capped on iPad so it doesn't blow
                // up either.
                ZStack(alignment: .center) {
                    WorldMapView()
                        .padding(.horizontal, 4)
                        .padding(.top, 4)
                }
                .frame(maxHeight: vSize == .compact ? 120 : 220)
                .frame(maxWidth: 640)

                Spacer(minLength: vSize == .compact ? 4 : 16)

                // Central Power Button
                powerButton
                    .padding(.bottom, 12)

                // Active connection time (shown while connected)
                if case .connected = model.connection {
                    Text(formatTime(TimeInterval(model.connectionActiveSeconds)))
                        .font(.system(size: 15, weight: .medium, design: .monospaced))
                        .foregroundStyle(Color.octGray60)
                        .padding(.bottom, 8)

                    // Live tunnel telemetry: SSH pool size, live data channels,
                    // transferred bytes, and the minutely ping.
                    statsStrip
                        .padding(.horizontal, 16)
                        .padding(.bottom, 8)
                } else if case .failed(let msg) = model.connection {
                    Text(msg == "freeTimeExhausted" ? model.copy.text(.failureFreeTimeExhausted) : "connectionError: \(msg)")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color(red: 0.85, green: 0.2, blue: 0.3))
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                        .padding(.bottom, 8)
                }

                Spacer(minLength: 8)

                // Free-time quota + rewarded-ad refill (stub ad for now)
                quotaBar
                    .padding(.horizontal, 16)
                    .padding(.bottom, vSize == .compact ? 6 : 10)

                // Selected Location Card
                selectedLocationCard
                    .padding(.horizontal, 16)
                    .padding(.bottom, vSize == .compact ? 8 : 20)
            }
            .frame(maxWidth: .infinity)
        }
        .background(Color.appBg)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { startTimerIfNeeded() }
        .onDisappear { timer?.invalidate(); timer = nil }
        .onChange(of: model.connection) { newStatus in
            switch newStatus {
            case .connected:
                startTimerIfNeeded()
            case .disconnected, .failed:
                timer?.invalidate()
                timer = nil
            case .connecting:
                break
            }
        }
        .sheet(isPresented: $showAddServer) {
            NavigationStack {
                AddServerView()
            }
        }
        .sheet(isPresented: $showLocationsSheet) {
            NavigationStack {
                LocationsView()
            }
        }
    }

    // MARK: - Top Status Card
    private var statusCard: some View {
        HStack(spacing: 12) {
            Spacer()
            if model.connection == .connected {
                Image(systemName: "checkmark.shield.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(Color.prim50)
            } else {
                Image(systemName: "shield")
                    .font(.system(size: 22, weight: .regular))
                    .foregroundStyle(Color(red: 0.35, green: 0.40, blue: 0.50))
            }

            Text(model.connection == .connected ? model.copy.text(.protected_) : model.copy.text(.unprotected))
                .font(.openSans(17, weight: .semibold))
                .foregroundStyle(Color.octGray100)
            Spacer()
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 20)
        .background(
            RoundedRectangle(cornerRadius: 18)
                .fill(Color.white)
                .shadow(color: Color.black.opacity(0.05), radius: 10, y: 4)
        )
    }

    // MARK: - Central Power Button (with arc progress ring)
    private var powerButton: some View {
        let scale: CGFloat = vSize == .compact ? 0.72 : 1.0
        return ZStack {
            // Animated thin arc ring during connecting
            if case .connecting = model.connection {
                SpinningArcView()
                    .frame(width: 190, height: 190)
                    .transition(.opacity.animation(.easeInOut(duration: 0.25)))
            }

            Button(action: toggleConnection) {
                ZStack {
                    // Soft outer ambient shadow circle
                    Circle()
                        .fill(Color.white.opacity(0.85))
                        .frame(width: 172, height: 172)
                        .shadow(color: Color(red: 0.85, green: 0.88, blue: 0.95), radius: 24, y: 10)

                    // Middle border / gradient ring
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: model.connection == .connected
                                    ? [Color(red: 0.90, green: 0.30, blue: 0.30).opacity(0.4), Color(red: 0.85, green: 0.25, blue: 0.25).opacity(0.2)]
                                    : [Color(red: 0.94, green: 0.95, blue: 0.97), Color(red: 0.89, green: 0.90, blue: 0.93)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 156, height: 156)

                    // Middle spacing ring
                    Circle()
                        .fill(Color.appBg)
                        .frame(width: 146, height: 146)

                    // Inner solid button disc (red when connected = disconnect)
                    Circle()
                        .fill(model.connection == .connected ? Color(red: 0.90, green: 0.30, blue: 0.30) : Color.white)
                        .frame(width: 138, height: 138)
                        .shadow(color: Color.black.opacity(0.06), radius: 8, y: 4)

                    // Power icon or spinner
                    if case .connecting = model.connection {
                        VStack(spacing: 4) {
                            Image(systemName: "power")
                                .font(.system(size: 36, weight: .regular))
                                .foregroundStyle(Color(red: 0.25, green: 0.45, blue: 0.85))
                            Text("Connecting")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(Color(red: 0.25, green: 0.45, blue: 0.85))
                        }
                    } else {
                        Image(systemName: "power")
                            .font(.system(size: 46, weight: .regular))
                            .foregroundStyle(model.connection == .connected ? Color.white : Color(red: 0.08, green: 0.16, blue: 0.28))
                    }
                }
            }
            .buttonStyle(PowerButtonStyle())
            // Double-tap protection: a fixed 2s cooldown after every press.
            // Mid-connect the button STAYS tappable (after the cooldown):
            // a press cancels the in-flight connection cleanly (the model
            // stops the manager; the extension unwinds its start at the next
            // checkpoint instead of wedging).
            .disabled(powerCooldown)
            .opacity(powerCooldown ? 0.75 : 1.0)
            .scaleEffect(vSize == .compact ? 0.72 : 1.0)
        }
    }

    // MARK: - Selected Location Card
    private var selectedLocationCard: some View {
        Button {
            if model.profile.host.isEmpty {
                showAddServer = true
            } else {
                showLocationsSheet = true
            }
        } label: {
            HStack(spacing: 12) {
                if model.profile.host.isEmpty {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 24))
                        .foregroundStyle(Color.sec50)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.copy.text(.addServerLabel))
                            .font(.openSans(15, weight: .medium))
                            .foregroundStyle(Color.octGray100)
                        Text(model.copy.text(.addServerDesc))
                            .font(.openSans(12))
                            .foregroundStyle(Color.octGray60)
                    }
                } else {
                    Text(model.serverFlag.isEmpty ? "🌐" : model.serverFlag)
                        .font(.system(size: 24))

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(model.serverCountry.isEmpty ? model.serverName : model.serverCountry)
                                .font(.openSans(15, weight: .semibold))
                                .foregroundStyle(Color.octGray100)
                            if let ping = model.serverPingMs {
                                Text("\(ping) ms")
                                    .font(.openSans(11, weight: .semibold))
                                    .foregroundStyle(Color.prim50)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.prim50.opacity(0.12), in: Capsule())
                            }
                        }
                        Text("\(model.profile.host):\(model.profile.port)")
                            .font(.openSans(12))
                            .foregroundStyle(Color.octGray60)
                    }
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.octGray100)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color.white)
                    .shadow(color: Color.black.opacity(0.04), radius: 10, y: 4)
            )
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Helpers

    private func toggleConnection() {
        guard !powerCooldown else { return }
        powerCooldown = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            powerCooldown = false
        }
        if model.connection == .connected {
            model.disconnect()
        } else if model.connection == .connecting {
            // Cancel mid-connect: clean stop, no wedge — the extension
            // unwinds its in-flight start at the next checkpoint.
            model.disconnect()
        } else {
            if model.profile.host.isEmpty {
                showAddServer = true
                return
            }
            model.connect()
        }
    }

    private func startTimerIfNeeded() {
        guard model.connection == .connected else { return }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak model] _ in
            model?.tickConnectionTimer()
        }
    }

    private func formatTime(_ t: TimeInterval) -> String {
        let h = Int(t) / 3600
        let m = (Int(t) % 3600) / 60
        let s = Int(t) % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%02d:%02d", m, s)
    }

    // MARK: - Live stats strip (connected only)

    private var statsStrip: some View {
        HStack(spacing: 0) {
            statCell(value: "\(model.sshConnectionCount)", label: "SSH")
            dividerDot
            statCell(value: "\(model.activeChannelCount)", label: "FLOWS")
            dividerDot
            statCell(value: "↓\(fmtMB(model.tunnelDownBytes)) ↑\(fmtMB(model.tunnelUpBytes))", label: "MB")
            dividerDot
            statCell(value: model.serverPingMs.map { "\($0) ms" } ?? "—", label: "PING")
        }
        .padding(.vertical, 8)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 12))
        .shadow(color: Color.black.opacity(0.04), radius: 6, y: 2)
    }

    private var dividerDot: some View {
        Circle().fill(Color.octGray40).frame(width: 3, height: 3)
    }

    private func statCell(value: String, label: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundStyle(Color.octGray100)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(label)
                .font(.system(size: 8, weight: .bold, design: .monospaced))
                .foregroundStyle(Color.octGray40)
        }
        .frame(maxWidth: .infinity)
    }

    private func fmtMB(_ bytes: Int) -> String {
        String(format: "%.1f", Double(bytes) / 1_048_576)
    }

    // MARK: - Free-time quota / rewarded-ad bar

    private var quotaBar: some View {
        HStack(spacing: 10) {
            Image(systemName: model.remainingQuotaSeconds > 0 ? "hourglass" : "hourglass.badge.exclamationmark")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(model.remainingQuotaSeconds > 600 ? Color.sec50 : Color(red: 0.9, green: 0.3, blue: 0.25))

            VStack(alignment: .leading, spacing: 1) {
                Text(model.copy.text(.freeTimeLeft))
                    .font(.openSans(10, weight: .semibold))
                    .foregroundStyle(Color.octGray40)
                Text(formatTime(model.remainingQuotaSeconds))
                    .font(.system(size: 14, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color.octGray100)
            }

            Spacer()

            Button { model.watchAd() } label: {
                HStack(spacing: 5) {
                    if model.adPlaying {
                        ProgressView()
                            .scaleEffect(0.7)
                    } else {
                        Image(systemName: "play.rectangle.fill")
                            .font(.system(size: 12))
                    }
                    Text(model.adPlaying
                         ? "…"
                         : (model.canWatchAd
                            ? model.copy.text(.watchAdPlus3h)
                            : cooldownText))
                        .font(.openSans(12, weight: .semibold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    (model.canWatchAd ? Color.sec50 : Color.octGray40),
                    in: RoundedRectangle(cornerRadius: 10)
                )
            }
            .buttonStyle(.plain)
            .disabled(!model.canWatchAd)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 14))
        .shadow(color: Color.black.opacity(0.04), radius: 8, y: 2)
    }

    /// "59m" while the 1-view-per-hour cooldown runs, "MAX" when the
    /// 3-view bank is full.
    private var cooldownText: String {
        if model.quota.bankedSeconds >= 3 * 3600 { return "MAX" }
        let s = Int(model.adCooldownRemaining)
        return s > 0 ? "\((s + 59) / 60)m" : "…"
    }
}

// MARK: - Power Button Style (Apple Design - instant feedback)

struct PowerButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.95 : 1.0)
            .animation(.spring(response: 0.3, dampingFraction: 1.0), value: configuration.isPressed)
    }
}

// MARK: - Thin Spinning Arc (connecting indicator)

struct SpinningArcView: View {
    @State private var rotation: Double = 0

    var body: some View {
        Circle()
            .trim(from: 0.0, to: 0.28)
            .stroke(
                AngularGradient(
                    colors: [Color(red: 0.25, green: 0.55, blue: 1.0).opacity(0.0),
                             Color(red: 0.25, green: 0.55, blue: 1.0),
                             Color(red: 0.15, green: 0.75, blue: 1.0)],
                    center: .center
                ),
                style: StrokeStyle(lineWidth: 2.5, lineCap: .round)
            )
            .rotationEffect(.degrees(rotation))
            .onAppear {
                withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) {
                    rotation = 360
                }
            }
    }
}

// MARK: - World Map (with animated pulsing server dot and compact Apple-design callout)

struct WorldMapView: View {
    @EnvironmentObject private var model: AppModel
    @State private var isPulsing = false

    var body: some View {
        GeometryReader { geo in
            let mapWidth = geo.size.width
            let mapHeight = mapWidth * (954.0 / 1920.0)
            let hasServer = !model.profile.host.isEmpty

            // Map server's real geographic coordinates to world map position
            let lonNorm = (model.serverLongitude + 180.0) / 360.0
            let latNorm = (90.0 - model.serverLatitude) / 180.0
            let dotX = min(max(lonNorm * mapWidth, 24), mapWidth - 24)
            let dotY = min(max(latNorm * mapHeight, 22), mapHeight - 22)

            ZStack(alignment: .topLeading) {
                Image("world_map")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: mapWidth, height: mapHeight)
                    .opacity(0.9)

                // Static dots for inactive servers, colored by ping
                ForEach(model.servers) { server in
                    let isSelected = server.id == model.selectedServer?.id
                    if !isSelected, let geo = model.serverGeoCache[server.id] {
                        let lon = (geo.lon + 180.0) / 360.0
                        let lat = (90.0 - geo.lat) / 180.0
                        let x = min(max(lon * mapWidth, 12), mapWidth - 12)
                        let y = min(max(lat * mapHeight, 12), mapHeight - 12)
                        let ping = model.serverPingCache[server.id]
                        let dotColor: Color = {
                            guard let ms = ping else { return Color.octGray40 }
                            if ms <= 80 { return Color.green }
                            if ms <= 150 { return Color.orange }
                            return Color.red
                        }()
                        Circle()
                            .fill(dotColor)
                            .frame(width: 6, height: 6)
                            .position(x: x, y: y)
                    }
                }

                if hasServer {
                    // Pulsing animated server dot
                    ZStack {
                        Circle()
                            .stroke(Color.prim50.opacity(0.6), lineWidth: 1.5)
                            .frame(width: 22, height: 22)
                            .scaleEffect(isPulsing ? 1.9 : 0.8)
                            .opacity(isPulsing ? 0 : 0.9)

                        Circle()
                            .fill(Color.prim50)
                            .frame(width: 8, height: 8)
                            .shadow(color: Color.prim50.opacity(0.9), radius: 5)
                    }
                    .position(x: dotX, y: dotY)
                    .animation(.spring(response: 0.5, dampingFraction: 0.7), value: dotX)

                    // Compact callout badge with country flag, location name and live ping
                    HStack(spacing: 5) {
                        Text(model.serverFlag.isEmpty ? "🌐" : model.serverFlag)
                            .font(.system(size: 11))

                        Circle()
                            .fill(model.connection == .connected ? Color.prim50 : (model.connection == .connecting ? Color.orange : Color.sec20))
                            .frame(width: 5, height: 5)

                        Text(model.serverCountry.isEmpty ? (model.serverName.isEmpty ? model.profile.host : model.serverName) : model.serverCountry)
                            .font(.openSans(11, weight: .semibold))
                            .foregroundStyle(Color.octGray100)
                            .lineLimit(1)

                        Text("•")
                            .font(.system(size: 8))
                            .foregroundStyle(Color.octGray40)

                        if let ping = model.serverPingMs {
                            Text("\(ping) ms")
                                .font(.openSans(10, weight: .semibold))
                                .foregroundStyle(Color.prim50)
                        } else if model.isResolvingMetadata {
                            ProgressView()
                                .controlSize(.mini)
                        } else {
                            Text(model.connection == .connected ? "32 ms" : "SSH2")
                                .font(.openSans(10, weight: .medium))
                                .foregroundStyle(model.connection == .connected ? Color.prim50 : Color.octGray60)
                        }
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(
                        Capsule()
                            .fill(Color.white)
                            .shadow(color: Color.black.opacity(0.12), radius: 8, x: 0, y: 3)
                    )
                    .position(x: dotX, y: max(18, dotY - 24))
                    .animation(.spring(response: 0.45, dampingFraction: 0.75), value: dotX)
                    .transition(.asymmetric(
                        insertion: .scale(scale: 0.7).combined(with: .opacity).combined(with: .offset(y: 8)),
                        removal: .scale(scale: 0.8).combined(with: .opacity)
                    ))
                }
            }
            .frame(width: mapWidth, height: mapHeight)
            .onAppear {
                withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: false)) {
                    isPulsing = true
                }
            }
        }
        .aspectRatio(1920.0 / 954.0, contentMode: .fit)
    }
}

// MARK: - World Map Background with Server Dots

struct WorldMapBackground: View {
    var body: some View {
        ZStack {
            Image("world_map")
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .ignoresSafeArea()
    }
}

struct ServerDot: Identifiable {
    let id = UUID()
    let x: CGFloat
    let y: CGFloat
}

// MARK: - Locations View

struct LocationsView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var editingServerID: String?
    @State private var showEdit = false
    @State private var showDeleteConfirm = false
    @State private var deleteTargetID: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    ForEach(model.servers) { server in
                        serverCard(server)
                    }

                    if model.servers.isEmpty {
                        HStack {
                            Text(model.copy.text(.noServerConfigured))
                                .foregroundStyle(Color.octGray60)
                            Spacer()
                        }
                        .padding(16)
                        .background(Color.octGray0, in: RoundedRectangle(cornerRadius: 16))
                    }

                    // Add Server button
                    NavigationLink(destination: AddServerView()) {
                        HStack(spacing: 12) {
                            Image(systemName: "plus.circle.fill")
                                .font(.system(size: 24))
                                .foregroundStyle(Color.sec50)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(model.copy.text(.addServerLabel))
                                    .font(.openSans(15, weight: .medium))
                                    .foregroundStyle(Color.octGray100)
                                Text(model.copy.text(.addServerDesc))
                                    .font(.openSans(12))
                                    .foregroundStyle(Color.octGray60)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Color.octGray40)
                        }
                        .padding(14)
                        .background(Color.octGray0, in: RoundedRectangle(cornerRadius: 16))
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                }
                .padding(16)
            }
            .background(Color.appBg)
            .navigationTitle(model.copy.text(.locations))
            .task {
                // Fresh pings when the list opens — skipped when the boot
                // sweep is still fresh (no double SYN spend).
                model.refreshAllServerPingsIfStale()
                // Heal any model-vs-system drift before the user taps a card:
                // a stale "connected" in the model would gray out switching
                // even though the tunnel is really down.
                model.resyncConnectionStateWithSystem()
            }
            .sheet(isPresented: $showEdit) {
                AddServerView(editing: true, editingID: editingServerID)
                    .environmentObject(model)
            }
            .confirmationDialog(model.copy.text(.deleteServerConfirm),
                                isPresented: $showDeleteConfirm,
                                titleVisibility: .visible) {
                Button(model.copy.text(.deleteServer), role: .destructive) {
                    if let id = deleteTargetID { model.deleteServer(id: id) }
                }
                Button(model.copy.text(.cancel), role: .cancel) { }
            }
        }
    }

    @ViewBuilder
    private func serverCard(_ server: ServerProfile) -> some View {
        let isSelected = server.id == model.selectedServer?.id
        let isConnected = isSelected && model.connection == .connected
        let geo = isSelected ? nil : model.serverGeoCache[server.id]
        let ping = isSelected ? model.serverPingMs : model.serverPingCache[server.id]
        let flag: String = {
            if isSelected { return model.serverFlag.isEmpty ? "🌐" : model.serverFlag }
            return geo?.flag ?? "🌐"
        }()
        let country: String = {
            if isSelected && !model.serverCountry.isEmpty { return model.serverCountry }
            if let geo { return geo.country }
            return server.name.isEmpty ? server.host : server.name
        }()

        // Server switching is only possible while fully disconnected: tapping
        // a card mid-connect would split the session (UI points at the new
        // server, the live tunnel still runs the old one).
        let switchLocked = model.connection == .connected || model.connection == .connecting
        return Button {
            model.selectServer(id: server.id)
            dismiss()
        } label: {
            HStack(spacing: 12) {
                Text(flag)
                    .font(.system(size: 26))
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(country)
                            .font(.openSans(16, weight: .semibold))
                            .foregroundStyle(Color.octGray100)
                        if let ping {
                            Text("\(ping) ms")
                                .font(.openSans(11, weight: .semibold))
                                .foregroundStyle(Color.prim50)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.prim50.opacity(0.12), in: Capsule())
                        }
                        if isConnected {
                            Circle()
                                .fill(Color.prim50)
                                .frame(width: 8, height: 8)
                        }
                    }
                    Text("\(server.host):\(server.port)")
                        .font(.openSans(12))
                        .foregroundStyle(Color.octGray60)
                }
                Spacer()
                if isSelected {
                    Button {
                        editingServerID = server.id
                        showEdit = true
                    } label: {
                        Image(systemName: "pencil")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(Color.sec50)
                            .frame(width: 30, height: 30)
                            .background(Color.sec50.opacity(0.12), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(model.copy.text(.editServerTitle))

                    Button {
                        deleteTargetID = server.id
                        showDeleteConfirm = true
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(Color.red)
                            .frame(width: 30, height: 30)
                            .background(Color.red.opacity(0.12), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(model.copy.text(.deleteServer))
                }
            }
            .padding(16)
        }
        .buttonStyle(.plain)
        .contentShape(.rect)
        .disabled(switchLocked)
        .opacity(switchLocked && !isSelected ? 0.55 : 1.0)
        .background(Color.octGray0, in: RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color.prim50, lineWidth: isConnected ? 1.5 : 0)
        )
    }
}

// MARK: - Settings View

struct SettingsViewNew: View {
    @EnvironmentObject private var model: AppModel
    @State private var showLanguagePicker = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    // Language selector card
                    VStack(alignment: .leading, spacing: 0) {
                        Text(model.copy.text(.languageSection))
                            .font(.openSans(13, weight: .semibold))
                            .foregroundStyle(Color.octGray60)
                            .padding(.horizontal, 16)
                            .padding(.top, 12)
                            .padding(.bottom, 8)

                        Button {
                            showLanguagePicker = true
                        } label: {
                            HStack(spacing: 10) {
                                Text(model.selectedLanguage?.flag ?? "🌐")
                                    .font(.title2)
                                Text(model.selectedLanguage?.title ?? "English")
                                    .font(.openSans(15, weight: .medium))
                                    .foregroundStyle(Color.octGray100)
                                Spacer()
                                Image(systemName: "chevron.up.chevron.down")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(Color.octGray40)
                                    .foregroundStyle(Color.octGray40)
                            }
                            .padding(14)
                        }
                        .buttonStyle(.plain)
                        .sheet(isPresented: $showLanguagePicker) {
                            LanguagePickerSheet(selected: model.selectedLanguage) { lang in
                                model.choose(lang)
                                showLanguagePicker = false
                            }
                        }
                    }
                    .background(Color.octGray0, in: RoundedRectangle(cornerRadius: 16))

                    // VPN Settings card
                    VStack(alignment: .leading, spacing: 0) {
                        Text(model.copy.text(.vpnSettings))
                            .font(.openSans(13, weight: .semibold))
                            .foregroundStyle(Color.octGray60)
                            .padding(.horizontal, 16)
                            .padding(.top, 12)
                            .padding(.bottom, 8)

                        NavigationLink(destination: ProtocolView()) {
                            settingsRow(icon: "lock.shield", title: model.copy.text(.protocolTitle), desc: model.copy.text(.protocolDesc))
                        }
                        .buttonStyle(.plain)
                        Divider().background(Color.octGray05).padding(.horizontal, 16)
                        NavigationLink(destination: DNSView()) {
                            settingsRow(icon: "network", title: model.copy.text(.dnsSettings), desc: model.copy.text(.dnsDesc))
                        }
                        .buttonStyle(.plain)
                        Divider().background(Color.octGray05).padding(.horizontal, 16)
                        NavigationLink(destination: AdvancedView()) {
                            settingsRow(icon: "gearshape.2", title: model.copy.text(.advanced), desc: model.copy.text(.advancedDesc))
                        }
                        .buttonStyle(.plain)
                        Divider().background(Color.octGray05).padding(.horizontal, 16)
                        // Local DNS rules live at the VPN-settings level (not
                        // inside the DNS screen): they apply BEFORE any DNS
                        // server — custom or public — and deserve first-class
                        // placement.
                        NavigationLink(destination: LocalDNSRulesView()) {
                            HStack(spacing: 12) {
                                Image(systemName: "shield.lefthalf.filled.badge.checkmark")
                                    .font(.system(size: 16))
                                    .foregroundStyle(Color(red: 0.85, green: 0.45, blue: 0.1))
                                    .frame(width: 24)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(model.copy.text(.dnsLocalRulesTitle))
                                        .font(.openSans(15, weight: .medium))
                                        .foregroundStyle(Color.octGray100)
                                    Text(model.copy.text(.dnsRulesCount))
                                        .font(.openSans(12))
                                        .foregroundStyle(Color.octGray60)
                                }
                                Spacer()
                                Text("\(model.settings.dnsRules.count)")
                                    .font(.openSans(11, weight: .semibold))
                                    .foregroundStyle(model.settings.dnsRules.isEmpty ? Color.octGray40 : Color(red: 0.85, green: 0.45, blue: 0.1))
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3)
                                    .background((model.settings.dnsRules.isEmpty ? Color.octGray40 : Color(red: 0.85, green: 0.45, blue: 0.1)).opacity(0.12), in: Capsule())
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(Color.octGray40)
                            }
                            .padding(14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                    }
                    .background(Color.octGray0, in: RoundedRectangle(cornerRadius: 16))

                    // Diagnostics card
                    VStack(alignment: .leading, spacing: 0) {
                        Text(model.copy.text(.diagnosticsSection))
                            .font(.openSans(13, weight: .semibold))
                            .foregroundStyle(Color.octGray60)
                            .padding(.horizontal, 16)
                            .padding(.top, 12)
                            .padding(.bottom, 8)

                        NavigationLink(destination: DiagnosticsView()) {
                            HStack(spacing: 12) {
                                Image(systemName: "stethoscope")
                                    .font(.system(size: 16))
                                    .foregroundStyle(Color.sec50)
                                    .frame(width: 24)
                                Text(model.copy.text(.connectionDiagnostics))
                                    .font(.openSans(15, weight: .medium))
                                    .foregroundStyle(Color.octGray100)
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(Color.octGray40)
                            }
                            .padding(14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                    }
                    .background(Color.octGray0, in: RoundedRectangle(cornerRadius: 16))

                    // About card
                    VStack(alignment: .leading, spacing: 0) {
                        Text(model.copy.text(.about))
                            .font(.openSans(13, weight: .semibold))
                            .foregroundStyle(Color.octGray60)
                            .padding(.horizontal, 16)
                            .padding(.top, 12)
                            .padding(.bottom, 8)

                        HStack {
                            Text(model.copy.text(.version))
                                .font(.openSans(15))
                                .foregroundStyle(Color.octGray100)
                            Spacer()
                            Text("1.0.0")
                                .font(.openSans(15))
                                .foregroundStyle(Color.octGray60)
                        }
                        .padding(14)
                    }
                    .background(Color.octGray0, in: RoundedRectangle(cornerRadius: 16))
                }
                .padding(16)
            }
            .background(Color.appBg)
            .navigationTitle(model.copy.text(.settings))
        }
    }

    private func settingsRow(icon: String, title: String, desc: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 16))
                .foregroundStyle(Color.sec50)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.openSans(15, weight: .medium))
                    .foregroundStyle(Color.octGray100)
                Text(desc)
                    .font(.openSans(12))
                    .foregroundStyle(Color.octGray60)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.octGray40)
        }
        .padding(14)
        .background(Color.octGray0, in: RoundedRectangle(cornerRadius: 16))
        .contentShape(.rect)
    }
}

// MARK: - Settings View

struct LanguagePickerSheet: View {
    let selected: AppLanguage?
    let onSelect: (AppLanguage) -> Void
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var model: AppModel

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(AppLanguage.allCases) { language in
                        Button {
                            onSelect(language)
                        } label: {
                            HStack(spacing: 12) {
                                Text(language.flag)
                                    .font(.title2)
                                Text(language.title)
                                    .font(.openSans(16, weight: .medium))
                                    .foregroundStyle(Color.octGray100)
                                Spacer()
                                if selected == language {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 14, weight: .semibold))
                                        .foregroundStyle(Color.sec50)
                                        .foregroundStyle(Color.sec50)
                                }
                            }
                            .padding(.horizontal, 20)
                            .padding(.vertical, 14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                language == selected
                                    ? Color.sec50.opacity(0.08)
                                    : Color.clear
                            )
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)

                        if language != AppLanguage.allCases.last {
                            Divider().background(Color.octGray05).padding(.leading, 52)
                        }
                    }
                }
                .padding(.vertical, 8)
            }
            .background(Color.octGray0)
            .navigationTitle(model.copy.text(.chooseLanguage))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(model.copy.text(.ok)) { dismiss() }
                        .foregroundStyle(Color.sec50)
                }
            }
        }
    }
}

// MARK: - Language Overlay

struct LanguageOverlay: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial).ignoresSafeArea()
            VStack(spacing: 22) {
                Image(systemName: "globe.americas.fill")
                    .font(.system(size: 42, weight: .semibold))
                    .foregroundStyle(.tint)
                    .foregroundStyle(.tint)
                Text(model.copy.text(.chooseLanguage))
                    .font(.title2.bold())
                Text(model.copy.text(.selectLanguageHint))
                    .foregroundStyle(.secondary)
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(AppLanguage.allCases) { language in
                            Button {
                                model.choose(language)
                            } label: {
                                HStack(spacing: 10) {
                                    Text(language.flag).font(.title2)
                                    Text(language.title).font(.body.weight(.medium))
                                    Spacer()
                                    if model.selectedLanguage == language {
                                        Image(systemName: "checkmark").foregroundStyle(.tint)
                                    }
                                }
                                .padding(14)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                                .contentShape(.rect)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(language.title)
                        }
                    }
                }
                .frame(maxHeight: 400)
            }
            .padding(24)
            .background(.thickMaterial, in: RoundedRectangle(cornerRadius: 28))
            .padding(22)
            .shadow(color: .black.opacity(0.15), radius: 30, y: 12)
        }
    }
}

// MARK: - Add Server View

struct AddServerView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    var editing: Bool = false
    /// When editing, the id of the server being modified (nil = adding new).
    var editingID: String? = nil
    @State private var address = ""
    @State private var username = ""
    @State private var port = "22"
    @State private var password = ""
    @State private var privateKey = ""
    @State private var hostKey = ""
    @State private var errorMessage: String?
    @State private var showErrorAlert = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    // Server credentials section
                    VStack(alignment: .leading, spacing: 0) {
                        Text(model.copy.text(.server))
                            .font(.openSans(13, weight: .semibold))
                            .foregroundStyle(Color.octGray60)
                            .padding(.horizontal, 16)
                            .padding(.top, 12)
                            .padding(.bottom, 6)

                        VStack(spacing: 6) {
                            fieldRow(
                                title: model.copy.text(.address),
                                placeholder: model.copy.text(.addressPlaceholder),
                                text: $address
                            )
                            fieldRow(
                                title: model.copy.text(.sshPort),
                                placeholder: model.copy.text(.portPlaceholder),
                                text: $port
                            )
                            fieldRow(
                                title: model.copy.text(.username),
                                placeholder: model.copy.text(.usernamePlaceholder),
                                text: $username
                            )
                            secureFieldRow(
                                title: model.copy.text(.passwordOptional),
                                placeholder: model.copy.text(.passwordPlaceholder),
                                text: $password
                            )
                        }
                        .padding(.horizontal, 12)
                        .padding(.bottom, 12)
                    }
                    .background(Color.octGray0, in: RoundedRectangle(cornerRadius: 16))

                    // Private Key section
                    VStack(alignment: .leading, spacing: 6) {
                        Text(model.copy.text(.ed25519PrivateKeyOptional))
                            .font(.openSans(13, weight: .semibold))
                            .foregroundStyle(Color.octGray60)
                            .padding(.horizontal, 16)
                            .padding(.top, 12)
                            .padding(.bottom, 2)

                        ZStack(alignment: .topLeading) {
                            if privateKey.isEmpty {
                                Text(model.copy.text(.privateKeyPlaceholder))
                                    .font(.system(.footnote, design: .monospaced))
                                    .foregroundStyle(Color.octGray40)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 10)
                            }
                            TextEditor(text: $privateKey)
                                .font(.system(.footnote, design: .monospaced))
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .padding(6)
                        }
                        .frame(minHeight: 100)
                        .background(Color(red: 0.965, green: 0.970, blue: 0.978), in: RoundedRectangle(cornerRadius: 10))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(Color.octGray05, lineWidth: 1)
                        )
                        .padding(.horizontal, 12)
                        .padding(.bottom, 12)
                    }
                    .background(Color.octGray0, in: RoundedRectangle(cornerRadius: 16))

                    // Host Key
                    VStack(alignment: .leading, spacing: 0) {
                        fieldRow(
                            title: model.copy.text(.pinnedHostKey),
                            placeholder: model.copy.text(.hostKeyPlaceholder),
                            text: $hostKey
                        )
                        .padding(12)
                    }
                    .background(Color.octGray0, in: RoundedRectangle(cornerRadius: 16))

                    // Add button
                    Button {
                        do {
                            let validHost = try ProfileValidator.validateHost(address)
                            let validPort = try ProfileValidator.validatePort(port)
                            let validUsername = try ProfileValidator.validateUsername(username)
                            // In edit mode we may be leaving the credential
                            // fields blank to keep what is already saved; only
                            // validate when the user actually entered something.
                            if !password.isEmpty || !privateKey.isEmpty {
                                try ProfileValidator.validateCredentials(password: password, privateKey: privateKey)
                            }

                            // Resolve the id: reuse the edited server's id (or the
                            // currently selected one when editing without an
                            // explicit id), otherwise mint a fresh one. Never
                            // mint blindly on edit — that spawns duplicates.
                            let id = editingID ?? (editing ? model.selectedServer?.id : nil) ?? UUID().uuidString

                            // When editing, preserve existing secrets if the user
                            // left the fields blank (same merge semantics as the
                            // old single-profile editor).
                            var existingPassword: String?
                            var existingPrivateKey: String?
                            if let existing = model.servers.first(where: { $0.id == id }) {
                                existingPassword = existing.password
                                existingPrivateKey = existing.privateKey
                            }
                            let resolvedPassword = password.isEmpty ? (existingPassword ?? "") : password
                            let resolvedPrivateKey = privateKey.isEmpty ? (existingPrivateKey ?? "") : privateKey

                            let profile = ServerProfile(
                                id: id,
                                name: validHost,
                                host: validHost,
                                port: validPort,
                                username: validUsername,
                                hostKey: hostKey,
                                dnsServers: [],
                                hasPassword: !resolvedPassword.isEmpty,
                                hasPrivateKey: !resolvedPrivateKey.isEmpty,
                                password: resolvedPassword.isEmpty ? nil : resolvedPassword,
                                privateKey: resolvedPrivateKey.isEmpty ? nil : resolvedPrivateKey
                            )

                            // Persist locally (instant UI) then close. Extension
                            // sync happens best-effort in the background.
                            model.saveServer(profile)
                            model.serverName = validHost
                            dismiss()
                        } catch {
                            errorMessage = error.localizedDescription
                            showErrorAlert = true
                         }
                    } label: {
                        Text(model.copy.text(editing ? .saveChanges : .addServer))
                            .font(.openSans(16, weight: .semibold))
                            .foregroundStyle(Color.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 15)
                            .background(Color.sec50, in: RoundedRectangle(cornerRadius: 16))
                    }
                    .buttonStyle(.plain)

                    // Hint
                    Text(model.copy.text(.credentialsHint))
                        .font(.openSans(12))
                        .foregroundStyle(Color.octGray60)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 16)
                }
                .padding(16)
            }
            .adaptiveCenterColumn()
            .background(Color.appBg)
            .navigationTitle(model.copy.text(editing ? .editServerTitle : .addServerTitle))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(model.copy.text(.cancel)) { dismiss() }
                        .foregroundStyle(Color.sec50)
                }
            }
            .onAppear {
                if editing, let server = model.servers.first(where: { $0.id == editingID }) {
                    address = server.host
                    username = server.username
                    port = String(server.port)
                    hostKey = server.hostKey
                    // Pre-fill secrets so the edit form shows what is stored.
                    password = server.password ?? ""
                    privateKey = server.privateKey ?? ""
                }
            }
            .alert(model.copy.text(.invalidInput), isPresented: $showErrorAlert) {
                Button(model.copy.text(.ok), role: .cancel) { }
            } message: {
                Text(errorMessage ?? "Please check the entered configuration.")
            }
        }
    }

    private func fieldRow(title: String, placeholder: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.openSans(12, weight: .medium))
                .foregroundStyle(Color.octGray60)
            TextField(placeholder, text: text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.openSans(14))
                .foregroundStyle(Color.octGray100)
                .padding(.vertical, 8)
                .padding(.horizontal, 10)
                .background(Color(red: 0.965, green: 0.970, blue: 0.978), in: RoundedRectangle(cornerRadius: 10))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.octGray05, lineWidth: 1)
                )
        }
    }

    private func secureFieldRow(title: String, placeholder: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.openSans(12, weight: .medium))
                .foregroundStyle(Color.octGray60)
            SecureField(placeholder, text: text)
                .textInputAutocapitalization(.never)
                .font(.openSans(14))
                .foregroundStyle(Color.octGray100)
                .padding(.vertical, 8)
                .padding(.horizontal, 10)
                .background(Color(red: 0.965, green: 0.970, blue: 0.978), in: RoundedRectangle(cornerRadius: 10))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.octGray05, lineWidth: 1)
                )
        }
    }
}

// MARK: - Diagnostics View

struct DiagnosticsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var showTechnicalDetails = false
    /// Live status snapshot pulled on appear + on every 2s while visible.
    @State private var phase = ""
    @State private var stopReason = ""
    @State private var lastError = ""
    @State private var pollTask: Task<Void, Never>?

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                // Live tunnel state — what the extension is doing RIGHT NOW
                // (same phase strings the console log shows).
                VStack(alignment: .leading, spacing: 0) {
                    Text(model.copy.text(.setupProgress))
                        .font(.openSans(13, weight: .semibold))
                        .foregroundStyle(Color.octGray60)
                        .padding(.horizontal, 16)
                        .padding(.top, 12)
                        .padding(.bottom, 8)

                    liveRow(icon: phaseIcon,
                            title: connectionTitle,
                            detail: phase.isEmpty ? "—" : phase)
                }
                .background(Color.octGray0, in: RoundedRectangle(cornerRadius: 16))

                // Live telemetry: pool, flows, bytes — same numbers as the
                // connected-screen strip, so diagnostics and the main screen
                // can never disagree.
                VStack(alignment: .leading, spacing: 0) {
                    Text("LIVE")
                        .font(.openSans(13, weight: .semibold))
                        .foregroundStyle(Color.octGray60)
                        .padding(.horizontal, 16)
                        .padding(.top, 12)
                        .padding(.bottom, 8)

                    profileRow(label: "SSH connections", value: model.sshConnectionCount > 0 ? String(model.sshConnectionCount) : "—")
                    Divider().background(Color.octGray05).padding(.horizontal, 16)
                    profileRow(label: "Active flows", value: model.activeChannelCount > 0 ? String(model.activeChannelCount) : "—")
                    Divider().background(Color.octGray05).padding(.horizontal, 16)
                    profileRow(label: "Downloaded", value: fmtMB(model.tunnelDownBytes))
                    Divider().background(Color.octGray05).padding(.horizontal, 16)
                    profileRow(label: "Uploaded", value: fmtMB(model.tunnelUpBytes))
                    Divider().background(Color.octGray05).padding(.horizontal, 16)
                    profileRow(label: model.copy.text(.ping), value: model.serverPingMs.map { "\($0) ms" } ?? "—")
                }
                .background(Color.octGray0, in: RoundedRectangle(cornerRadius: 16))

                // Profile
                VStack(alignment: .leading, spacing: 0) {
                    Text(model.copy.text(.profile))
                        .font(.openSans(13, weight: .semibold))
                        .foregroundStyle(Color.octGray60)
                        .padding(.horizontal, 16)
                        .padding(.top, 12)
                        .padding(.bottom, 8)

                    profileRow(label: model.copy.text(.server), value: model.profile.host.isEmpty ? "—" : model.profile.host)
                    Divider().background(Color.octGray05).padding(.horizontal, 16)
                    profileRow(label: model.copy.text(.sshPort), value: String(model.profile.port))
                    Divider().background(Color.octGray05).padding(.horizontal, 16)
                    profileRow(label: model.copy.text(.username), value: model.profile.username.isEmpty ? "—" : model.profile.username)
                    Divider().background(Color.octGray05).padding(.horizontal, 16)
                    profileRow(label: model.copy.text(.authentication), value: model.profile.privateKey.isEmpty ? model.copy.text(.passwordKeychain) : model.copy.text(.ed25519Key))
                    Divider().background(Color.octGray05).padding(.horizontal, 16)
                    profileRow(label: "DNS", value: model.settings.useCustomDNS && !model.settings.validatedDNSServers.isEmpty ? model.settings.validatedDNSServers.joined(separator: ", ") : "8.8.8.8 (default)")
                }
                .background(Color.octGray0, in: RoundedRectangle(cornerRadius: 16))

                // Stop reason / last error — the WHY of the last disconnect.
                if !stopReason.isEmpty || !lastError.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(model.copy.text(.status))
                            .font(.openSans(13, weight: .semibold))
                        .foregroundStyle(Color.octGray60)
                        .padding(.horizontal, 16)
                        .padding(.top, 12)
                        .padding(.bottom, 8)

                        if !stopReason.isEmpty {
                            profileRow(label: "Stop reason", value: stopReason)
                        }
                        if !lastError.isEmpty, lastError != "none" {
                            Divider().background(Color.octGray05).padding(.horizontal, 16)
                            profileRow(label: "Last error", value: lastError)
                        }
                    }
                    .background(Color.octGray0, in: RoundedRectangle(cornerRadius: 16))
                }

                // Error
                if case .failed(let message) = model.connection {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(model.copy.text(.error))
                            .font(.openSans(13, weight: .semibold))
                            .foregroundStyle(Color.octGray60)
                            .padding(.horizontal, 16)
                            .padding(.top, 12)
                            .padding(.bottom, 8)

                        Text(friendlyFailure(message))
                            .foregroundStyle(.red)
                            .padding(14)

                        DisclosureGroup(model.copy.text(.technicalDetails), isExpanded: $showTechnicalDetails) {
                            Text(message)
                                .font(.system(.footnote, design: .monospaced))
                                .textSelection(.enabled)
                        }
                        .padding(14)
                    }
                    .background(Color.octGray0, in: RoundedRectangle(cornerRadius: 16))
                }
            }
            .padding(16)
        }
        .adaptiveCenterColumn()
        .background(Color.appBg)
        .navigationTitle(model.copy.text(.diagnosticsTitle))
        .task {
            await refreshExtensionStatus()
            pollTask?.cancel()
            pollTask = Task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(2))
                    await refreshExtensionStatus()
                }
            }
        }
        .onDisappear { pollTask?.cancel() }
    }

    private func refreshExtensionStatus() async {
        let status = await VPNExtensionAPI.call(from: model.extensionManager, cmd: .status, timeout: 2)
        guard !Task.isCancelled else { return }
        phase = status["phase"] ?? ""
        stopReason = status["stopReason"] ?? ""
        let errRsp = await VPNExtensionAPI.call(from: model.extensionManager, cmd: .lastError, timeout: 2)
        if !Task.isCancelled { lastError = errRsp["error"] ?? "none" }
    }

    /// Raw internal failure strings -> what a human should read. Technical
    /// detail stays one tap away in the disclosure below.
    private func friendlyFailure(_ message: String) -> String {
        switch message {
        case "freeTimeExhausted":
            return "Free time is over. Watch an ad to get +3 hours."
        default:
            return message
        }
    }

    private var connectionTitle: String {
        switch model.connection {
        case .connected: return model.copy.text(.connected)
        case .connecting: return model.copy.text(.connecting)
        case .disconnected: return model.copy.text(.disconnected)
        case .failed: return model.copy.text(.error)
        }
    }

    private var phaseIcon: String {
        switch model.connection {
        case .connected: return "checkmark.circle.fill"
        case .connecting: return "arrow.triangle.2.circlepath"
        case .disconnected: return "circle"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }

    private func fmtMB(_ bytes: Int) -> String {
        bytes > 0 ? String(format: "%.1f MB", Double(bytes) / 1_048_576) : "—"
    }

    private func liveRow(icon: String, title: String, detail: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(Color.prim50)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.openSans(15, weight: .medium))
                    .foregroundStyle(Color.octGray100)
                Text(detail)
                    .font(.openSans(12))
                    .foregroundStyle(Color.octGray60)
            }
            Spacer()
            if model.connection == .connecting { ProgressView().controlSize(.small) }
        }
        .padding(14)
    }

    private func progressRow(_ title: String, active: Bool) -> some View {
        HStack {
            Image(systemName: active ? "arrow.triangle.2.circlepath" : "circle")
                .foregroundStyle(active ? .orange : Color.octGray40)
                .frame(width: 24)
            Text(title)
                .font(.openSans(15))
                .foregroundStyle(Color.octGray100)
            Spacer()
            if active { ProgressView().controlSize(.small) }
        }
        .padding(14)
    }

    private func profileRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.openSans(15))
                .foregroundStyle(Color.octGray60)
            Spacer()
            Text(value)
                .font(.openSans(15, weight: .medium))
                .foregroundStyle(Color.octGray100)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(14)
    }
}

// MARK: - Preview

#Preview {
    RootView()
        .environmentObject(AppModel())
}

// MARK: - Protocol View

struct ProtocolView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(model.copy.text(.vpnProtocol))
                        .font(.openSans(13, weight: .semibold))
                        .foregroundStyle(Color.octGray60)
                        .padding(.horizontal, 16)
                        .padding(.top, 12)
                        .padding(.bottom, 8)

                    // The relay runs on NIOSSH (SSH-2) — the transport is the
                    // protocol, there is no second implementation to switch
                    // to. The old "SSH legacy" option changed a stored string
                    // and nothing else, which is worse than not offering it.
                    protocolOption(name: "SSH2 (SSH-2 over NIOSSH)",
                                   desc: model.copy.text(.ssh2Desc),
                                   selected: true) {}
                }
                .background(Color.octGray0, in: RoundedRectangle(cornerRadius: 16))

                Text(model.copy.text(.ssh2Recommended))
                    .font(.openSans(12))
                    .foregroundStyle(Color.octGray60)
                    .padding(.horizontal, 16)
            }
            .padding(16)
        }
        .adaptiveCenterColumn()
        .background(Color.appBg)
        .navigationTitle(model.copy.text(.protocolTitle))
        .navigationBarTitleDisplayMode(.inline)
    }

    private func protocolOption(name: String, desc: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .font(.openSans(15, weight: .medium))
                        .foregroundStyle(Color.octGray100)
                    Text(desc)
                        .font(.openSans(12))
                        .foregroundStyle(Color.octGray60)
                }
                Spacer()
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 18))
                    .foregroundStyle(selected ? Color.prim50 : Color.octGray40)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - DNS View (custom servers OR public preset — mutually exclusive)

struct DNSView: View {
    @EnvironmentObject private var model: AppModel
    @State private var showCustomInfo = false
    /// Which preset's info bubble is open (one at a time).
    @State private var openPresetInfoID: String?

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                // ---- Custom DNS servers (own values) ----
                VStack(alignment: .leading, spacing: 0) {
                    Text(model.copy.text(.dnsSettings))
                        .font(.openSans(13, weight: .semibold))
                        .foregroundStyle(Color.octGray60)
                        .padding(.horizontal, 16)
                        .padding(.top, 12)
                        .padding(.bottom, 8)

                    HStack(spacing: 8) {
                        Text(model.copy.text(.useCustomDNS))
                            .font(.openSans(15, weight: .medium))
                            .foregroundStyle(Color.octGray100)
                        InfoDotButton(isVisible: $showCustomInfo)
                        Spacer()
                        Toggle("", isOn: customToggle)
                            .tint(Color.prim50)
                            .labelsHidden()
                    }
                    .padding(14)

                    if showCustomInfo {
                        InfoBubble(title: model.copy.text(.dnsUseCustomInfoTitle),
                                   message: model.copy.text(.dnsUseCustomInfoBody))
                            .padding(.horizontal, 14)
                            .padding(.bottom, 12)
                    }

                    if model.settings.useCustomDNS {
                        Divider().background(Color.octGray05).padding(.horizontal, 16)
                        VStack(spacing: 0) {
                            dnsField(label: model.copy.text(.primaryDNS), text: $model.settings.primaryDNS)
                            Divider().background(Color.octGray05).padding(.horizontal, 16)
                            dnsField(label: model.copy.text(.secondaryDNS), text: $model.settings.secondaryDNS)
                        }
                    }
                }
                .background(Color.octGray0, in: RoundedRectangle(cornerRadius: 16))

                // ---- Public presets (choosing one switches OFF custom) ----
                VStack(alignment: .leading, spacing: 0) {
                    Text(model.copy.text(.dnsPresetsTitle))
                        .font(.openSans(13, weight: .semibold))
                        .foregroundStyle(Color.octGray60)
                        .padding(.horizontal, 16)
                        .padding(.top, 12)
                        .padding(.bottom, 8)

                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(DNSPresets.all.enumerated()), id: \.element.id) { index, preset in
                                if index > 0 {
                                    Divider().background(Color.octGray05).padding(.horizontal, 16)
                                }
                                presetRow(preset)
                            }
                        }
                    }
                    .frame(maxHeight: 354)   // ~3.5 rows visible
                }
                .background(Color.octGray0, in: RoundedRectangle(cornerRadius: 16))

                Text(model.copy.text(.dnsRulesHint))
                    .font(.openSans(11))
                    .foregroundStyle(Color.octGray40)
                    .padding(.horizontal, 16)
            }
            .padding(16)
        }
        .adaptiveCenterColumn()
        .background(Color.appBg)
        .navigationTitle(model.copy.text(.dnsSettings))
        .navigationBarTitleDisplayMode(.inline)
    }

    /// Custom mode and preset mode are mutually exclusive: turning custom ON
    /// clears the preset choice; the fields then carry the user's own values.
    private var customToggle: Binding<Bool> {
        Binding(
            get: { model.settings.useCustomDNS },
            set: { on in
                model.settings.useCustomDNS = on
                if on { model.settings.presetDNS = [] }
            }
        )
    }

    private func presetRow(_ preset: DNSPreset) -> some View {
        let selected = model.settings.presetDNS == [preset.primary, preset.secondary]
        let infoOpen = openPresetInfoID == preset.id
        return VStack(spacing: 0) {
            // Whole-card tap: select like a server card (green highlight).
            // Re-tap the selected preset deselects it; tapping another
            // preset switches. No separate select circle.
            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                    if selected {
                        model.settings.presetDNS = []
                        ConsoleLogStore.shared.log(level: .info, tag: "DNS",
                            message: "preset deselected: \(preset.name)")
                    } else {
                        model.settings.presetDNS = [preset.primary, preset.secondary]
                        model.settings.useCustomDNS = false
                        ConsoleLogStore.shared.log(level: .info, tag: "DNS",
                            message: "preset selected: \(preset.name) (\(preset.primary), \(preset.secondary))")
                    }
                }
            } label: {
                VStack(spacing: 6) {
                    // Row 1: name + "?" on the left, chips pushed right
                    // (space-between) — everything on one line, compact.
                    HStack(spacing: 6) {
                        HStack(spacing: 4) {
                            Text(preset.name)
                                .font(.openSans(14, weight: .semibold))
                                .foregroundStyle(Color.octGray100)
                                .lineLimit(1)
                            InfoDotButtonCompact(isVisible: infoOpen) {
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                                    openPresetInfoID = infoOpen ? nil : preset.id
                                }
                            }
                        }
                        Spacer(minLength: 8)
                        FlowChips(chips: preset.chips.map { (model.copy.chipText($0), Self.chipColor($0)) })
                    }
                    // Row 2: the resolver IPs. Small but DARK — readable,
                    // not the washed-out gray the review called invisible.
                    HStack(spacing: 6) {
                        Text("\(preset.primary)  •  \(preset.secondary)")
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(Color.octGray80)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        if selected {
                            Image(systemName: "checkmark")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(Color.prim50)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(selected ? Color.prim50.opacity(0.10) : Color.octGray0)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(selected ? Color.prim50 : Color.octGray05, lineWidth: selected ? 1.5 : 1)
                )
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            if infoOpen {
                InfoBubble(title: preset.name,
                           message: model.copy.presetDescription(preset))
                    .padding(.horizontal, 6)
                    .padding(.bottom, 10)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
    }

    private static func chipColor(_ chip: DNSPreset.Chip) -> Color {
        switch chip {
        case .noFilter: return Color.octGray40
        case .privacy: return Color(red: 0.55, green: 0.35, blue: 0.85)
        case .malware: return Color(red: 0.13, green: 0.44, blue: 0.85)
        case .phishing: return Color(red: 0.45, green: 0.25, blue: 0.85)
        case .ads: return Color(red: 0.85, green: 0.45, blue: 0.1)
        case .trackers: return Color(red: 0.75, green: 0.55, blue: 0.1)
        case .adult: return Color(red: 0.16, green: 0.62, blue: 0.35)
        case .safeSearch: return Color(red: 0.1, green: 0.55, blue: 0.55)
        }
    }

    private func dnsField(label: String, text: Binding<String>) -> some View {
        HStack {
            Text(label)
                .font(.openSans(15))
                .foregroundStyle(Color.octGray60)
            Spacer()
            TextField("0.0.0.0", text: text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .multilineTextAlignment(.trailing)
                .font(.openSans(15))
        }
        .padding(14)
    }
}

// MARK: - Local DNS rules (VPN-settings level screen)

struct LocalDNSRulesView: View {
    @EnvironmentObject private var model: AppModel
    @State private var showRulesInfo = false
    @State private var showAddRule = false
    @State private var editingRule: DNSBlocklistEntry?

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 8) {
                        Text(model.copy.text(.dnsLocalRulesTitle))
                            .font(.openSans(13, weight: .semibold))
                            .foregroundStyle(Color.octGray60)
                        InfoDotButton(isVisible: $showRulesInfo)
                        Spacer()
                        Text("\(model.settings.dnsRules.count) \(model.copy.text(.dnsRulesCount))")
                            .font(.openSans(11, weight: .semibold))
                            .foregroundStyle(model.settings.dnsRules.isEmpty ? Color.octGray40 : Color(red: 0.85, green: 0.45, blue: 0.1))
                        Button {
                            showAddRule = true
                        } label: {
                            Image(systemName: "plus")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 26, height: 26)
                                .background(Color.sec50, in: Circle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(model.copy.text(.dnsAddRule))
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 8)

                    if showRulesInfo {
                        InfoBubble(title: model.copy.text(.dnsLocalRulesInfoTitle),
                                   message: model.copy.text(.dnsLocalRulesInfoBody))
                            .padding(.horizontal, 14)
                            .padding(.bottom, 12)
                    }

                    if model.settings.dnsRules.isEmpty {
                        Text(model.copy.text(.dnsRulesEmpty))
                            .font(.openSans(12))
                            .foregroundStyle(Color.octGray40)
                            .padding(.horizontal, 16)
                            .padding(.bottom, 14)
                    } else {
                        VStack(spacing: 0) {
                            ForEach(Array(model.settings.dnsRules.enumerated()), id: \.element.id) { index, rule in
                                if index > 0 {
                                    Divider().background(Color.octGray05).padding(.horizontal, 16)
                                }
                                dnsRuleRow(rule)
                            }
                        }
                        .padding(.bottom, 4)
                    }
                }
                .background(Color.octGray0, in: RoundedRectangle(cornerRadius: 16))

                Text(model.copy.text(.dnsRulesHint))
                    .font(.openSans(11))
                    .foregroundStyle(Color.octGray40)
                    .padding(.horizontal, 16)
            }
            .padding(16)
        }
        .adaptiveCenterColumn()
        .background(Color.appBg)
        .navigationTitle(model.copy.text(.dnsLocalRulesTitle))
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showAddRule) {
            AddDNSRuleView()
                .presentationDetents([.medium])
        }
        .sheet(item: $editingRule) { rule in
            AddDNSRuleView(editing: rule)
                .presentationDetents([.medium])
        }
    }

    private func dnsRuleRow(_ rule: DNSBlocklistEntry) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(rule.domain)
                        .font(.openSans(14, weight: .medium))
                        .foregroundStyle(Color.octGray100)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(rule.kind == .block ? model.copy.text(.dnsRuleBlocked) : model.copy.text(.dnsRuleOverride))
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                        .foregroundStyle(rule.kind == .block
                                         ? Color(red: 1.0, green: 0.25, blue: 0.35)
                                         : Color(red: 0.13, green: 0.44, blue: 0.85))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background((rule.kind == .block
                                      ? Color(red: 1.0, green: 0.25, blue: 0.35)
                                      : Color(red: 0.13, green: 0.44, blue: 0.85)).opacity(0.12), in: Capsule())
                }
                Text(rule.kind == .block ? "0.0.0.0" : rule.ip)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Color.octGray40)
                // Scope under the address: exact domain or subdomains too.
                Text(rule.includeSubdomains
                     ? model.copy.text(.dnsRuleScopeSubtree)
                     : model.copy.text(.dnsRuleScopeExact))
                    .font(.openSans(10))
                    .foregroundStyle(Color.octGray40.opacity(0.8))
            }
            Spacer()
            Button {
                editingRule = rule
            } label: {
                Image(systemName: "pencil")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.sec50)
                    .frame(width: 30, height: 30)
                    .background(Color.sec50.opacity(0.10), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(model.copy.text(.dnsEditRule))
            Button {
                model.removeDNSRule(id: rule.id)
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 14))
                    .foregroundStyle(Color.red.opacity(0.7))
                    .frame(width: 30, height: 30)
                    .background(Color.red.opacity(0.08), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(model.copy.text(.dnsRuleDelete))
        }
        .padding(14)
    }
}

// MARK: - Info tooltip components (reused across settings screens)

/// Compact round "?" (per-row): same persistent tooltip mechanics, smaller
/// footprint so it fits inside a preset row without fighting the tap target.
struct InfoDotButtonCompact: View {
    let isVisible: Bool
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: "questionmark")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(isVisible ? .white : Color.octGray40)
                .frame(width: 18, height: 18)
                .background(isVisible ? Color.prim50 : Color.octGray40.opacity(0.35), in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("info")
    }
}

/// Wrapping row of small colored chips (capability labels). Keeps preset
/// rows compact for any chip count and any language width.
struct FlowChips: View {
    let chips: [(String, Color)]
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Chips may wrap onto a second line for long translations.
            LayoutChips(chips: chips)
        }
    }
    private struct LayoutChips: View {
        let chips: [(String, Color)]
        @State private var totalWidth: CGFloat = 0
        var body: some View {
            var width: CGFloat = 0
            var height: CGFloat = 0
            return GeometryReader { geo in
                ZStack(alignment: .topLeading) {
                    Color.clear.frame(width: geo.size.width, height: height).onAppear { totalWidth = geo.size.width }
                    ForEach(Array(chips.enumerated()), id: \.offset) { _, chip in
                        chipView(chip.0, chip.1)
                            .padding(.trailing, 4)
                            .padding(.bottom, 4)
                            .alignmentGuide(.leading) { d in
                                if abs(width - d.width) > totalWidth {
                                    width = 0
                                    height -= d.height
                                }
                                let result = width
                                if chip == chips.last! {
                                    width = 0
                                } else {
                                    width -= d.width
                                }
                                return result
                            }
                            .alignmentGuide(.top) { _ in
                                let result = height
                                if chip == chips.last! {
                                    height = 0
                                }
                                return result
                            }
                    }
                }
            }
            .frame(height: 40)
        }
        private func chipView(_ text: String, _ color: Color) -> some View {
            Text(text)
                .font(.system(size: 8, weight: .bold, design: .monospaced))
                .foregroundStyle(color)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(color.opacity(0.12), in: Capsule())
        }
    }
}

/// Round "?" button toggling a tooltip bubble. The bubble below is part of the
/// layout (persistent — it doesn't vanish when you scroll or tap elsewhere on
/// the same control group).
struct InfoDotButton: View {
    @Binding var isVisible: Bool
    var body: some View {
        Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                isVisible.toggle()
            }
        } label: {
            Image(systemName: "questionmark")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(isVisible ? .white : Color.octGray40)
                .frame(width: 20, height: 20)
                .background(isVisible ? Color.prim50 : Color.octGray40.opacity(0.35), in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("info")
    }
}

/// Rounded tooltip card with a title + body.
struct InfoBubble: View {
    let title: String
    let message: String
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.openSans(12, weight: .semibold))
                .foregroundStyle(Color.prim50)
            Text(message)
                .font(.openSans(12))
                .foregroundStyle(Color.octGray60)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(Color.prim50.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.prim50.opacity(0.25), lineWidth: 1)
        )
    }
}

// MARK: - Add DNS rule sheet (block / override)

struct AddDNSRuleView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    /// Nil = creating a new rule; non-nil = editing that rule in place.
    let editing: DNSBlocklistEntry?
    @State private var domain = ""
    @State private var ip = ""
    @State private var mode: DNSBlocklistEntry.Kind = .block
    /// Subtree (domain + all subdomains) or exact domain only — explicit, so
    /// the user never has to guess how wide the rule bites.
    @State private var includeSubdomains = true
    @State private var errorText: String?

    init(editing: DNSBlocklistEntry? = nil) {
        self.editing = editing
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(model.copy.text(.dnsAddRuleDomain))
                        .font(.openSans(13, weight: .semibold))
                        .foregroundStyle(Color.octGray60)
                    TextField(model.copy.text(.dnsAddRuleDomainPlaceholder), text: $domain)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .font(.system(.body, design: .monospaced))
                        .padding(12)
                        .background(Color.octGray0, in: RoundedRectangle(cornerRadius: 12))
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text(model.copy.text(.dnsAddRuleMode))
                        .font(.openSans(13, weight: .semibold))
                        .foregroundStyle(Color.octGray60)
                    Picker("", selection: $mode) {
                        Text(model.copy.text(.dnsAddRuleModeBlock)).tag(DNSBlocklistEntry.Kind.block)
                        Text(model.copy.text(.dnsAddRuleModeOverride)).tag(DNSBlocklistEntry.Kind.override)
                    }
                    .pickerStyle(.segmented)
                }

                // Scope: exact domain vs domain + every subdomain. No
                // guessing — the toggle states precisely what matches.
                VStack(alignment: .leading, spacing: 8) {
                    Text(model.copy.text(.dnsRuleScope))
                        .font(.openSans(13, weight: .semibold))
                        .foregroundStyle(Color.octGray60)
                    Picker("", selection: $includeSubdomains) {
                        Text(model.copy.text(.dnsRuleScopeExact)).tag(false)
                        Text(model.copy.text(.dnsRuleScopeSubtree)).tag(true)
                    }
                    .pickerStyle(.segmented)
                }

                if mode == .override {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(model.copy.text(.dnsAddRuleIP))
                            .font(.openSans(13, weight: .semibold))
                            .foregroundStyle(Color.octGray60)
                        TextField(model.copy.text(.dnsAddRuleIPPlaceholder), text: $ip)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.decimalPad)
                            .font(.system(.body, design: .monospaced))
                            .padding(12)
                            .background(Color.octGray0, in: RoundedRectangle(cornerRadius: 12))
                    }
                }

                if let errorText {
                    Text(errorText)
                        .font(.openSans(12))
                        .foregroundStyle(Color.red)
                }

                Spacer()

                Button {
                    if let failure = model.addDNSRule(domain: domain, kind: mode, ip: ip,
                                                      includeSubdomains: includeSubdomains,
                                                      replacing: editing) {
                        errorText = failure
                    } else {
                        dismiss()
                    }
                } label: {
                    Text(editing == nil ? model.copy.text(.dnsAddRuleAdd) : model.copy.text(.dnsSaveRule))
                        .font(.openSans(15, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Color.sec50, in: RoundedRectangle(cornerRadius: 14))
                }
                .buttonStyle(.plain)
                .disabled(domain.isEmpty || (mode == .override && ip.isEmpty))
            }
            .padding(16)
            .adaptiveCenterColumn()
            .background(Color.appBg)
            .navigationTitle(editing == nil ? model.copy.text(.dnsAddRule) : model.copy.text(.dnsEditRuleTitle))
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                if let editing {
                    domain = editing.domain
                    mode = editing.kind
                    ip = editing.kind == .override ? editing.ip : ""
                    includeSubdomains = editing.includeSubdomains
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(model.copy.text(.dnsAddRuleCancel)) { dismiss() }
                }
            }
        }
    }
}

// MARK: - Advanced View

struct AdvancedView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(model.copy.text(.connectionSection))
                        .font(.openSans(13, weight: .semibold))
                        .foregroundStyle(Color.octGray60)
                        .padding(.horizontal, 16)
                        .padding(.top, 12)
                        .padding(.bottom, 8)

                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(model.copy.text(.killSwitch))
                                .font(.openSans(15, weight: .medium))
                                .foregroundStyle(Color.octGray100)
                            Text(model.copy.text(.killSwitchDesc))
                                .font(.openSans(12))
                                .foregroundStyle(Color.octGray60)
                        }
                        Spacer()
                        Toggle("", isOn: $model.settings.killSwitch)
                            .tint(Color.prim50)
                    }
                    .padding(14)

                    Divider().background(Color.octGray05).padding(.horizontal, 16)

                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(model.copy.text(.connectOnDemand))
                                .font(.openSans(15, weight: .medium))
                                .foregroundStyle(Color.octGray100)
                            Text(model.copy.text(.connectOnDemandDesc))
                                .font(.openSans(12))
                                .foregroundStyle(Color.octGray60)
                        }
                        Spacer()
                        Toggle("", isOn: $model.settings.connectOnDemand)
                            .tint(Color.prim50)
                    }
                    .padding(14)
                }
                .background(Color.octGray0, in: RoundedRectangle(cornerRadius: 16))

                VStack(alignment: .leading, spacing: 0) {
                    Text(model.copy.text(.debugSection))
                        .font(.openSans(13, weight: .semibold))
                        .foregroundStyle(Color.octGray60)
                        .padding(.horizontal, 16)
                        .padding(.top, 12)
                        .padding(.bottom, 8)

                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(model.copy.text(.enableLogging))
                                .font(.openSans(15, weight: .medium))
                                .foregroundStyle(Color.octGray100)
                            Text(model.copy.text(.enableLoggingDesc))
                                .font(.openSans(12))
                                .foregroundStyle(Color.octGray60)
                        }
                        Spacer()
                        Toggle("", isOn: $model.settings.enableLogging)
                            .tint(Color.prim50)
                    }
                    .padding(14)
                }
                .background(Color.octGray0, in: RoundedRectangle(cornerRadius: 16))
            }
            .padding(16)
        }
        .adaptiveCenterColumn()
        .background(Color.appBg)
        .navigationTitle(model.copy.text(.advanced))
        .navigationBarTitleDisplayMode(.inline)
    }
}
