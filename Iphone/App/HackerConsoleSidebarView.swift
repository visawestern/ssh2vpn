import SwiftUI
import UniformTypeIdentifiers
import VPNCore

// MARK: - Vuexy-style Floating theCustomizer Button

public struct FloatingCustomizerButton: View {
    @Binding var isOpen: Bool
    let logCount: Int
    let isConnecting: Bool

    @State private var isGlowing = false

    public init(isOpen: Binding<Bool>, logCount: Int, isConnecting: Bool) {
        self._isOpen = isOpen
        self.logCount = logCount
        self.isConnecting = isConnecting
    }

    public var body: some View {
        Button {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                isOpen.toggle()
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "terminal.fill")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Color.white)

                if isConnecting {
                    Circle()
                        .fill(Color(red: 0.0, green: 1.0, blue: 0.4))
                        .frame(width: 6, height: 6)
                        .scaleEffect(isGlowing ? 1.5 : 0.8)
                        .opacity(isGlowing ? 1.0 : 0.4)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                UnevenRoundedRectangle(
                    topLeadingRadius: 16,
                    bottomLeadingRadius: 16,
                    bottomTrailingRadius: 0,
                    topTrailingRadius: 0
                )
                .fill(
                    LinearGradient(
                        colors: [Color(red: 0.08, green: 0.12, blue: 0.22), Color(red: 0.04, green: 0.06, blue: 0.12)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .shadow(color: Color.black.opacity(0.35), radius: 8, x: -2, y: 3)
            )
            .overlay(
                UnevenRoundedRectangle(
                    topLeadingRadius: 16,
                    bottomLeadingRadius: 16,
                    bottomTrailingRadius: 0,
                    topTrailingRadius: 0
                )
                .stroke(Color(red: 0.0, green: 0.94, blue: 1.0).opacity(0.4), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .onAppear {
            withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                isGlowing = true
            }
        }
    }
}

// MARK: - Sliding Right Hacker Console Sidebar

public struct HackerConsoleSidebarView: View {
    @Binding var isOpen: Bool
    @State private var entries: [ConsoleLogEntry] = ConsoleLogStore.shared.entries
    @State private var autoScroll: Bool = true
    @State private var showCopiedToast: Bool = false
    @State private var showShareSheet: Bool = false
    @State private var shareFileUrl: URL?

    public init(isOpen: Binding<Bool>) {
        self._isOpen = isOpen
    }

    public var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .trailing) {
                // Backdrop scrim
                if isOpen {
                    Color.black.opacity(0.55)
                        .ignoresSafeArea()
                        .transition(.opacity)
                        .onTapGesture {
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                                isOpen = false
                            }
                        }
                }

                // Sliding Drawer
                if isOpen {
                    VStack(spacing: 0) {
                        // Header
                        headerView

                        Divider()
                            .background(Color(red: 0.0, green: 0.94, blue: 1.0).opacity(0.3))

                        // Terminal Log Body
                        terminalLogList

                        // Bottom status prompt
                        footerPrompt
                    }
                    .frame(width: min(geo.size.width * 0.90, 420))
                    .frame(maxHeight: .infinity)
                    .background(Color(red: 0.05, green: 0.07, blue: 0.11).ignoresSafeArea())
                    .overlay(
                        Rectangle()
                            .stroke(Color(red: 0.0, green: 0.94, blue: 1.0).opacity(0.2), lineWidth: 1)
                    )
                    .shadow(color: Color.black.opacity(0.6), radius: 24, x: -10, y: 0)
                    .transition(.move(edge: .trailing))
                }

                // Toast notification
                if showCopiedToast {
                    VStack {
                        Spacer()
                        HStack(spacing: 8) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(Color(red: 0.0, green: 1.0, blue: 0.4))
                            Text("LOGS COPIED TO CLIPBOARD")
                                .font(.system(size: 12, weight: .bold, design: .monospaced))
                                .foregroundStyle(Color.white)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(Color.black.opacity(0.9), in: Capsule())
                        .overlay(Capsule().stroke(Color(red: 0.0, green: 1.0, blue: 0.4), lineWidth: 1))
                        .padding(.bottom, 32)
                    }
                    .transition(.opacity.combined(with: .scale))
                    .zIndex(100)
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .consoleLogDidAppend)) { note in
            if let entry = note.object as? ConsoleLogEntry {
                entries.append(entry)
            } else {
                entries = ConsoleLogStore.shared.entries
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .consoleLogDidClear)) { _ in
            entries.removeAll()
        }
        .sheet(isPresented: $showShareSheet) {
            if let url = shareFileUrl {
                ShareSheet(items: [url])
            }
        }
    }

