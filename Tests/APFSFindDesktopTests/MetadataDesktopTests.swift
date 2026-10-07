import APFSFindCore
import Foundation
import XCTest
@testable import APFSFindDesktop

@MainActor
final class MetadataDesktopTests: XCTestCase {
    func testHeadersDirectionPersistenceUnavailableAndFormatting() async throws {
        let suite = "apfsfind.metadata-tests."+UUID().uuidString, defaults = UserDefaults(suiteName:suite)!
        defer { defaults.removePersistentDomain(forName:suite) }
        let service = SortDesktopService(), model = SearchViewModel(service:service,actions:FileActionController(),debounce:.milliseconds(1),defaults:defaults)
        model.selectSort(.size); XCTAssertEqual(model.sort.key,.relevance)
        let volume = VolumeDescriptor(volumeUUID:UUID(),displayName:"Test",mountPath:"/fixture")
        model.updateSessions([.init(volume:volume,state:.live,searchAvailable:true,freshness:.live,indexedEntries:80,snapshotBytes:0,unreadableDirectories:0,pendingReplayEvents:0,metadataAvailable:true,metadataFreshness:.catchingUp)])
        XCTAssertNotNil(model.metadataWarning)
        model.selectSort(.size); XCTAssertEqual(model.sort,.init(key:.size))
        model.selectSort(.size); XCTAssertEqual(model.sort.direction,.ascending)
        model.selectSort(.modificationTime); XCTAssertEqual(model.sort.direction,.descending)
        model.selectSort(.name); XCTAssertEqual(model.sort.direction,.ascending)
        let next = SearchViewModel(service:service,actions:FileActionController(),defaults:defaults)
        XCTAssertEqual(next.sort,model.sort)
        model.query = "match"; await ready(model)
        XCTAssertEqual(model.hits.count,50); model.selectedIndex = 3; let id = model.selectedHit?.id
        model.loadMore(); await ready(model); XCTAssertEqual(model.hits.count,80); XCTAssertEqual(model.selectedHit?.id,id)
        XCTAssertEqual(model.sort.key,.name)
        model.query = "another"; await ready(model); XCTAssertEqual(model.hits.count,50); XCTAssertEqual(model.sort.key,.name)
        model.selectSort(.relevance); XCTAssertEqual(model.sort,.init())
        XCTAssertEqual(ResultFormatting.size(nil),"—"); XCTAssertEqual(ResultFormatting.time(nil),"—")
        XCTAssertFalse(ResultFormatting.size(1024).isEmpty); XCTAssertFalse(ResultFormatting.time(1_700_000_000_000_000_000).isEmpty)
        await model.cancel(); await next.cancel()
    }
    func testHiddenWindowSkipsQueriesAndRestoresSavedMetadataSort() async throws {
        let suite = "apfsfind.metadata-tests."+UUID().uuidString, defaults = UserDefaults(suiteName:suite)!
        defer { defaults.removePersistentDomain(forName:suite) }
        defaults.set("size",forKey:"lastSortKey"); defaults.set("descending",forKey:"lastSortDirection")
        let service = SortDesktopService(), model = SearchViewModel(service:service,actions:FileActionController(),debounce:.milliseconds(1),defaults:defaults)
        let volume = VolumeDescriptor(volumeUUID:UUID(),displayName:"Test",mountPath:"/fixture")
        model.setSearchVisible(false)
        model.query = "hidden"
        model.updateSessions([.init(volume:volume,state:.live,searchAvailable:true,freshness:.live,indexedEntries:80,snapshotBytes:0,unreadableDirectories:0,pendingReplayEvents:0,metadataAvailable:false)])
        XCTAssertEqual(model.sort.key,.relevance); XCTAssertEqual(defaults.string(forKey:"lastSortKey"),"size")
        model.updateSessions([.init(volume:volume,state:.live,searchAvailable:true,freshness:.live,indexedEntries:80,snapshotBytes:0,unreadableDirectories:0,pendingReplayEvents:0,metadataAvailable:true,metadataFreshness:.live)])
        XCTAssertEqual(model.sort.key,.size)
        try await Task.sleep(for:.milliseconds(20))
        let hiddenSubmissions = await service.submissions
        XCTAssertEqual(hiddenSubmissions,0); XCTAssertFalse(model.pending)
        model.setSearchVisible(true); model.refreshQuery(); await ready(model)
        XCTAssertEqual(model.hits.count,50)
        let shownSubmissions = await service.submissions
        XCTAssertEqual(shownSubmissions,1)
        model.setSearchVisible(false); await model.cancel()
    }
    private func ready(_ model:SearchViewModel) async {
        let end = ProcessInfo.processInfo.systemUptime+3
        while model.pending && ProcessInfo.processInfo.systemUptime < end { try? await Task.sleep(for:.milliseconds(1)) }
        XCTAssertFalse(model.pending)
    }
}
private actor SortDesktopService: DesktopSearching {
    let volume = VolumeDescriptor(volumeUUID:UUID(),displayName:"Test",mountPath:"/fixture")
    private(set) var submissions = 0
    func cancel() {}
    func submit(_ request:SearchRequest) async -> MultiVolumeSearchResult? {
        submissions += 1
        let hits = (0..<min(80,request.limit)).map { VolumeSearchHit(hit:.init(path:"/fixture/\(request.query)-\($0)",kind:.file),volume:volume,freshness:.live) }
        return .init(requestID:request.id,hits:hits,searchedVolumes:1,catchingUpVolumes:0,offlineVolumes:0,failedVolumes:[],latencyMilliseconds:1,cancelled:false,hasMore:request.limit<80)
    }
}
