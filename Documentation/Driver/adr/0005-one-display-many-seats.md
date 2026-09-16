# One Virtual Display, many Agent Seats, v1 ships one

A Seat Host owns exactly one Virtual Display and creates Agent Seats on it; a
seat owns its Adopted Windows, its guard, its recovery and its capture. Version
one refuses a second seat (`seatLimitReached`), but nothing in the model assumes
a single one, so the second seat costs no redesign.

## Context

Stage Manager decides which window on the display is at full size and keeps the
others as thumbnails, so windows are staged and stashed rather than tiled, and
raising the window to act on is the primitive that makes several adopted windows
practical (measured: 0.5 s on Chrome, 19 ms on a cooperative window, with no app
activation). What v1 does not have is contention: two seats sharing one display
would compete for the stage, the fence and the input identity checks, and that
needs measurement before it is designed.
