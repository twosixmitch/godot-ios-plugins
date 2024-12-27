import StoreKit
import SwiftGodot


#initSwiftExtension(
    cdecl: "swift_entry_point",
    types: [
        InAppStore.self,
        InAppStoreProduct.self
    ]
)

public enum StoreError: Error {
    case failedVerification
}


@Godot
class InAppStore: Node {
    enum InAppStoreError: Int, Error {
        case none          = 0
        case unknown       = 1
        case userCancelled = 2
        case networkError  = 3
        case systemError   = 4
    }
    
    enum InAppPurchaseStatus: Int {
        case successful              = 0
        case successfulButUnverified = 1
        case pendingAuthorization    = 2
        case cancelledByUser         = 3
        case error                   = 4
    }
    
    enum InAppPurchaseError: Int, Error {
        case none            = 0
        case productNotFound = 1
        case purchaseFailed  = 2
    }
    
    /// Called when a product is puchased
    #signal("product_purchased", arguments: ["product_id": String.self])
    /// Called when a purchase is revoked
    #signal("product_revoked", arguments: ["product_id": String.self])
    
    private(set) var productIDs: [String] = []
    private(set) var products: [Product]
    private(set) var purchasedProducts: Set<String> = Set<String>()
    
    var updateListenerTask: Task<Void, Error>? = nil
    
    required init() {
        products = []
        super.init()
    }
    
    required init(nativeHandle: UnsafeRawPointer) {
        products = []
        super.init(nativeHandle: nativeHandle)
    }
    
    deinit {
        updateListenerTask?.cancel()
    }
    
    /// Initialize purchases
    ///
    /// - Parameters:
    ///     - productIdentifiers: An array of product identifiers that you enter in App Store Connect.
    @Callable
    func initialize(productIDs: [String]) {
        self.productIDs = productIDs
        
        updateListenerTask = self.listenForTransactions()
        
        Task {
            await updateProducts()
            await updateProductStatus()
        }
    }
    
    /// Get products
    ///
    /// - Parameters:
    ///     - identifiers: An array of product identifiers that you enter in App Store Connect.
    ///     - onComplete: Callback with parameters: (error: Variant, products: Variant) -> (error: Int, products: [``InAppStoreProduct``])
    @Callable
    func getProducts(identifiers: [String], onComplete: Callable) {
        Task {
            do {
                let storeProducts: [Product] = try await Product.products(for: identifiers)
                var products: GArray = GArray()
                
                // Convert the StoreKit objects into objects Godot can read.
                for storeProduct: Product in storeProducts {
                    var product: InAppStoreProduct = InAppStoreProduct()
                    product.displayName      = storeProduct.displayName
                    product.displayPrice     = storeProduct.displayPrice
                    product.storeDescription = storeProduct.description
                    product.productID        = storeProduct.id
                    
                    switch storeProduct.type {
                    case .consumable:
                        product.type = InAppStoreProduct.TYPE_CONSUMABLE
                    case .nonConsumable:
                        product.type = InAppStoreProduct.TYPE_NON_CONSUMABLE
                    case .autoRenewable:
                        product.type = InAppStoreProduct.TYPE_AUTO_RENEWABLE
                    case .nonRenewable:
                        product.type = InAppStoreProduct.TYPE_NON_RENEWABLE
                    default:
                        product.type = InAppStoreProduct.TYPE_UNKNOWN
                    }
                    
                    products.append(Variant(product))
                }
                
                // Return the objects back to the Godot runtime.
                onComplete.callDeferred(Variant(InAppStoreError.none.rawValue), Variant(products))
                
            } catch StoreKitError.userCancelled {
                onComplete.callDeferred(Variant(InAppStoreError.userCancelled.rawValue), Variant(GArray()))
            } catch StoreKitError.networkError(let urlError) {
                onComplete.callDeferred(Variant(InAppStoreError.networkError.rawValue), Variant(GArray()))
            } catch StoreKitError.systemError(let sysError) {
                onComplete.callDeferred(Variant(InAppStoreError.systemError.rawValue), Variant(GArray()))
            } catch {
                GD.pushError("InAppStore: getProducts, failed to get products from App Store, error: \(error)")
                onComplete.callDeferred(Variant(InAppStoreError.unknown.rawValue), Variant(GArray()))
            }
        }
    }
    
