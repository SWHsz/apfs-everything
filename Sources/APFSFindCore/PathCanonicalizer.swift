import Darwin
import Foundation
import CAPFSShim

public enum PathCanonicalizationError: Error, CustomStringConvertible, Sendable {
    case invalidPath(String)
    case inaccessibleRoot(String, Int32)
    case notDirectory(String)

    public var description: String {
        switch self {
        case .invalidPath(let path): return "Invalid path: \(path)"
        case .inaccessibleRoot(let path, let code): return "Cannot resolve root \(path): \(String(cString: strerror(code)))"
        case .notDirectory(let path): return "Scan root is not a directory: \(path)"
        }
    }
}

public enum PathCanonicalizer {
    /// Resolves the existing scan root once. Symlinks encountered by the scanner remain entries.
    public static func canonicalRoot(_ path: String) throws -> String {
        guard !path.isEmpty, !path.contains("\0") else {
            throw PathCanonicalizationError.invalidPath(path)
        }
        let expanded = (path as NSString).expandingTildeInPath
        let absolute = expanded.hasPrefix("/") ? expanded : FileManager.default.currentDirectoryPath + "/" + expanded
        var resolved = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard apfs_resolve_local_root(absolute, &resolved, resolved.count) == 0 else {
            throw PathCanonicalizationError.inaccessibleRoot(path, errno)
        }
        let canonical = String(decoding: resolved.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        var metadata = stat()
        guard Darwin.lstat(canonical, &metadata) == 0 else {
            throw PathCanonicalizationError.inaccessibleRoot(canonical, errno)
        }
        guard metadata.st_mode & S_IFMT == S_IFDIR else {
            throw PathCanonicalizationError.notDirectory(canonical)
        }
        return canonical
    }

    /// Pure lexical normalization for event/index paths; never accesses the filesystem.
    public static func normalize(_ path: String) -> String? {
        guard path.hasPrefix("/"), !path.contains("\0") else { return nil }
        var components: [Substring] = []
        for component in path.split(separator: "/", omittingEmptySubsequences: true) {
            if component == "." { continue }
            if component == ".." {
                if !components.isEmpty { components.removeLast() }
            } else {
                components.append(component)
            }
        }
        return "/" + components.joined(separator: "/")
    }

    public static func isWithin(_ path: String, root: String) -> Bool {
        guard let path = normalize(path), let root = normalize(root) else { return false }
        return root == "/" || path == root || path.hasPrefix(root + "/")
    }

    public static func parent(of path: String) -> String {
        guard let normalized = normalize(path), normalized != "/",
              let slash = normalized.lastIndex(of: "/") else { return "/" }
        if slash == normalized.startIndex { return "/" }
        return String(normalized[..<slash])
    }

    /// Deduplicates directories and removes descendants covered by an ancestor.
    public static func minimalRoots(_ paths: [String]) -> [String] {
        let unique = Set(paths.compactMap(normalize))
        // Check only the actual ancestors, rather than comparing every retained
        // root. A burst containing many unrelated directories stays bounded by
        // path depth. Lexical adjacency is insufficient: /a- can sort between
        // /a and /a/child, while /a still covers /a/child.
        return unique.filter { path in
            var ancestor = path
            while ancestor != "/", let slash = ancestor.lastIndex(of: "/") {
                ancestor = slash == ancestor.startIndex ? "/" : String(ancestor[..<slash])
                if unique.contains(ancestor) { return false }
            }
            return true
        }.sorted()
    }
}
