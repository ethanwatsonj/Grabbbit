//
//  CaptureOrganizer.swift
//  Grabbit
//

import Foundation

enum CaptureOrganizer {
    private static var windowInfoByCaptureID: [UUID: WindowSignature] = [:]

    /// Window metadata captured at screenshot time, before Grabbit UI took focus.
    /// Kept in-memory for the session and persisted on the history manifest so
    /// library Auto-Tag still has signal after a cold relaunch.
    static func registerCaptureContext(captureID: UUID, windowInfo: WindowSignature) {
        windowInfoByCaptureID[captureID] = windowInfo
        CaptureHistory.shared.setWindowSignature(id: captureID, windowInfo)
    }

    static func windowInfo(for captureID: UUID) -> WindowSignature? {
        if let live = windowInfoByCaptureID[captureID] {
            return live
        }
        if let stored = CaptureHistory.shared.windowSignature(for: captureID) {
            windowInfoByCaptureID[captureID] = stored
            return stored
        }
        return nil
    }

    @discardableResult
    static func moveCapture(id: UUID, to destination: CaptureDestination) -> Bool {
        moveCapture(id: id, to: destination, signature: nil)
    }

    @discardableResult
    private static func moveCapture(id: UUID, to destination: CaptureDestination, signature: WindowSignature?) -> Bool {
        let directory = destinationDirectoryURL(for: destination)

        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            return false
        }

        guard CaptureHistory.shared.moveCapture(id: id, toDirectory: directory) != nil else {
            return false
        }

        if let signature {
            CaptureDestinationMappingCache.shared.confirm(signature: signature, destination: destination)
        }
        return true
    }

    private static func destinationDirectoryURL(for destination: CaptureDestination) -> URL {
        var directory = AppSettings.destinationFolderURL
        directory.appendPathComponent(destination.productFolder, isDirectory: true)
        if let subfolder = destination.subfolder, !subfolder.isEmpty {
            directory.appendPathComponent(subfolder, isDirectory: true)
        }
        return directory
    }
}
