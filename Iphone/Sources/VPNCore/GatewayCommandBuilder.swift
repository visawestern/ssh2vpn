import Foundation

/// Builds a shell command that starts the gateway over the SSH session's
/// stdin/stdout. The script is encoded so its contents cannot be interpreted
/// as shell syntax. Credentials are never part of this command.
public enum GatewayCommandBuilder {
    public static func pythonInline(script: Data, brokerID: String = "") -> String {
        let encoded = script.base64EncodedString()
        let suffix = brokerID.isEmpty ? "" : " --broker-id " + brokerID
        return "python3 -c \"import base64;exec(compile(base64.b64decode('" + encoded + "'),'sshtunnel-gateway.py','exec'))\"" + suffix
    }

    /// Builds a command that writes a native binary to a private temp file
    /// (0700) and executes it — the binary-mode counterpart of `pythonInline`.
    /// The binary is base64-encoded so it travels safely over the SSH channel
    /// and is never interpreted as shell syntax.
    public static func binaryInline(data: Data, brokerID: String = "") -> String {
        let encoded = data.base64EncodedString()
        let suffix = brokerID.isEmpty ? "" : " --broker-id " + brokerID
        return "python3 -c \"import base64,os,stat,tempfile; d=base64.b64decode('" + encoded + "'); fd,p=tempfile.mkstemp(prefix='pvvpn-bin-'); os.write(fd,d); os.close(fd); os.chmod(p,0o700); os.execv(p,['pvvpn-gateway" + suffix + "'])\""
    }
}
