import Foundation

/// Coin logos from Binance's public asset list (an undocumented web endpoint, not the market-data API),
/// cached on disk per coin. Every failure just means "no icon": the sticker falls back to a monogram.
public actor CoinIcons {
    public typealias Fetch = @Sendable (URL) async throws -> (data: Data, status: Int)

    private static let catalogURL = URL(string: "https://www.binance.com/bapi/asset/v2/public/asset/asset/get-all-asset")!

    private let directory: URL?
    private let fetch: Fetch
    private var catalog: [String: URL]?

    /// `directory` nil disables the disk cache.
    public init(directory: URL?, fetch: Fetch? = nil) {
        self.directory = directory
        self.fetch = fetch ?? { url in
            var request = URLRequest(url: url)
            request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await URLSession.shared.data(for: request)
            return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
        }
    }

    public func data(for base: String) async -> Data? {
        let code = base.uppercased()
        let file = directory?.appending(path: "\(code).png")
        if let file, let cached = try? Data(contentsOf: file), !cached.isEmpty { return cached }
        guard let url = await logoURL(code), let (data, status) = try? await fetch(url), status == 200, !data.isEmpty else { return nil }
        if let file, let directory {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? data.write(to: file, options: .atomic)
        }
        return data
    }

    private func logoURL(_ code: String) async -> URL? {
        if catalog == nil {
            guard let (data, status) = try? await fetch(Self.catalogURL), status == 200 else { return nil }
            catalog = Self.parse(data)
        }
        return catalog?[code]
    }

    static func parse(_ data: Data) -> [String: URL]? {
        struct Reply: Decodable {
            struct Asset: Decodable { let assetCode: String; let logoUrl: String? }
            let data: [Asset]
        }
        guard let reply = try? JSONDecoder().decode(Reply.self, from: data) else { return nil }
        return Dictionary(reply.data.compactMap { a in a.logoUrl.flatMap(URL.init(string:)).map { (a.assetCode.uppercased(), $0) } },
                          uniquingKeysWith: { first, _ in first })
    }
}
