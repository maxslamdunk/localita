import Foundation
import Testing
@testable import TurboFieldfareAppCore
@testable import TurboFieldfareMacInference

@Suite struct DecodeServiceConversationResetTests {
    @Test func aResetWithNoConnectionFailsRatherThanReportingSuccess() async throws {
        let client = DecodeServiceInferenceClient()
        await #expect(throws: AppInferenceError.self) {
            try await client.resetConversation(epoch: UUID())
        }
    }
}
