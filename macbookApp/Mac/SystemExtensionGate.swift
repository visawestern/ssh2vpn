import Foundation
import SystemExtensions
import VPNCore

/// MAC-only: активация packet-tunnel SYSTEM extension.
///
/// На macOS 10.15+ NetworkExtension живёт в Contents/Library/SystemExtensions
/// и не стартует, пока пользователь один раз не разрешит его в
/// System Settings → General → Login Items & Extensions. Этот гейт
/// вызывается из `connect()` до любых стартов туннеля: без активной
/// экстеншн startVPNTunnel не с кем разговаривать.
///
/// Повторный запрос для уже активной экстеншн дёшев (сразу .completed).
@MainActor
final class MacSystemExtensionGate {
    static let shared = MacSystemExtensionGate()
    static let extensionIdentifier = "com.ssh2vpn.mac.packet-tunnel"

    enum Outcome {
        case completed
        case needsApproval
        case rebootRequired
        case failed(String)
    }

    /// nil = можно стартовать туннель, String = показать как .failed с текстом.
    func ensureActive() async -> String? {
        switch await requestActivation() {
        case .completed:
            return nil
        case .needsApproval:
            ConsoleLogStore.shared.log(level: .warning, tag: "SYSEXT",
                message: "system extension needs user approval — System Settings → General → Login Items & Extensions → enable SSH2VPN, then Connect again")
            return "System extension not approved — enable SSH2VPN in System Settings → General → Login Items & Extensions, then tap Connect again"
        case .rebootRequired:
            return "System extension will complete after reboot — reboot your Mac, then tap Connect"
        case .failed(let message):
            ConsoleLogStore.shared.log(level: .error, tag: "SYSEXT",
                message: "system extension activation failed: \(message)")
            return "System extension activation failed: \(message)"
        }
    }

    // MARK: - Private

    /// Удерживает делегата живым, пока запрос не завершится
    /// (OSSystemExtensionRequest не retains delegate).
    private var pendingDelegate: ActivationDelegate?

    private func requestActivation() async -> Outcome {
        await withCheckedContinuation { continuation in
            let box = ResumeBox(continuation)
            let request = OSSystemExtensionRequest.activationRequest(
                forExtensionWithIdentifier: Self.extensionIdentifier, queue: .main)
            let delegate = ActivationDelegate { [weak self] outcome in
                self?.pendingDelegate = nil
                box.resume(outcome)
            }
            pendingDelegate = delegate
            request.delegate = delegate
            OSSystemExtensionManager.shared.submitRequest(request)
            // Не висим вечно, если пользователь проигнорировал запрос:
            // через 3 минуты отдаём управление с понятной инструкцией.
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(180))
                box.resume(.failed("timed out waiting for approval — enable SSH2VPN in System Settings → General → Login Items & Extensions, then tap Connect again"))
            }
        }
    }

    /// Single-resume guard: колбэки делегата + watchdog могут прийти оба.
    private final class ResumeBox {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Outcome, Never>?
        init(_ c: CheckedContinuation<Outcome, Never>) { continuation = c }
        func resume(_ outcome: Outcome) {
            lock.lock()
            let c = continuation
            continuation = nil
            lock.unlock()
            c?.resume(returning: outcome)
        }
    }

    private final class ActivationDelegate: NSObject, OSSystemExtensionRequestDelegate {
        private let finish: (Outcome) -> Void
        init(finish: @escaping (Outcome) -> Void) { self.finish = finish }

        func request(_ request: OSSystemExtensionRequest,
                     actionForReplacingExtension existing: OSSystemExtensionProperties,
                     withExtension ext: OSSystemExtensionProperties) -> OSSystemExtensionRequest.ReplacementAction {
            // Обновление экстеншн при новой сборке — заменяем молча.
            .replace
        }

        func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
            ConsoleLogStore.shared.log(level: .warning, tag: "SYSEXT",
                message: "approval needed: System Settings → General → Login Items & Extensions")
            finish(.needsApproval)
        }

        func request(_ request: OSSystemExtensionRequest,
                     didFinishWithResult result: OSSystemExtensionRequest.Result) {
            switch result {
            case .completed:
                ConsoleLogStore.shared.log(level: .success, tag: "SYSEXT",
                    message: "system extension active")
                finish(.completed)
            case .willCompleteAfterReboot:
                finish(.rebootRequired)
            @unknown default:
                finish(.failed("unknown activation result"))
            }
        }

        func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
            finish(.failed(error.localizedDescription))
        }
    }
}
