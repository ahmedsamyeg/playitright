//
//  PlayItRightTests.swift
//  PlayItRightTests
//

import Foundation
import Testing
@testable import PlayItRight

@MainActor
struct PlayItRightTests {
    @Test("Fresh library opens with an empty grid")
    func freshLibraryLoads() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let databaseURL = directory.appendingPathComponent("library.db")
        let library = LibraryViewModel(databaseURL: databaseURL)

        await library.load()

        #expect(library.state == .loaded([]))
        #expect(library.databasePath == databaseURL.path)
        #expect(FileManager.default.fileExists(atPath: databaseURL.path))
    }
}
