import Foundation

public struct ReactorConfiguration: Sendable {
    public var baseURL: URL
    public var modelName: String
    public var apiVersion: Int
    public var webRTCVersion: String
    public var sdkVersion: String

    public init(
        modelName: String,
        baseURL: URL = ReactorConfiguration.productionBaseURL,
        apiVersion: Int = 1,
        webRTCVersion: String = "1.0",
        sdkVersion: String = "0.1.0"
    ) {
        self.modelName = modelName
        self.baseURL = baseURL
        self.apiVersion = apiVersion
        self.webRTCVersion = webRTCVersion
        self.sdkVersion = sdkVersion
    }

    public static let productionBaseURL = URL(string: "https://api.reactor.inc")!
}
