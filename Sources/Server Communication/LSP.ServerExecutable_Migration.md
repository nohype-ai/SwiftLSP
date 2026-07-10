
# Shortest path with FoundationToolz 0.5.9 left alone

**One structural change in SwiftLSP**, same pattern you already use for WebSocket.

## Only real work: rewrite `ServerExecutable`

File: `Sources/Server Communication/LSP.ServerExecutable.swift`

Stop subclassing. Own an `Executable` and implement `ExecutableProcessor`:

```text
ServerExecutable
  ├─ packetDetector
  ├─ executable = try Executable(config:processor: self)   // Executable! after other lets
  ├─ run/stop/receive/isRunning  → forward to executable
  └─ ExecutableProcessor
        didSend(output:) → packetDetector.read
        didSend(error:)  → call public handler var
        didTerminate()   → call public handler var (name clash: not `var didTerminate`)
```

Leave `Executable.Configuration.sourceKitLSP` extension as-is.

That’s the entire API migration FoundationToolz forces. No Package.swift concurrency flags help; no other SwiftLSP types *must* change for this compile error.

## Name clash (only snag for LSPService)

Old surface (inherited): `var didTerminate`  
Required protocol method: `func didTerminate()`

They can’t coexist. Shortest fix:

| Surface | Keep name? |
|--------|------------|
| `didSendError` property | Yes |
| terminate property | Rename e.g. `didTerminateHandler` **or** pass both into `init` |
| `run` / `stop` / `receive` | Yes (forwarders) |

`ServerExecutable` isn’t used inside SwiftLSP tests/sources elsewhere—only **LSPService** (`RouteConfigurator`) sets `didSendError` / `didTerminate` and calls `run`/`stop`/`receive`.

- **SwiftLSP alone:** implement as above → `swift build` green.
- **LSPService too:** 1–2-line rename (or init-based handlers) in `RouteConfigurator.swift` after the API name you choose.

## Deliberately out of scope

Nested weak processors, actors, greenfield streams, `LSPServerConnection` redesign, `@unchecked` unless the compiler errors (with tools 5.6, usually warnings only—as with `WebSocketConnection`).

---

**Bottom line:** with FT frozen, the shortest path is **composition + `ExecutableProcessor` in that one file + forward process APIs** (~mirror `WebSocketConnection`). Everything else can wait.
