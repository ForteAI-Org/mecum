import QtQuick

Rectangle {
    id: root
    width: 700
    height: 450
    color: "#263642"
    property int clicks: 0
    property int drops: 0
    property int dragEnters: 0
    property int dragMoves: 0
    property int dragReleases: 0
    property int keyDowns: 0
    property int keyCode: 0
    property int keyModifiers: 0

    Rectangle {
        objectName: "button"
        x: 24; y: 24; width: 240; height: 48
        color: "#d5e5ec"
        Accessible.role: Accessible.Button
        Accessible.name: "Quick probe button"
        Text { anchors.centerIn: parent; text: "Quick probe button" }
        MouseArea { anchors.fill: parent; onClicked: root.clicks += 1 }
    }

    Rectangle {
        x: 24; y: 88; width: 652; height: 48
        color: "white"
        TextInput {
            id: field
            objectName: "field"
            anchors.fill: parent
            anchors.margins: 10
            font.pixelSize: 20
            selectByMouse: true
            Accessible.name: "Quick probe text"
            Keys.onPressed: function(event) {
                root.keyDowns += 1
                root.keyCode = event.key
                root.keyModifiers = event.modifiers
                event.accepted = false
            }
        }
    }

    Flickable {
        id: scroll
        objectName: "scroll"
        x: 24; y: 160; width: 652; height: 120
        contentWidth: width
        contentHeight: 1200
        clip: true
        Rectangle { width: scroll.width; height: 1200; color: "#b7c9d4" }
        Repeater {
            model: 20
            Text { x: 12; y: index * 58 + 12; text: "Quick scroll row " + index }
        }
    }

    Rectangle {
        objectName: "destination"
        x: 440; y: 320; width: 236; height: 100
        color: destination.containsDrag ? "#81ba98" : "#dae5cd"
        Text { anchors.centerIn: parent; text: "Drop destination" }
        DropArea {
            id: destination
            anchors.fill: parent
            keys: ["mecum-quick-probe"]
            onEntered: root.dragEnters += 1
            onPositionChanged: root.dragMoves += 1
            onDropped: function(drop) {
                if (drop.source === source) {
                    root.drops += 1
                    drop.acceptProposedAction()
                }
            }
        }
    }

    Rectangle {
        id: source
        objectName: "source"
        x: 24; y: 340; width: 100; height: 60
        z: 1
        color: "#e0ac8a"
        Drag.active: dragMouse.drag.active
        Drag.keys: ["mecum-quick-probe"]
        Drag.source: source
        Drag.hotSpot.x: width / 2
        Drag.hotSpot.y: height / 2
        Text { anchors.centerIn: parent; text: "Drag source" }
        MouseArea {
            id: dragMouse
            anchors.fill: parent
            drag.target: source
            onReleased: {
                root.dragReleases += 1
                source.Drag.drop()
            }
        }
    }
}
