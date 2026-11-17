/*
 * Copyright (C) 2025 OpenCloud GmbH
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation; either version 2 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful, but
 * WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY
 * or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License
 * for more details.
 */

import FileProvider
import OSLog

/// Enumerates server directories and replays persistent changes from the requested anchor.
class FileProviderEnumerator: NSObject, NSFileProviderEnumerator {
    private let enumeratedItemIdentifier: NSFileProviderItemIdentifier
    private weak var fpExtension: FileProviderExtension?
    private let operationLock = NSLock()
    private var operations: [UUID: Task<Void, Never>] = [:]
    private var invalidated = false
    private static let pageSize = 500
    private struct Page: Codable {
        let container: String
        let epoch: String
        let after: String
    }
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "eu.opencloud.desktop.FileProviderExt", category: "FileProviderEnumerator")

    init(enumeratedItemIdentifier: NSFileProviderItemIdentifier, domain: NSFileProviderDomain, fpExtension: FileProviderExtension) {
        self.enumeratedItemIdentifier = enumeratedItemIdentifier
        self.fpExtension = fpExtension
        super.init()
    }

    func invalidate() {
        operationLock.lock()
        invalidated = true
        let tasks = Array(operations.values)
        operationLock.unlock()
        for task in tasks { task.cancel() }
    }

    private func startOperation(_ operation: @escaping () async -> Void) {
        let identifier = UUID()
        operationLock.lock()
        let task = Task {
            await operation()
            finishOperation(identifier)
        }
        operations[identifier] = task
        if invalidated { task.cancel() }
        operationLock.unlock()
    }

    private func finishOperation(_ identifier: UUID) {
        operationLock.lock()
        operations.removeValue(forKey: identifier)
        operationLock.unlock()
    }

    private func providerError(_ error: Error) -> Error {
        if case DatabaseError.expiredAnchor = error {
            return NSFileProviderError(.syncAnchorExpired)
        }
        return fileProviderError(error)
    }

    private func item(_ metadata: ItemMetadata) -> NSFileProviderItem {
        let parent = metadata.parentOcId == ItemDatabase.rootContainerId
            ? NSFileProviderItemIdentifier.rootContainer
            : NSFileProviderItemIdentifier(metadata.parentOcId)
        return FileProviderItem(metadata: metadata, parentItemIdentifier: parent, supportsTrash: fpExtension?.supportsTrash ?? false)
    }

    private func directory(ext: FileProviderExtension, webdav: WebDAVClient, database: ItemDatabase) async throws -> (path: String, parent: String) {
        if enumeratedItemIdentifier == .rootContainer {
            return ("/", ItemDatabase.rootContainerId)
        }
        var metadata = await database.itemMetadata(ocId: enumeratedItemIdentifier.rawValue)
        if metadata == nil {
            metadata = try await ext.resolveItemFromServer(identifier: enumeratedItemIdentifier, webdav: webdav, database: database)
        }
        guard let metadata = metadata, metadata.isDirectory else {
            throw NSFileProviderError(.noSuchItem)
        }
        return (metadata.remotePath, metadata.ocId)
    }

    private struct DirectorySnapshot {
        /// The directory's own ETag in this listing; record it only after `missing` is applied.
        let etag: String
        let items: [ItemMetadata]
        let missing: [ItemMetadata]
        /// Cached child ETags before this listing merged new ones.
        let previousETags: [String: String]
    }

    private func loadDirectory(path: String, parent: String, webdav: WebDAVClient, database: ItemDatabase) async throws -> DirectorySnapshot {
        // Capture before the network request so concurrent local writes are not deleted.
        try Task.checkCancellation()
        let previous = await database.childItems(parentOcId: parent)
        let started = Date()
        let response = try await webdav.listDirectory(path: path)
        var metadata: [ItemMetadata] = []
        for remote in response.dropFirst() {
            try Task.checkCancellation()
            let merged = try await database.mergeServerMetadata(ItemMetadata(from: remote, parentOcId: parent), fetchedAfter: started)
            metadata.append(merged)
        }
        let identifiers = Set(metadata.map { $0.ocId })
        return DirectorySnapshot(etag: response.first?.etag ?? "", items: metadata,
                                 missing: previous.filter { !identifiers.contains($0.ocId) },
                                 previousETags: Dictionary(previous.map { ($0.ocId, $0.etag) }, uniquingKeysWith: { first, _ in first }))
    }

    /// Whether a child directory's cached subtree may differ from the server.
    /// OpenCloud propagates ETags to every ancestor, so an unchanged ETag proves
    /// that nothing below it changed and the whole subtree can be skipped.
    private func needsListing(_ child: ItemMetadata, in snapshot: DirectorySnapshot, database: ItemDatabase) async -> Bool {
        if let listed = await database.listedETag(ocId: child.ocId) { return listed != child.etag }
        // Children cached before ETags were recorded: reconcile once.
        if await database.hasChildren(parentOcId: child.ocId) { return true }
        // Never listed: a changed or new folder may have received a known item moved
        // out of another folder. Its own new children are not followed further, so
        // a fresh subtree is listed one level deep, not recursively.
        if let previousETag = snapshot.previousETags[child.ocId] { return previousETag != child.etag }
        return !snapshot.previousETags.isEmpty
    }

    private func refreshDirectory(path: String, parent: String, webdav: WebDAVClient, database: ItemDatabase) async throws -> [ItemMetadata] {
        if let metadata = await database.itemMetadata(ocId: parent), metadata.isTrashed {
            return try await FileProviderTrash.refresh(webdav: webdav, database: database, parent: metadata)
        }
        let snapshot = try await loadDirectory(path: path, parent: parent, webdav: webdav, database: database)
        if !snapshot.missing.isEmpty {
            // A child missing from one parent may have moved to another. Reconcile
            // known folders before discarding its identity and materialization state.
            try await refreshWorkingSet(webdav: webdav, database: database)
        }
        for missing in snapshot.missing {
            try Task.checkCancellation()
            let retirement = await fpExtension?.syncStatus.removalScope(metadata: missing, database: database)
            try await database.deleteIfUnchanged(missing)
            if let retirement { await fpExtension?.syncStatus.retireRemovedItems(retirement, database: database) }
        }
        // No listed ETag here: it vouches for the whole subtree, which only the
        // working-set pass reconciles.
        return await database.childItems(parentOcId: parent)
    }

    private func refreshWorkingSet(webdav: WebDAVClient, database: ItemDatabase) async throws {
        // Refresh known folders, including parents of materialized nested files.
        // Opening another Finder window must not be required to discover their changes.
        // Descend only into folders whose ETag changed, so an idle check costs one
        // listing instead of one per known folder.
        if await webdav.supportsTrash {
            do { _ = try await FileProviderTrash.refresh(webdav: webdav, database: database) }
            catch WebDAVError.fileNotFound { /* The server may not offer an optional trash endpoint. */ }
            catch let error as CocoaError where error.code == .featureUnsupported {}
        }
        let pass = WorkingSetPass()
        _ = try await reconcile(path: "/", ocId: ItemDatabase.rootContainerId, pass: pass, webdav: webdav, database: database)
        // Apply all moves before deletions, so moving a cached folder between known
        // parents keeps its descendants and their local state.
        for item in pass.missing {
            try Task.checkCancellation()
            let retirement = await fpExtension?.syncStatus.removalScope(metadata: item, database: database)
            try await database.deleteIfUnchanged(item)
            if let retirement { await fpExtension?.syncStatus.retireRemovedItems(retirement, database: database) }
        }
        try await database.setListedETags(pass.deferredETags)
    }

    private final class WorkingSetPass {
        var missing: [ItemMetadata] = []
        /// Folders with items to remove: recorded only after the removals, or the next pass would skip them.
        var deferredETags: [String: String] = [:]
    }

    /// Lists a folder and, depth first, each subfolder that may have changed. A folder's ETag is
    /// recorded as soon as its whole subtree is reconciled, so an interrupted pass (cancelled by
    /// the system, or a failed request) continues where it stopped instead of starting over.
    /// Returns whether the subtree needed no removals.
    private func reconcile(path: String, ocId: String, pass: WorkingSetPass, webdav: WebDAVClient, database: ItemDatabase) async throws -> Bool {
        try Task.checkCancellation()
        let snapshot: DirectorySnapshot
        do {
            snapshot = try await loadDirectory(path: path, parent: ocId, webdav: webdav, database: database)
        } catch WebDAVError.fileNotFound where ocId != ItemDatabase.rootContainerId {
            if let current = await database.itemMetadata(ocId: ocId) { pass.missing.append(current) }
            return false
        }
        pass.missing.append(contentsOf: snapshot.missing)
        var clean = snapshot.missing.isEmpty
        for child in snapshot.items where child.isDirectory && !child.isTrashed {
            if await needsListing(child, in: snapshot, database: database),
               try await !reconcile(path: child.remotePath, ocId: child.ocId, pass: pass, webdav: webdav, database: database) {
                clean = false
            }
        }
        if clean {
            try await database.setListedETags([ocId: snapshot.etag])
        } else {
            pass.deferredETags[ocId] = snapshot.etag
        }
        return clean
    }

    func enumerateItems(for observer: NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage) {
        guard let ext = fpExtension else {
            observer.finishEnumeratingWithError(NSFileProviderError(.notAuthenticated))
            return
        }
        startOperation {
            let activity = ext.syncStatus.begin(.metadata, key: "enumerate:" + self.enumeratedItemIdentifier.rawValue)
            do {
                try Task.checkCancellation()
                guard ext.isAuthenticated, let webdav = ext.webdavClient, let database = ext.database else {
                    throw NSFileProviderError(.notAuthenticated)
                }
                let anchor = try await database.currentSyncAnchor()
                let epoch = String(data: anchor, encoding: .utf8)!.components(separatedBy: ":")[0]
                let initial = page.rawValue == NSFileProviderPage.initialPageSortedByName as Data || page.rawValue == NSFileProviderPage.initialPageSortedByDate as Data
                let cursor: String?
                if initial {
                    cursor = nil
                } else {
                    guard let token = try? JSONDecoder().decode(Page.self, from: page.rawValue),
                          token.container == self.enumeratedItemIdentifier.rawValue, token.epoch == epoch else {
                        throw NSFileProviderError(.pageExpired)
                    }
                    cursor = token.after
                }
                let parent: String?
                switch self.enumeratedItemIdentifier {
                case .trashContainer:
                    if initial, await webdav.supportsTrash { _ = try await FileProviderTrash.refresh(webdav: webdav, database: database) }
                    parent = NSFileProviderItemIdentifier.trashContainer.rawValue
                case .workingSet:
                    if initial { try await self.refreshWorkingSet(webdav: webdav, database: database) }
                    parent = nil
                default:
                    let folder = try await self.directory(ext: ext, webdav: webdav, database: database)
                    if initial { _ = try await self.refreshDirectory(path: folder.path, parent: folder.parent, webdav: webdav, database: database) }
                    parent = folder.parent
                }
                let result = try await database.itemsPage(parentOcId: parent, after: cursor, limit: Self.pageSize)
                try Task.checkCancellation()
                let next = try result.next.map {
                    NSFileProviderPage(try JSONEncoder().encode(Page(container: self.enumeratedItemIdentifier.rawValue, epoch: epoch, after: $0)))
                }
                observer.didEnumerate(result.items.map(self.item))
                if initial && self.enumeratedItemIdentifier != .trashContainer { ext.remoteCheckSucceeded() }
                ext.syncStatus.finish(activity, error: nil, checkedRemote: initial && self.enumeratedItemIdentifier == .workingSet)
                observer.finishEnumerating(upTo: next)
            } catch {
                ext.syncStatus.finish(activity, error: self.providerError(error))
                let container = self.enumeratedItemIdentifier == .rootContainer ? "root" : self.enumeratedItemIdentifier == .workingSet ? "working-set" : self.enumeratedItemIdentifier == .trashContainer ? "trash" : "directory"
                self.logger.error("Enumeration failed [\(container, privacy: .public)]: \(fileProviderErrorDiagnostic(error), privacy: .public)")
                observer.finishEnumeratingWithError(self.providerError(error))
            }
        }
    }

    func enumerateChanges(for observer: NSFileProviderChangeObserver, from anchor: NSFileProviderSyncAnchor) {
        guard let ext = fpExtension else {
            observer.finishEnumeratingWithError(NSFileProviderError(.notAuthenticated))
            return
        }
        startOperation {
            let activity = ext.syncStatus.begin(.metadata, key: "enumerate:" + self.enumeratedItemIdentifier.rawValue)
            do {
                try Task.checkCancellation()
                guard ext.isAuthenticated, let webdav = ext.webdavClient, let database = ext.database else {
                    throw NSFileProviderError(.notAuthenticated)
                }
                try await database.validateSyncAnchor(anchor.rawValue)
                let parent: String?
                switch self.enumeratedItemIdentifier {
                case .trashContainer:
                    if await webdav.supportsTrash { _ = try await FileProviderTrash.refresh(webdav: webdav, database: database) }
                    parent = NSFileProviderItemIdentifier.trashContainer.rawValue
                case .workingSet:
                    try await self.refreshWorkingSet(webdav: webdav, database: database)
                    parent = nil
                default:
                    let folder = try await self.directory(ext: ext, webdav: webdav, database: database)
                    _ = try await self.refreshDirectory(path: folder.path, parent: folder.parent, webdav: webdav, database: database)
                    parent = folder.parent
                }
                let changes = try await database.changes(since: anchor.rawValue, parentOcId: parent)
                try Task.checkCancellation()
                observer.didUpdate(changes.updated.map(self.item))
                observer.didDeleteItems(withIdentifiers: changes.deleted.map { NSFileProviderItemIdentifier($0) })
                ext.remoteCheckSucceeded()
                ext.syncStatus.finish(activity, error: nil, checkedRemote: self.enumeratedItemIdentifier == .workingSet)
                observer.finishEnumeratingChanges(upTo: NSFileProviderSyncAnchor(changes.anchor), moreComing: changes.moreComing)
            } catch {
                ext.syncStatus.finish(activity, error: self.providerError(error))
                self.logger.error("Change enumeration failed: \(fileProviderErrorDiagnostic(error), privacy: .public)")
                observer.finishEnumeratingWithError(self.providerError(error))
            }
        }
    }

    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        guard let database = fpExtension?.database else {
            completionHandler(nil)
            return
        }
        startOperation {
            do {
                try Task.checkCancellation()
                completionHandler(NSFileProviderSyncAnchor(try await database.currentSyncAnchor()))
            } catch {
                completionHandler(nil)
            }
        }
    }
}
