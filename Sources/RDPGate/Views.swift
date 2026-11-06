import SwiftUI

// MARK: - Menu bar panel

struct MenuContent: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Targets").font(.headline)
                Spacer()
                Button {
                    openWindow(id: "editor", value: RDPTarget())
                } label: {
                    Image(systemName: "plus")
                }
                .controlSize(.small)
                .help("Add a target")
            }

            if let loadError = model.loadError {
                VStack(alignment: .leading, spacing: 4) {
                    Label("config.json could not be read — changes will not be saved",
                          systemImage: "exclamationmark.octagon.fill")
                        .font(.caption.bold())
                    Text(loadError)
                        .font(.caption2.monospaced())
                        .lineLimit(4)
                        .textSelection(.enabled)
                    Text(model.storeURL.path)
                        .font(.caption2.monospaced())
                        .textSelection(.enabled)
                    Text("The file is left untouched. Fix or restore it, then quit and reopen RDPGate.")
                        .font(.caption2)
                    Button("Reveal in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([model.storeURL])
                    }
                    .controlSize(.small)
                }
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
                .padding(8)
                .background(.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
            }

            if model.resolveFreeRDP() == nil {
                Label("FreeRDP not found — install it with:  brew install freerdp",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if model.config.targets.isEmpty {
                Text("No targets yet. Use + to add one.")
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.vertical, 6)
            } else {
                ForEach(model.config.targets) { target in
                    TargetRow(target: target)
                    if target.id != model.config.targets.last?.id { Divider() }
                }
            }

            Divider()

            HStack {
                Button("Settings…") { openWindow(id: "settings") }
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
            }
            .controlSize(.small)
        }
        .padding(14)
        .frame(width: 400)
    }
}

struct TargetRow: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    let target: RDPTarget

    private var status: TargetStatus { model.status[target.id] ?? .idle }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text(target.displayName).font(.subheadline).bold()
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if case .testing = status {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Test") { model.test(target) }.controlSize(.small)
                }
                Button("Connect") { model.connect(target) }
                    .controlSize(.small)
                    .disabled(model.resolveFreeRDP() == nil)
                Button {
                    openWindow(id: "editor", value: target)
                } label: {
                    Image(systemName: "pencil")
                }
                .controlSize(.small)
            }

            switch status {
            case .idle, .testing:
                EmptyView()
            case .reachable(let msg):
                Label(msg, systemImage: "checkmark.circle.fill")
                    .font(.caption).foregroundStyle(.green)
                    .fixedSize(horizontal: false, vertical: true)
            case .unreachable(let msg):
                Label(msg, systemImage: "xmark.circle.fill")
                    .font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 2)
    }

    private var subtitle: String {
        var bits = ["\(target.host):\(target.port)"]
        if case .missingIdentity = model.config.credentialSource(for: target) {
            bits.append("identity missing")
        } else {
            let eff = model.config.effectiveTarget(target)
            let who = [eff.domain, eff.username].filter { !$0.isEmpty }.joined(separator: "\\")
            if !who.isEmpty { bits.append(who) }
        }
        if let proxy = target.proxy(default: model.config.settings) {
            bits.append("via \(proxy.host):\(proxy.port)")
        } else {
            bits.append("direct")
        }
        return bits.joined(separator: " · ")
    }
}

