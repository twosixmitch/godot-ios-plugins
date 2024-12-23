// The Swift Programming Language
// https://docs.swift.org/swift-book

import StoreKit
import SwiftGodot


#initSwiftExtension(cdecl: "swift_entry_point", types: [InAppStore.self])


@Godot
class InAppStore: Node {
    #signal("initted")
    /// Called when a product is puchased
    //#signal("product_purchased", arguments: ["product_id": String.self])
    
    private(set) var productIDs: [String] = []
    private(set) var products: [Product]
    private(set) var purchasedProducts: Set<String> = Set<String>()
    
    required init() {
        products = []
        super.init()
    }

    required init(nativeHandle: UnsafeRawPointer) {
        products = []
        super.init(nativeHandle: nativeHandle)
    }
    
    deinit {
        GD.print("Was deinit!")
    }
    
    @Callable
    public func initialize(productIDs: [String]) {
        self.productIDs = productIDs
        GD.print("initting for ya")
        emit(signal: InAppStore.initted)
    }
}
