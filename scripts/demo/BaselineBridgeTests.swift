import DSHTransport
@testable import DSHCore
import XCTest

@MainActor
final class BaselineBridgeTests: XCTestCase {
    struct Peer: Decodable { let address: String, pin: Data, bearer: String }

    func testApprovalAndQueueOverPinnedTLS() async throws {
        let file = try XCTUnwrap(ProcessInfo.processInfo.environment["DSHM_COMPAT_PEER"])
        continueAfterFailure = false
        let offer = try String(contentsOf: URL(filePath: file + ".offer"), encoding: .utf8)
        XCUIApplication().launch()
        let app = openDeepLink(try XCTUnwrap(URL(string: offer)))
        let confirm = app.buttons["pairing.confirm"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 15))
        confirm.tap()
        let status = app.descendants(matching: .any)["pairing.status"]
        XCTAssertEqual(waitForValue(status, in: ["paired", "failed"], timeout: 30), "paired", status.label)
        app.buttons["pairing.done"].tap()
        openDrawer(app)
        let channel = app.descendants(matching: .any)["host.channel"]
        XCTAssertTrue(channel.waitForExistence(timeout: 20))
        XCTAssertEqual(channel.value as? String, "TLS 1.3")

        let peer = try JSONDecoder().decode(Peer.self, from: Data(contentsOf: URL(filePath: file)))
        let connection = HostConnection(endpoints: [try XCTUnwrap(HostEndpoint(address: peer.address))],
                                        spkiSHA256: peer.pin, authorization: "Bearer " + peer.bearer)
        try await connection.connect()
        let capabilities = await connection.capabilities
        XCTAssertTrue(capabilities.contains("approvals.v1"))
        XCTAssertTrue(capabilities.contains("conversation.v2"))
        let resumed = try await connection.resume(logID: "", afterSeq: 0)
        let listing = try await connection.listTasks()
        XCTAssertFalse(resumed.logID.isEmpty)
        XCTAssertEqual(listing.logID, resumed.logID)
        let task = try await connection.createTask(prompt: "Run the tool and wait for my approval.", selection: nil, workspace: nil, uploadIDs: [])
        var pending: Approval?
        for _ in 0..<120 {
            pending = try await connection.listTasks().tasks.first { $0.taskID == task }?.approvals.first
            if pending != nil { break }
            try await Task.sleep(for: .milliseconds(250))
        }
        let approval = try XCTUnwrap(pending)
        let queued = try await connection.sendMessage(taskID: task, text: "Wait for the next turn", mode: .queue, uploadIDs: [])
        let placement = try await connection.editQueue(taskID: task, messageID: queued, action: .remove)
        XCTAssertEqual(placement, .removed)
        try await connection.answerApproval(id: approval.id, allow: false)
        let updated = try await connection.listTasks()
        XCTAssertEqual(updated.tasks.first { $0.taskID == task }?.approvals.count, 0)
        await connection.disconnect()
    }
}
