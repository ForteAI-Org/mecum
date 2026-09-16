# The kit owns the seat's capture path

Capture is inside the kit, not left to the consumer: the Seat Host owns the
Monitor stream of the Virtual Display and each Agent Seat owns the window stream
plus one-shot Stills. The reason is the invariant "one owner of the capture
path": with the consumer building its own `SCStream`, nothing prevents two
concurrent capture owners on the same surface. The kit hands out `SeatFrame`
values backed by an IOSurface and a `MonitorLayer`; the consumer keeps its own
view and its own vision pipeline.

## Consequences

Frames are zero-copy (`IOSurface` into `CALayer.contents`), which measured 6 %
of one core against 42 % for the CGImage pipeline at 60 fps. Verifying an effect
by diffing two Stills stays the consumer's job: the kit reports delivery, never
effect.
