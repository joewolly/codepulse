import Foundation

struct GitHubRepositoryIdentity: Equatable, Sendable {
    let owner: String
    let name: String

    init?(owner: String, name: String) {
        guard Self.isValidRepositoryComponent(owner),
              Self.isValidRepositoryComponent(name) else {
            return nil
        }
        self.owner = owner
        self.name = name
    }

    init?(nameWithOwner: String) {
        let components = nameWithOwner.split(separator: "/", omittingEmptySubsequences: false)
        guard components.count == 2 else { return nil }
        self.init(owner: String(components[0]), name: String(components[1]))
    }

    var nameWithOwner: String {
        "\(owner)/\(name)"
    }

    var webURL: URL {
        // The initializer only accepts URL-safe GitHub owner/repository names.
        URL(string: "https://github.com/\(nameWithOwner)")!
    }

    private static func isValidRepositoryComponent(_ value: String) -> Bool {
        guard !value.isEmpty else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            switch scalar.value {
            case 48...57, 65...90, 97...122, 45, 46, 95:
                return true
            default:
                return false
            }
        }
    }
}

enum GitHubRemoteParser {
    static func parse(_ remote: String) -> GitHubRepositoryIdentity? {
        let value = remote.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }

        if value.hasPrefix("git@github.com:") {
            return identity(fromPath: String(value.dropFirst("git@github.com:".count)))
        }

        guard let components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(),
              components.host?.lowercased() == "github.com",
              components.port == nil,
              components.query == nil,
              components.fragment == nil else {
            return nil
        }

        switch scheme {
        case "https":
            guard components.user == nil, components.password == nil else { return nil }
        case "ssh":
            guard components.user == "git", components.password == nil else { return nil }
        default:
            return nil
        }

        return identity(fromPath: components.percentEncodedPath)
    }

    private static func identity(fromPath path: String) -> GitHubRepositoryIdentity? {
        let normalizedPath = path.hasPrefix("/") ? String(path.dropFirst()) : path
        guard !normalizedPath.isEmpty,
              !normalizedPath.hasSuffix("/"),
              !normalizedPath.contains("//") else {
            return nil
        }

        let components = normalizedPath.split(separator: "/", omittingEmptySubsequences: false)
        guard components.count == 2 else { return nil }

        let owner = String(components[0])
        var name = String(components[1])
        if name.hasSuffix(".git") {
            name.removeLast(4)
        }
        return GitHubRepositoryIdentity(owner: owner, name: name)
    }
}

enum GitHubURLValidator {
    static func trustedHTTPSURL(_ url: URL) -> URL? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "https",
              components.host?.lowercased() == "github.com",
              components.user == nil,
              components.password == nil,
              components.port == nil,
              components.query == nil,
              components.fragment == nil,
              !components.path.isEmpty else {
            return nil
        }
        return url
    }

    static func trustedHTTPSURL(_ value: String) -> URL? {
        guard let url = URL(string: value) else { return nil }
        return trustedHTTPSURL(url)
    }
}
