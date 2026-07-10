import Foundation
import SwiftyToolz

public extension LSP
{
    /**
     Wraps a ``LSP/Message`` on the data level and corresponds to the LSP "Base Protocol"
     
     See how [the LSP specifies its "Base Protocol"](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#baseProtocol).
     */
    struct Packet: Equatable, Sendable
    {
        /**
         Detects a ``LSP/Packet`` that starts at the beginning of a `Data` instance
        
         `LSP.Packet` wraps an LSP message on the level of data / data streams and corresponds to the LSP "Base Protocol". See how [the LSP specifies its "Base Protocol"](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#baseProtocol).
         - Parameter data: Data that presumably starts with an LSP-conform endoded `LSP.Packet`
         */
        public init(parsingPrefixOf data: Data) throws
        {
            (header, content) = try Parser.parseHeaderAndContent(fromPrefixOf: data)
        }
        
        /**
         Make a ``LSP/Packet`` from the given packet content data
         
         Throws an error if the given content data is not an LSP-conform encoding of a packet's content part. See the [LSP content part specification](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#contentPart).
         
         - Parameter content: LSP-conform JSON encoding of an LSP packet's content part
         */
        public init(withContent content: Data) throws
        {
            try Parser.verify(content: content)
            self.header = "Content-Length: \(content.count)".data!
            self.content = content
        }
        
        /// The LSP-conform encoding of the whole packet
        ///
        /// See how [the LSP specifies its "Base Protocol"](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#baseProtocol).
        public var data: Data { header + separator + content }
        
        /// The length of the whole packet data in Bytes
        public var length: Int { header.count + separator.count + content.count }
        
        /// The LSP-conform encoding of the packet's header part
        ///
        /// See the [LSP content part specification](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#headerPart).
        public let header: Data
        
        /// The LSP-conform encoding of the packet's header/content separator
        ///
        /// See how [the LSP specifies its "Base Protocol"](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#baseProtocol).
        public var separator: Data { Parser.separator }
        
        /// The LSP-conform encoding of the packet's content part
        ///
        /// See the [LSP content part specification](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#contentPart).
        public let content: Data
        
        private enum Parser
        {
            static func parseHeaderAndContent(fromPrefixOf data: Data) throws -> (Data, Data)
            {
                guard !data.isEmpty else { throw "Data is empty" }
                
                guard let header = Parser.header(fromBeginningOf: data) else
                {
                    throw "Data doesn't start with header:\n\(data.utf8String)"
                }
                
                guard let contentLength = Parser.contentLength(fromHeader: header) else
                {
                    throw "Header declares no content length"
                }
                
                let headerPlusSeparatorLength = header.count + separator.count
                let packetLength = headerPlusSeparatorLength + contentLength
                
                guard packetLength <= data.count else { throw "Incomplete packet data" }
                
                let content = data[headerPlusSeparatorLength ..< packetLength]
                try verify(content: content)
                
                return (header, content)
            }
            
            static func verify(content: Data) throws
            {
                _ = try Message(content)
            }
            
            private static func header(fromBeginningOf data: Data) -> Data?
            {
                guard !data.isEmpty else { return nil }
                
                guard let separatorIndex = indexOfSeparator(in: data) else
                {
                    log(verbose: "Data (\(data.count) Byte) contains no header/content separator:\n\(data.utf8String) (yet)")
                    return nil
                }
                
                guard separatorIndex > 0 else
                {
                    log(error: "Empty header")
                    return nil
                }
                
                return data[0 ..< separatorIndex]
            }
            
            private static func indexOfSeparator(in data: Data) -> Int?
            {
                guard !data.isEmpty else { return nil }
                let lastDataIndex = data.count - 1
                let lastPossibleSeparatorIndex = lastDataIndex - (separator.count - 1)
                guard lastPossibleSeparatorIndex >= 0 else { return nil }
                
                for index in 0 ... lastPossibleSeparatorIndex
                {
                    let potentialSeparator = data[index ..< index + separator.count]
                    if potentialSeparator == separator { return index }
                }

                return nil
            }
            
            private static func contentLength(fromHeader header: Data) -> Int?
            {
                let headerString = header.utf8String
                let headerLines = headerString.components(separatedBy: "\r\n")
                
                for headerLine in headerLines
                {
                    if headerLine.hasPrefix("Content-Length")
                    {
                        guard let lengthString = headerLine.components(separatedBy: ": ").last
                        else { return nil }
                        
                        return Int(lengthString)
                    }
                }
                
                return nil
            }
            
            fileprivate static let separator = Data([13, 10, 13, 10]) // ascii: "\r\n\r\n"
        }
    }
}
