// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0

import Foundation
import Shared
@_exported import MozillaAppServices

private let log = Logger.syncLogger

public protocol BookmarksHandler {
    func getRecentBookmarks(limit: UInt, completion: @escaping ([BookmarkItemData]) -> Void)
}

public protocol HistoryMetadataObserver {
    func noteHistoryMetadataObservation(key: HistoryMetadataKey,
                                        observation: HistoryMetadataObservation,
                                        completion: @escaping () -> Void)
}

public class RustPlaces: BookmarksHandler, HistoryMetadataObserver {
    let databasePath: String

    let writerQueue: DispatchQueue
    let readerQueue: DispatchQueue

    public var api: PlacesAPI?

    public var writer: PlacesWriteConnection?
    public var reader: PlacesReadConnection?

    public fileprivate(set) var isOpen: Bool = false

    private var didAttemptToMoveToBackup = false
    private var notificationCenter: NotificationCenter

    public init(databasePath: String,
                notificationCenter: NotificationCenter = NotificationCenter.default) {
        self.databasePath = databasePath
        self.notificationCenter = notificationCenter
        self.writerQueue = DispatchQueue(label: "RustPlaces writer queue: \(databasePath)", attributes: [])
        self.readerQueue = DispatchQueue(label: "RustPlaces reader queue: \(databasePath)", attributes: [])
    }

    private func open() -> NSError? {
        do {
            api = try PlacesAPI(path: databasePath)
            isOpen = true
            notificationCenter.post(name: .RustPlacesOpened, object: nil)
            return nil
        } catch let err as NSError {
            if let placesError = err as? PlacesApiError {
                SentryIntegration.shared.sendWithStacktrace(
                    message: "Places error when opening Rust Places database",
                    tag: SentryTag.rustPlaces,
                    severity: .error,
                    description: placesError.localizedDescription)
            } else {
                SentryIntegration.shared.sendWithStacktrace(
                    message: "Unknown error when opening Rust Places database",
                    tag: SentryTag.rustPlaces,
                    severity: .error,
                    description: err.localizedDescription)
            }

            return err
        }
    }

    private func close() -> NSError? {
        api = nil
        writer = nil
        reader = nil
        isOpen = false
        return nil
    }

    private func withWriter<T>(_ callback: @escaping(_ connection: PlacesWriteConnection) throws -> T) -> Deferred<Maybe<T>> {
        let deferred = Deferred<Maybe<T>>()

        writerQueue.async {
            guard self.isOpen else {
                deferred.fill(Maybe(failure: PlacesConnectionError.connUseAfterApiClosed as MaybeErrorType))
                return
            }

            if self.writer == nil {
                self.writer = self.api?.getWriter()
            }

            if let writer = self.writer {
                do {
                    let result = try callback(writer)
                    deferred.fill(Maybe(success: result))
                } catch let error {
                    deferred.fill(Maybe(failure: error as MaybeErrorType))
                }
            } else {
                deferred.fill(Maybe(failure: PlacesConnectionError.connUseAfterApiClosed as MaybeErrorType))
            }
        }

        return deferred
    }

    private func withReader<T>(_ callback: @escaping(_ connection: PlacesReadConnection) throws -> T) -> Deferred<Maybe<T>> {
        let deferred = Deferred<Maybe<T>>()

        readerQueue.async {
            guard self.isOpen else {
                deferred.fill(Maybe(failure: PlacesConnectionError.connUseAfterApiClosed as MaybeErrorType))
                return
            }

            if self.reader == nil {
                do {
                    self.reader = try self.api?.openReader()
                } catch let error {
                    deferred.fill(Maybe(failure: error as MaybeErrorType))
                }
            }

            if let reader = self.reader {
                do {
                    let result = try callback(reader)
                    deferred.fill(Maybe(success: result))
                } catch let error {
                    deferred.fill(Maybe(failure: error as MaybeErrorType))
                }
            } else {
                deferred.fill(Maybe(failure: PlacesConnectionError.connUseAfterApiClosed as MaybeErrorType))
            }
        }

        return deferred
    }

