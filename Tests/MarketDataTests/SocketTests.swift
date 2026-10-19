import Domain
import Foundation
import Network
import Testing
@testable import MarketData

/// A real WebSocket server on localhost: the adapters' `connect` runs against it exactly as against an exchange.
final class SocketServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "socket-server")
    private let greeting: [String], reply: @Sendable (String) -> [String]
    private let lock = NSLock()
    private var _received: [String] = [], connections: [NWConnection] = []
    var received: [String] { lock.withLock { _received } }

    init(greeting: [String] = [], reply: @escaping @Sendable (String) -> [String] = { _ in [] }) throws {
        let ws = NWProtocolWebSocket.Options()
        ws.autoReplyPing = true
        let params = NWParameters.tcp
        params.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
        listener = try NWListener(using: params, on: .any)
        self.greeting = greeting
        self.reply = reply
    }

    /// Starts listening; the port it got.
    func start() async throws -> UInt16 {
        listener.newConnectionHandler = { [self] connection in
            lock.withLock { connections.append(connection) }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 0.5) { [self] in for text in greeting { send(text, on: connection) } } // after the handshake and the client's first ping
            receive(on: connection)
        }
        return try await withCheckedThrowingContinuation { continuation in
            let done = NSLock(); nonisolated(unsafe) var resumed = false
            listener.stateUpdateHandler = { [listener] state in
                done.lock(); defer { done.unlock() }
                guard !resumed else { return }
                switch state {
                case .ready: resumed = true; continuation.resume(returning: listener.port!.rawValue)
                case .failed(let error): resumed = true; continuation.resume(throwing: error)
                default: break
                }
            }
            listener.start(queue: queue)
        }
    }

    func stop() {
        lock.withLock { connections.forEach { $0.cancel() } }
        listener.cancel()
    }

    private func send(_ text: String, on connection: NWConnection) {
        let meta = NWProtocolWebSocket.Metadata(opcode: .text)
        connection.send(content: Data(text.utf8), contentContext: NWConnection.ContentContext(identifier: "t", metadata: [meta]), completion: .idempotent)
    }

    private func receive(on connection: NWConnection) {
        connection.receiveMessage { [self] data, context, _, error in
            if let data, let meta = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata, meta.opcode == .text {
                let text = String(decoding: data, as: UTF8.self)
                lock.withLock { _received.append(text) }
                for answer in reply(text) { send(answer, on: connection) }
            }
            if error == nil { receive(on: connection) }
        }
    }
}

/// The first `count` events of a feed; fails after `seconds` of silence.
func events(_ feed: AsyncThrowingStream<FeedEvent, any Error>, count: Int, seconds: Double = 8) async throws -> [FeedEvent] {
    try await withThrowingTaskGroup(of: [FeedEvent].self) { group in
        group.addTask {
            var out: [FeedEvent] = []
            for try await event in feed { out.append(event); if out.count == count { break } }
            return out
        }
        group.addTask { try await Task.sleep(for: .seconds(seconds)); throw URLError(.timedOut) }
        defer { group.cancelAll() }
        return try await group.next()!
    }
}

@Suite(.serialized) struct SocketTests {
    let gram = Instrument(base: "GRAM", quote: "USDT")

    @Test func binanceAnnouncesTheConnectionThenStreamsTicks() async throws {
        let server = try SocketServer(greeting: [#"{"e":"24hrMiniTicker","E":1672515782136,"s":"GRAMUSDT","c":"0.0551","o":"0.054"}"#])
        let port = try await server.start()
        defer { server.stop() }
        let got = try await events(BinanceAdapter(streamBase: "ws://127.0.0.1:\(port)").connect(to: gram), count: 2)
        #expect(got.first == .connected)
        guard case .tick(let tick) = got.last else { Issue.record("no tick"); return }
        #expect(tick.price == Decimal(string: "0.0551"))
    }

    @Test func poloniexSubscribesThenStreamsTicks() async throws {
        let server = try SocketServer(reply: { _ in [#"{"channel":"ticker","data":[{"symbol":"GRAM_USDT","open":"1.30","close":"1.41","ts":"1700000001000"}]}"#] })
        let port = try await server.start()
        defer { server.stop() }
        let got = try await events(PoloniexAdapter(socketURL: URL(string: "ws://127.0.0.1:\(port)")!).connect(to: gram), count: 2)
        #expect(got.first == .connected)
        guard case .tick(let tick) = got.last else { Issue.record("no tick"); return }
        #expect(tick.price == Decimal(string: "1.41"))
        #expect(server.received.first?.contains(#""symbols":["GRAM_USDT"]"#) == true)
    }

    @Test func bybitSubscribesThenStreamsTicks() async throws {
        let server = try SocketServer(reply: { _ in [#"{"topic":"tickers.GRAMUSDT","ts":1700000001000,"type":"snapshot","data":{"symbol":"GRAMUSDT","lastPrice":"1.41","prevPrice24h":"1.30"}}"#] })
        let port = try await server.start()
        defer { server.stop() }
        let got = try await events(BybitAdapter(socketURL: URL(string: "ws://127.0.0.1:\(port)")!).connect(to: gram), count: 2)
        #expect(got.first == .connected)
        guard case .tick(let tick) = got.last else { Issue.record("no tick"); return }
        #expect(tick.price == Decimal(string: "1.41"))
        #expect(server.received.first == #"{"op":"subscribe","args":["tickers.GRAMUSDT"]}"#)
    }

    @Test func anErrorFromTheExchangeEndsTheFeed() async throws {
        let bybit = try SocketServer(reply: { _ in [#"{"success":false,"ret_msg":"handler not found"}"#] })
        let poloniex = try SocketServer(reply: { _ in [#"{"event":"error","message":"bad"}"#] })
        let ports = (try await bybit.start(), try await poloniex.start())
        defer { bybit.stop(); poloniex.stop() }
        await #expect(throws: (any Error).self) { _ = try await events(BybitAdapter(socketURL: URL(string: "ws://127.0.0.1:\(ports.0)")!).connect(to: gram), count: 2) }
        await #expect(throws: (any Error).self) { _ = try await events(PoloniexAdapter(socketURL: URL(string: "ws://127.0.0.1:\(ports.1)")!).connect(to: gram), count: 2) }
    }

    @Test func anUnreachableServerEndsTheFeedWithAnError() async throws {
        await #expect(throws: (any Error).self) { _ = try await events(BybitAdapter(socketURL: URL(string: "ws://127.0.0.1:1")!).connect(to: gram), count: 1) }
        await #expect(throws: (any Error).self) { _ = try await events(PoloniexAdapter(socketURL: URL(string: "ws://127.0.0.1:1")!).connect(to: gram), count: 1) }
        await #expect(throws: (any Error).self) { _ = try await events(BinanceAdapter(streamBase: "ws://127.0.0.1:1").connect(to: gram), count: 1) }
    }

    @Test func aBadStreamAddressFailsAtOnce() async throws {
        await #expect(throws: (any Error).self) { _ = try await events(BinanceAdapter(streamBase: "http://[bad").connect(to: gram), count: 1) }
    }
}