// MARK: - Settings

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Form {
            Section {
                if model.config.identities.isEmpty {
                    Text("None yet. An identity holds a username, domain and password that many targets can share — change the password once and every target using it follows.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(model.config.identities) { identity in
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(identity.displayName)
                            Text(identitySubtitle(identity))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button {
                            openWindow(id: "identity", value: identity)
                        } label: {
                            Image(systemName: "pencil")
                        }
                        .controlSize(.small)
                    }
                }
            } header: {
                HStack {
                    Text("Shared identities")
                    Spacer()
                    Button {
                        openWindow(id: "identity", value: Identity())
                    } label: {
                        Image(systemName: "plus")
                    }
                    .controlSize(.small)
                    .help("Add a shared identity")
                }
            }

            Section("Default SOCKS5 proxy (optional)") {
                Text("Targets set to “Default proxy” use this. Leave the host blank and they connect directly instead.")
                    .font(.caption).foregroundStyle(.secondary)
                TextField("Host", text: $model.config.settings.defaultProxyHost)
                TextField("Port", value: $model.config.settings.defaultProxyPort,
                          format: .number.grouping(.never))
            }

            Section("Behaviour") {
                Toggle("Check reachability before connecting", isOn: $model.config.settings.preflight)
                Text("Fails in seconds with a reason instead of opening a window that hangs and disappears when the path is down.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("FreeRDP") {
                TextField("Binary path (blank = auto-detect)", text: $model.config.settings.freerdpPath)
                Text(model.resolveFreeRDP() ?? "Not found. Install with: brew install freerdp")
                    .font(.caption)
                    .foregroundStyle(model.resolveFreeRDP() == nil ? .red : .secondary)
                    .textSelection(.enabled)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .padding()
        .onChange(of: model.config.settings) { _, _ in model.persist() }
    }

    private func identitySubtitle(_ identity: Identity) -> String {
        let n = model.config.targets(using: identity.id).count
        return "\(identity.summary) · \(n) target\(n == 1 ? "" : "s")"
    }
}

// MARK: - Identity editor

struct IdentityEditor: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State var identity: Identity
    /// Write-only: the stored password is never read back into this view.
    @State private var password: String = ""
    @State private var hasSavedPassword = false
    @State private var error: String?

    private var isExisting: Bool { model.config.identity(identity.id) != nil }
    private var users: [RDPTarget] { model.config.targets(using: identity.id) }

    var body: some View {
        Form {
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Identity") {
                TextField("Name, e.g. CORP admin", text: $identity.name)
                TextField("Username", text: $identity.username)
                TextField("Domain (optional)", text: $identity.domain)
            }

            Section("Password") {
                Toggle("Save password in the macOS keychain", isOn: $identity.savePassword)
                if identity.savePassword {
                    SecureField(hasSavedPassword ? "Password (blank = keep the saved one)" : "Password",
                                text: $password)
                    Text("Stored once in your login keychain and used by every target that picks this identity.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("FreeRDP will prompt for the password on each connection." +
                         (hasSavedPassword ? " The saved password is deleted when you save." : ""))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            if isExisting {
                Section("Used by") {
                    if users.isEmpty {
                        Text("No targets").foregroundStyle(.secondary)
                    } else {
                        ForEach(users) { Text($0.displayName) }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .padding()
        .onAppear { hasSavedPassword = Keychain.exists(for: identity.id, kind: .identity) }
        .toolbar {
            ToolbarItemGroup {
                if isExisting {
                    Button("Delete", role: .destructive, action: delete)
                        .disabled(!users.isEmpty)
                        .help(users.isEmpty ? "Delete this identity" : "Still used by \(users.count) target(s)")
                }
                Button("Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    // A ticked "Save password" with nothing stored and nothing typed
                    // would claim a keychain item that does not exist.
                    .disabled(identity.username.trimmingCharacters(in: .whitespaces).isEmpty
                              || (identity.savePassword && !hasSavedPassword && password.isEmpty))
            }
        }
    }

    private func save() {
        error = nil
        if identity.savePassword {
            // Secret first, then the config that relies on it. Blank keeps
            // whatever is stored — no keychain call at all.
            if !password.isEmpty,
               !Keychain.save(password, for: identity.id, kind: .identity) {
                error = "Could not save the password to the keychain. Nothing was changed."
                return
            }
            if let err = model.upsertIdentity(identity) { error = err; return }
        } else {
            // Config first, then remove the secret it no longer points at.
            if let err = model.upsertIdentity(identity) { error = err; return }
            if !Keychain.delete(for: identity.id, kind: .identity) {
                error = "Saved, but the old password could not be deleted from the keychain."
                return
            }
        }
        dismiss()
    }

    private func delete() {
        if let err = model.removeIdentity(identity) {
            error = err
        } else {
            dismiss()
        }
    }
}

// MARK: - Target editor

struct TargetEditor: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow

    @State var target: RDPTarget
    @State private var password: String = ""
    @State private var loadedPassword = false
    @State private var error: String?

    private var isExisting: Bool {
        model.config.targets.contains { $0.id == target.id }
    }

    var body: some View {
        Form {
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Connection") {
                TextField("Name", text: $target.name)
                TextField("Host", text: $target.host)
                TextField("Port", value: $target.port, format: .number.grouping(.never))
            }

            Section("Network path") {
                Picker("Route", selection: $target.proxyMode) {
                    ForEach(ProxyMode.allCases) { Text($0.label).tag($0) }
                }
                if target.proxyMode == .custom {
                    TextField("Proxy host", text: $target.proxyHost)
                    TextField("Proxy port", value: $target.proxyPort,
                              format: .number.grouping(.never))
                }
                Text("Hostnames are sent to the proxy to resolve, so internal names that do not resolve on this Mac still work.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Credentials") {
                // UUID? tags must match the selection type exactly, or the
                // picker silently shows nothing selected.
                Picker("Use", selection: $target.identityID) {
                    Text("This target's own").tag(UUID?.none)
                    ForEach(model.config.identities) { identity in
                        Text("\(identity.displayName) (\(identity.summary))").tag(UUID?.some(identity.id))
                    }
                    if case .missingIdentity = model.config.credentialSource(for: target) {
                        Text("Identity missing").tag(target.identityID)
                    }
                }

                switch model.config.credentialSource(for: target) {
                case .own:
                    TextField("Username (blank = FreeRDP asks)", text: $target.username)
                    TextField("Domain (optional)", text: $target.domain)
                    Toggle("Save password in the macOS keychain", isOn: $target.savePassword)
                    if target.savePassword {
                        SecureField("Password", text: $password)
                        Text("Stored in your login keychain, readable only while the Mac is unlocked, and passed to FreeRDP over stdin — never on the command line, where other processes could read it.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("FreeRDP will prompt for the password on each connection.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                case .identity(let identity):
                    LabeledContent("Signs in as", value: identity.summary)
                    Text(identity.savePassword
                         ? "Password comes from the shared identity's keychain item. Edit it in Settings → Shared identities."
                         : "The identity has no saved password — FreeRDP will prompt on each connection.")
                        .font(.caption).foregroundStyle(.secondary)
                    if target.savePassword || Keychain.exists(for: target.id, kind: .target) {
                        Text("Saving removes this target's own saved password; it is no longer used.")
                            .font(.caption).foregroundStyle(.orange)
                    }
                case .missingIdentity:
                    Label("The identity this target used no longer exists. Pick another, or switch to this target's own credentials.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .onChange(of: target.identityID) { _, newValue in
                if newValue == nil {
                    // Back to own credentials: show what is actually stored
                    // now, not whatever the field held before.
                    loadedPassword = false
                    password = ""
                    loadPassword()
                } else {
                    password = ""
                }
            }

            Section("Display") {
                Toggle("Resize the session with the window", isOn: $target.dynamicResolution)
                    .disabled(!target.fixedSize.isEmpty)
                Toggle("RDP8 graphics pipeline (/gfx)", isOn: $target.enableGFX)
                Text("Windows 11 and newer builds generally need /gfx before they will resize dynamically. Older Server builds work either way — turn it off if a session misbehaves.")
                    .font(.caption).foregroundStyle(.secondary)
                TextField("Fixed size, e.g. 1920x1080 (blank = dynamic)", text: $target.fixedSize)
            }

            Section("Redirection") {
                Toggle("Audio", isOn: $target.audio)
                Toggle("Clipboard", isOn: $target.redirectClipboard)
                Toggle("Drives", isOn: $target.redirectDrives)
            }

            Section("Advanced") {
                TextField("Extra FreeRDP flags", text: $target.extraFlags)
                Text(preview)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .frame(width: 540)
        .padding()
        .onAppear(perform: loadPassword)
        .toolbar {
            ToolbarItemGroup {
                if isExisting {
                    // Copies what is on screen, unsaved edits included, into a new
                    // unsaved editor. This window stays open so those edits are not
                    // lost; nothing is persisted until Save in the new window.
                    Button("Duplicate") {
                        openWindow(id: "editor", value: target.duplicated())
                    }
                    Button("Delete", role: .destructive) {
                        if let err = model.remove(target) {
                            error = err
                        } else {
                            dismiss()
                        }
                    }
                }
                Button("Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(target.host.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private func loadPassword() {
        guard !loadedPassword else { return }
        loadedPassword = true
        // Own mode only: an identity-backed target must never pull its stale
        // own secret into editor state, where Save could write it back.
        guard target.identityID == nil else { return }
        if target.savePassword, let existing = Keychain.load(for: target.id) {
            password = existing
        }
    }

    private func save() {
        error = nil
        // Validate before touching the keychain, so a refused save destroys nothing.
        if let err = model.config.validate(target) { error = err; return }

        if target.identityID != nil {
            // Identity mode: the target's own password is no longer used.
            // Config first, then delete the secret it no longer points at.
            var saved = target
            saved.savePassword = false
            if let err = model.upsert(saved) { error = err; return }
            target = saved
            if !Keychain.delete(for: target.id, kind: .target) {
                error = "Saved, but this target's old password could not be deleted from the keychain."
                return
            }
        } else if target.savePassword {
            // Secret first, then the config that relies on it.
            if !password.isEmpty, !Keychain.save(password, for: target.id) {
                error = "Could not save the password to the keychain. Nothing was changed."
                return
            }
            if let err = model.upsert(target) { error = err; return }
        } else {
            if let err = model.upsert(target) { error = err; return }
            if !Keychain.delete(for: target.id, kind: .target) {
                error = "Saved, but the old password could not be deleted from the keychain."
                return
            }
        }
        dismiss()
    }

    /// Previewed with the effective credentials, so identity-backed targets
    /// show the identity's /u and /d — and, as ever, never a password.
    private var preview: String {
        Launcher.commandLine(binary: model.resolveFreeRDP() ?? "sdl-freerdp",
                             target: model.config.effectiveTarget(target),
                             settings: model.config.settings)
    }
}