    public func migrateBookmarksIfNeeded(fromBrowserDB browserDB: BrowserDB) {
        // Since we use the existence of places.db as an indication that we've
        // already migrated bookmarks, assert that places.db is not open here.
        assert(!isOpen, "Shouldn't attempt to migrate bookmarks after opening Rust places.db")

        // We only need to migrate bookmarks here if the old browser.db file
        // already exists AND the new Rust places.db file does NOT exist yet.
        // This is to ensure that we only ever run this migration ONCE. In
        // addition, it is the caller's (Profile.swift) responsibility to NOT
        // use this migration API for users signed into a Firefox Account.
        // Those users will automatically get all their bookmarks on next Sync.
        guard FileManager.default.fileExists(atPath: browserDB.databasePath),
            !FileManager.default.fileExists(atPath: databasePath) else {
            return
        }

        // Ensure that the old BrowserDB schema is up-to-date before migrating.
        _ = browserDB.touch().value

        // Open the Rust places.db now for the first time.
        _ = reopenIfClosed()

        do {
            try api?.migrateBookmarksFromBrowserDb(path: browserDB.databasePath)
        } catch let err as NSError {
            SentryIntegration.shared.sendWithStacktrace(
                message: "Error encountered while migrating bookmarks from BrowserDB",
                tag: SentryTag.rustPlaces,
                severity: .error,
                description: err.localizedDescription)
        }
    }

    public func getBookmarksTree(rootGUID: GUID, recursive: Bool) -> Deferred<Maybe<BookmarkNodeData?>> {
        return withReader { connection in
            return try connection.getBookmarksTree(rootGUID: rootGUID, recursive: recursive)
        }
    }

    public func getBookmark(guid: GUID) -> Deferred<Maybe<BookmarkNodeData?>> {
        return withReader { connection in
            return try connection.getBookmark(guid: guid)
        }
    }

    public func getRecentBookmarks(limit: UInt, completion: @escaping ([BookmarkItemData]) -> Void) {
        let deferredResponse = withReader { connection in
            return try connection.getRecentBookmarks(limit: limit)
        }

        deferredResponse.upon { result in
            completion(result.successValue ?? [])
        }
    }

    public func getRecentBookmarks(limit: UInt) -> Deferred<Maybe<[BookmarkItemData]>> {
        return withReader { connection in
            return try connection.getRecentBookmarks(limit: limit)
        }
    }

    public func getBookmarkURLForKeyword(keyword: String) -> Deferred<Maybe<String?>> {
        return withReader { connection in
            return try connection.getBookmarkURLForKeyword(keyword: keyword)
        }
    }

    public func getBookmarksWithURL(url: String) -> Deferred<Maybe<[BookmarkItemData]>> {
        return withReader { connection in
            return try connection.getBookmarksWithURL(url: url)
        }
    }

    public func isBookmarked(url: String) -> Deferred<Maybe<Bool>> {
        return getBookmarksWithURL(url: url).bind { result in
            guard let bookmarks = result.successValue else {
                return deferMaybe(false)
            }

            return deferMaybe(!bookmarks.isEmpty)
        }
    }

    public func searchBookmarks(query: String, limit: UInt) -> Deferred<Maybe<[BookmarkItemData]>> {
        return withReader { connection in
            return try connection.searchBookmarks(query: query, limit: limit)
        }
    }

    public func interruptWriter() {
        writer?.interrupt()
    }

    public func interruptReader() {
        reader?.interrupt()
    }

    public func runMaintenance() {
        _ = withWriter { connection in
            try connection.runMaintenance()
        }
    }

    public func deleteBookmarkNode(guid: GUID) -> Success {
        return withWriter { connection in
            let result = try connection.deleteBookmarkNode(guid: guid)
            guard result else {
                log.debug("Bookmark with GUID \(guid) does not exist.")
                return
            }

            self.notificationCenter.post(name: .BookmarksUpdated, object: self)
        }
    }

