import Foundation
import Network
import XCTest
@testable import HomeostatShared

final class BoundedHTTPTests: XCTestCase {
    /// A local server that answers "ok" after `delay` seconds.
    func slowServer(delay: Double) async throws -> (NWListener, URL) {
        let listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { connection in
            connection.start(queue: .global())
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { _, _, _, _ in
                DispatchQueue.global().asyncAfter(deadline: .now() + delay) {
                    let reply = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok"
                    connection.send(content: Data(reply.utf8), completion: .contentProcessed { _ in connection.cancel() })
                }
            }
        }
        let ready = AsyncStream<UInt16> { continuation in
            listener.stateUpdateHandler = { if case .ready = $0 { continuation.yield(listener.port!.rawValue) } }
        }
        listener.start(queue: .global())
        var ports = ready.makeAsyncIterator()
        let port = await ports.next()!
        return (listener, URL(string: "http://127.0.0.1:\(port)/")!)
    }

    func testTimeoutIsTheCallersNotAFixedTenSeconds() async throws {
        let (listener, url) = try await slowServer(delay: 1.5)
        defer { listener.cancel() }
        do {
            _ = try await BoundedHTTP.send(URLRequest(url: url), timeout: 0.5)
            XCTFail("a 0.5 s budget must not wait for a 1.5 s answer")
        } catch {}
        let (data, response) = try await BoundedHTTP.send(URLRequest(url: url), timeout: 5)
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(data, Data("ok".utf8))
    }
}
