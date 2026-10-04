"""Owned QWidget target for a native QDrag MIME transfer between two controls."""

import json
import os
import sys
import uuid
from pathlib import Path

from PySide6.QtCore import QMimeData, QPoint, QTimer, Qt
from PySide6.QtGui import QDrag
from PySide6.QtWidgets import QApplication, QHBoxLayout, QLabel, QWidget


state_path = Path(sys.argv[1])
payload = "mecum-native-drag-" + str(uuid.uuid4())
state = {
    "fixture": "qt-native-drag",
    "payload": payload,
    "presses": 0,
    "moves": 0,
    "releases": 0,
    "dragStarted": 0,
    "dragFinished": False,
    "dragResult": -1,
    "enters": 0,
    "drops": 0,
    "received": "",
}


def publish():
    for name, widget in (("source", source), ("destination", destination)):
        origin = widget.mapToGlobal(widget.rect().topLeft())
        state[name + "Frame"] = [origin.x(), origin.y(), widget.width(), widget.height()]
    temporary = state_path.with_suffix(".tmp")
    temporary.write_text(json.dumps(state, sort_keys=True))
    os.replace(temporary, state_path)


class Source(QLabel):
    def __init__(self):
        super().__init__("Native drag source")
        self.press_position = None
        self.setAlignment(Qt.AlignmentFlag.AlignCenter)
        self.setAccessibleName("Native drag source")

    def mousePressEvent(self, event):
        if event.button() == Qt.MouseButton.LeftButton:
            state["presses"] += 1
            self.press_position = event.position().toPoint()
            publish()

    def mouseMoveEvent(self, event):
        state["moves"] += 1
        state["moveButtons"] = event.buttons().value
        state["moveGlobal"] = [event.globalPosition().x(), event.globalPosition().y()]
        publish()
        if self.press_position is None or not event.buttons() & Qt.MouseButton.LeftButton:
            return
        if (event.position().toPoint() - self.press_position).manhattanLength() < QApplication.startDragDistance():
            return
        self.press_position = None
        data = QMimeData()
        data.setText(payload)
        drag = QDrag(self)
        drag.setMimeData(data)
        drag.setHotSpot(QPoint(0, 0))
        state["dragStarted"] += 1
        publish()
        result = drag.exec(Qt.DropAction.CopyAction)
        state["dragResult"] = result.value
        state["dragFinished"] = True
        publish()

    def mouseReleaseEvent(self, event):
        if event.button() == Qt.MouseButton.LeftButton:
            state["releases"] += 1
            self.press_position = None
            publish()


class Destination(QLabel):
    def __init__(self):
        super().__init__("Native drop destination")
        self.setAlignment(Qt.AlignmentFlag.AlignCenter)
        self.setAccessibleName("Native drop destination")
        self.setAcceptDrops(True)

    def dragEnterEvent(self, event):
        if event.source() is source and event.mimeData().text() == payload:
            state["enters"] += 1
            event.acceptProposedAction()
            publish()

    def dropEvent(self, event):
        if event.source() is source and event.mimeData().text() == payload:
            state["drops"] += 1
            state["received"] = event.mimeData().text()
            event.acceptProposedAction()
            publish()


app = QApplication(sys.argv)
app.setApplicationName("Mecum Qt Probe")
window = QWidget()
window.setWindowTitle("Mecum Qt Probe")
window.resize(700, 300)
layout = QHBoxLayout(window)
source = Source()
destination = Destination()
layout.addWidget(source)
layout.addWidget(destination)
window.show()
timer = QTimer()
timer.timeout.connect(publish)
timer.start(25)
publish()
sys.exit(app.exec())
