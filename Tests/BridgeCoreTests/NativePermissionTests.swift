import Foundation
import XCTest
@testable import BridgeMac

@MainActor final class NativePermissionTests: XCTestCase {
    func testCompletionReturnsGrantOrDenialFromBackgroundCallback() async throws {
        for granted in [true, false] {
            let result = try await NativeEventKitProvider.requestFullAccess { completion in
                MainActor.assertIsolated()
                DispatchQueue.global().async { completion(granted, nil) }
            }
            XCTAssertEqual(result, granted)
        }
    }
    func testCompletionErrorBecomesBoundedPermissionErrorEvenWhenGranted() async {
        enum SyntheticFailure: Error { case failed }
        do {
            _ = try await NativeEventKitProvider.requestFullAccess { completion in
                MainActor.assertIsolated()
                DispatchQueue.global().async { completion(true, SyntheticFailure.failed) }
            }
            XCTFail("A provider error must fail the permission request")
        } catch {
            XCTAssertEqual(error as? EventKitAdapterError, .permissionRequired)
        }
    }
}
