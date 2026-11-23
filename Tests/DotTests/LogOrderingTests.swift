import Foundation
import XCTest

import DotCore

/// The log is written on a queue of its own now, so two things that a
/// synchronous write gave for free have to be proved: a reader that waits for
/// `flush()` sees every line, and each writer's lines keep the order it wrote
/// them in.
final class LogOrderingTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dot-log-order-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testOneThousandLinesFromTwoThreadsArriveWholeAndInOrder() throws {
        let log = Log()
        let url = directory.appendingPathComponent("Dot.log")
        XCTAssertTrue(log.openFile(at: url))

        let perWriter = 500
        let group = DispatchGroup()
        for writer in 0..<2 {
            DispatchQueue.global(qos: .userInitiated).async(group: group) {
                for index in 0..<perWriter {
                    log.info("line-\(writer)-\(index)", [
                        "writer": .int(writer),
                        "index": .int(index),
                    ])
                }
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 30), .success, "a writer never finished")

        // The one call a reader needs: everything written before it is on disk.
        log.flush()

        let written = try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n")
            .map(String.init)
        XCTAssertEqual(written.count, perWriter * 2, "a line was lost or duplicated")

        for writer in 0..<2 {
            let indexes = written.compactMap { line -> Int? in
                guard let data = line.data(using: .utf8),
                      let object = try? JSONSerialization.jsonObject(with: data),
                      let fields = object as? [String: Any],
                      fields["writer"] as? Int == writer
                else { return nil }
                return fields["index"] as? Int
            }
            XCTAssertEqual(
                indexes,
                Array(0..<perWriter),
                "writer \(writer)'s lines did not keep the order it wrote them in"
            )
        }
    }
}
