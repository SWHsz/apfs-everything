import CoreServices

/// Independent from namespace classification: typed content writes refresh columns only.
public enum MetadataEventImpact: Sendable, Equatable {
    case none, refreshSizeAndTime, refreshTime, remove, reconcileParent, invalidated

    public static func classify(_ event: FileSystemEvent) -> Self {
        let flags = event.flags
        let invalid = UInt32(kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped |
            kFSEventStreamEventFlagEventIdsWrapped | kFSEventStreamEventFlagRootChanged |
            kFSEventStreamEventFlagMount | kFSEventStreamEventFlagUnmount)
        if flags & invalid != 0 { return .invalidated }
        if flags & UInt32(kFSEventStreamEventFlagMustScanSubDirs) != 0 { return .reconcileParent }
        if flags & UInt32(kFSEventStreamEventFlagHistoryDone) != 0 { return .none }
        let types = UInt32(kFSEventStreamEventFlagItemIsFile | kFSEventStreamEventFlagItemIsDir | kFSEventStreamEventFlagItemIsSymlink)
        let namespace = UInt32(kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemRemoved | kFSEventStreamEventFlagItemRenamed)
        let content = UInt32(kFSEventStreamEventFlagItemModified | kFSEventStreamEventFlagItemInodeMetaMod)
        let ancillary = UInt32(kFSEventStreamEventFlagItemXattrMod | kFSEventStreamEventFlagItemFinderInfoMod |
            kFSEventStreamEventFlagItemChangeOwner | kFSEventStreamEventFlagOwnEvent |
            kFSEventStreamEventFlagItemIsHardlink | kFSEventStreamEventFlagItemIsLastHardlink | kFSEventStreamEventFlagItemCloned)
        if flags & ~(types | namespace | content | ancillary) != 0 { return .reconcileParent }
        if flags & UInt32(kFSEventStreamEventFlagItemCreated) != 0 && flags & UInt32(kFSEventStreamEventFlagItemRemoved) != 0 { return .reconcileParent }
        if flags & UInt32(kFSEventStreamEventFlagItemRemoved) != 0 { return .remove }
        if flags & (namespace | content) != 0 {
            return flags & UInt32(kFSEventStreamEventFlagItemIsDir | kFSEventStreamEventFlagItemIsSymlink) != 0 ? .refreshTime : .refreshSizeAndTime
        }
        // Typeless metadata events can conceal sockets or other namespace creation.
        if flags & ancillary != 0 && flags & types == 0 { return .reconcileParent }
        return .none
    }
}
