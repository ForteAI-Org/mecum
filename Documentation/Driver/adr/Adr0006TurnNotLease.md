# The kit offers a Turn, not a Lease

An Agent Seat is held through a Turn: exclusive, cooperative use between two safe
points, acquired in arrival order and released only once every Command has been
confirmed. The Turn has no expiry, no priority, no revocation and no preemption.
Those belong to the Orchestrator's SeatBroker, which builds Lease and Epoch on
top of the Turn and its monotonic generation.

## Why the line is here

The kit's job is to say what a seat can do and to make exclusivity safe; deciding
who gets the seat next is a policy question that needs task priorities, budgets
and agent health, none of which the kit can see. Putting a TTL in the kit would
force it to choose what happens when the clock runs out while a Command is in
flight, which is exactly the ambiguous-effect case the kit refuses to guess at.

## Consequences

Ceding a seat is cheap but not free: another holder may change the screen. The
kit does not hide that, it measures it. `Turn.generation` and
`seatChangedSinceLastHold` tell the next holder whether it must perceive again
before acting, and the broker derives its Epoch from that generation.
