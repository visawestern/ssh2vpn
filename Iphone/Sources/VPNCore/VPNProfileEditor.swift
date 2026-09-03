/// A server profile as edited in the form. Fields map 1:1 to the UI and are
/// deliberately plain so this type stays free of any Apple framework imports
/// and is fully testable on macOS.
public struct EditableServerProfile: Equatable {
    public var host: String
    public var port: Int
    public var username: String
    public var password: String
    public var privateKey: String
    public var hostKey: String

    public init(
        host: String,
        port: Int,
        username: String,
        password: String,
        privateKey: String,
        hostKey: String
    ) {
        self.host = host
        self.port = port
        self.username = username
        self.password = password
        self.privateKey = privateKey
        self.hostKey = hostKey
    }
}

/// Pure logic for editing a saved server profile.
///
/// The edit form intentionally does not pre-fill the secret fields (we do not
/// echo stored passwords/keys back into the UI). So when the user leaves a
/// secret field blank we must keep the previously stored value; blanks only
/// mean "unchanged", never "clear this secret".
public enum VPNProfileEditor {
    /// Merges `edited` fields over `existing`, preserving any secret that was
    /// left blank in the edit form.
    public static func merge(existing: EditableServerProfile, edited: EditableServerProfile) -> EditableServerProfile {
        EditableServerProfile(
            host: edited.host,
            port: edited.port,
            username: edited.username,
            password: edited.password.isEmpty ? existing.password : edited.password,
            privateKey: edited.privateKey.isEmpty ? existing.privateKey : edited.privateKey,
            hostKey: edited.hostKey.isEmpty ? existing.hostKey : edited.hostKey
        )
    }
}
