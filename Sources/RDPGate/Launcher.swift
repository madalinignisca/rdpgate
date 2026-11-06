import Foundation

enum Launcher {

    /// Build the FreeRDP argument list for a target.
    /// The password is never an argument — see `launch`.
    static func arguments(for target: RDPTarget,
                          settings: AppSettings,
                          withPassword: Bool = false) -> [String] {
        var args: [String] = []

        let hostPart = target.port == 3389 ? target.host : "\(target.host):\(target.port)"
        args.append("/v:\(hostPart)")

        if let proxy = target.proxy(default: settings) {
            args.append("/proxy:socks5://\(proxy.host):\(proxy.port)")
        }

        args.append("/cert:tofu")
        args.append(target.audio ? "/audio-mode:redirect" : "/audio-mode:none")
        args.append(target.redirectDrives ? "+drives" : "-drives")
        args.append(target.redirectClipboard ? "+clipboard" : "-clipboard")
        args.append("/network:auto")

        let user = target.username.trimmingCharacters(in: .whitespaces)
        if !user.isEmpty { args.append("/u:\(user)") }
        let domain = target.domain.trimmingCharacters(in: .whitespaces)
        if !domain.isEmpty { args.append("/d:\(domain)") }

        // Read the password from stdin rather than passing /p:<secret>, which
        // would expose it in `ps` output to every process on the machine.
        if withPassword { args.append("/from-stdin") }

        // The RDP8 graphics pipeline. Newer Windows generally only negotiates
        // the Display Control channel — and therefore dynamic resizing — when
        // this is on. Older Server builds work either way.
        if target.enableGFX { args.append("/gfx") }

        let size = target.fixedSize.trimmingCharacters(in: .whitespaces)
        if !size.isEmpty {
            args.append("/size:\(size)")
        } else if target.dynamicResolution {
            args.append("+dynamic-resolution")
        }

        let extra = target.extraFlags.trimmingCharacters(in: .whitespaces)
        if !extra.isEmpty {
            args.append(contentsOf: extra.split(separator: " ").map(String.init))
        }

        return args
    }

    /// A copy-pasteable command line, so a connection can always be reproduced
    /// or debugged outside the app. Never contains the password.
    static func commandLine(binary: String, target: RDPTarget, settings: AppSettings) -> String {
        ([binary] + arguments(for: target, settings: settings))
            .map { $0.contains(" ") ? "'\($0)'" : $0 }
            .joined(separator: " ")
    }

    /// Launch FreeRDP. Returns an error string on failure, nil on success.
    @discardableResult
    static func launch(binary: String,
                       target: RDPTarget,
                       settings: AppSettings,
                       password: String? = nil) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = arguments(for: target,
                                      settings: settings,
                                      withPassword: password != nil)
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        let stdin = Pipe()
        process.standardInput = password != nil ? stdin : FileHandle.nullDevice

        do {
            try process.run()
            if let password {
                stdin.fileHandleForWriting.write(Data((password + "\n").utf8))
                try? stdin.fileHandleForWriting.close()
            }
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}
