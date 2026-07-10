import FoundationToolz
import Foundation
import SwiftyToolz

public extension LSP
{
    /// An ``LSPServerConnection`` that uses a `WebSocket` to talk to an LSP server
    ///
    /// The client should set the four handlers defined by the protocol ``LSPServerConnection``
    class WebSocketConnection: LSPServerConnection, WebSocketProcessor
    {
        // MARK: - Initialize
        
        /// Initialize with a URL
        /// - Parameter url: The endpoint URL on which to connect to the websocket
        public init(url: URL) throws
        {
            self.url = url
            try ensureWebSocketIsStored()
        }
        
        // MARK: - Talk to LSP Server
        
        private func process(data: Data)
        {
            do
            {
                let message = try LSP.Message(LSP.Packet(parsingPrefixOf: data).content)

                switch message
                {
                case .request:
                    throw "Received request from LSP server"
                case .response(let response):
                    serverDidSendResponse(response)
                case .notification(let notification):
                    serverDidSendNotification(notification)
                }
            }
            catch
            {
                log(error.readable)
                log("Received data:\n" + data.utf8String)
            }
        }
        
        public var serverDidSendResponse: (LSP.Message.Response) -> Void = { _ in }
        public var serverDidSendNotification: (LSP.Message.Notification) -> Void = { _ in }
        public var serverDidSendErrorOutput: (String) -> Void = { _ in }
        
        /// Send a ``LSP/Message`` via the data channel of the `WebSocket`
        /// - Parameter message: The `LSP.Message` to send
        public func sendToServer(_ message: LSP.Message) async throws
        {
            try await getWebSocket().send(try LSP.Packet(message).data)
        }
        
        // MARK: - Manage Connection
        
        public var didCloseWithError: (Error) -> Void =
        {
            _ in log(warning: "LSP WebSocket connection error handler not set")
        }
        
        // MARK: - WebSocket
        
        private func getWebSocket() throws -> WebSocket
        {
            try ensureWebSocketIsStored()
        }
        
        @discardableResult
        private func ensureWebSocketIsStored() throws -> WebSocket
        {
            if let storedWebSocket
            {
                return storedWebSocket
            }
            
            let newWebSocket = try url.webSocket(processor: self)
            storedWebSocket = newWebSocket
            return newWebSocket
        }
        
        private var storedWebSocket: WebSocket?
        private let url: URL
        
        // MARK: - WebSocketProcessor Protocol
        
        public func didReceive(data: Data)
        {
            process(data: data)
        }
        
        public func didReceive(text: String)
        {
            serverDidSendErrorOutput(text)
        }
        
        public func didCloseWithError(webSocket: WebSocket, error: Error)
        {
            storedWebSocket = nil
            didCloseWithError(error)
        }
    }
}
