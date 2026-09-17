import SwiftUI
import AppKit
import VPNCore

// MAC-fork Iphone/App/AddServerChooserView.swift: iOS-only SwiftUI API
// (navigationBarTitleDisplayMode, topBar* placements, fullScreenCover,
// presentationDetents) заменены на macOS-эквиваленты. Логика та же.

/// The "Add Server" chooser: the user's own VPS, nothing else. No
/// third-party storefront, no external links, no badges (Guideline 5.6).
struct AddServerChooserView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    /// Set when the user picks "own VPS" — the parent swaps to the manual
    /// AddServerView form.
    var onOwnServer: () -> Void
    /// Set when the user comes back from Safari holding credentials.
    var onImportCredentials: () -> Void

    @State private var showDocs = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    header
                    ownCard
                    footer
                }
                .padding(16)
            }
            .adaptiveCenterColumn()
            .background(Color.appBg)
            .navigationTitle(model.copy.text(.vpsChooseTitle))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(model.copy.text(.cancel)) { dismiss() }
                        .foregroundStyle(Color.sec50)
                }
                // Documentation: the same guide as the main screen's book
                // icon — right where "which VPS?" is being decided, so
                // nobody has to guess what any of this means.
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        showDocs = true
                    } label: {
                        Image(systemName: "book.closed.fill")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Color(red: 0.25, green: 0.45, blue: 0.85))
                    }
                    .accessibilityLabel(model.copy.text(.documentation))
                }
            }
            .sheet(isPresented: $showDocs) {
                NavigationStack {
                    DocsView(language: model.selectedLanguage?.rawValue)
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button {
                                    showDocs = false
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(Color.octGray100)
                                }
                                .accessibilityLabel(model.copy.text(.cancel))
                            }
                        }
                }
            }
        }
    }

    // MARK: - Sections

    private var header: some View {
        Text(model.copy.text(.vpsOwnServerDesc))
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
            // Reuses the visible label: an accessibility hint must speak
            // the user's language, and this button's whole meaning is the
            // paste-import entry point.
            .accessibilityHint(Text(model.copy.text(.vpsHaveCredentials)))
        }
        .padding(.top, 2)
    }
}

struct PressableCardStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .opacity(configuration.isPressed ? 0.9 : 1)
            .animation(.spring(response: 0.3, dampingFraction: 1.0), value: configuration.isPressed)
    }
}
