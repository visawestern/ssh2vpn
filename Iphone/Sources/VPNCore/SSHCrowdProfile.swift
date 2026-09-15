import Foundation

/// Single source of truth for the "crowd" cover story: every handshake byte
/// the app emits must be indistinguishable from a Termux admin's OpenSSH 9.6
/// (tmux + periodic SFTP). TSPU sees the version string and the KEXINIT
/// proposal lists in PLAINTEXT, so these constants are load-bearing — the
/// loopback golden test (SSHCrowdHandshakeTests) asserts the actual wire
/// bytes match them, so the profile can never silently drift from the fork.
public enum SSHCrowdProfile {
    /// Client version banner, byte-identical to OpenSSH 9.6. Sent as the
    /// first line on every connection, before any encryption.
    public static let clientBanner = "SSH-2.0-OpenSSH_9.6"

    /// Protocol keepalive request name — the same global request
    /// `ssh -o ServerAliveInterval` sends. Answered by stock sshd with
    /// SSH_MSG_REQUEST_SUCCESS; no channel open/close dance needed.
    public static let keepaliveRequestName = "keepalive@openssh.com"

    /// Rekey thresholds mirroring OpenSSH's `RekeyLimit default 4G 1h`.
    public static let rekeyByteLimit: UInt64 = 4 * 1024 * 1024 * 1024
    public static let rekeyInterval: TimeInterval = 3600

    /// Expected KEXINIT proposal order on the wire, mirroring OpenSSH 9.6's
    /// RELATIVE order among the primitives NIOSSH implements. Entries the
    /// fork cannot negotiate (PQ-hybrid KEX, CTR ciphers, cert hostkeys) are
    /// deliberately NOT advertised — listing them would break negotiation
    /// when the server picks one — so a byte-exact match against a real
    /// OpenSSH client is out of scope; relative order is what hides us.
    public static let keyExchangeOrder = [
        "curve25519-sha256", "curve25519-sha256@libssh.org",
        "ecdh-sha2-nistp256", "ecdh-sha2-nistp384", "ecdh-sha2-nistp521",
    ]
    public static let hostKeyOrder = [
        "ssh-ed25519",
        "ecdsa-sha2-nistp256", "ecdsa-sha2-nistp384", "ecdsa-sha2-nistp521",
    ]
    /// OpenSSH lists aes128-gcm before aes256-gcm (after the CTR modes the
    /// fork does not implement).
    public static let cipherOrder = [
        "aes128-gcm@openssh.com", "aes256-gcm@openssh.com",
    ]
}
