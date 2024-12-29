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
        case none            = 0
        case unknown         = 1
        case userCancelled   = 2
        case networkError    = 3
        case systemError     = 4
        case productNotFound = 5
    }
    
    enum InAppPurchaseStatus: Int {
        case successful              = 0
        case successfulButUnverified = 1
        case pendingAuthorization    = 2
        case userCancelled           = 3
        case error                   = 4
    }
    
    private(set) var purchasedProductIDs = Set<String>()
    
    var transactionObserver: Task<Void, Never>? = nil
    
    required init() {
        super.init()
    }
    
    required init(nativeHandle: UnsafeRawPointer) {
        super.init(nativeHandle: nativeHandle)
    }
    
    deinit {
        transactionObserver?.cancel()
    }
    
    /// Initialize purchases
    ///
    /// - Parameters:
    ///     - productIdentifiers: An array of product identifiers that you enter in App Store Connect.
    ///     - onComplete: Callback with parameters: (error: Variant, purchased_product_ids: Variant) -> (error: Int, purchased_product_ids: [``String``])
    @Callable
    func initialize(onComplete: Callable) {
        transactionObserver = self.observeTransactionUpdates()
        
        Task {
            await updatePurchasedProducts()
            onComplete.callDeferred(Variant(InAppStoreError.none.rawValue), Variant(getPurchasedProductIDs()))
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
                onComplete.callDeferred(Variant(InAppStoreError.unknown.rawValue), Variant(GArray()))
            }
        }
    }
    
    /// Purchase a product
    ///
    /// - Parameters:
    ///     - productID: The identifier of the product that you enter in App Store Connect.
    ///     - onComplete: Callback with parameter: (product_id: Variant, error: Variant, status: Variant) -> (product_id: String, error: Int `InAppStoreError`, status: Int `InAppPurchaseStatus`)
    @Callable
    func purchase(_ productID: String, onComplete: Callable) {
        Task {
            do {
                // First lets find the StoreKit object with this product id.
                let product: Product? = try await getProduct(productID)
                
                // Early escape if we can't find it.
                guard let product else {
                    onComplete.callDeferred(Variant(productID), Variant(InAppStoreError.productNotFound.rawValue), Variant(InAppPurchaseStatus.error.rawValue))
                    return
                }
                
                // Let's attempt to purchase the product.
                let result: Product.PurchaseResult = try await product.purchase()
                
                switch result {
                case let .success(.verified(transaction)):
                    // Successful purhcase!
                    await transaction.finish()
                    await self.updatePurchasedProducts()
                    onComplete.callDeferred(Variant(productID), Variant(InAppStoreError.none.rawValue), Variant(InAppPurchaseStatus.successful.rawValue))
                    break
                    
                case let .success(.unverified(_, error)):
                    // Successful purchase but transaction/receipt can't be verified.
                    // Could be a jailbroken phone. I'm just going to consider this a valid purchase.
                    onComplete.callDeferred(Variant(productID), Variant(InAppStoreError.none.rawValue), Variant(InAppPurchaseStatus.successful.rawValue))
                    break
                
                case .pending:
                    // Transaction waiting on SCA (Strong Customer Authentication) or approval from Ask to Buy.
                    onComplete.callDeferred(Variant(productID), Variant(InAppStoreError.none.rawValue), Variant(InAppPurchaseStatus.pendingAuthorization.rawValue))
                    break
                    
                case .userCancelled:
                    // User cancelled the purchase.
                    onComplete.callDeferred(Variant(productID), Variant(InAppStoreError.none.rawValue), Variant(InAppPurchaseStatus.userCancelled.rawValue))
                    break
                
                @unknown default:
                    // Encountered something we didnt handle. Let's consider it an error.
                    onComplete.callDeferred(Variant(productID), Variant(InAppStoreError.unknown.rawValue), Variant(InAppPurchaseStatus.error.rawValue))
                    break
                }
            } catch {
                GD.pushError("IAP Failed to get products from App Store, error: \(error)")
                onComplete.callDeferred(Variant(productID), Variant(InAppStoreError.unknown.rawValue), Variant(InAppPurchaseStatus.error.rawValue))
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
        return purchasedProductIDs.contains(productID)
    }
    
    /// Restore purchases
    ///
    /// - Parameter onComplete: Callback with parameter: (error: Variant) -> (error: Int)
    @Callable
    func restorePurchases(onComplete: Callable) {
        Task {
            do {
                try await AppStore.sync()
                await updatePurchasedProducts()
                onComplete.callDeferred(Variant(InAppStoreError.none.rawValue), Variant(getPurchasedProductIDs()))
            } catch StoreKitError.userCancelled {
                onComplete.callDeferred(Variant(InAppStoreError.userCancelled.rawValue), Variant(GArray()))
            } catch StoreKitError.networkError(let urlError) {
                onComplete.callDeferred(Variant(InAppStoreError.networkError.rawValue), Variant(GArray()))
            } catch StoreKitError.systemError(let sysError) {
                onComplete.callDeferred(Variant(InAppStoreError.systemError.rawValue), Variant(GArray()))
            } catch {
                GD.pushError("InAppStore: Failed to restore purchases: \(error)")
                onComplete.callDeferred(Variant(InAppStoreError.unknown.rawValue), Variant(GArray()))
            }
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
    
    func updatePurchasedProducts() async {
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result else {
                continue
            }

            if transaction.revocationDate == nil {
                self.purchasedProductIDs.insert(transaction.productID)
            } else {
                self.purchasedProductIDs.remove(transaction.productID)
            }
        }
    }
    
    private func getPurchasedProductIDs() -> GArray {
        var products: GArray = GArray()
        for productID in purchasedProductIDs {
            products.append(Variant(productID))
        }
        return products
    }
    
    private func observeTransactionUpdates() -> Task<Void, Never> {
        Task(priority: .background) { [unowned self] in
            for await verificationResult in Transaction.updates {
                // TODO: Using verificationResult directly would be better
                await self.updatePurchasedProducts()
            }
        }
    }
}
