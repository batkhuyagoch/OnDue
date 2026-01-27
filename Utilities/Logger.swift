import Foundation
import Combine

enum Logger {
    static func info(_ message: String) {
        print("[OnDue] \(message)")
    }
}
