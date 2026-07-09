## Redesign from the Ground up for modern Concurrency
**🚨 This is a painful but ultimately necessary transformation. It is made necessary by the likely last such disruptive transformation of Swift itself.**
FoundationToolz already broke api with its changed initializer of WebSocket. instead of migrating to a breaking change that is not future-proof we might as well first make the breaking change in FoundationToolz future proof (aligned with modern Swift)
[TargetDesign-ServerConnectionConcurrency.md](TargetDesign-ServerConnectionConcurrency.md) concludes that **greenfield (actor + `AsyncThrowingStream`) is the target**, and the processor pattern is just a migration tax.
A mental-model shift is required—modern Swift wants:
- **One owner** (actor) holding mutable state
- **Values flowing through** (`async` send, `AsyncSequence` receive)
- **No reverse dependencies** (no callbacks phoning home)
The old mental model (Entity graphs with mutual back-refs) is exactly what `Sendable` punishes. The fix isn't more `Sendable` annotations—it's removing the callback arrows.
So: update FoundationToolz's `WebSocket`/`Executable` to the stream/actor shape first (or the factory-returning-`(stream, send)` tuple), then SwiftLSP becomes trivial. That change *is* the future-proof API.
