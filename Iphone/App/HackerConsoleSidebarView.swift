import SwiftUI
import UniformTypeIdentifiers
import VPNCore

// MARK: - Vuexy-style Floating theCustomizer Button

public struct FloatingCustomizerButton: View {
    @Binding var isOpen: Bool
    /// Live count, updated on every log line. (A plain init-time Int would go
    /// stale because the parent view doesn't re-render on log appends.)
    @State private var logCount: Int = ConsoleLogStore.shared.entries.count
    let isConnecting: Bool

    @State private var isGlowing = false

    public init(isOpen: Binding<Bool>, isConnecting: Bool) {
        self._isOpen = isOpen
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
        .onReceive(NotificationCenter.default.publisher(for: .consoleLogDidAppend)) { _ in
            logCount = ConsoleLogStore.shared.entries.count
        }
        .onReceive(NotificationCenter.default.publisher(for: .consoleLogDidClear)) { _ in
            logCount = 0
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
    /// Empty = every tag; otherwise ONLY these tags pass (multi-select).
    @State private var selectedTags: Set<String> = []
    /// Whether the custom type-filter dropdown sheet is open.
    @State private var isTypeDropdownOpen: Bool = false

    public init(isOpen: Binding<Bool>) {
        self._isOpen = isOpen
    }

    /// Distinct tags present in the buffer, top-counted, so the filter chips
    /// stay useful instead of listing tags that never appear.
    private var availableTags: [String] {
        var counts: [String: Int] = [:]
        for e in entries { counts[e.tag, default: 0] += 1 }
        return counts.keys.sorted { counts[$0]! > counts[$1]! }
    }

    private var visibleEntries: [ConsoleLogEntry] {
        guard !selectedTags.isEmpty else { return entries }
        return entries.filter { selectedTags.contains($0.tag) }
    }

    /// Stable per-tag color: each type keeps its own hue across launches
    /// (hash → golden-angle rotation over a vivid palette).
    static func tagColor(_ tag: String) -> Color {
        var hash: UInt64 = 0
        for scalar in tag.unicodeScalars { hash = hash &* 31 &+ UInt64(scalar.value) }
        let hue = Double((hash % 12)) / 12.0
        return Color(hue: hue, saturation: 0.72, brightness: 0.95)
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

                Text(selectedTags.isEmpty
                     ? "\(entries.count) lines"
                     : "\(visibleEntries.count)/\(entries.count) \(selectedTags.count) on")
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

            // Type filter: custom dropdown with MULTI-SELECT colored chips.
            // Each tag has its own stable hue; selection state is shown both
            // in the collapsed capsule (colored dots) and in the list.
            if !availableTags.isEmpty {
                TypeFilterDropdown(
                    availableTags: availableTags,
                    selected: $selectedTags,
                    isOpen: $isTypeDropdownOpen,
                    color: Self.tagColor
                )
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Color(red: 0.03, green: 0.04, blue: 0.07))
        .zIndex(10)
    }

    // MARK: - Terminal Log List
    private var terminalLogList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 5) {
                    if visibleEntries.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("/* SSH2VPN Terminal Logger Initialized */")
                                .foregroundStyle(Color.gray.opacity(0.7))
                            Text(selectedTags.isEmpty
                                 ? "/* Ready to capture transport events... */"
                                 : "/* No entries for the selected types yet */")
                                .foregroundStyle(Color.gray.opacity(0.7))
                        }
                        .font(.system(size: 11, design: .monospaced))
                        .padding(12)
                    } else {
                        // Newest-first: the freshest line is always at the
                        // top, right where the eye lands when the drawer
                        // opens — no scrolling down a growing backlog to see
                        // what just happened. Older entries drift downward.
                        ForEach(visibleEntries.reversed()) { entry in
                            logRow(entry)
                                .id(entry.id)
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            }
            .background(Color(red: 0.04, green: 0.05, blue: 0.08))
            .onChange(of: entries.count) {
                if autoScroll, let newest = entries.last {
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo(newest.id, anchor: .top)
                    }
                }
            }
        }
    }

    // MARK: - Log Row with Hacker Colors (2 lines per entry: meta, then body)
    private func logRow(_ entry: ConsoleLogEntry) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            // Line 1 — date like now + type/tag
            HStack(spacing: 6) {
                Text(entry.formattedTimestamp)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Color.gray.opacity(0.8))

                Text("[\(entry.tag)]")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(Self.tagColor(entry.tag).opacity(0.9))
            }

            // Line 2 — the actual parameters / message body
            Text(entry.message)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(messageColor(for: entry.level))
                .lineLimit(nil)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
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

