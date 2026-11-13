import Foundation
import SafariServices

/// Safari requires a native handler for every web extension; Pergola's extension talks to the app
/// over its local API instead, so this just answers.
@objc(SafariWebExtensionHandler)
final class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {
    func beginRequest(with context: NSExtensionContext) {
        context.completeRequest(returningItems: [], completionHandler: nil)
    }
}
