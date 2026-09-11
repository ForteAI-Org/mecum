//
//  SymbolTable.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 08/09/2026.
//

import Darwin
import ObjectiveC

/// ResolvedSymbol is one primitive that answered, with the two facts a Ledger
/// row needs: the exact spelling that was asked for and the image it came out
/// of. "Symbol present" without an image is a useless datum, because
/// `dlopen(nil)` searches every loaded image and the `CG*` spellings live in
/// CoreGraphics while their `SL*` twins live in SkyLight.
nonisolated public struct ResolvedSymbol: Sendable, Equatable {

    /// The spelling that was passed to `dlsym`.
    public let name: String

    /// The last path component of the image the symbol was found in, or an
    /// empty string when `dladdr` cannot name it.
    public let image: String

    /// The resolved address, kept as a bit pattern so the value stays trivially
    /// `Sendable`.
    public let address: UInt

    public init(name: String, image: String, address: UInt) {
        self.name    = name
        self.image   = image
        self.address = address
    }
}

/// SymbolTable resolves every private primitive the kit uses **once**, at first
/// touch, instead of once per call site: resolving where it is used means a
/// `dlopen` plus a `dlsym` in every file that needs one, and on the posting path
/// that lands on every single event.
///
/// A primitive that does not resolve is **not** an error here. Refusing at
/// resolution time would turn a missing selector on one Mac into a crash for
/// every Facility; instead the failure is a state that `FacilityGate` reads,
/// and only the Facility that needs the missing primitive goes `unavailable`.
nonisolated public final class SymbolTable: Sendable {

    /// The table for this process. Resolution is lazy and happens once.
    public static let shared = SymbolTable()

    /// Every C symbol that answered, by primitive.
    public let symbols: [PrivateSymbol: ResolvedSymbol]

    /// Every private class that answered, by primitive. The `image` is the one
    /// the Objective-C runtime reports for the class, not for a symbol.
    public let classes: [PrivateClass: ResolvedSymbol]

    /// The `ledgerKey` of every selector its owning class responds to.
    public let selectors: Set<String>

    init() {
        let handle = dlopen(nil, RTLD_LAZY)
        var symbols  : [PrivateSymbol: ResolvedSymbol] = [:]
        var classes  : [PrivateClass: ResolvedSymbol]  = [:]
        var selectors: Set<String>                     = []

        for symbol in PrivateSymbol.allCases {
            var address = handle.flatMap { dlsym($0, symbol.rawValue) }
            if address == nil, let image = dlopen(symbol.image, RTLD_LAZY) {
                address = dlsym(image, symbol.rawValue)
            }
            guard let address else { continue }
            symbols[symbol] = ResolvedSymbol(
                name   : symbol.rawValue,
                image  : Self.imageName(containing: address),
                address: UInt(bitPattern: address)
            )
        }

        for privateClass in PrivateClass.allCases {
            guard let resolved = objc_lookUpClass(privateClass.rawValue) else { continue }
            classes[privateClass] = ResolvedSymbol(
                name   : privateClass.rawValue,
                image  : Self.imageName(ofClass: resolved),
                address: UInt(bitPattern: Unmanaged.passUnretained(resolved as AnyObject).toOpaque())
            )
            for selector in PrivateSelector.all where selector.owner == privateClass {
                guard class_respondsToSelector(resolved, sel_getUid(selector.name)) else { continue }
                selectors.insert(selector.ledgerKey)
            }
        }

        self.symbols   = symbols
        self.classes   = classes
        self.selectors = selectors
    }

    /// The raw address of a resolved symbol, or `nil` when it did not resolve.
    public func address(of symbol: PrivateSymbol) -> UnsafeRawPointer? {
        guard let entry = symbols[symbol] else { return nil }
        return UnsafeRawPointer(bitPattern: entry.address)
    }

    /// The class object itself, for the call sites that have to send it a
    /// message. It is guarded by the resolution recorded at init rather than
    /// being a bare `objc_lookUpClass`, so a Facility cannot reach a class the
    /// gate never saw: the table stays the single answer to "is this primitive
    /// here".
    public func objcClass(_ privateClass: PrivateClass) -> AnyClass? {
        guard classes[privateClass] != nil else { return nil }
        return objc_lookUpClass(privateClass.rawValue)
    }

    /// The symbol as a callable `@convention(c)` function. The caller states
    /// the ABI, and a wrong ABI is undefined behaviour: this is the one place
    /// in the kit where the type system stops helping, which is exactly why the
    /// shape of every record and argument list is a Ledger check and not a
    /// comment.
    public func function<Function>(_ symbol: PrivateSymbol, as type: Function.Type) -> Function? {
        guard let address = address(of: symbol) else { return nil }
        return unsafeBitCast(address, to: type)
    }

    /// True when the primitive is present on this system. Fields, records and
    /// behaviours have nothing to resolve: they are decided by the Ledger and
    /// by the record round trip, so they answer `true` here.
    public func isResolved(_ requirement: PrimitiveRequirement) -> Bool {
        switch requirement {
        case .symbol(let symbol):        symbols[symbol]      != nil
        case .objcClass(let objcClass):  classes[objcClass]   != nil
        case .selector(let selector):    selectors.contains(selector.ledgerKey)
        case .field, .record, .behavior: true
        }
    }

    /// The Ledger key of the first primitive of the list that is missing, which
    /// is what a Facility puts in `unavailable(reason:)`.
    public func firstUnresolved(of requirements: [PrimitiveRequirement]) -> String? {
        requirements.first { !isResolved($0) }?.ledgerKey
    }

    private static func imageName(containing address: UnsafeRawPointer) -> String {
        var info = Dl_info()
        guard dladdr(address, &info) != 0, let path = info.dli_fname else { return "" }
        return Self.lastComponent(of: String(cString: path))
    }

    private static func imageName(ofClass resolved: AnyClass) -> String {
        guard let path = class_getImageName(resolved) else { return "" }
        return Self.lastComponent(of: String(cString: path))
    }

    private static func lastComponent(of path: String) -> String {
        path.split(separator: "/").last.map(String.init) ?? path
    }
}
