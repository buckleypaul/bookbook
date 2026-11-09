import Foundation
import Testing
@testable import BBNet

@Suite struct Phase16bOfflineCodesTests {
    @Test func connectionLostIsTransportNotOffline() {
        let error = URLSessionHTTPClient.map(URLError(.networkConnectionLost), host: "h")
        #expect(error == .transport(code: URLError.Code.networkConnectionLost.rawValue, host: "h"))
        #expect(!URLSessionHTTPClient.offlineCodes.contains(.networkConnectionLost))
    }
}
