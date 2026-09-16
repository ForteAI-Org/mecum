# Accessibility is used only to place a window

The kit's only use of the accessibility API is placing the target window:
`AXPosition` to move it onto the Virtual Display, `AXRaise` to stage it, and
`_AXUIElementGetWindow` to find the element for a Window ID. It never reads the
element tree and never acts on a control. Observation, semantics and target
resolution belong to the consumer, which reaches the kit with coordinates.

## Context

The research this kit comes from exists because accessibility is not a reliable
control surface: a standard `NSTextView` refuses a mouse selection from an
inactive window even when accessibility can set the same selection directly. The
project's rule is that private input primitives do the acting and accessibility
does not become an implicit fallback.
