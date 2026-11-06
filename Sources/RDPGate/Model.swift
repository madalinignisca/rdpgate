import Foundation

// MARK: - Persisted model

enum ProxyMode: String, Codable, CaseIterable, Identifiable {
    case direct        // no proxy
    case useDefault    // the proxy configured in Settings
    case custom        // this target's own proxy

    var id: String { rawValue }

    var label: String {
        switch self {
        case .direct:     return "Direct (no proxy)"
        case .useDefault: return "Default proxy"
        case .custom:     return "Custom proxy"
        }
    }
}

struct RDPTarget: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var name: String = ""
    var host: String = ""
    var port: Int = 3389
    var username: String = ""
    var domain: String = ""

    /// When set, username, domain and password come from this shared identity
    /// and the target's own credential fields are ignored entirely.
    var identityID: UUID? = nil

    var proxyMode: ProxyMode = .useDefault
    var proxyHost: String = ""
    var proxyPort: Int = 1080

    /// Password is in the keychain, not here. This only records intent.
    var savePassword: Bool = false

    /// Send resolution updates when the window is resized. Needs the Display
    /// Control channel, which newer Windows tends to negotiate only when the
    /// RDP8 graphics pipeline is also on — hence `enableGFX`.
    var dynamicResolution: Bool = true
    var enableGFX: Bool = true

    /// Empty means "use dynamic resolution". Set e.g. 1920x1080 to pin it.
    var fixedSize: String = ""

    var audio: Bool = false
    var redirectClipboard: Bool = true
    var redirectDrives: Bool = false
    var extraFlags: String = ""

    var displayName: String { name.isEmpty ? host : name }

    /// A sibling target with the same settings but its own identity.
    ///
    /// The password is deliberately not carried over: keychain items are keyed by
    /// UUID, and copying one would duplicate a secret as a side effect of a UI
    /// convenience. `savePassword` is cleared so the copy never claims a keychain
    /// entry it does not have.
    func duplicated() -> RDPTarget {
        var copy = self
        copy.id = UUID()
        copy.name = "\(displayName) copy"
        copy.savePassword = false
        return copy
    }

    /// Resolved proxy for this target, or nil for a direct connection.
    func proxy(default settings: AppSettings) -> (host: String, port: Int)? {
        switch proxyMode {
        case .direct:
            return nil
        case .useDefault:
            let h = settings.defaultProxyHost.trimmingCharacters(in: .whitespaces)
            return h.isEmpty ? nil : (h, settings.defaultProxyPort)
        case .custom:
            let h = proxyHost.trimmingCharacters(in: .whitespaces)
            return h.isEmpty ? nil : (h, proxyPort)
        }
    }
}

struct AppSettings: Codable, Equatable {
    /// Optional. Targets set to "Default proxy" use this; leave blank to make
    /// them direct connections instead.
    var defaultProxyHost: String = ""
    var defaultProxyPort: Int = 1080

    /// Empty means auto-detect from the usual Homebrew locations.
    var freerdpPath: String = ""

    /// Probe reachability before launching, so a dead path fails in seconds
    /// with a reason instead of a window that hangs and disappears.
    var preflight: Bool = true
}

/// Credentials shared by many targets — typically one AD account used on every
/// server in a domain. The password is in the keychain under `Keychain.Kind.identity`.
struct Identity: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var name: String = ""
    var username: String = ""
    var domain: String = ""
    var savePassword: Bool = false

    /// DOMAIN\user, the way Windows writes it.
    var summary: String {
        let u = username.trimmingCharacters(in: .whitespaces)
        let d = domain.trimmingCharacters(in: .whitespaces)
        if u.isEmpty { return "no username" }
        return d.isEmpty ? u : "\(d)\\\(u)"
    }

    var displayName: String { name.isEmpty ? summary : name }
}

struct Config: Codable {
    var settings: AppSettings = AppSettings()
    var targets: [RDPTarget] = []
    /// Added after targets already existed in people's config files — see
    /// `init(from:)` for why that matters.
    var identities: [Identity] = []
}

extension Config {
    /// Hand-written because synthesized decoding throws on a missing key even
    /// when the property has a default. A config.json from before identities
    /// existed would then fail to decode, `Store.load` would return an empty
    /// Config, and the next save would overwrite every target.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        settings = try c.decode(AppSettings.self, forKey: .settings)
        targets = try c.decode([RDPTarget].self, forKey: .targets)
        identities = try c.decodeIfPresent([Identity].self, forKey: .identities) ?? []
    }
}

// MARK: - Credential resolution
//
// Every decision about which username, domain and password a target uses is
// made here, as pure functions of Config, so it can be tested without SwiftUI,
// the keychain or the user's real config file.

