import Foundation

/// Orchestrates the save->reload->start sequence that fixes
/// NEVPNErrorDomain Code=1 (configurationInvalid).
///
/// The critical fix: after saveToPreferences completes we must reload
/// preferences before calling startVPNTunnel, otherwise the manager's
/// in-memory state can be out of sync with the network extension and the
/// tunnel fails to start.
public protocol VPNConnectionSaver: AnyObject {
    /// Persists the built configuration. Called before any start.
    func save(configuration: VPNConfiguration, completion: @escaping (VPNConnectionError?) -> Void)
    /// Reloads the persisted configuration so the in-memory manager matches
    /// what the network extension will read. Returns an error if reload fails.
    func reload(completion: @escaping (VPNConnectionError?) -> Void)
}

/// Default no-op conformer used by production; real work happens in the
/// App-target VPNController which subclasses/embeds these responsibilities.
public final class VPNConnectionCoordinator {

    private let saver: VPNConnectionSaver
    private let manager: VPNConnectionManager
    private let stateLock = NSLock()
    private var isConnecting = false

    public init(saver: VPNConnectionSaver, manager: VPNConnectionManager) {
        self.saver = saver
        self.manager = manager
    }

    /// Full connection sequence: build -> save -> reload -> start.
    /// On any failure, `completion` is called with the error and no start
    /// is attempted.
    ///
    /// Guards against re-entrant/double connect: while a connection attempt
    /// is in flight, a second call is rejected with `.alreadyConnected`
    /// instead of racing two save/start chains.
    public func connect(
        profile: VPNProfileInput,
        providerBundleIdentifier: String,
        completion: @escaping (VPNConnectionError?) -> Void
    ) {
        stateLock.lock()
        if isConnecting {
            stateLock.unlock()
            completion(.alreadyConnected)
            return
        }
        isConnecting = true
        stateLock.unlock()

        let configuration: VPNConfiguration
        do {
            configuration = try VPNConfigurationBuilder.build(
                profile: profile,
                providerBundleIdentifier: providerBundleIdentifier
            )
        } catch let error as VPNConfigurationError {
            stateLock.lock(); isConnecting = false; stateLock.unlock()
            completion(map(error))
            return
        } catch {
            stateLock.lock(); isConnecting = false; stateLock.unlock()
            completion(.invalidConfiguration(error.localizedDescription))
            return
        }

        saver.save(configuration: configuration) { [weak self] saveError in
            guard let self = self else { return }
            defer { self.finishAttempt() }
            guard saveError == nil else {
                completion(saveError)
                return
            }

            self.saver.reload { reloadError in
                guard reloadError == nil else {
                    self.finishAttempt()
                    completion(reloadError)
                    return
                }

                self.manager.start(
                    host: profile.host,
                    port: profile.port,
                    username: profile.username,
                    providerBundleIdentifier: providerBundleIdentifier,
                    providerConfiguration: configuration.providerConfiguration,
                    completion: { [weak self] error in
                        self?.finishAttempt()
                        completion(error)
                    }
                )
            }
        }
    }

    /// Immediately tears down any in-flight attempt and stops the manager.
    public func disconnect() {
        stateLock.lock()
        isConnecting = false
        stateLock.unlock()
        manager.stop()
    }

    public var isBusy: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return isConnecting
    }

    private func finishAttempt() {
        stateLock.lock()
        isConnecting = false
        stateLock.unlock()
    }

    private func map(_ error: VPNConfigurationError) -> VPNConnectionError {
        switch error {
        case .emptyHost: return .invalidConfiguration("Empty host")
        case .invalidPort: return .invalidConfiguration("Invalid port")
        case .missingCredentials: return .invalidConfiguration("Missing credentials")
        case .emptyProviderBundleIdentifier: return .invalidConfiguration("Empty provider bundle identifier")
        }
    }
}