// MARK: - Multi-select type-filter dropdown (custom, colored chips)
/// Collapsed: a capsule listing either ALL or the selected type dots.
/// Expanded: a panel with one colored chip per tag — tap toggles it in the
/// selection Set; multiple chips may be active at once (AND-free union).
/// "ALL" clears the selection.
struct TypeFilterDropdown: View {
    let availableTags: [String]
    @Binding var selected: Set<String>
    @Binding var isOpen: Bool
    let color: (String) -> Color

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Collapsed trigger
            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                    isOpen.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Color(red: 0.0, green: 0.94, blue: 1.0))

                    if selected.isEmpty {
                        Text("TYPES: ALL")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundStyle(Color(red: 0.0, green: 0.94, blue: 1.0))
                    } else {
                        // Colored dots summarize the active selection.
                        HStack(spacing: 3) {
                            ForEach(selected.sorted(), id: \.self) { tag in
                                Circle()
                                    .fill(color(tag))
                                    .frame(width: 7, height: 7)
                            }
                            Text("TYPES: \(selected.count)")
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .foregroundStyle(Color(red: 0.0, green: 0.94, blue: 1.0))
                        }
                    }

                    Spacer(minLength: 4)

                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Color(red: 0.0, green: 0.94, blue: 1.0).opacity(0.7))
                        .rotationEffect(.degrees(isOpen ? 180 : 0))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(
                    Color(red: 0.0, green: 0.94, blue: 1.0).opacity(0.10),
                    in: Capsule()
                )
                .overlay(
                    Capsule().stroke(Color(red: 0.0, green: 0.94, blue: 1.0).opacity(0.35), lineWidth: 1)
                )
            }
            .buttonStyle(.plain)

            // Expanded panel
            if isOpen {
                VStack(alignment: .leading, spacing: 8) {
                    // ALL chip (clears the filter)
                    allChip

                    // Per-type chips, wrapped via FlowLayout, each in its own
                    // stable hue; selected = filled, unselected = tinted.
                    FlowLayout(spacing: 6) {
                        ForEach(availableTags, id: \.self) { tag in
                            typeChip(tag)
                        }
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color(red: 0.05, green: 0.07, blue: 0.12))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(Color(red: 0.0, green: 0.94, blue: 1.0).opacity(0.25), lineWidth: 1)
                        )
                )
                .transition(.opacity.combined(with: .move(edge: .top)))
                .padding(.top, 6)
            }
        }
    }

    private var allChip: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.12)) {
                selected.removeAll()
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: selected.isEmpty ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 10, weight: .bold))
                Text("ALL")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
            }
            .foregroundStyle(selected.isEmpty ? Color.black : Color(red: 0.0, green: 0.94, blue: 1.0))
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(
                selected.isEmpty
                    ? Color(red: 0.0, green: 0.94, blue: 1.0)
                    : Color(red: 0.0, green: 0.94, blue: 1.0).opacity(0.12),
                in: Capsule()
            )
        }
        .buttonStyle(.plain)
    }

    private func typeChip(_ tag: String) -> some View {
        let isActive = selected.contains(tag)
        let c = color(tag)
        return Button {
            withAnimation(.easeInOut(duration: 0.12)) {
                if isActive { selected.remove(tag) } else { selected.insert(tag) }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: isActive ? "checkmark" : "circle.fill")
                    .font(.system(size: 8, weight: .black))
                Text(tag)
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
            }
            .foregroundStyle(isActive ? Color.black : c)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(isActive ? c : c.opacity(0.16), in: Capsule())
            .overlay(
                Capsule().stroke(c.opacity(isActive ? 0 : 0.55), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}
