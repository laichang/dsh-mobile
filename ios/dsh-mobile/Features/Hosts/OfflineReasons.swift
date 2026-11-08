import DSHCore
import SwiftUI

/// D125 · screens H and X3: why a host's bridge does not answer, in the user's words. DSHKit
/// sorts each failed address into a reason (`AddressFailure.Kind`); these are its words.
extension AddressFailure.Kind {
    /// After the address on the host row (H): "127.0.0.1:47801 · <sentence> (<error>)".
    var sentence: Text {
        switch self {
        case .nothingListens: Text("Nothing listens on this port", tableName: "Hosts")
        case .otherProgram: Text("Another program uses this port, not the DSH bridge", tableName: "Hosts")
        case .notReachable: Text("Not reachable", tableName: "Hosts")
        }
    }

    /// On the offline card (X3), which shows no address: the port in the words.
    func sentence(port: Int) -> Text {
        switch self {
        case .nothingListens: Text("Nothing listens on port \(String(port))", tableName: "Hosts")
        case .otherProgram: Text("Another program uses port \(String(port))", tableName: "Hosts")
        case .notReachable: Text("Not reachable", tableName: "Hosts")
        }
    }

    /// What to do on the computer, when the computer answered (H). The phone does not move the
    /// bridge to another port by itself.
    var fix: Text? {
        switch self {
        case .otherProgram:
            Text("Stop that program on the computer, or give the bridge another port in DSH and pair again.", tableName: "Hosts")
        case .nothingListens:
            Text("Start DSH on the computer, with the dsh-mobile bridge on.", tableName: "Hosts")
        case .notReachable:
            nil
        }
    }

    /// The computer answered at this address: the problem is DSH's bridge, not the network.
    var computerAnswers: Bool { self != .notReachable }
}