    /// Purchase a product
    ///
    /// - Parameters:
    ///     - productID: The identifier of the product that you enter in App Store Connect.
    ///     - onComplete: Callback with parameter: (error: Variant, status: Variant) -> (error: Int `InAppPurchaseError`, status: Int `InAppPurchaseStatus`)
    @Callable
    func purchase(_ productID: String, onComplete: Callable) {
        GD.print("InAppStore: purchase(\(productID))")
        
        Task {
            do {
                if let product: Product = try await getProduct(productID) {
                    let result: Product.PurchaseResult = try await product.purchase()
                    
                    switch result {
                    case .success(let verification):
                        // Success
                        let transaction: Transaction = try checkVerified(verification)
                        await transaction.finish()
                        
                        onComplete.callDeferred(Variant(productID), Variant(InAppPurchaseError.none.rawValue), Variant(InAppPurchaseStatus.successful.rawValue))
                        break
                    case .pending:
                        // Transaction waiting on authentication or approval
                        onComplete.callDeferred(Variant(productID), Variant(InAppPurchaseError.none.rawValue), Variant(InAppPurchaseStatus.pendingAuthorization.rawValue))
                        break
                        
                    case .userCancelled:
                        // User cancelled the purchase
                        onComplete.callDeferred(Variant(productID), Variant(InAppPurchaseError.none.rawValue), Variant(InAppPurchaseStatus.cancelledByUser.rawValue))
                        break
                    }
                } else {
                    onComplete.callDeferred(Variant(productID), Variant(InAppPurchaseError.productNotFound.rawValue), Variant(InAppPurchaseStatus.error.rawValue))
                }
            } catch {
                GD.pushError("IAP Failed to get products from App Store, error: \(error)")
                onComplete.callDeferred(Variant(productID), Variant(InAppPurchaseError.purchaseFailed.rawValue), Variant(InAppPurchaseStatus.error.rawValue))
            }
        }
    }
    
    /// Check if a product is purchased
    ///
    /// - Parameters:
    ///     - productID: The identifier of the product that you enter in App Store Connect.,
    ///
    /// - Returns: True if a product is purchased
    @Callable
    func isPurchased(_ productID: String) -> Bool {
        GD.print("InAppStore: isPurchased(\(productID))")
        return purchasedProducts.contains(productID)
    }
    
    /// Restore purchases
    ///
    /// - Parameter onComplete: Callback with parameter: (error: Variant) -> (error: Int)
    @Callable
    func restorePurchases(onComplete: Callable) {
        Task {
            do {
                try await AppStore.sync()
                onComplete.callDeferred(Variant(InAppStoreError.none.rawValue))
            } catch {
                GD.pushError("InAppStore: Failed to restore purchases: \(error)")
                onComplete.callDeferred(Variant(InAppStoreError.unknown.rawValue))
            }
        }
    }
    
    /// Get the current app environment
    ///
    /// - Parameter onComplete: Callback with parameter: (error: Variant, data: Variant) -> (error: Int, data: String)
    @Callable
    public func getEnvironment(onComplete: Callable) {
        GD.print("InAppStore getEnvironment")
        
        guard let path = Bundle.main.appStoreReceiptURL?.path else {
            onComplete.callDeferred(Variant(InAppStoreError.unknown.rawValue), Variant("unknown"))
            return
        }
        
        if path.contains("CoreSimulator") {
            onComplete.callDeferred(Variant(InAppStoreError.none.rawValue), Variant("xcode"))
        } else if path.contains("sandboxReceipt") {
            onComplete.callDeferred(Variant(InAppStoreError.none.rawValue), Variant("sandbox"))
        } else {
            onComplete.callDeferred(Variant(InAppStoreError.none.rawValue), Variant("production"))
        }
    }
    
    //
    // Internal functionality
    //
    
    func getProduct(_ productIdentifier: String) async throws -> Product? {
        var product: [Product] = []
        do {
            product = try await Product.products(for: [productIdentifier])
        } catch {
            GD.pushError("Unable to get product with identifier: \(productIdentifier): \(error)")
        }
        
        return product.first
    }
    
    func updateProducts() async {
        print("InAppStore: update products")
        
        do {
            let storeProducts = try await Product.products(for: productIDs)
            products = storeProducts
            GD.print("InAppStore: update products complete, found \(products.count) products")
        } catch {
            GD.pushError("Failed to get products from App Store: \(error)")
        }
    }
    
    func updateProductStatus() async {
        print("InAppStore: update product status")
        
        for await result: VerificationResult<Transaction> in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result else {
                continue
            }
            
            if transaction.revocationDate == nil {
                self.purchasedProducts.insert(transaction.productID)
                emit(signal: InAppStore.productPurchased, transaction.productID)
            } else {
                self.purchasedProducts.remove(transaction.productID)
                emit(signal: InAppStore.productRevoked, transaction.productID)
            }
        }
    }
    
    func checkVerified<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .unverified:
            throw StoreError.failedVerification
        case .verified(let safe):
            return safe
        }
    }
    
    func listenForTransactions() -> Task<Void, Error> {
        print("InAppStore: listen for transactions")
        return Task.detached {
            for await result: VerificationResult<Transaction> in Transaction.updates {
                do {
                    let transaction: Transaction = try self.checkVerified(result)
                    await self.updateProductStatus()
                    await transaction.finish()
                } catch {
                    GD.pushWarning("Transaction failed verification")
                }
            }
        }
    }
}
