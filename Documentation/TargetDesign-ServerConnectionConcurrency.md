# Target Design: Server Connection Concurrency

Checkpoint for adapting SwiftLSP to FoundationToolz’s concurrency-safe `WebSocket` / `Executable` APIs (processor protocols, Swift 6–friendly `Sendable` boundaries).

Status: **design exploration** — includes both a **greenfield modern-Swift ideal** and an **incremental migration** path. Prefer reading the greenfield section before implementing; do not treat nested processors as “the” modern answer if a stream/actor redesign is viable.

---

## Why a small Sendable requirement felt like a bomb

The blow-up is not really “Swift hates protocols” or “Sendable is impossibly deep.” It is this mismatch:

| Pre-concurrency style (this codebase) | What Swift 6 concurrency wants |
|---|---|
| Shared objects call back into other shared objects | **One isolation domain** owns mutable state |
| Mutable `var` handlers / delegates / processors | **Values in, values out** (`async` / `AsyncSequence`) |
| “Make the object `Sendable` so anyone can call it” | Prefer **not sharing** the object; share **messages** |
| Layer of classes that retain each other | **Structured tasks** + clear parent lifetime |

`Sendable` is a check that says: *this value may cross isolation domains.*  
Callback-oriented designs need the *callee* to be safe when invoked from foreign domains → the sink must be `Sendable` → every implementor gets infected → weak refs, nested boxes, `@unchecked`, dependency inversion protocols, retain-cycle surgery.

**That complexity is the cost of preserving “objects that phone home.”**  
Modern Swift’s idiomatic move is: **stop phoning home.** Own the I/O in an actor (or a task), and **stream events as data.**

Concurrency is not in fundamental tension with “good design.” It is in tension with **shared mutable reference graphs + callbacks.** Protocols remain excellent for *capabilities* and *dependency direction*; they are a poor vehicle for *event delivery across threads* unless the protocol is essentially “AsyncSequence” or “async API.”

---

## Greenfield: idiomatic modern Swift for this feature

If we could question the codebase at the root and re-implement “LSP over WebSocket” cleanly, this is the straightforward shape.

### Principles

1. **`actor` = mutable session / connection state** (request maps, open socket, lifecycle).
2. **Inbound I/O = `AsyncSequence` / `AsyncStream` of values** (frames, packets, messages, or errors) — not `didReceive` on a protocol.
3. **Outbound I/O = `async` methods** (`send`) — not completion-handler soup.
4. **`Sendable` mainly for value types** (`LSP.Message`, `Data`, errors) crossing task/actor boundaries.
5. **Structured concurrency for lifetime**: a task that reads the socket dies when the session ends; cancel ends the receive loop.
6. **No processor/delegate required** for the happy path. No nested weak forwarders. No “connection is Sendable because WebSocket is.”

### Minimal architecture (WebSocket)

```text
App
  └─ LSP.Session (actor)                  // was ServerCommunicationHandler + connection glue
        ├─ owns URLSessionWebSocketTask   // or a thin helper, not a second “brain”
        ├─ runReceiveLoop() as Task       // for await message in …
        ├─ pending requests dictionary    // isolated by actor
        └─ public API: request / notify / events for server push
```

Sketch (illustrative, not prescribed API names):

```swift
public actor LSPSession {
    private let task: URLSessionWebSocketTask
    private var pending: [LSP.Message.ID: CheckedContinuation<JSON, Error>] = [:]

    public init(url: URL) {
        // create & resume webSocketTask
    }

    public func run() async {
        // structured: caller awaits run, or session starts an unstructured child Task it cancels on close
        while true {
            let message = try await task.receive()  // or AsyncStream wrapper
            switch message {
            case .data(let data):
                await handleIncoming(data)  // parse packet → resume continuation or yield notification
            case .string(let text):
                // stderr-style / log channel
            @unknown default:
                break
            }
        }
    }

    public func request(_ request: LSP.Request) async throws -> JSON { /* continuation + send */ }
    public func notify(_ notification: LSP.Notification) async throws { /* send */ }

    public func send(_ message: LSP.Message) async throws {
        try await task.send(.data(try LSP.Packet(message).data))
    }
}
```

Optional: expose server notifications as `AsyncStream<LSP.Notification>` instead of stored handler closures — same idea, pull-based.

### Where FoundationToolz fits in a greenfield world

A modern `WebSocket` helper would **not** look like “Sendable class + Sendable processor.”

It would look like one of:

**A. Actor (simplest mental model)**

