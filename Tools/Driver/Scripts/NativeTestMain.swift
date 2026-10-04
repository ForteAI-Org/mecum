//
//  NativeTestMain.swift
//  Mecum, Driver native tests
//

import Darwin
import Foundation
import Testing

/// NativeTestMain runs a built Swift Testing bundle from a synchronous RunLoop.
/// The bundle owns AppKit pumping. Testing supplies the final exit status.
/// A synchronous main survives a native RunLoop return during async capture;
/// Swift's async main otherwise exits before the native test reports completion.
@main
@MainActor
struct NativeTestMain {

    static func main() {
        guard CommandLine.arguments.count > 1 else {
            print("usage: NativeTestMain <test-bundle-binary> <Swift Testing arguments>")
            exit(2)
        }
        let path = CommandLine.arguments[1]
        guard let bundle = dlopen(path, RTLD_NOW | RTLD_GLOBAL) else {
            let detail = dlerror().map { String(cString: $0) } ?? "unknown loader error"
            print("NativeTestMain could not load the test bundle: \(detail)")
            exit(2)
        }
        // Keep the bundle loaded for the process; async tests borrow its code.
        _ = bundle
        let timer = Timer(timeInterval: 0.05, repeats: true) { _ in }
        RunLoop.main.add(timer, forMode: .common)
        Task { @MainActor in
            let status: CInt = await Testing.__swiftPMEntryPoint()
            exit(status)
        }
        while true { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
    }
}