    public func deleteBookmarksWithURL(url: String) -> Success {
        return getBookmarksWithURL(url: url) >>== { bookmarks in
            let deferreds = bookmarks.map({ self.deleteBookmarkNode(guid: $0.guid) })
            return all(deferreds).bind { results in
                if let error = results.find({ $0.isFailure })?.failureValue {
                    return deferMaybe(error)
                }

                self.notificationCenter.post(name: .BookmarksUpdated, object: self)
                return succeed()
            }
        }
    }

    public func createFolder(parentGUID: GUID, title: String,
                             position: UInt32?) -> Deferred<Maybe<GUID>> {
        return withWriter { connection in
            return try connection.createFolder(parentGUID: parentGUID, title: title, position: position)
        }
    }

    public func createSeparator(parentGUID: GUID,
                                position: UInt32?) -> Deferred<Maybe<GUID>> {
        return withWriter { connection in
            return try connection.createSeparator(parentGUID: parentGUID, position: position)
        }
    }

    @discardableResult
    public func createBookmark(parentGUID: GUID,
                               url: String,
                               title: String?,
                               position: UInt32?) -> Deferred<Maybe<GUID>> {
        return withWriter { connection in
            let response = try connection.createBookmark(parentGUID: parentGUID, url: url, title: title, position: position)
            self.notificationCenter.post(name: .BookmarksUpdated, object: self)
            return response
        }
    }

    public func updateBookmarkNode(guid: GUID, parentGUID: GUID? = nil, position: UInt32? = nil, title: String? = nil, url: String? = nil) -> Success {
        return withWriter { connection in
            return try connection.updateBookmarkNode(guid: guid, parentGUID: parentGUID, position: position, title: title, url: url)
        }
    }

    public func reopenIfClosed() -> NSError? {
        var error: NSError?

        writerQueue.sync {
            guard !isOpen else { return }

            error = open()
        }

        return error
    }

    public func forceClose() -> NSError? {
        var error: NSError?

        writerQueue.sync {
            guard isOpen else { return }

            error = close()
        }

        return error
    }

    public func syncBookmarks(unlockInfo: SyncUnlockInfo) -> Success {
        let deferred = Success()

        writerQueue.async {
            guard self.isOpen else {
                deferred.fill(Maybe(failure: PlacesConnectionError.connUseAfterApiClosed as MaybeErrorType))
                return
            }

            do {
                try _ = self.api?.syncBookmarks(unlockInfo: unlockInfo)
                deferred.fill(Maybe(success: ()))
            } catch let err as NSError {
                if let placesError = err as? PlacesApiError {
                    SentryIntegration.shared.sendWithStacktrace(
                        message: "Places error when syncing Places database",
                        tag: SentryTag.rustPlaces,
                        severity: .error,
                        description: placesError.localizedDescription)
                } else {
                    SentryIntegration.shared.sendWithStacktrace(
                        message: "Unknown error when opening Rust Places database",
                        tag: SentryTag.rustPlaces,
                        severity: .error,
                        description: err.localizedDescription)
                }

                deferred.fill(Maybe(failure: err))
            }
        }

        return deferred
    }

    public func syncHistory(unlockInfo: SyncUnlockInfo) -> Success {
        let deferred = Success()

        writerQueue.async {
            guard self.isOpen else {
                deferred.fill(Maybe(failure: PlacesConnectionError.connUseAfterApiClosed as MaybeErrorType))
                return
            }

            do {
                try _ = self.api?.syncHistory(unlockInfo: unlockInfo)
                deferred.fill(Maybe(success: ()))
            } catch let err as NSError {
                if let placesError = err as? PlacesApiError {
                    SentryIntegration.shared.sendWithStacktrace(message: "Places error when syncing Places database",
                                                                tag: SentryTag.rustPlaces,
                                                                severity: .error,
                                                                description: placesError.localizedDescription)
                } else {
                    SentryIntegration.shared.sendWithStacktrace(message: "Unknown error when opening Rust Places database",
                                                                tag: SentryTag.rustPlaces,
                                                                severity: .error,
                                                                description: err.localizedDescription)
                }

                deferred.fill(Maybe(failure: err))
            }
        }

        return deferred
    }