```swift
public actor WebSocket {
    public init(url: URL) async throws { … }
    public func send(_ data: Data) async throws { … }
    public func messages() -> AsyncThrowingStream<Message, Error> { … }
    // cancel / close ends the stream
}
```

**B. Session factory returning streams (even less “object identity”)**

```swift
public enum WebSocket {
    public struct Event: Sendable { /* data / text / close */ }

    public static func connect(
        url: URL
    ) -> (events: AsyncThrowingStream<Event, Error>, send: @Sendable (Data) async throws -> Void)
}
```

Either way:

- Event delivery = **sequence of Sendable values**
- No reverse dependency to a client type
- No retain cycle with a processor
- No need for the app’s connection class to be `Sendable`

Stdio/`Executable` gets the same treatment: `AsyncStream<Data>` for stdout/stderr, `async` write for stdin, process lifetime tied to a task/actor.

### Transport abstraction without callback protocols

If you still want “WebSocket vs stdio” swappable:

```swift
public protocol LSPTransport: Sendable {
    func send(_ message: LSP.Message) async throws
    func events() -> AsyncThrowingStream<LSPTransportEvent, Error>
}

public enum LSPTransportEvent: Sendable {
    case message(LSP.Message)
    case errorOutput(String)
    case failed(Error)
}
```

Note: this protocol is a **capability + stream**, not a bag of `var` handlers. Implementors can be actors. Clients **consume** the stream inside *their* actor. Dependency graph stays a DAG; no back-ref protocol required for events.

Compare to today:

```swift
protocol LSPServerConnection: AnyObject {
    var serverDidSendResponse: … { get set }  // callback soup
}
```

That older shape is what collides with concurrency.

### What we would drop or merge

| Today | Greenfield |
|---|---|
| `WebSocket` + `WebSocketProcessor` | `WebSocket` actor or stream pair |
| `WebSocketConnection` as adapter + handler vars | Often **unnecessary** — session actor talks to socket/stream directly, or to `LSPTransport` |
| `LSPServerConnection` mutable handlers | `LSPTransport` with `send` + `events` |
| Nested processor / weak owner / client protocols for events | **Not needed** for event delivery |
| Making adapters `Sendable` | Prefer **isolating** them (actor) or not sharing them |

`LSP.Message` / `Packet` / `PacketDetector` stay — they are pure data/framing and already fit modern Swift.

### Mental model (one sentence)

**One actor owns the session; bytes and LSP messages move as Sendable values through async send and async sequences; nothing important is a Sendable callback target.**

### Why this feels “simple” again

- Lifetime = task/actor cancellation, not weak delegate graphs  
- Structure = dependency DAG of *values and capabilities*, not mutual phone-home objects  
- Concurrency checker helps instead of pushing `@unchecked` and processor boxes  
- Protocols describe **what you can do**, not **who to call when something happens**

---

## Two tracks from here

| Track | When to use | Cost |
|---|---|---|
| **Greenfield (above)** | You can change FoundationToolz + SwiftLSP APIs meaningfully | Redesign transports; fewer types; modern idioms |
| **Incremental (rest of this doc)** | Must keep callback-shaped APIs / small diffs | Processors, careful ownership, possible `@unchecked` boxes — *migration tax*, not “ideal Swift” |

The sections below document the **incremental** path that preserves the current layering while fixing FoundationToolz’s processor model. Treat them as *how to survive the retrofit*, not as the best end state if greenfield is allowed.

---

## Goals (incremental track)

1. Align SwiftLSP with FoundationToolz’s move from **mutable stored closures** to **fixed processor protocols** injected at construction of I/O primitives.
2. Avoid blindly making every layer `Sendable`. Put `Sendable` only where concurrent use is real and the type’s wiring is fixed.
3. Keep a clear layering so each type has one job clients (and future us) can remember.
4. Prefer greenfield (streams + actors) when API churn is acceptable; use processors only as a bridge.

---

## Background: what FoundationToolz already did

`WebSocket` (and the same pattern on `Executable`) used to expose mutable handlers:

- `didReceiveData` / `didReceiveText` / `didCloseWithError`
- (Executable: `didSendOutput` / `didSendError` / `didTerminate`)

Those made true `Sendable` impossible. FoundationToolz replaced them with:

- `WebSocketProcessor: Sendable` — fixed at `WebSocket` init, stored as `let`
- `ExecutableProcessor: Sendable` — fixed at `Executable` init, stored as `let`