enum CredentialSource: Equatable {
    case own
    case identity(Identity)
    /// identityID points at nothing (e.g. hand-edited JSON). Deliberately not
    /// a fallback to the target's own fields: those may be stale.
    case missingIdentity
}

extension Config {
    func identity(_ id: UUID) -> Identity? {
        identities.first { $0.id == id }
    }

    func credentialSource(for target: RDPTarget) -> CredentialSource {
        guard let iid = target.identityID else { return .own }
        return identity(iid).map(CredentialSource.identity) ?? .missingIdentity
    }

    /// The target as FreeRDP should see it: username and domain replaced by the
    /// identity's, or blanked when the identity is missing so FreeRDP prompts.
    func effectiveTarget(_ target: RDPTarget) -> RDPTarget {
        var t = target
        switch credentialSource(for: target) {
        case .own:
            break
        case .identity(let i):
            t.username = i.username
            t.domain = i.domain
        case .missingIdentity:
            t.username = ""
            t.domain = ""
        }
        return t
    }

    /// Which keychain item holds the password for this target, if any.
    func passwordRef(for target: RDPTarget) -> (kind: Keychain.Kind, id: UUID)? {
        switch credentialSource(for: target) {
        case .own:                return target.savePassword ? (.target, target.id) : nil
        case .identity(let i):    return i.savePassword ? (.identity, i.id) : nil
        case .missingIdentity:    return nil
        }
    }

    func targets(using identityID: UUID) -> [RDPTarget] {
        targets.filter { $0.identityID == identityID }
    }

    /// Nil when the target may be saved.
    func validate(_ target: RDPTarget) -> String? {
        if let iid = target.identityID, identity(iid) == nil {
            return "The selected identity no longer exists. Pick another or use this target's own credentials."
        }
        return nil
    }
}

// MARK: - Storage

enum Store {
    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("RDPGate", isDirectory: true)
    }

    static var file: URL { directory.appendingPathComponent("config.json") }

    enum LoadResult {
        case loaded(Config)
        /// Nothing at the path at all: a first run. Safe to start empty and save.
        case fresh
        /// Something is there that we cannot use. It must never be overwritten.
        case unreadable(String)
    }

    /// "Could not read" and "nothing there" used to be the same answer — an
    /// empty Config — and the next save then wrote that empty list over the
    /// user's file. Only a confirmed absence counts as a first run.
    static func load(from url: URL = file) -> LoadResult {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            return isAbsent(url) ? .fresh : .unreadable(error.localizedDescription)
        }
        do {
            return .loaded(try JSONDecoder().decode(Config.self, from: data))
        } catch {
            return .unreadable(String(describing: error))
        }
    }

    /// True only when there is no directory entry at all. `lstat` does not
    /// follow links: a dangling symlink (say, into a dotfiles repo that is not
    /// mounted) also reads as "no such file", but an atomic save would replace
    /// the link with a plain file, so it must count as present.
    private static func isAbsent(_ url: URL) -> Bool {
        var st = stat()
        return lstat(url.path, &st) != 0 && errno == ENOENT
    }

    /// Throws so that callers changing credentials can order keychain writes
    /// around a config write that is known to have succeeded.
    static func save(_ cfg: Config, to url: URL = file) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try enc.encode(cfg)
        try data.write(to: url, options: .atomic)
    }
}

// MARK: - Per-target status

enum TargetStatus: Equatable {
    case idle
    case testing
    case reachable(String)
    case unreachable(String)
}

// MARK: - App model

@MainActor
final class AppModel: ObservableObject {
    @Published var config: Config
    @Published var status: [UUID: TargetStatus] = [:]

    /// Set when config.json exists but could not be read. The app then runs
    /// read-only for the session: the file is the user's data, and an empty
    /// in-memory list must never be saved over it.
    @Published private(set) var loadError: String?

    let storeURL: URL

    init(storeURL: URL = Store.file) {
        self.storeURL = storeURL
        switch Store.load(from: storeURL) {
        case .loaded(let cfg):
            config = cfg
        case .fresh:
            config = Config()
        case .unreadable(let why):
            config = Config()
            loadError = why
        }
    }

    // Ordering rule for anything that pairs a config write with a keychain write:
    // adding a secret → keychain first, then config; removing one → config
    // first, then keychain. A crash in between then leaves at worst an unused
    // keychain item, never config that points at a password already deleted.
    // Callers in the editors follow the same rule.

    /// Nil on success, otherwise a message fit to show.
    @discardableResult
    func persist() -> String? {
        // Every config write goes through here, so this one check is the
        // read-only mode.
        if loadError != nil {
            return "Not saved: config.json could not be read when RDPGate started, so it is left untouched. Fix or restore it, then quit and reopen RDPGate."
        }
        do {
            try Store.save(config, to: storeURL)
            return nil
        } catch {
            return "Could not save the configuration: \(error.localizedDescription)"
        }
    }

