import Foundation
import Combine

enum Logger {
    static func info(_ message: String) {
        print("[OnDue] ℹ️  \(message)")
    }
    
    static func warn(_ message: String) {
        print("[OnDue] ⚠️  \(message)")
    }
    
    static func error(_ message: String) {
        print("[OnDue] ❌ \(message)")
    }
}
