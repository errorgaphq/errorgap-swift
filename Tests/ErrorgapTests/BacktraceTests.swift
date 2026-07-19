import Foundation
import Testing
@testable import Errorgap

struct BacktraceTests {
    private struct LocatedError: Error, ErrorgapBacktraceProviding {
        let errorgapBacktrace: [ErrorgapBacktraceFrame]
    }

    @Test func includesInlineSwiftSourceForApplicationFrames() {
        let targetLine = #line + 1
        let swiftSourceMarker = "swift-source-marker"
        let error = LocatedError(errorgapBacktrace: [ErrorgapBacktraceFrame(
            file: #filePath,
            line: targetLine,
            function: "BacktraceTests.applicationFrame",
            inApp: true
        )])

        let frames = Backtrace.fromError(
            error,
            rootDirectory: FileManager.default.currentDirectoryPath,
            inAppModules: ["ErrorgapTests"]
        )
        let source = frames[0]["source"] as? [String: Any]
        let lines = source?["lines"] as? [String]
        #expect(frames[0]["in_app"] as? Bool == true)
        #expect(lines?.contains(where: { $0.contains(swiftSourceMarker) }) == true)
    }

    @Test func preservesVendorClassificationAndSource() {
        let frame = ErrorgapBacktraceFrame(
            file: #filePath,
            line: #line,
            function: "VendorInventory.requireStock",
            inApp: false
        )
        let frames = Backtrace.fromError(
            LocatedError(errorgapBacktrace: [frame]),
            rootDirectory: FileManager.default.currentDirectoryPath
        )
        #expect(frames[0]["in_app"] as? Bool == false)
        #expect(frames[0]["source"] != nil)
    }
}
