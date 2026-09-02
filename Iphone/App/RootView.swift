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
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                OctohideTabBar(selected: $selectedTab, copy: model.copy)
            }

            // Vuexy-style Floating theCustomizer terminal button
            VStack {
                Spacer()
                FloatingCustomizerButton(
                    isOpen: $isConsoleOpen,
                    logCount: ConsoleLogStore.shared.entries.count,
                    isConnecting: model.connection == .connecting
                )
                .padding(.bottom, 110)
            }
            .ignoresSafeArea(.keyboard, edges: .bottom)

            // Right sliding Hacker Console Sidebar
            HackerConsoleSidebarView(isOpen: $isConsoleOpen)

            if model.needsLanguageSelection {
                LanguageOverlay()
                    .transition(.opacity)
            }
        }
        .preferredColorScheme(nil)
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
    @State private var elapsed: TimeInterval = 0
    @State private var timer: Timer?
    @State private var showAddServer = false
    @State private var showLocationsSheet = false

    var body: some View {
        VStack(spacing: 0) {
            // Top Status Card ("Unprotected" / "Protected")
            statusCard
                .padding(.horizontal, 16)
                .padding(.top, 8)

            // Upper area with World Map
            ZStack(alignment: .center) {
                WorldMapView()
                    .padding(.horizontal, 4)
                    .padding(.top, 4)
            }
            .frame(maxHeight: 220)

            Spacer(minLength: 16)

            // Central Power Button
            powerButton
                .padding(.bottom, 12)

            // Cancel / Disconnect button visible during connecting or failed states
            cancelOrDisconnectButton
                .animation(.spring(response: 0.35, dampingFraction: 0.8), value: model.connection == .connecting)
                .padding(.bottom, 12)

            Spacer(minLength: 8)

            // Selected Location Card
            selectedLocationCard
                .padding(.horizontal, 16)
                .padding(.bottom, 20)
        }
        .background(Color.appBg)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { startTimerIfNeeded() }
        .onDisappear { timer?.invalidate() }
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
        ZStack {
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
                                    ? [Color.prim50.opacity(0.4), Color.prim100.opacity(0.2)]
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

                    // Inner solid white button disc
                    Circle()
                        .fill(model.connection == .connected ? Color.prim50 : Color.white)
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
        }
    }

    // MARK: - Cancel / Disconnect Button (shown when not idle)
    @ViewBuilder
    private var cancelOrDisconnectButton: some View {
        let showCancel: Bool = {
            switch model.connection {
            case .connecting: return true
            case .failed: return true
            default: return false
            }
        }()

        if showCancel {
            Button {
                model.disconnect()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15, weight: .medium))
                    Text("Cancel")
                        .font(.system(size: 14, weight: .semibold))
                }
                .foregroundStyle(Color(red: 0.85, green: 0.2, blue: 0.3))
                .padding(.horizontal, 22)
                .padding(.vertical, 10)
                .background(
                    Capsule()
                        .fill(Color(red: 0.85, green: 0.2, blue: 0.3).opacity(0.10))
                )
                .overlay(
                    Capsule()
                        .stroke(Color(red: 0.85, green: 0.2, blue: 0.3).opacity(0.3), lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
            .transition(.scale.combined(with: .opacity))
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
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color.white)
                    .shadow(color: Color.black.opacity(0.04), radius: 10, y: 4)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Helpers

    private func toggleConnection() {
        if model.connection == .connected {
            model.disconnect()
            timer?.invalidate()
            timer = nil
            elapsed = 0
        } else {
            if model.profile.host.isEmpty {
                showAddServer = true
                return
            }
            model.connect()
            startTimerIfNeeded()
        }
    }

    private func startTimerIfNeeded() {
        guard model.connection == .connected else { return }
        timer?.invalidate()
        elapsed = 0
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            elapsed += 1
        }
    }

    private func formatTime(_ t: TimeInterval) -> String {
        let h = Int(t) / 3600
        let m = (Int(t) % 3600) / 60
        let s = Int(t) % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%02d:%02d", m, s)
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

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    // Your Server card
                    VStack(alignment: .leading, spacing: 0) {
                        Text(model.copy.text(.yourServer))
                            .font(.openSans(13, weight: .semibold))
                            .foregroundStyle(Color.octGray60)
                            .padding(.horizontal, 16)
                            .padding(.top, 12)
                            .padding(.bottom, 8)

                        if model.profile.host.isEmpty {
                            HStack {
                                Text(model.copy.text(.noServerConfigured))
                                    .foregroundStyle(Color.octGray60)
                                Spacer()
                            }
                            .padding(16)
                        } else {
                            HStack(spacing: 12) {
                                Text(model.serverFlag.isEmpty ? "🌐" : model.serverFlag)
                                    .font(.system(size: 26))
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 6) {
                                        Text(model.serverCountry.isEmpty ? model.serverName : model.serverCountry)
                                            .font(.openSans(16, weight: .semibold))
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
                                Spacer()
                                if model.connection == .connected {
                                    Text(model.copy.text(.active))
                                        .font(.caption.weight(.medium))
                                        .foregroundStyle(Color.white)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 4)
                                        .background(Color.prim50, in: Capsule())
                                }
                            }
                            .padding(16)
                        }
                    }
                    .background(Color.octGray0, in: RoundedRectangle(cornerRadius: 16))

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
                    }
                    .buttonStyle(.plain)
                }
                .padding(16)
            }
            .background(Color.appBg)
            .navigationTitle(model.copy.text(.locations))
        }
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
                            .background(
                                language == selected
                                    ? Color.sec50.opacity(0.08)
                                    : Color.clear
                            )
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
                                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
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
                            try ProfileValidator.validateCredentials(password: password, privateKey: privateKey)

                            model.profile = VPNProfile(
                                host: validHost,
                                port: validPort,
                                username: validUsername,
                                password: password,
                                privateKey: privateKey,
                                hostKey: hostKey
                            )
                            model.serverName = validHost
                            dismiss()
                        } catch {
                            errorMessage = error.localizedDescription
                            showErrorAlert = true
                        }
                    } label: {
                        Text(model.copy.text(.addServer))
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
            .background(Color.appBg)
            .navigationTitle(model.copy.text(.addServerTitle))
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(model.copy.text(.cancel)) { dismiss() }
                        .foregroundStyle(Color.sec50)
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

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                // Setup Progress
                VStack(alignment: .leading, spacing: 0) {
                    Text(model.copy.text(.setupProgress))
                        .font(.openSans(13, weight: .semibold))
                        .foregroundStyle(Color.octGray60)
                        .padding(.horizontal, 16)
                        .padding(.top, 12)
                        .padding(.bottom, 8)

                    progressRow(model.copy.text(.connecting), active: model.connection == .connecting)
                    Divider().background(Color.octGray05).padding(.horizontal, 16)
                    progressRow(model.copy.text(.preparingGateway), active: model.connection == .connecting)
                    Divider().background(Color.octGray05).padding(.horizontal, 16)
                    progressRow(model.copy.text(.testingTunnel), active: model.connection == .connecting)
                    Divider().background(Color.octGray05).padding(.horizontal, 16)
                    progressRow(model.copy.text(.ready), active: model.connection == .connected)
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
                }
                .background(Color.octGray0, in: RoundedRectangle(cornerRadius: 16))

                // Error
                if case .failed(let message) = model.connection {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(model.copy.text(.error))
                            .font(.openSans(13, weight: .semibold))
                            .foregroundStyle(Color.octGray60)
                            .padding(.horizontal, 16)
                            .padding(.top, 12)
                            .padding(.bottom, 8)

                        Text(message)
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
        .background(Color.appBg)
        .navigationTitle(model.copy.text(.diagnosticsTitle))
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
                .font(.openSans(15))
                .foregroundStyle(Color.octGray100)
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
    @State private var selectedProtocol = "SSH2"

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

                    protocolOption(name: "SSH2", desc: model.copy.text(.ssh2Desc), selected: selectedProtocol == "SSH2") {
                        selectedProtocol = "SSH2"
                    }
                    Divider().background(Color.octGray05).padding(.horizontal, 16)
                    protocolOption(name: "SSH", desc: model.copy.text(.sshLegacy), selected: selectedProtocol == "SSH") {
                        selectedProtocol = "SSH"
                    }
                }
                .background(Color.octGray0, in: RoundedRectangle(cornerRadius: 16))

                Text(model.copy.text(.ssh2Recommended))
                    .font(.openSans(12))
                    .foregroundStyle(Color.octGray60)
                    .padding(.horizontal, 16)
            }
            .padding(16)
        }
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
                    .foregroundStyle(selected ? Color.prim50 : Color.octGray40)
            }
            .padding(14)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - DNS View

