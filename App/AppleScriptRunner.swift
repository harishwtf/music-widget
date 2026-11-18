import AppKit
import Foundation

/// Runs AppleScript on the main thread with compiled-script caching.
enum AppleScriptRunner {
    private static var cache: [String: NSAppleScript] = [:]
    /// Error number of the most recent run (nil when it succeeded).
    static var lastErrorNumber: Int?
    static var lastErrorMessage: String = ""

    @discardableResult
    static func run(_ source: String) -> NSAppleEventDescriptor? {
        let script: NSAppleScript
        if let cached = cache[source] {
            script = cached
        } else {
            guard let fresh = NSAppleScript(source: source) else { return nil }
            var compileError: NSDictionary?
            guard fresh.compileAndReturnError(&compileError) else {
                NSLog("AppleScript compile error: \(compileError ?? [:])")
                return nil
            }
            cache[source] = fresh
            script = fresh
        }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if let error {
            lastErrorNumber = (error["NSAppleScriptErrorNumber"] as? NSNumber)?.intValue ?? -1
            lastErrorMessage = error["NSAppleScriptErrorMessage"] as? String ?? ""
            NSLog("AppleScript error: \(error)")
            return nil
        }
        lastErrorNumber = nil
        lastErrorMessage = ""
        return result
    }

    static func string(_ source: String) -> String? {
        run(source)?.stringValue
    }

    static func isRunning(bundleID: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }
}

/// Parses AppleScript numbers, tolerating locale decimal commas and exponent notation.
func scriptNumber(_ s: String) -> Double {
    Double(s.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")) ?? 0
}

let unitSeparator = "\u{1F}"