    public func resetBookmarksMetadata() -> Success {
        let deferred = Success()

        writerQueue.async {
            guard self.isOpen else {
                deferred.fill(Maybe(failure: PlacesConnectionError.connUseAfterApiClosed as MaybeErrorType))
                return
            }

            do {
                try self.api?.resetBookmarkSyncMetadata()
                deferred.fill(Maybe(success: ()))
            } catch let error {
                deferred.fill(Maybe(failure: error as MaybeErrorType))
            }
        }

        return deferred
    }

    public func resetHistoryMetadata() -> Success {
         let deferred = Success()

         writerQueue.async {
             guard self.isOpen else {
                 deferred.fill(Maybe(failure: PlacesConnectionError.connUseAfterApiClosed as MaybeErrorType))
                 return
             }

             do {
                 try self.api?.resetHistorySyncMetadata()
                 deferred.fill(Maybe(success: ()))
             } catch let error {
                 deferred.fill(Maybe(failure: error as MaybeErrorType))
             }
         }

         return deferred
     }

    public func getHistoryMetadataSince(since: Int64) -> Deferred<Maybe<[HistoryMetadata]>> {
        return withReader { connection in
            return try connection.getHistoryMetadataSince(since: since)
        }
    }

    public func getHighlights(weights: HistoryHighlightWeights, limit: Int32) -> Deferred<Maybe<[HistoryHighlight]>> {
        return withReader { connection in
            return try connection.getHighlights(weights: weights, limit: limit)
        }
    }

    public func queryHistoryMetadata(query: String, limit: Int32) -> Deferred<Maybe<[HistoryMetadata]>> {
        return withReader { connection in
            return try connection.queryHistoryMetadata(query: query, limit: limit)
        }
    }

    public func noteHistoryMetadataObservation(key: HistoryMetadataKey,
                                               observation: HistoryMetadataObservation,
                                               completion: @escaping () -> Void) {
        let deferredResponse = withReader { connection in
            return self.noteHistoryMetadataObservation(key: key, observation: observation)
        }

        deferredResponse.upon { result in
            completion()
        }
    }

    /**
        Title observations must be made first for any given url. Observe one fact at a time (e.g. just the viewTime, or just the documentType).
     */
    public func noteHistoryMetadataObservation(key: HistoryMetadataKey, observation: HistoryMetadataObservation) -> Deferred<Maybe<Void>> {
        return withWriter { connection in
            if let title = observation.title {
                let response: Void = try connection.noteHistoryMetadataObservationTitle(key: key, title: title)
                self.notificationCenter.post(name: .HistoryUpdated, object: nil)
                return response
            }
            if let documentType = observation.documentType {
                let response: Void = try connection.noteHistoryMetadataObservationDocumentType(key: key, documentType: documentType)
                self.notificationCenter.post(name: .HistoryUpdated, object: nil)
                return response
            }
            if let viewTime = observation.viewTime {
                let response: Void = try connection.noteHistoryMetadataObservationViewTime(key: key, viewTime: viewTime)
                self.notificationCenter.post(name: .HistoryUpdated, object: nil)
                return response
            }
        }
    }

    public func deleteHistoryMetadataOlderThan(olderThan: Int64) -> Deferred<Maybe<Void>> {
        return withWriter { connection in
            let response: Void = try connection.deleteHistoryMetadataOlderThan(olderThan: olderThan)
            self.notificationCenter.post(name: .HistoryUpdated, object: nil)
            return response
        }
    }

    private func deleteHistoryMetadata(since startDate: Int64) -> Deferred<Maybe<Void>> {
        let now = Date().toMillisecondsSince1970()
        return withWriter { connection in
            return try connection.deleteVisitsBetween(start: startDate, end: now)
        }
    }

    public func deleteHistoryMetadata(
        since startDate: Int64,
        completion: @escaping (Bool) -> Void
    ) {
        let deferredResponse = deleteHistoryMetadata(since: startDate)
        deferredResponse.upon { result in
            completion(result.isSuccess)
        }
    }

