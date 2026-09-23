import json
import os
import sys
from pathlib import Path

from PySide6.QtCore import QTimer, Qt
from PySide6.QtWidgets import (
    QApplication,
    QComboBox,
    QDialog,
    QLabel,
    QLineEdit,
    QMenu,
    QPushButton,
    QScrollArea,
    QSlider,
    QVBoxLayout,
    QWidget,
)


STATE_PATH = Path(sys.argv[1])
state = {
    "text": "",
    "selectionStart": -1,
    "selectionLength": 0,
    "keyDowns": 0,
    "clicks": 0,
    "doubleClicks": 0,
    "rightClicks": 0,
    "scroll": 0,
    "slider": 0,
    "comboIndex": 0,
    "comboText": "Alpha",
    "menuOpen": False,
    "menuChoices": 0,
    "modalOpen": False,
}
measured_widgets = {}


def widget_frame(widget):
    origin = widget.mapToGlobal(widget.rect().topLeft())
    return [origin.x(), origin.y(), widget.width(), widget.height()]


def update_geometry():
    changed = False
    for name, widget in measured_widgets.items():
        frame = widget_frame(widget)
        if state.get(name) != frame:
            state[name] = frame
            changed = True
    if changed:
        publish()


def publish():
    temp = STATE_PATH.with_suffix(".tmp")
    temp.write_text(json.dumps(state, sort_keys=True))
    os.replace(temp, STATE_PATH)


class ProbeLineEdit(QLineEdit):
    def keyPressEvent(self, event):
        state["keyDowns"] += 1
        publish()
        super().keyPressEvent(event)

    def mouseDoubleClickEvent(self, event):
        state["doubleClicks"] += 1
        publish()
        super().mouseDoubleClickEvent(event)

    def contextMenuEvent(self, event):
        state["rightClicks"] += 1
        state["menuOpen"] = True
        publish()
        menu = QMenu(self)
        choice = menu.addAction("Clear probe text")

        def publish_choice_frame():
            rectangle = menu.actionGeometry(choice)
            origin = menu.mapToGlobal(rectangle.topLeft())
            state["menuChoiceFrame"] = [
                origin.x(), origin.y(), rectangle.width(), rectangle.height()
            ]
            publish()

        menu.aboutToShow.connect(lambda: QTimer.singleShot(0, publish_choice_frame))
        selected = menu.exec(event.globalPos())
        state["menuOpen"] = False
        state.pop("menuChoiceFrame", None)
        if selected == choice:
            state["menuChoices"] += 1
            self.clear()
        publish()


app = QApplication(sys.argv)
app.setApplicationName("Mecum Qt Probe")
window = QWidget()
window.setWindowTitle("Mecum Qt Probe")
window.resize(700, 580)
layout = QVBoxLayout(window)

field = ProbeLineEdit()
field.setObjectName("probeText")
field.setAccessibleName("Probe Text")
field.setPlaceholderText("Probe Text")
layout.addWidget(field)


def sync_text():
    state["text"] = field.text()
    state["selectionStart"] = field.selectionStart()
    state["selectionLength"] = len(field.selectedText())
    publish()


field.textChanged.connect(sync_text)
field.selectionChanged.connect(sync_text)
field.cursorPositionChanged.connect(lambda _before, _after: sync_text())

button = QPushButton("Click target")
button.setAccessibleName("Click target")
button.clicked.connect(lambda: (state.__setitem__("clicks", state["clicks"] + 1), publish()))
layout.addWidget(button)

slider = QSlider(Qt.Orientation.Horizontal)
slider.setRange(0, 100)
slider.setAccessibleName("Probe slider")
slider.valueChanged.connect(lambda value: (state.__setitem__("slider", value), publish()))
layout.addWidget(slider)

combo = QComboBox()
combo.setAccessibleName("Probe choices")
combo.addItems(["Alpha", "Beta", "Gamma"])
combo.currentIndexChanged.connect(lambda index: (
    state.__setitem__("comboIndex", index),
    state.__setitem__("comboText", combo.currentText()),
    publish(),
))
layout.addWidget(combo)

scroll = QScrollArea()
scroll.setAccessibleName("Probe scroll")
scroll.setWidgetResizable(True)
content = QWidget()
content.setMinimumHeight(1700)
content_layout = QVBoxLayout(content)
for number in range(30):
    content_layout.addWidget(QLabel(f"Scroll row {number:02d}"))
scroll.setWidget(content)
scroll.setFixedHeight(185)
scroll.verticalScrollBar().valueChanged.connect(
    lambda value: (state.__setitem__("scroll", value), publish())
)
layout.addWidget(scroll)


def open_modal():
    dialog = QDialog(window)
    dialog.setWindowTitle("Probe Modal")
    dialog_layout = QVBoxLayout(dialog)
    dialog_layout.addWidget(QLabel("Temporary modal"))
    cancel = QPushButton("Cancel")
    cancel.clicked.connect(dialog.reject)
    dialog_layout.addWidget(cancel)
    state["modalOpen"] = True
    publish()
    dialog.exec()
    state["modalOpen"] = False
    publish()


modal = QPushButton("Open modal")
modal.setAccessibleName("Open modal")
modal.clicked.connect(open_modal)
layout.addWidget(modal)

measured_widgets.update({
    "textFrame": field,
    "buttonFrame": button,
    "sliderFrame": slider,
    "scrollFrame": scroll.viewport(),
    "comboFrame": combo,
    "modalFrame": modal,
})
publish()
window.show()
timer = QTimer()
timer.timeout.connect(update_geometry)
timer.start(100)
sys.exit(app.exec())
