extension Ghostty {
    /// Possible errors from internal Ghostty calls.
    enum Error: Swift.Error, CustomLocalizedStringResourceConvertible, Equatable {
        case apiFailed

        /// (ramon fork / cloud-hosts) A surface was restored/launched bound to a
        /// remote host name (`pty-remote-host` registry key) that could not be
        /// resolved — renamed, removed, or the config didn't load. This is the
        /// D4 "host not in registry / unreachable" state: we NEVER fall back to a
        /// local-socket dial or a fresh spawn for such a surface.
        case remoteHostUnresolvable(String)

        var localizedStringResource: LocalizedStringResource {
            switch self {
            case .apiFailed: return "libghostty API call failed"
            case .remoteHostUnresolvable(let name):
                return "Remote host \"\(name)\" is not in the pty-remote-host configuration"
            }
        }
    }
}
