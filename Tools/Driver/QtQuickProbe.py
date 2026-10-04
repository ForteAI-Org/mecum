"""Owned Qt Quick target with measured item geometry and native state oracles."""

import json
import os
import sys
import time
from pathlib import Path

from PySide6.QtCore import QEvent, QObject, QTimer, QUrl
from PySide6.QtGui import QGuiApplication
from PySide6.QtQuick import QQuickItem, QQuickView


state_path = Path(sys.argv[1])
wheel_observation = {"wheelEvents": 0}
input_method_events = []


class InputObserver(QObject):
    def eventFilter(self, watched, event):
        if event.type() == QEvent.Type.InputMethod:
            input_method_events.append({
                "target": watched.objectName(),
                "preedit": event.preeditString(),
                "commit": event.commitString(),
                "replacementStart": event.replacementStart(),
                "replacementLength": event.replacementLength(),
                "time": time.monotonic_ns(),
            })
            del input_method_events[:-32]
        if event.type() == QEvent.Type.Wheel:
            wheel_observation.update({
                "wheelEvents": wheel_observation["wheelEvents"] + 1,
                "wheelPosition": [event.position().x(), event.position().y()],
                "wheelAngle": [event.angleDelta().x(), event.angleDelta().y()],
                "wheelPixels": [event.pixelDelta().x(), event.pixelDelta().y()],
                "wheelModifiers": event.modifiers().value,
            })
        return False


app = QGuiApplication(sys.argv)
app.setApplicationName("Mecum Qt Probe")
view = QQuickView()
view.setTitle("Mecum Qt Probe")
observer = InputObserver()
app.installEventFilter(observer)
view.setSource(QUrl.fromLocalFile(str(Path(__file__).with_suffix(".qml"))))
if view.status() == QQuickView.Status.Error:
    raise RuntimeError("Qt Quick probe failed to load: " + str(view.errors()))
root = view.rootObject()
items = {
    name: root.findChild(QQuickItem, name)
    for name in ("button", "field", "scroll", "source", "destination")
}
if any(item is None for item in items.values()):
    raise RuntimeError("Qt Quick probe has no complete measured item set")


def publish():
    state = {"fixture": "qt-quick"}
    state["inputMethodEvents"] = list(input_method_events)
    state["applicationState"] = app.applicationState().name
    state["focusObject"] = app.focusObject().objectName() if app.focusObject() else None
    state.update(wheel_observation)
    for key in ("clicks", "drops", "dragEnters", "dragMoves", "dragReleases", "keyDowns", "keyCode", "keyModifiers"):
        state[key] = root.property(key)
    field = items["field"]
    for key in ("text", "selectedText", "cursorPosition", "selectionStart", "selectionEnd",
                "activeFocus", "preeditText", "inputMethodComposing"):
        state[key] = field.property(key)
    state["scroll"] = items["scroll"].property("contentY")
    for name, item in items.items():
        point = item.mapToGlobal(item.boundingRect().topLeft())
        state[name + "Frame"] = [point.x(), point.y(), item.width(), item.height()]
    temporary = state_path.with_suffix(".tmp")
    temporary.write_text(json.dumps(state, sort_keys=True))
    os.replace(temporary, state_path)


view.show()
timer = QTimer()
timer.timeout.connect(publish)
timer.start(25)
publish()
sys.exit(app.exec())
