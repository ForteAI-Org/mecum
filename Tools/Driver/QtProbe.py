import json
import os
import sys
from pathlib import Path

from PySide6.QtCore import QTimer, Qt
from PySide6.QtGui import QColor, QPainter
from PySide6.QtWidgets import (
    QApplication,
    QComboBox,
    QDialog,
    QDialogButtonBox,
    QFileDialog,
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
COMMAND_PATH = Path(sys.argv[2]) if len(sys.argv) > 2 else None
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
    "secondOpen": False,
    "secondClicks": 0,
    "nativeCommandSequence": 0,
    "menuOpen": False,
    "menuChoices": 0,
    "modalOpen": False,
    "fileDialogOpen": False,
    "fileDialogMode": "",
    "fileDialogAccepted": False,
    "canvasPresses": 0,
    "canvasMoves": 0,
    "canvasReleases": 0,
    "canvasScrolls": 0,
    "canvasKeys": 0,
    "canvasKeyText": "",
    "canvasLastX": -1,
}
measured_widgets = {}
active_dialog = None
active_file_dialog = None


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


class ProbeCanvas(QWidget):
    def __init__(self):
        super().__init__()
        self.setAccessibleName("Probe Canvas")
        self.setFocusPolicy(Qt.FocusPolicy.StrongFocus)
        self.setMinimumHeight(110)

    def paintEvent(self, event):
        painter = QPainter(self)
        painter.fillRect(self.rect(), QColor(40, 58, 72))
        painter.setPen(QColor(235, 244, 250))
        painter.drawText(self.rect(), Qt.AlignmentFlag.AlignCenter, "Probe Canvas")

    def mousePressEvent(self, event):
        if event.button() == Qt.MouseButton.LeftButton:
            self.setFocus()
            state["canvasPresses"] += 1
            state["canvasLastX"] = int(event.position().x())
            publish()

    def mouseMoveEvent(self, event):
        if event.buttons() & Qt.MouseButton.LeftButton:
            state["canvasMoves"] += 1
            state["canvasLastX"] = int(event.position().x())
            publish()

    def mouseReleaseEvent(self, event):
        if event.button() == Qt.MouseButton.LeftButton:
            state["canvasReleases"] += 1
            state["canvasLastX"] = int(event.position().x())
            publish()

    def wheelEvent(self, event):
        state["canvasScrolls"] += 1
        publish()

    def keyPressEvent(self, event):
        state["canvasKeys"] += 1
        state["canvasKeyText"] = event.text()
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

canvas = ProbeCanvas()
layout.addWidget(canvas)


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

second_window = QWidget()
second_window.setWindowTitle("Probe Secondary")
second_window.resize(340, 180)
second_layout = QVBoxLayout(second_window)
second_button = QPushButton("Secondary click")
second_button.setAccessibleName("Secondary click")
second_button.clicked.connect(lambda: (
    state.__setitem__("secondClicks", state["secondClicks"] + 1), publish()
))
second_layout.addWidget(second_button)


def open_second():
    second_window.show()
    measured_widgets["secondButtonFrame"] = second_button
    state["secondOpen"] = True
    publish()


def close_second():
    second_window.close()
    measured_widgets.pop("secondButtonFrame", None)
    state.pop("secondButtonFrame", None)
    state["secondOpen"] = False
    publish()


second_opener = QPushButton("Open second window")
second_opener.setAccessibleName("Open second window")
second_opener.clicked.connect(open_second)
layout.addWidget(second_opener)


def poll_native_command():
    if COMMAND_PATH is None or not COMMAND_PATH.exists():
        return
    try:
        command = json.loads(COMMAND_PATH.read_text())
    except (OSError, json.JSONDecodeError):
        return
    sequence = command.get("sequence", 0)
    if sequence <= state["nativeCommandSequence"]:
        return
    state["nativeCommandSequence"] = sequence
    action = command.get("action")
    if action == "openCombo":
        combo.showPopup()
    elif action == "chooseBeta":
        combo.setCurrentIndex(1)
        combo.hidePopup()
    elif action == "closeModal" and active_dialog is not None:
        active_dialog.reject()
    elif action == "closeSecond":
        close_second()
    elif action == "closeFileDialog" and active_file_dialog is not None:
        active_file_dialog.reject()
    publish()

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
    global active_dialog
    dialog = QDialog(window)
    active_dialog = dialog
    dialog.setWindowTitle("Probe Modal")
    dialog_layout = QVBoxLayout(dialog)
    dialog_layout.addWidget(QLabel("Temporary modal"))
    cancel = QPushButton("Cancel")
    cancel.setAccessibleName("Cancel modal")
    cancel.clicked.connect(dialog.reject)
    dialog_layout.addWidget(cancel)
    measured_widgets["modalCancelFrame"] = cancel
    state["modalOpen"] = True
    publish()
    dialog.exec()
    active_dialog = None
    state["modalOpen"] = False
    measured_widgets.pop("modalCancelFrame", None)
    state.pop("modalCancelFrame", None)
    publish()


modal = QPushButton("Open modal")
modal.setAccessibleName("Open modal")
modal.clicked.connect(open_modal)
layout.addWidget(modal)


def open_file_dialog(native=False):
    global active_file_dialog
    title = "Probe Native File Dialog" if native else "Probe Widget File Dialog"
    dialog = QFileDialog(window, title)
    dialog.setFileMode(QFileDialog.FileMode.ExistingFile)
    dialog.setOption(QFileDialog.Option.DontUseNativeDialog, not native)
    active_file_dialog = dialog
    state["fileDialogOpen"] = True
    state["fileDialogMode"] = "native" if native else "widget"
    publish()

    def publish_cancel_frame():
        box = dialog.findChild(QDialogButtonBox)
        cancel = box.button(QDialogButtonBox.StandardButton.Cancel) if box else None
        if cancel is not None:
            measured_widgets["fileCancelFrame"] = cancel
            update_geometry()

    if not native:
        QTimer.singleShot(0, publish_cancel_frame)
    result = dialog.exec()
    active_file_dialog = None
    measured_widgets.pop("fileCancelFrame", None)
    state.pop("fileCancelFrame", None)
    state["fileDialogOpen"] = False
    state["fileDialogAccepted"] = result == QDialog.DialogCode.Accepted
    publish()


file_opener = QPushButton("Open widget file dialog")
file_opener.setAccessibleName("Open widget file dialog")
file_opener.clicked.connect(lambda: open_file_dialog(False))
layout.addWidget(file_opener)

native_file_opener = QPushButton("Open native file dialog")
native_file_opener.setAccessibleName("Open native file dialog")
native_file_opener.clicked.connect(lambda: open_file_dialog(True))
layout.addWidget(native_file_opener)

measured_widgets.update({
    "textFrame": field,
    "canvasFrame": canvas,
    "buttonFrame": button,
    "sliderFrame": slider,
    "scrollFrame": scroll.viewport(),
    "comboFrame": combo,
    "secondOpenFrame": second_opener,
    "modalFrame": modal,
    "fileOpenFrame": file_opener,
    "nativeFileOpenFrame": native_file_opener,
})
publish()
window.show()
timer = QTimer()
timer.timeout.connect(update_geometry)
timer.start(100)
command_timer = QTimer()
command_timer.timeout.connect(poll_native_command)
command_timer.start(40)
sys.exit(app.exec())
