@testable import DSHCore
import XCTest

final class BaselineBridgeTests: XCTestCase {
    func testApprovalAndQueueOverPinnedTLS() async throws {
        let file = try XCTUnwrap(ProcessInfo.processInfo.environment["DSHM_COMPAT_PEER"])
        let pairing = Pairing()
        let offer = try String(contentsOf: URL(filePath: file + ".offer"), encoding: .utf8)
        let host = try await pairing.pair(PairingOffer(string: offer))
        let config = try XCTUnwrap(HostSync.HostConfig(paired: host, using: pairing))
        #if DSHM_BASELINE_CLIENT
        let connection = config.connection
        #else
        let connection = config.commands
        #endif
        try await connection.connect()
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
