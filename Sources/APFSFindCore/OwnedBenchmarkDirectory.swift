import Darwin
import Foundation

public enum BenchmarkDirectoryError: Error, CustomStringConvertible {
    case unsafe(String), io(String, Int32)
    public var description: String {
        switch self {
        case .unsafe(let path): "Refusing cleanup of unowned or replaced benchmark directory: \(path)"
        case .io(let operation, let code): "\(operation): \(String(cString: strerror(code)))"
        }
    }
}

/// Only an exact UUID child created by this instance may be removed. A supplied
/// cache path must name a new child; existing directories are never adopted.
public final class OwnedBenchmarkDirectory {
    public let path: String
    public let parent: String
    public let name: String
    private let inode: ino_t
    private let device: dev_t
    private let parentInode: ino_t
    private let parentDevice: dev_t
    private var removed = false

    public convenience init(parent: String, prefix: String, id: UUID = UUID()) throws {
        try self.init(newPath: parent + "/" + prefix + id.uuidString, parent: parent, prefix: prefix)
    }
    public init(newPath: String, parent suppliedParent: String, prefix: String) throws {
        guard ["apfsfind-real-cache-", "apfsfind-real-bench-"].contains(prefix) else {
            throw BenchmarkDirectoryError.unsafe(newPath)
        }
        parent = try PathCanonicalizer.canonicalRoot(suppliedParent)
        guard parent != "/" else { throw BenchmarkDirectoryError.unsafe(newPath) }
        guard let candidate = PathCanonicalizer.normalize(newPath),
              PathCanonicalizer.parent(of: candidate) == parent, candidate != parent, candidate != "/" else {
            throw BenchmarkDirectoryError.unsafe(newPath)
        }
        name = String(candidate.dropFirst(parent == "/" ? 1 : parent.count + 1))
        guard name.hasPrefix(prefix), let id = UUID(uuidString: String(name.dropFirst(prefix.count))),
              name == prefix + id.uuidString else { throw BenchmarkDirectoryError.unsafe(newPath) }
        var parentInfo = stat()
        guard lstat(parent, &parentInfo) == 0, parentInfo.st_mode & S_IFMT == S_IFDIR else {
            throw BenchmarkDirectoryError.unsafe(parent)
        }
        parentInode = parentInfo.st_ino; parentDevice = parentInfo.st_dev
        guard mkdir(candidate, 0o700) == 0 else { throw BenchmarkDirectoryError.io("create benchmark directory", errno) }
        var info = stat()
        guard lstat(candidate, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == geteuid(), info.st_mode & 0o7777 == 0o700 else {
            throw BenchmarkDirectoryError.unsafe(candidate)
        }
        path = candidate; inode = info.st_ino; device = info.st_dev
    }
    public func validate() throws {
        var p = stat(), info = stat()
        guard path == (parent == "/" ? "" : parent) + "/" + name,
              PathCanonicalizer.parent(of: path) == parent,
              lstat(parent, &p) == 0, p.st_mode & S_IFMT == S_IFDIR,
              p.st_ino == parentInode, p.st_dev == parentDevice,
              try PathCanonicalizer.canonicalRoot(parent) == parent else {
            throw BenchmarkDirectoryError.unsafe(path)
        }
        guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              info.st_ino == inode, info.st_dev == device, info.st_uid == geteuid(),
              info.st_mode & 0o7777 == 0o700,
              try PathCanonicalizer.canonicalRoot(path) == path else {
            throw BenchmarkDirectoryError.unsafe(path)
        }
    }
    public func remove() throws {
        if removed { return }
        try validate()
        try FileManager.default.removeItem(atPath: path)
        removed = true
    }
}