`WebSocket` itself remains `Sendable` because it is a shared I/O handle: async `send` from caller isolation, receive completions on session queues, and (as a general FoundationToolz type) possible use across isolation domains. That requirement is **not** “because SwiftLSP clients hold a `WebSocket`.” After ownership encapsulation, SwiftLSP clients may never see `WebSocket` at all; the socket is still concurrent I/O *internally*, and FoundationToolz still exposes it as a library primitive.

---

## Core design principle

| Concern | Where it lives |
|---|---|
| True concurrent I/O primitive | FoundationToolz: `WebSocket` / `Executable` (`Sendable`, fixed processor) |
| Transport adapter (bytes ↔ LSP messages) | SwiftLSP: `WebSocketConnection` / `ServerExecutable` |
| Request/response matching & client-facing async API | SwiftLSP: `ServerCommunicationHandler` (actor) |
| Event sink for a layer | A **processor/client protocol** (`Sendable`), not reassigned stored closures |

**Do not** make “everything that touches WebSocket is `Sendable`” the rule.  
**Do** repeat the same *structural* fix one layer up: replace mutable handler vars with a fixed processor protocol.

---

## Ownership / creation pattern (the “wrinkle” solution)

### Already used one layer down: connection creates socket (ensure-pattern)

`LSP.WebSocketConnection` already owns the socket lifecycle:

1. Holds durable identity/config (`url`).
2. Lazily creates / recreates the lower I/O object when needed (`ensureWebSocketIsStored()`).
3. Installs a **fixed** `WebSocketProcessor` at socket creation time.
4. On close, drops the stored socket (`storedWebSocket = nil`) so a later send can open a new one with the same processor wiring.

