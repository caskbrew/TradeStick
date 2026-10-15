/// A user's API key and secret for one exchange.
public struct APICredentials: Equatable, Sendable {
    public var key: String
    public var secret: String
    public init(key: String, secret: String) { self.key = key; self.secret = secret }
}
