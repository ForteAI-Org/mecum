# Native menu requests share the Seat observation boundary

The consumer can invoke an explicitly requested native application-menu leaf. This is a
separate route from coordinate input, not an implicit fallback. Menu reading, path resolution,
AXPress and effect verification remain in the Engine and its adapters; the Driver imports no
menu semantics or control-tree reader. This preserves the layer boundary in ADR 0004.

`AgentSeat.performNativeMenuAction` holds an existing Turn and observation. It checks readiness,
identity, geometry and existing menus, prepares user-focus recovery, then gives the adapter a
one-use boundary check. The adapter calls that check immediately before AXPress, after its
native lookup and focused-window identity check. The boundary rechecks the stop gate, Turn,
observation and geometry and consumes the observation. Native timeout cannot authorize a replay.

The call is marked acting for the whole operation and follows newly born windows afterwards.
It does not fabricate a mouse event or InputReceipt. The consumer owns the native delivery
result and must establish the actual effect before claiming success or teaching memory.
The adapter never raises the target or changes AX focus to force context to match.

Unit tests cover consumption, stale references and the deliberate stop. Pro Tools' Setup → I/O
path is a live example, not a compatibility claim for every application or macOS build.