    /// Apply `change`, persist, and roll the in-memory config back if the write fails.
    private func commit(_ change: (inout Config) -> Void) -> String? {
        let before = config
        change(&config)
        if let err = persist() {
            config = before
            return err
        }
        return nil
    }

    @discardableResult
    func upsert(_ target: RDPTarget) -> String? {
        if let err = config.validate(target) { return err }
        return commit { cfg in
            if let i = cfg.targets.firstIndex(where: { $0.id == target.id }) {
                cfg.targets[i] = target
            } else {
                cfg.targets.append(target)
            }
        }
    }

    @discardableResult
    func remove(_ target: RDPTarget) -> String? {
        if let err = commit({ $0.targets.removeAll { $0.id == target.id } }) { return err }
        status[target.id] = nil
        // Only the target's own item. Shared identity passwords live under a
        // different keychain service and cannot be reached from here.
        guard Keychain.delete(for: target.id, kind: .target) else {
            return "Target removed, but its saved password could not be deleted from the keychain."
        }
        return nil
    }

    @discardableResult
    func upsertIdentity(_ identity: Identity) -> String? {
        commit { cfg in
            if let i = cfg.identities.firstIndex(where: { $0.id == identity.id }) {
                cfg.identities[i] = identity
            } else {
                cfg.identities.append(identity)
            }
        }
    }

    /// Refuses while any target still uses the identity. Checked here, at the
    /// moment of deletion, not just by disabling a button that may be stale.
    @discardableResult
    func removeIdentity(_ identity: Identity) -> String? {
        let users = config.targets(using: identity.id)
        guard users.isEmpty else {
            return "Still used by: " + users.map(\.displayName).joined(separator: ", ")
        }
        if let err = commit({ $0.identities.removeAll { $0.id == identity.id } }) { return err }
        guard Keychain.delete(for: identity.id, kind: .identity) else {
            return "Identity removed, but its saved password could not be deleted from the keychain."
        }
        return nil
    }

    /// Resolve the FreeRDP binary: explicit setting first, then Homebrew paths.
    func resolveFreeRDP() -> String? {
        let explicit = config.settings.freerdpPath.trimmingCharacters(in: .whitespaces)
        if !explicit.isEmpty {
            return FileManager.default.isExecutableFile(atPath: explicit) ? explicit : nil
        }
        let candidates = [
            "/opt/homebrew/bin/sdl-freerdp",   // Apple silicon Homebrew
            "/usr/local/bin/sdl-freerdp",      // Intel Homebrew
            "/opt/homebrew/bin/sdl-freerdp3",
            "/usr/local/bin/sdl-freerdp3",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    // MARK: Reachability

    /// Test one target. Uses its own proxy if it has one, otherwise direct TCP.
    func test(_ target: RDPTarget, then continuation: (@MainActor (Bool) -> Void)? = nil) {
        status[target.id] = .testing
        let proxy = target.proxy(default: config.settings)
        let host = target.host
        let port = target.port
        let id = target.id

        Task.detached {
            let outcome: ProbeOutcome
            let via: String
            if let proxy {
                outcome = Net.socks5Probe(proxyHost: proxy.host, proxyPort: proxy.port,
                                          host: host, port: port, timeout: 8)
                via = "via \(proxy.host):\(proxy.port)"
            } else {
                outcome = Net.checkTCP(host: host, port: port, timeout: 8)
                via = "direct"
            }

            await MainActor.run {
                switch outcome {
                case .success:
                    self.status[id] = .reachable("\(host):\(port) reachable \(via)")
                    continuation?(true)
                case .failure(let why):
                    self.status[id] = .unreachable(why)
                    continuation?(false)
                }
            }
        }
    }

    /// Connect, optionally pre-flighting first.
    func connect(_ target: RDPTarget) {
        guard let binary = resolveFreeRDP() else {
            status[target.id] = .unreachable("FreeRDP not found — brew install freerdp")
            return
        }

        let go: @MainActor () -> Void = { [weak self] in
            guard let self else { return }
            // Resolved at launch time, so an identity's password change applies
            // to every target using it on the next connect.
            let effective = self.config.effectiveTarget(target)
            let password = self.config.passwordRef(for: target)
                .flatMap { Keychain.load(for: $0.id, kind: $0.kind) }
            if let err = Launcher.launch(binary: binary,
                                         target: effective,
                                         settings: self.config.settings,
                                         password: password) {
                self.status[target.id] = .unreachable(err)
            } else {
                self.status[target.id] = .idle
            }
        }

        if config.settings.preflight {
            test(target) { ok in if ok { go() } }
        } else {
            go()
        }
    }
}