struct DNSView: View {
    @EnvironmentObject private var model: AppModel
    @State private var primaryDNS = "1.1.1.1"
    @State private var secondaryDNS = "8.8.8.8"
    @State private var useCustomDNS = false

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(model.copy.text(.dnsSettings))
                        .font(.openSans(13, weight: .semibold))
                        .foregroundStyle(Color.octGray60)
                        .padding(.horizontal, 16)
                        .padding(.top, 12)
                        .padding(.bottom, 8)

                    HStack {
                        Text(model.copy.text(.useCustomDNS))
                            .font(.openSans(15, weight: .medium))
                            .foregroundStyle(Color.octGray100)
                        Spacer()
                        Toggle("", isOn: $useCustomDNS)
                            .tint(Color.prim50)
                    }
                    .padding(14)

                    if useCustomDNS {
                        Divider().background(Color.octGray05).padding(.horizontal, 16)
                        VStack(spacing: 0) {
                            dnsField(label: model.copy.text(.primaryDNS), text: $primaryDNS)
                            Divider().background(Color.octGray05).padding(.horizontal, 16)
                            dnsField(label: model.copy.text(.secondaryDNS), text: $secondaryDNS)
                        }
                    }
                }
                .background(Color.octGray0, in: RoundedRectangle(cornerRadius: 16))

                Text(model.copy.text(.customDNSHint))
                    .font(.openSans(12))
                    .foregroundStyle(Color.octGray60)
                    .padding(.horizontal, 16)
            }
            .padding(16)
        }
        .background(Color.appBg)
        .navigationTitle(model.copy.text(.dnsSettings))
        .navigationBarTitleDisplayMode(.inline)
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

// MARK: - Advanced View

struct AdvancedView: View {
    @EnvironmentObject private var model: AppModel
    @State private var killSwitch = true
    @State private var connectOnDemand = false
    @State private var enableLogging = false

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
                        Toggle("", isOn: $killSwitch)
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
                        Toggle("", isOn: $connectOnDemand)
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
                        Toggle("", isOn: $enableLogging)
                            .tint(Color.prim50)
                    }
                    .padding(14)
                }
                .background(Color.octGray0, in: RoundedRectangle(cornerRadius: 16))
            }
            .padding(16)
        }
        .background(Color.appBg)
        .navigationTitle(model.copy.text(.advanced))
        .navigationBarTitleDisplayMode(.inline)
    }
}
