// SPDX-License-Identifier: GPL-2.0-or-later
// The Chumby's screen: as large as fits, keeping its shape, one texel per
// Chumby pixel scaled without smoothing. The mouse (or a finger) on it is
// the pen; with the keyboard focus, keys go to the Chumby.
import QtQuick
import QtQuick.Controls
import QtQuick.Dialogs
import QtCore
import ChumbyDesktop

FocusScope {
    id: view

    required property Machine machine
    // Whole device pixels per Chumby pixel, when there's room for one.
    property bool sharp: true

    readonly property real dpr: Screen.devicePixelRatio
    readonly property real margin: 12
    readonly property real fit: Math.max(0.25, Math.min((width - 2 * margin) / machine.screenWidth,
                                                         (height - 2 * margin) / machine.screenHeight))
    readonly property real shown: sharp && fit * dpr >= 1 ? Math.floor(fit * dpr) / dpr : fit

    function snap(v) { return Math.round(v * dpr) / dpr }

    function saveScreenshot() {
        const stamp = new Date().toISOString().replace(/[:T]/g, "-").replace(/\..*/, "")
        shotDialog.selectedFile = shotDialog.currentFolder + "/chumby-" + stamp + ".png"
        shotDialog.open()
    }

    function reportGeometry() {
        const p = screen.mapToItem(null, 0, 0)
        machine.setScreenGeometry(p.x, p.y, shown)
    }
    onShownChanged: Qt.callLater(reportGeometry)
    onWidthChanged: Qt.callLater(reportGeometry)
    onHeightChanged: Qt.callLater(reportGeometry)
    onXChanged: Qt.callLater(reportGeometry)

    Rectangle {
        anchors.fill: parent
        color: Qt.darker(palette.window, 1.15)
    }

    // The keyboard focus: a ring around the screen.
    Rectangle {
        x: screen.x - 3
        y: screen.y - 3
        width: screen.width * view.shown + 6
        height: screen.height * view.shown + 6
        radius: 4
        color: "transparent"
        border.width: 2
        border.color: palette.highlight
        visible: view.activeFocus
    }

    ChumbyScreen {
        id: screen
        width: view.machine.screenWidth
        height: view.machine.screenHeight
        textureSize: Qt.size(width, height)
        smooth: false
        antialiasing: false
        fillColor: "black"
        transformOrigin: Item.TopLeft
        scale: view.shown
        x: view.snap((view.width - width * view.shown) / 2)
        y: view.snap((view.height - height * view.shown) / 2)
        Accessible.name: qsTr("The Chumby's screen")
        Accessible.role: Accessible.Graphic

        MouseArea {
            id: pen
            anchors.fill: parent
            cursorShape: Qt.CrossCursor
            onPressed: mouse => {
                view.forceActiveFocus()
                view.machine.pen(mouse.x, mouse.y, true)
            }
            onPositionChanged: mouse => {
                if (pressed)
                    view.machine.pen(mouse.x, mouse.y, true)
            }
            onReleased: mouse => view.machine.pen(mouse.x, mouse.y, false)
            onCanceled: view.machine.pen(mouseX, mouseY, false)
        }
    }

    Connections {
        target: view.machine
        function onFrameReady() {
            screen.update()
            if (!view.seenFrame)
                view.seenFrame = true
        }
        function onPhaseChanged() {
            if (view.machine.phase === "starting")
                view.seenFrame = false
        }
    }
    property bool seenFrame: false

    BusyIndicator {
        anchors.centerIn: parent
        running: !view.seenFrame && view.machine.phase !== "idle"
        visible: running
    }

    // Paused: the screen dimmed, and a way back.
    Rectangle {
        x: screen.x
        y: screen.y
        width: screen.width * view.shown
        height: screen.height * view.shown
        color: "#a0000000"
        visible: view.machine.paused
        Column {
            anchors.centerIn: parent
            spacing: 8
            Label {
                anchors.horizontalCenter: parent.horizontalCenter
                text: qsTr("Paused")
                color: "white"
                font.bold: true
                font.pointSize: 16
            }
            Button {
                anchors.horizontalCenter: parent.horizontalCenter
                text: qsTr("Resume")
                icon.name: "media-playback-start"
                onClicked: view.machine.pause(false)
            }
        }
    }

    // Keys: everything goes to the Chumby while the screen has the focus,
    // except the app's Ctrl+Shift shortcuts and Quit.
    function appShortcut(e) {
        const cs = Qt.ControlModifier | Qt.ShiftModifier
        return (e.modifiers & cs) === cs
            || ((e.modifiers & Qt.ControlModifier) && e.key === Qt.Key_Q)
    }
    Keys.onShortcutOverride: e => e.accepted = !appShortcut(e)
    Keys.onPressed: e => {
        if (appShortcut(e)) {
            e.accepted = false
            return
        }
        // The guest repeats keys itself.
        e.accepted = e.isAutoRepeat
            || machine.key(Qt.platform.pluginName, e.nativeScanCode, e.key, e.modifiers, true)
    }
    Keys.onReleased: e => {
        if (e.isAutoRepeat)
            return
        e.accepted = machine.key(Qt.platform.pluginName, e.nativeScanCode, e.key, e.modifiers, false)
    }
    onActiveFocusChanged: if (!activeFocus) machine.releaseKeys()

    FileDialog {
        id: shotDialog
        title: qsTr("Save screenshot")
        fileMode: FileDialog.SaveFile
        nameFilters: [qsTr("PNG images (*.png)")]
        defaultSuffix: "png"
        currentFolder: StandardPaths.writableLocation(StandardPaths.PicturesLocation)
        onAccepted: {
            const url = selectedFile.toString()
            view.machine.screenshot(decodeURIComponent(url.replace(/^file:\/\//, "")))
        }
    }
}