    private func migrateHistory(dbPath: String, lastSyncTimestamp: Int64) -> Deferred<Maybe<HistoryMigrationResult>> {
        return withWriter { connection in
            return try connection.migrateHistoryFromBrowserDb(path: dbPath, lastSyncTimestamp: lastSyncTimestamp)
        }
    }

    public func migrateHistory(dbPath: String, lastSyncTimestamp: Int64, completion: @escaping (HistoryMigrationResult) -> Void, errCallback: @escaping (Error?) -> Void) {
        _ = reopenIfClosed()
        let deferredResponse = self.migrateHistory(dbPath: dbPath, lastSyncTimestamp: lastSyncTimestamp)
        deferredResponse.upon { result in
            guard result.isSuccess, let result = result.successValue else {
                errCallback(result.failureValue)
                return
            }
            completion(result)
        }
    }

    public func deleteHistoryMetadata(key: HistoryMetadataKey) -> Deferred<Maybe<Void>> {
        return withWriter { connection in
            let response: Void = try connection.deleteHistoryMetadata(key: key)
            self.notificationCenter.post(name: .HistoryUpdated, object: nil)
            return response
        }
    }

    public func deleteVisitsFor(url: Url) -> Deferred<Maybe<Void>> {
        return withWriter { connection in
            return try connection.deleteVisitsFor(url: url)
        }
    }
}

// MARK: History APIs

extension VisitTransition {
    public static func fromVisitType(visitType: VisitType) -> Self {
        switch visitType {
        case .unknown:
            return VisitTransition.link
        case .link:
            return VisitTransition.link
        case .typed:
            return VisitTransition.typed
        case .bookmark:
            return VisitTransition.bookmark
        case .embed:
            return VisitTransition.embed
        case .permanentRedirect:
            return VisitTransition.redirectPermanent
        case .temporaryRedirect:
            return VisitTransition.redirectTemporary
        case .download:
            return VisitTransition.download
        case .framedLink:
            return VisitTransition.framedLink
        case .recentlyClosed:
            return VisitTransition.link
        }
    }
}

extension RustPlaces {
    public func applyObservation(visitObservation: VisitObservation) -> Success {
        return withWriter { connection in
            return try connection.applyObservation(visitObservation: visitObservation)
        }
    }

    public func deleteEverythingHistory() -> Success {
        return withWriter { connection in
            return try connection.deleteEverythingHistory()
        }
    }

    public func deleteVisitsFor(_ url: String) -> Success {
        return withWriter { connection in
            return try connection.deleteVisitsFor(url: url)
        }
    }

    public func deleteVisitsBetween(_ date: Date) -> Success {
        return withWriter { connection in
            return try connection.deleteVisitsBetween(start: PlacesTimestamp(date.toMillisecondsSince1970()),
                                                      end: PlacesTimestamp(Date().toMillisecondsSince1970()))
        }
    }

    public func queryAutocomplete(matchingSearchQuery filter: String, limit: Int) -> Deferred<Maybe<[SearchResult]>> {
        return withReader { connection in
            return try connection.queryAutocomplete(search: filter, limit: Int32(limit))
        }
    }

    public func getVisitPageWithBound(limit: Int, offset: Int, excludedTypes: VisitTransitionSet) -> Deferred<Maybe<HistoryVisitInfosWithBound>> {
        return withReader { connection in
            return try connection.getVisitPageWithBound(bound: Int64(Date().toMillisecondsSince1970()),
                                                        offset: Int64(offset),
                                                        count: Int64(limit),
                                                        excludedTypes: excludedTypes)
        }
    }

    public func getTopFrecentSiteInfos(limit: Int, thresholdOption: FrecencyThresholdOption) -> Deferred<Maybe<[TopFrecentSiteInfo]>> {
        return withReader { connection in
            return try connection.getTopFrecentSiteInfos(numItems: Int32(limit), thresholdOption: thresholdOption)
        }
    }
}
