import CoreServices

public struct FileSystemEvent: Sendable {
    public let path: String
    public let flags: UInt32
    public let id: UInt64
    public init(path: String, flags: UInt32, id: UInt64 = 0) {
        self.path = path; self.flags = flags; self.id = id
    }
}

public enum EventClassification: Equatable, Sendable {
    case historyDone, contentOnly, simpleCreate(EntryKind), simpleRemove
    case ambiguous, subtreeDirty, invalidated
}

public enum EventClassifier {
    public static func classify(_ event: FileSystemEvent) -> EventClassification {
        let f = event.flags
        let invalid = UInt32(kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped |
                             kFSEventStreamEventFlagEventIdsWrapped | kFSEventStreamEventFlagRootChanged)
        if f & invalid != 0 { return .invalidated }
        if f & UInt32(kFSEventStreamEventFlagMustScanSubDirs) != 0 { return .subtreeDirty }
        if f & UInt32(kFSEventStreamEventFlagHistoryDone) != 0 { return .historyDone }
        if f & UInt32(kFSEventStreamEventFlagMount | kFSEventStreamEventFlagUnmount) != 0 { return .ambiguous }
        let created = f & UInt32(kFSEventStreamEventFlagItemCreated) != 0
        let removed = f & UInt32(kFSEventStreamEventFlagItemRemoved) != 0
        if f & UInt32(kFSEventStreamEventFlagItemRenamed) != 0 || (created && removed) { return .ambiguous }
        let content = UInt32(kFSEventStreamEventFlagItemModified | kFSEventStreamEventFlagItemInodeMetaMod |
                             kFSEventStreamEventFlagItemXattrMod | kFSEventStreamEventFlagItemFinderInfoMod |
                             kFSEventStreamEventFlagItemChangeOwner)
        let types = UInt32(kFSEventStreamEventFlagItemIsFile | kFSEventStreamEventFlagItemIsDir |
                           kFSEventStreamEventFlagItemIsSymlink)
        let ancillary = UInt32(kFSEventStreamEventFlagOwnEvent | kFSEventStreamEventFlagItemIsHardlink |
                               kFSEventStreamEventFlagItemIsLastHardlink | kFSEventStreamEventFlagItemCloned)
        let known = content | types | ancillary | UInt32(kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemRemoved)
        if f & ~known != 0 { return .ambiguous }
        if removed { return .simpleRemove }
        if created {
            let type = f & types
            if type == UInt32(kFSEventStreamEventFlagItemIsFile) { return .simpleCreate(.file) }
            if type == UInt32(kFSEventStreamEventFlagItemIsDir) { return .simpleCreate(.directory) }
            if type == UInt32(kFSEventStreamEventFlagItemIsSymlink) { return .simpleCreate(.symlink) }
            return .ambiguous
        }
        // Metadata flags without a known object type can describe namespace
        // creation (observed for bind(AF_UNIX) as XattrMod without Created).
        // Preserve the low-cost ignore path only for typed existing objects.
        if f & content != 0 {
            let type = f & types
            return [UInt32(kFSEventStreamEventFlagItemIsFile), UInt32(kFSEventStreamEventFlagItemIsDir),
                    UInt32(kFSEventStreamEventFlagItemIsSymlink)].contains(type) ? .contentOnly : .ambiguous
        }
        return .ambiguous
    }
}