    // MARK: - Header
    private var headerView: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(">_ SSH2_TERMINAL")
                    .font(.system(size: 14, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color(red: 0.0, green: 1.0, blue: 0.4))

                Spacer()

                Text("\(entries.count) lines")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color(red: 0.0, green: 0.94, blue: 1.0))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color(red: 0.0, green: 0.94, blue: 1.0).opacity(0.15), in: Capsule())

                Button {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                        isOpen = false
                    }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Color.gray)
                        .padding(6)
                }
                .buttonStyle(.plain)
            }

            // Action Toolbar (Clear, Copy, Export)
            HStack(spacing: 8) {
                // Clear button
                Button {
                    ConsoleLogStore.shared.clear()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "trash")
                        Text("CLEAR")
                    }
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color(red: 1.0, green: 0.3, blue: 0.4))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(Color(red: 1.0, green: 0.3, blue: 0.4).opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)

                // Copy button
                Button {
                    let dump = ConsoleLogStore.shared.exportPlainText()
                    UIPasteboard.general.string = dump
                    withAnimation {
                        showCopiedToast = true
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
                        withAnimation {
                            showCopiedToast = false
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "doc.on.doc")
                        Text("COPY")
                    }
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color(red: 0.0, green: 0.94, blue: 1.0))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(Color(red: 0.0, green: 0.94, blue: 1.0).opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)

                // Export/Share button
                Button {
                    exportLogsToFile()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "square.and.arrow.up")
                        Text("SHARE")
                    }
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color(red: 0.0, green: 1.0, blue: 0.4))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(Color(red: 0.0, green: 1.0, blue: 0.4).opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)

                Spacer()
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Color(red: 0.03, green: 0.04, blue: 0.07))
    }

    // MARK: - Terminal Log List
    private var terminalLogList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 5) {
                    if entries.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("/* SSH2VPN Terminal Logger Initialized */")
                                .foregroundStyle(Color.gray.opacity(0.7))
                            Text("/* Ready to capture transport events... */")
                                .foregroundStyle(Color.gray.opacity(0.7))
                        }
                        .font(.system(size: 11, design: .monospaced))
                        .padding(12)
                    } else {
                        ForEach(entries) { entry in
                            logRow(entry)
                                .id(entry.id)
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            }
            .background(Color(red: 0.04, green: 0.05, blue: 0.08))
            .onChange(of: entries.count) { _ in
                if autoScroll, let last = entries.last {
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
    }

    // MARK: - Log Row with Hacker Colors
    private func logRow(_ entry: ConsoleLogEntry) -> some View {
        HStack(alignment: .top, spacing: 6) {
            // Timestamp
            Text(entry.formattedTimestamp)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Color.gray.opacity(0.8))

            // Tag badge
            Text("[\(entry.tag)]")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(tagColor(for: entry.level))

            // Message body
            Text(entry.message)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(messageColor(for: entry.level))
                .lineLimit(nil)
                .textSelection(.enabled)
        }
    }

    // MARK: - Colors for log categories
    private func tagColor(for level: ConsoleLogLevel) -> Color {
        switch level {
        case .info: return Color(red: 0.4, green: 0.7, blue: 1.0)
        case .ssh: return Color(red: 0.0, green: 0.94, blue: 1.0)
        case .success: return Color(red: 0.0, green: 1.0, blue: 0.4)
        case .warning: return Color(red: 1.0, green: 0.75, blue: 0.0)
        case .error: return Color(red: 1.0, green: 0.25, blue: 0.35)
        case .system: return Color(red: 0.75, green: 0.4, blue: 1.0)
        case .rawIn: return Color(red: 0.3, green: 1.0, blue: 0.7)
        case .rawOut: return Color(red: 0.9, green: 0.9, blue: 0.3)
        }
    }

    private func messageColor(for level: ConsoleLogLevel) -> Color {
        switch level {
        case .info: return Color(red: 0.85, green: 0.90, blue: 0.95)
        case .ssh: return Color(red: 0.70, green: 0.95, blue: 1.0)
        case .success: return Color(red: 0.70, green: 1.0, blue: 0.8)
        case .warning: return Color(red: 1.0, green: 0.90, blue: 0.6)
        case .error: return Color(red: 1.0, green: 0.5, blue: 0.6)
        case .system: return Color(red: 0.90, green: 0.80, blue: 1.0)
        case .rawIn: return Color(red: 0.80, green: 1.0, blue: 0.9)
        case .rawOut: return Color(red: 1.0, green: 1.0, blue: 0.8)
        }
    }

    // MARK: - Footer Prompt
    private var footerPrompt: some View {
        HStack(spacing: 6) {
            Text("root@ssh2vpn:~#")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(Color(red: 0.0, green: 1.0, blue: 0.4))

            Text("stream active")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Color.gray)

            Spacer()

            Toggle("Auto-scroll", isOn: $autoScroll)
                .labelsHidden()
                .tint(Color(red: 0.0, green: 1.0, blue: 0.4))
                .scaleEffect(0.7)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color(red: 0.02, green: 0.03, blue: 0.05))
    }

    private func exportLogsToFile() {
        let dump = ConsoleLogStore.shared.exportPlainText()
        let tempDir = FileManager.default.temporaryDirectory
        let fileName = "ssh2vpn_logs_\(Int(Date().timeIntervalSince1970)).log"
        let fileUrl = tempDir.appendingPathComponent(fileName)
        try? dump.write(to: fileUrl, atomically: true, encoding: .utf8)
        self.shareFileUrl = fileUrl
        self.showShareSheet = true
    }
}

// MARK: - UIActivityViewController bridge
private struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