**Important:** passing `processor: self` while also strongly storing the socket is a retain cycle (see [Retain cycles](#retain-cycles-ownership-vs-fixed-processor)). Target wiring uses a nested processor with a **weak** owner, not `self` as the strong processor:

```text
WebSocketConnection (owns url + socket)
        │
        │  ensureWebSocketIsStored()
        │  url.webSocket(processor: nestedProcessor)  // nestedProcessor.owner = self (weak)
        ▼
    WebSocket (Sendable, let processor → nestedProcessor)
```

That is the pattern that avoids “client of this layer must construct and hold the lower object and wire callbacks,” without inverting ownership.

### Apply the same pattern one layer up

`ServerCommunicationHandler` should own the connection the same way the connection owns the socket:

1. Holds durable identity/config (e.g. endpoint URL + language, or a connection factory).
2. Creates (or lazily creates) the `LSPServerConnection` **after** the actor exists as a complete `self`.
3. Installs a **fixed** `LSPServerConnectionClient` at connection construction — either the actor with a cycle-safe upward ref, or a tiny nested forwarder that weakly / unownedly hops into the actor.
4. Optionally clears / recreates the connection on hard failure the same way the socket is cleared on close — only if reconnect is a product requirement.

```text
ServerCommunicationHandler (actor)
        │
        │  ensureConnectionIsStored()
        │  WebSocketConnection(url:…, client: …)  // fixed client; weak upward if needed
        ▼
WebSocketConnection (owns url + socket, fixed client)
        │
        │  ensureWebSocketIsStored()
        │  url.webSocket(processor: nestedProcessor)
        ▼
    WebSocket
```

**Why this dissolves the “pass `self` into init” wrinkle**

- For a **class**, ensure/create runs once stored properties are set; nested processor gets `owner = self` then.
- For an **actor**, lazy ensure is even more natural: create the connection on first use (or post-init setup) when the actor is fully initialized.
- Two-phase mutable handler assignment (`connection.serverDidSendResponse = { … }`) goes away; wiring is fixed client/processor at construction.

Symmetric transport for stdio: same ensure + nested `ExecutableProcessor` with weak owner, not a strong process↔adapter loop.

---

## Target callback surfaces (no mutable handler vars)

### FoundationToolz (already done)

```swift
public protocol WebSocketProcessor: Sendable {
    func didReceive(data: Data)
    func didReceive(text: String)
    func didCloseWithError(webSocket: WebSocket, error: Error)
}

public protocol ExecutableProcessor: Sendable {
    func didSend(output: Data)
    func didSend(error: Data)
    func didTerminate()
}
```

### SwiftLSP (to do) — replace `LSPServerConnection` mutable vars

Today:

```swift
var serverDidSendResponse: (LSP.Message.Response) -> Void { get set }
var serverDidSendNotification: (LSP.Message.Notification) -> Void { get set }
var serverDidSendErrorOutput: (String) -> Void { get set }
var didCloseWithError: (Error) -> Void { get set }
```

Target: one fixed client protocol (name TBD; e.g. `LSPServerConnectionClient` or `LSPServerConnectionProcessor`):

```swift
public protocol LSPServerConnectionClient: Sendable {
    func serverDidSendResponse(_ response: LSP.Message.Response)
    func serverDidSendNotification(_ notification: LSP.Message.Notification)
    func serverDidSendErrorOutput(_ output: String)
    func connectionDidCloseWithError(_ error: Error)
}
```

`LSPServerConnection` then becomes roughly: “can send messages” + “was constructed with a fixed client,” not “bag of reassigned closures.”

`ServerCommunicationHandler` is the natural implementer (already an actor → already `Sendable`). Its methods hop naturally into actor isolation; the current `Task { [weak self] in await self?… }` wrappers become ordinary actor method calls from the connection’s client callbacks (exact hop style may still use `Task` if the connection calls from a non-isolated context).

---

## What should be `Sendable`?

| Type | `Sendable`? | Why |
|---|---|---|
| `WebSocket` | **Yes** | I/O primitive; concurrent send/receive; FoundationToolz API |
| `WebSocketProcessor` | **Yes** | Invoked from receive completions; stored in `WebSocket` |
| `Executable` / `ExecutableProcessor` | **Yes** | Same story for process I/O |
| `LSPServerConnectionClient` (new) | **Yes** | Invoked from transport callbacks; fixed at connection init |
| `ServerCommunicationHandler` | **Yes** (actor) | Owns request maps and client-facing state |
| `WebSocketConnection` | **Not required as a goal** | Adapter with owned socket; may become safely Sendable later if remaining state is fixed/serialized, but do **not** force it only to pass `self` as `WebSocketProcessor` without fixing handler vars |
| `LSPServerConnection` (protocol) | **Not inherently** | Transport capability; implementors vary |
| Message/packet value types | **Yes** (already) | Pure data crossing isolation domains |

**Anti-goal:** expand `Sendable` upward “because WebSocket is Sendable.”  
**Goal:** expand the **processor pattern** upward so each layer’s event sink is fixed and Sendable, while adapters stay simple.

---

## Purpose of each type (mental model + future API docs)

Read top-down (what product code uses) or bottom-up (how bytes arrive).

### Product / client-facing

#### `LSP.ServerCommunicationHandler` (typealias `LSP.Server`)

- **Purpose:** High-level LSP *client session* over a transport: async request/response matching, notifications, connection shutdown handling.
- **Is:** An **actor** — the isolation boundary for pending continuations and client callbacks.
- **Does:** `request`, `notify`, registers how the app wants to hear about server notifications / stderr / shutdown.
- **Does not:** Know WebSocket frames or process pipes; only talks to an `LSPServerConnection` (or owns one via the ensure-pattern above).
- **Concurrency role:** Owns concurrent session state. Ideal implementer of `LSPServerConnectionClient`.

#### `LSP.Message` / `LSP.Packet` / `LSP.PacketDetector`

- **Purpose:** Protocol data model and framing — encode/decode messages, wrap content in LSP header+body packets, detect packets in a byte stream.
- **Is:** Value types / pure helpers (`Sendable` where they are values).
- **Does not:** Open sockets, run processes, or match request IDs.

### Transport abstraction

#### `LSPServerConnection`

- **Purpose:** **Capability protocol** for “raw duplex LSP I/O”: send an `LSP.Message`, deliver inbound responses/notifications/error output/close to a fixed client.
- **Is:** The seam between session logic and a concrete transport (WebSocket, stdio executable, test doubles).
- **Target shape:** `sendToServer` + construction with `LSPServerConnectionClient`; **no** mutable handler properties.
- **Does not:** Implement request ID matching or language-specific initialize helpers.

#### `LSPServerConnectionClient` (target name TBD)

- **Purpose:** **Event sink** for a connection — the processor pattern applied one layer above FoundationToolz.
- **Is:** `Sendable` protocol implemented typically by `ServerCommunicationHandler`.
- **Does:** Receive already-parsed LSP-oriented events (response, notification, error output, connection failure).
- **Does not:** Own the socket or process.

### Concrete transports (SwiftLSP)

#### `LSP.WebSocketConnection`

- **Purpose:** **WebSocket transport adapter** for LSP: owns endpoint URL and socket lifecycle; turns socket data into `LSP.Message`s and LSP packets on the way out.
- **Is:** An `LSPServerConnection` implementor; **also** a `WebSocketProcessor` (or owns a tiny private processor that forwards to `self`).
- **Does:**
  - Create/recreate `WebSocket` with `processor: self` (ensure-pattern).
  - Parse packets/messages from binary frames; treat text frames as error output (current convention).
  - Forward parsed events to `LSPServerConnectionClient`.
  - Clear stored socket on close so later sends can reconnect.
- **Does not:** Match requests to responses; that is the actor’s job.
- **Client visibility:** Preferred public way to use LSP-over-WebSocket without holding a FoundationToolz `WebSocket`.

#### `LSP.ServerExecutable`

- **Purpose:** **Stdio transport helper** for a language server process: run an executable, feed stdin, detect `LSP.Packet`s on stdout (historical/current role).
- **Target:** Align with `ExecutableProcessor` the same way WebSocket aligned with `WebSocketProcessor` — fixed processor at construction, no post-hoc handler vars on `Executable`.
- **Relationship to `LSPServerConnection`:** Today it is process-oriented; full symmetry with `WebSocketConnection` may mean an explicit stdio `LSPServerConnection` adapter or making `ServerExecutable` that adapter. The concurrency *pattern* should match either way.
- **Does not:** Need to be the product-facing request API; pair with `ServerCommunicationHandler` when async request matching is required.

### I/O primitives (FoundationToolz — dependency)

#### `WebSocket`

- **Purpose:** General **WebSocket I/O object**: connect, async send data/text, deliver receive/close to a fixed `WebSocketProcessor`.
- **Is:** `Sendable`, opaque task wrapper around `URLSessionWebSocketTask`.
- **Does not:** Know LSP, packets, or JSON-RPC.

#### `WebSocketProcessor`

- **Purpose:** Fixed, Sendable **callback surface** for `WebSocket` (data / text / close).
- **Typical implementor in SwiftLSP:** `WebSocketConnection` (or a private nested forwarder).

#### `Executable` / `ExecutableProcessor`

- **Purpose:** General process I/O (stdin/stdout/stderr/termination) with the same fixed-processor concurrency model as `WebSocket`.
- **Typical implementor in SwiftLSP:** `ServerExecutable` or a dedicated adapter.

---

## End-to-end data flow (target)

### Outbound (client → server)

```text
App
  → await ServerCommunicationHandler.request / notify
    → await LSPServerConnection.sendToServer(message)
      → WebSocketConnection: Packet(message).data
        → WebSocket.send(data)
```

### Inbound (server → client)

```text
WebSocket receive (session queue)
  → WebSocketProcessor (WebSocketConnection)
    → parse Packet / Message
      → LSPServerConnectionClient (ServerCommunicationHandler actor)
        → resume request continuation  or  client notification handlers
```

### Connection failure

```text
WebSocket failure / deinit while live
  → WebSocketProcessor.didCloseWithError
    → WebSocketConnection clears storedWebSocket
      → LSPServerConnectionClient.connectionDidCloseWithError
        → actor cancels pending requests, notifies app
```

---

## Implementation notes (when coding)

1. **Prefer processor pattern over `@unchecked Sendable`** on adapters. Unchecked is a migration hatch, not the target.
2. **Keep `WebSocket` Sendable in FoundationToolz** even though SwiftLSP hides it; encapsulation ≠ single-threaded use.
3. **Reuse ensure/create-with-self** at both boundaries (handler→connection, connection→socket) so ownership and processor wiring stay consistent.
4. **Apply the same design to Executable / ServerExecutable / LSPService** so stdio and WebSocket do not diverge.
5. **Later:** fold the purpose blurbs above into DocC comments on each type; this file remains the design checkpoint.

---

## Retain cycles: ownership vs fixed processor

### Does the issue exist?

**Yes**, with the current “connection *is* the processor and also stores the socket strongly” wiring:

```text
WebSocketConnection ──strong──► WebSocket ──strong (let)──► processor (= connection)
        ▲                                                         │
        └─────────────────────── same object ─────────────────────┘
```

`WebSocket` stores `private let processor: WebSocketProcessor` (strong, for a fixed Sendable sink).  
`WebSocketConnection` stores `storedWebSocket: WebSocket?` (strong, as owner).  
If the connection itself is the processor, that is a classic retain cycle: neither can reach `deinit` while the other is alive.

Receive closures on `URLSessionWebSocketTask` already use `[weak self]`, so they do **not** keep the `WebSocket` alive. The cycle is purely the Swift reference graph between connection and socket.

The same risk exists one layer up if `ServerCommunicationHandler` is the connection client **and** the connection strongly retains the actor while the actor strongly retains the connection.

### Why “weak `storedWebSocket`” is the wrong fix

Making the socket weak on the connection would break the cycle, but it **inverts ownership**:

- The connection is supposed to **own** the transport (it creates it, recreates it after close, sends through it).
- `WebSocket` does **not** document “processor must not retain me” and does not look like a parent in a delegate relationship; it looks like a child service with a callback sink.
- In the usual hierarchy, **parent owns child; child does not own parent**. A weak child reference on the parent is the opposite of that.

So weak `storedWebSocket` is a technical leak fix that lies about who owns whom. Avoid it as the target design.

### Idiomatic modern Swift resolutions

Three legitimate patterns; prefer **A** for SwiftLSP without waiting on FoundationToolz, and consider **B** as a FoundationToolz API improvement.

#### A. Nested processor with weak parent (recommended at the SwiftLSP boundary)

Do **not** pass `self` (the connection) as the `WebSocketProcessor`. Pass a small nested object that the socket owns strongly and that only **weakly** points back at the connection:

```text
WebSocketConnection ──strong──► WebSocket ──strong──► NestedProcessor
        ▲                                                  │
        └──────────────── weak ────────────────────────────┘
```

Sketch:

```swift
final class WebSocketConnection: LSPServerConnection {
    private final class SocketProcessor: WebSocketProcessor {
        weak var owner: WebSocketConnection?
        func didReceive(data: Data) { owner?.handleSocketData(data) }
        func didReceive(text: String) { owner?.handleSocketText(text) }
        func didCloseWithError(webSocket: WebSocket, error: Error) {
            owner?.handleSocketClose(error)
        }
    }

    private let socketProcessor = SocketProcessor()
    private var storedWebSocket: WebSocket?   // strong — real ownership

    private func ensureWebSocketIsStored() throws -> WebSocket {
        if let storedWebSocket { return storedWebSocket }
        socketProcessor.owner = self
        let ws = try url.webSocket(processor: socketProcessor)
        storedWebSocket = ws
        return ws
    }
}
```

Properties:

- Ownership stays normal: **connection owns socket**.
- Cycle broken at the **callback edge**, where weak references are expected (delegate-style).
- `WebSocket` can keep `let processor` and `Sendable`.
- Processor methods do not need a stored `WebSocket`; close already passes `webSocket:` if needed. The connection keeps a strong socket only for **send** and lifecycle.

This is the same idea as UIKit/AppKit delegates and as “listener object with weak owner,” adapted to a `Sendable` protocol existential stored strongly on the child.

Apply the same pattern one layer up if needed:

```text
ServerCommunicationHandler ──strong──► Connection ──strong──► NestedClientForwarder? 
```

Often the actor-as-client does **not** create a cycle: the connection holds the client strongly (`let client`), and the actor holds the connection strongly — **that is still a cycle**. Break it with either:

- connection holds client as **weak** class-bound client (if protocol is `AnyObject`), or
- nested forwarder owned by connection with **weak** actor reference, or
- Foundation-style: client protocol is class-bound and connection stores it weakly (true delegate).

For an **actor** client, prefer: connection stores a weak reference to a class box, or the handler owns the connection and the connection’s client is a nested `final class` forwarder that hops into the actor with `unowned`/`weak` + `Task`. Exact shape can be chosen at implementation time; the rule is the same: **strong ownership downward, weak callback upward**.

#### B. Weak (or unowned) processor on `WebSocket` (FoundationToolz-side, classic delegate)

Make the I/O object hold the sink the way delegates work:

```swift
public protocol WebSocketProcessor: AnyObject, Sendable { … }

// inside WebSocket:
private weak var processor: WebSocketProcessor?
```

Then:

```text
WebSocketConnection ──strong──► WebSocket ──weak──► connection (as processor)
```

Properties:

- Matches textbook parent/child + delegate.
- Documents lifetime: processor must outlive active callbacks only as long as parent exists; if parent dies first, weak processor is nil (define behavior: drop events / cancel task).
- **Sendable tension:** `weak var` is mutable. Realistic options: keep `WebSocket` as carefully synchronized / `@unchecked Sendable`, or isolate processor access. This is why FoundationToolz chose strong `let processor` — simpler Sendable story, worse ownership story.
- `unowned` is an alternative if the API **guarantees** the processor outlives the socket (parent always owns socket and always outlives it). Safer than weak for call sites (no nil), fatal if violated.

If FoundationToolz moves to weak processor, SwiftLSP can pass `self` as processor again without a cycle. Until then, prefer **A**.

#### C. Don’t store the socket on the processor object (structural)

The processor **type** never holds a `WebSocket`. Only the owner does. That alone is not enough if the owner *is* the processor (still one object with two roles). It becomes enough when combined with **A** (separate processor object) or **B** (weak processor on socket).

Note: `didCloseWithError(webSocket:error:)` already passes the socket in, so processor implementations rarely need a stored socket reference for handling events.

### Interaction with “ensure / create with `self`”

The ensure-pattern remains valid for **ownership and recreation**:

- Parent owns config + child instance.
- Parent creates child when needed and clears it on hard failure.

What changes is **who is passed as processor**:

- Not: `url.webSocket(processor: self)` when `self` also strongly stores the socket.
- Yes: `url.webSocket(processor: socketProcessor)` with a cycle-safe, Sendable-compatible sink (below).

### FAQ: nested processor, Sendable, and type dependencies

#### Did we just shift the Sendable problem onto the nested processor?

**Partly — if the nested processor holds `weak var owner: WebSocketConnection?` and `WebSocketConnection` is not `Sendable`.**

Under Swift 6, `WebSocketProcessor: Sendable` means the concrete processor must be `Sendable`. A class whose only interesting state is a weak reference to a **non-`Sendable`** owner does **not** get `Sendable` for free. So naïvely:

```swift
final class SocketProcessor: WebSocketProcessor {
    weak var owner: WebSocketConnection?  // non-Sendable owner
}
```

fails clean checking and can look like we only moved the problem from “connection isn’t Sendable” to “processor isn’t Sendable,” which would then threaten `WebSocket`’s `Sendable` (it stores the processor).

**That is not a dead end.** There are two honest resolutions; prefer the first when it fits.

##### Resolution 1 — Prefer: nested processor holds only `Sendable` state (no weak connection owner)

Do not put the connection on the processor. Forward **only `Sendable` payloads** into a **`Sendable` client** (typically the `ServerCommunicationHandler` actor), with a **weak/unowned upward** edge so the session graph can tear down:

```text
Actor ──strong──► Connection ──strong──► WebSocket ──strong──► NestedProcessor
  ▲                                                                  │
  └──────────────── weak / unowned client (Sendable hop) ────────────┘
```

- `NestedProcessor` can be **truly `Sendable`**: fixed client handle that only delivers `Data` / `String` / `Error` / LSP values (parse may live on the processor if pure, or on the actor).
- **Socket-level** cycle (connection ↔ socket because processor ≡ connection) is gone: the processor is not the connection and does not strong-own it.
- **Session-level** cycle (actor → connection → … → processor → actor) is avoided by **not** strongly retaining the actor from the processor; use a weak class-bound client, unowned where lifetime is guaranteed, or an explicit teardown that nils the connection and cancels the socket.
- Clearing `storedWebSocket` stays on the **owner side** (connection/actor after `connectionDidCloseWithError`), not via `weak var owner` on the processor.

##### Resolution 2 — Pragmatic: `@unchecked Sendable` weak-owner box

```swift
final class SocketProcessor: WebSocketProcessor, @unchecked Sendable {
    weak var owner: WebSocketConnection?
}
```

This **does** shift the concurrency proof to a trust annotation, but the annotation is **localized** to a tiny forwarder whose only job is “hop events to owner.” That is a common, idiomatic pattern when the parent is intentionally non-`Sendable` and the child I/O type requires a `Sendable` sink. It is better than `@unchecked Sendable` on the whole `WebSocketConnection` or weak-owned transport.

**Do not** pretend the weak-owner box is cleanly `Sendable` without unchecked or equivalent; document why unchecked is valid (weak ref only, no other shared mutable state, calls are fire-and-forget into owner).

##### What does *not* work cleanly

- Weak `storedWebSocket` on the connection to “fix” cycles (ownership inversion).
- Claiming `WebSocket` need not be `Sendable` only because the nested processor is awkward (hides the real issue).

#### Do we need another protocol for the weak back-reference?

**Yes — if the processor is a peer type that must call back into the connection — and the reason is architectural type dependency, not the compiler.**

A **type dependency cycle** (A uses B and B uses A) is a serious design smell: the two types collapse into one conceptual blob. Nothing outside can depend on “just one of them”; layering and replaceability die. That is a different issue from retain cycles and from import/compiler cycles.

##### Bad: peer types with mutual knowledge

```text
WebSocketConnection  ──depends on──►  SocketProcessor
SocketProcessor      ──depends on──►  WebSocketConnection   // weak owner: WebSocketConnection?
```

Even with `weak`, the **dependency** is still cyclic. Lifetime is fixed; structure is not.

##### Acceptable without an extra protocol: nesting (not a peer)

```text
WebSocketConnection
  └── private final class SocketProcessor   // implementation detail of Connection
        weak var owner: WebSocketConnection?
```

Here there is **one** type in the architecture (`WebSocketConnection`). The nested class is not a second layer citizen; it cannot be depended on from outside and does not sit beside the connection in the dependency graph. Nesting **hides** the back-ref inside one type’s implementation — it does not create a peer dependency cycle.

Use nesting only when the processor is truly private glue, not a reusable abstraction.

##### Better for peer / shared processors: invert the back-ref through a protocol

If the processor is (or might become) its own type, the weak owner must **not** be typed as `WebSocketConnection`. It must be typed as a protocol the connection **conforms to** and the processor **depends on**:

```text
                    ┌── WebSocketSocketSink  (protocol, AnyObject)
                    │         ▲
                    │         │ conforms
                    │  WebSocketConnection
                    │         │ depends
                    │         ▼
                    └── SocketProcessor  ──depends on──►  WebSocketSocketSink
                              │
                              └──depends on──►  WebSocketProcessor  (FoundationToolz)
```

DAG (no cycle):

- `SocketProcessor` → `WebSocketSocketSink`, `WebSocketProcessor`
- `WebSocketConnection` → `SocketProcessor`, `WebSocketSocketSink` (implements it), `LSPServerConnection`, …

`WebSocketSocketSink` would carry only what the socket forwarder needs (data / text / close handling), class-bound so `weak` works. That is the same move as classic “delegate protocol”: **child depends on abstract parent role, not on concrete parent type.**

##### Best alignment with the rest of this design: no back-ref to the connection at all

Resolution 1 already removes the need for a connection-typed (or connection-sink-typed) back-ref on the socket processor:

```text
NestedProcessor  →  LSPServerConnectionClient  (and WebSocketProcessor)
WebSocketConnection  →  NestedProcessor, LSPServerConnectionClient, WebSocket
ServerCommunicationHandler  →  LSPServerConnection
ServerCommunicationHandler  :  LSPServerConnectionClient
```

Still a DAG. The processor never names `WebSocketConnection`. Socket events go **up** to the session client protocol; connection ownership/clearing stays on the connection/actor side. Prefer this when parse-and-forward can live without calling into the concrete connection type.

##### Layer-level inversion (session)

Same principle one layer up — this is not optional sugar; it **is** the structure:

```text
WebSocketConnection           →  LSPServerConnectionClient
ServerCommunicationHandler    →  LSPServerConnection
ServerCommunicationHandler    :  LSPServerConnectionClient
```

Transports depend on an abstract client; the actor depends on an abstract connection. **No type dependency cycle** between handler and connection. Runtime retain cycles (strong refs in a ring) are orthogonal and still need weak upward edges or explicit teardown.

**Summary**

| Question | Answer |
|---|---|
| Nested processor Sendable? | Weak non-`Sendable` owner ⇒ not cleanly `Sendable`. Prefer processor state = `Sendable` client + payloads; else `@unchecked Sendable` on a tiny private nested forwarder. |
| Protocol for weak back-ref? | **Yes when the processor is a peer type** — otherwise you get a type dependency cycle (design collapse). Nest private glue *or* depend on a sink protocol *or* (preferred) only on `LSPServerConnectionClient` and never on the connection type. |

### Executable side

Same analysis for `Executable` + `ExecutableProcessor` + `ServerExecutable`: strong `let processor` on the process wrapper plus “executable adapter is the processor and stores the `Executable`” would cycle. Use nested processor with Sendable client / `@unchecked` weak owner, or weak processor on `Executable`.

---

## Explicit non-goals

- Making `WebSocketConnection` `Sendable` as an end in itself.
- Removing `Sendable` from FoundationToolz `WebSocket` because SwiftLSP owns the instance.
- Keeping `LSPServerConnection`’s mutable handler properties long-term.
- Pushing request/response matching down into the transport layer.
- Breaking retain cycles by making the owned transport `weak` on the owner (ownership inversion).

---

## One-line summary

**Each layer owns the layer below and creates it; event delivery uses a fixed Sendable processor/client with weak upward references (nested forwarder or classic weak delegate), never a strong parent↔child loop — same structural idea at WebSocket and at `LSPServerConnection`.**
