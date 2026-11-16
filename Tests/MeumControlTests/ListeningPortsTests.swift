import Darwin
import XCTest
@testable import MeumControl

final class ListeningPortsTests: XCTestCase {
    /// Opens a listening TCP socket on a free port; returns (fd, port).
    private func listen() throws -> (Int32, Int) {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(fd, 0)
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = 0
        let rc = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        XCTAssertEqual(rc, 0)
        XCTAssertEqual(Darwin.listen(fd, 1), 0)
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) } }
        return (fd, Int(UInt16(bigEndian: addr.sin_port)))
    }

    func testFindsOwnListeningPortAndThroughAParent() throws {
        let (fd, port) = try listen()
        defer { close(fd) }
        XCTAssertTrue(ListeningPorts.ports(of: getpid()).contains(port))
        // the test process is a descendant of its parent: the parent's tree reports the port
        let found = ListeningPorts.byRoot(["root": getppid()])
        XCTAssertTrue(found["root"]?.contains(port) ?? false, "\(found)")
        close(fd)
        XCTAssertFalse(ListeningPorts.ports(of: getpid()).contains(port))
    }

    func testTree() {
        let parents: [pid_t: pid_t] = [2: 1, 3: 2, 4: 2, 5: 9]
        XCTAssertEqual(ListeningPorts.tree(of: 2, parents: parents), [2, 3, 4])
        XCTAssertEqual(ListeningPorts.tree(of: 7, parents: parents), [7])
    }

    func testAgentsOwnPortsAreSkippedButTheirChildrensCount() {
        // 1 shell -> 2 agent (own service on 50000) -> 3 dev server on 3000; 4 a plain listener on 8080
        let parents: [pid_t: pid_t] = [2: 1, 3: 2, 4: 1]
        let ports: [pid_t: [Int]] = [2: [50000], 3: [3000], 4: [8080]]
        let found = ListeningPorts.collect(["ws": pid_t(1)], parents: parents, ports: { ports[$0] ?? [] },
                                           skip: { $0 == 2 })
        XCTAssertEqual(found["ws"], [3000, 8080])
        // an agent alone leaves the workspace without ports
        XCTAssertNil(ListeningPorts.collect(["ws": pid_t(2)], parents: [:], ports: { ports[$0] ?? [] }, skip: { $0 == 2 })["ws"])
    }
}
