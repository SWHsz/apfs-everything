import Foundation

@MainActor
enum ResultFormatting {
    private static let sizes: ByteCountFormatter = { let f = ByteCountFormatter(); f.countStyle = .file; return f }()
    private static let dates: DateFormatter = { let f = DateFormatter(); f.dateStyle = .short; f.timeStyle = .short; return f }()
    static func size(_ value: UInt64?) -> String {
        guard let value, value <= Int64.max else { return value.map { "\($0) B" } ?? "—" }
        return sizes.string(fromByteCount:Int64(value))
    }
    static func time(_ value: Int64?) -> String {
        guard let value else { return "—" }
        return dates.string(from:Date(timeIntervalSince1970:Double(value)/1_000_000_000))
    }
}
