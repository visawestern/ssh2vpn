import SwiftUI
import VPNCore

/// Paste-anything credential import. The parser runs fully on-device; the
/// parsed fields appear in an EDITABLE preview so a wrong parse never saves
/// silently. Fields validate through the same ProfileValidator as manual entry.
struct ImportCredentialsView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var raw = ""
    @State private var parsed: CredentialParser.Parsed?
    @State private var host = ""
    @State private var port = "22"
    @State private var username = "root"
    @State private var password = ""
    @State private var errorMessage: String?
    @State private var showError = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    if parsed == nil {
                        pasteSection
                    } else {
                        previewSection
                    }
                }
                .padding(16)
            }
            .adaptiveCenterColumn()
            .background(Color.appBg)
            .navigationTitle(model.copy.text(parsed == nil ? .importTitle : .importParsedTitle))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(model.copy.text(.cancel)) { dismiss() }
                        .foregroundStyle(Color.sec50)
                }
            }
            .alert(model.copy.text(.invalidInput), isPresented: $showError) {
                Button(model.copy.text(.ok), role: .cancel) { }
            } message: {
                Text(errorMessage ?? "")
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    // MARK: - Paste (before parse)

    private var pasteSection: some View {
        VStack(spacing: 14) {
            Text(model.copy.text(.importSubtitle))
                .font(.openSans(13))
                .foregroundStyle(Color.octGray60)
                .multilineTextAlignment(.center)

            ZStack(alignment: .topLeading) {
                if raw.isEmpty {
                    Text(model.copy.text(.importPlaceholder))
                        .font(.openSans(13))
                        .foregroundStyle(Color.octGray40)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $raw)
                    .font(.system(.footnote, design: .monospaced))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .frame(minHeight: 120)
                    .padding(6)
                    .accessibilityLabel(Text(model.copy.text(.importTitle)))
            }
            .background(Color.octGray0, in: RoundedRectangle(cornerRadius: 16))
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(Color.octGray05, lineWidth: 1)
            )

            Button {
                parseNow()
            } label: {
                Text(model.copy.text(.importParseButton))
                    .font(.openSans(16, weight: .semibold))
                    .foregroundStyle(Color.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 15)
                    .background(raw.isEmpty ? Color.sec50.opacity(0.4) : Color.sec50,
                                in: RoundedRectangle(cornerRadius: 16))
            }
            .buttonStyle(PressableCardStyle())
            .disabled(raw.isEmpty)
        }
    }

    // MARK: - Editable preview (after parse)

    private var previewSection: some View {
        VStack(spacing: 14) {
            VStack(spacing: 6) {
                fieldRow(title: model.copy.text(.address),
                        placeholder: model.copy.text(.addressPlaceholder),
                        text: $host)
                fieldRow(title: model.copy.text(.sshPort),
                        placeholder: model.copy.text(.portPlaceholder),
                        text: $port)
                fieldRow(title: model.copy.text(.username),
                        placeholder: model.copy.text(.usernamePlaceholder),
                        text: $username)
                secureRow(title: model.copy.text(.passwordOptional),
                          placeholder: model.copy.text(.passwordPlaceholder),
                          text: $password)
            }
            .padding(12)
            .background(Color.octGray0, in: RoundedRectangle(cornerRadius: 16))

            Button {
                save()
            } label: {
                Text(model.copy.text(.importSave))
                    .font(.openSans(16, weight: .semibold))
                    .foregroundStyle(Color.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 15)
                    .background(Color.sec50, in: RoundedRectangle(cornerRadius: 16))
            }
            .buttonStyle(PressableCardStyle())

            Button(model.copy.text(.cancel)) {
                parsed = nil
                raw = ""
            }
            .font(.openSans(13))
            .foregroundStyle(Color.octGray60)
            .buttonStyle(.plain)
        }
    }

    // MARK: - Actions

    private func parseNow() {
        do {
            let result = try CredentialParser.parse(raw)
            parsed = result
            host = result.host
            port = String(result.port)
            username = result.username
            password = result.password ?? ""
        } catch {
            errorMessage = model.copy.text(.importParseFailed)
            showError = true
        }
    }

    private func save() {
        do {
            let validHost = try ProfileValidator.validateHost(host)
            let validPort = try ProfileValidator.validatePort(port)
            let validUsername = try ProfileValidator.validateUsername(username)
            try ProfileValidator.validateCredentials(password: password, privateKey: "")

            let profile = ServerProfile(
                id: UUID().uuidString,
                name: validHost,
                host: validHost,
                port: validPort,
                username: validUsername,
                hostKey: "",
                dnsServers: [],
                hasPassword: !password.isEmpty,
                hasPrivateKey: false,
                password: password.isEmpty ? nil : password,
                privateKey: nil
            )
            model.saveServer(profile)
            model.serverName = validHost
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
            showError = true
        }
    }

    // MARK: - Field rows (mirror AddServerView styling)

    private func fieldRow(title: String, placeholder: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.openSans(11, weight: .semibold))
                .foregroundStyle(Color.octGray60)
            TextField(placeholder, text: text)
                .font(.openSans(14))
                .foregroundStyle(Color.octGray100)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(Color.appBg, in: RoundedRectangle(cornerRadius: 10))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        }
    }

    private func secureRow(title: String, placeholder: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.openSans(11, weight: .semibold))
                .foregroundStyle(Color.octGray60)
            SecureField(placeholder, text: text)
                .font(.openSans(14))
                .foregroundStyle(Color.octGray100)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(Color.appBg, in: RoundedRectangle(cornerRadius: 10))
                .textInputAutocapitalization(.never)
        }
    }
}
