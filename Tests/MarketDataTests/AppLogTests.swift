import Foundation
import Testing
@testable import MarketData

@Suite(.serialized) struct AppLogTests {
    @Test func theLogRotatesAndStaysBounded() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "applog-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        AppLog.start(directory: dir, limit: 1000)
        for i in 0..<200 { AppLog.write("line \(i) " + String(repeating: "x", count: 40)) }
        let size = { (name: String) in (try? FileManager.default.attributesOfItem(atPath: dir.appending(path: name).path)[.size] as? Int) ?? 0 }
        #expect(size("app.log") < 1200)
        #expect(size("app.log.1") > 0 && size("app.log.1") < 1200)
        #expect(try String(contentsOf: dir.appending(path: "app.log")).contains("line 199"))
        AppLog.stop()
    }
}
