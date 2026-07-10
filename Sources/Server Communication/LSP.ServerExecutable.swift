#if os(macOS)

import Foundation
import FoundationToolz
import SwiftyToolz

public extension LSP {

    /**
     Represents an LSP server's executable file and allows to receive ``LSP/Message``s from it
     
     This does not work in a sandboxed app!
     */
    class ServerExecutable: ExecutableProcessor {
        
        // MARK: - Life Cycle
        
        /**
         Initializes with process configuration and callbacks for all process events.
         
         All three client handlers are fixed at construction so setup is complete before `run()`.
         */
        public init(config: Executable.Configuration,
                    handleLSPPacket: @escaping (LSP.Packet) -> Void,
                    handleError: @escaping (Data) -> Void,
                    handleTermination: @escaping () -> Void) throws {
            packetDetector = PacketDetector(handleLSPPacket)
            self.handleError = handleError
            self.handleTermination = handleTermination
            try ensureExecutableIsStored(config: config)
        }
        
        // MARK: - Controlling the Executable
        
        public func run() throws {
            try getExecutable().run()
        }
        
        public func stop() {
            storedExecutable?.stop()
        }
        
        public func receive(input: Data) {
            storedExecutable?.receive(input: input)
        }
        
        public var isRunning: Bool {
            storedExecutable?.isRunning ?? false
        }
        
        // MARK: - ExecutableProcessor Protocol Conformance
        
        public func didSend(output: Data) {
            packetDetector.read(output)
        }
        
        public func didSend(error: Data) {
            handleError(error)
        }
        
        public func didTerminate() {
            storedExecutable = nil
            handleTermination()
        }
        
        // MARK: - Executable
        
        private func getExecutable() throws -> Executable {
            guard let storedExecutable else {
                throw "LSP.ServerExecutable has no executable"
            }
            return storedExecutable
        }
        
        @discardableResult
        private func ensureExecutableIsStored(config: Executable.Configuration) throws -> Executable {
            if let storedExecutable {
                return storedExecutable
            }
            
            let newExecutable = try Executable(config: config, processor: self)
            storedExecutable = newExecutable
            return newExecutable
        }
        
        private var storedExecutable: Executable?
        private let packetDetector: LSP.PacketDetector
        private let handleError: (Data) -> Void
        private let handleTermination: () -> Void
    }
}

public extension Executable.Configuration
{
    static var sourceKitLSP: Executable.Configuration
    {
        .init(path: "/usr/bin/xcrun",
              arguments: ["sourcekit-lsp"],
              environment: ["SOURCEKIT_LOGGING": "0"])
    }
}

#endif
