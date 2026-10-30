// SPDX-License-Identifier: GPL-2.0-or-later
// The window: a header toolbar, the Chumby's screen, and the controls in
// a side panel (docked when there's room, a drawer when there isn't).
import QtCore
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import ChumbyDesktop

ApplicationWindow {
    id: win

    readonly property bool running: machine.phase === "running"
    readonly property bool active: running || machine.phase === "starting"
    // Room for the controls beside the screen at its own size, at least.
    readonly property bool wide: width >= inspectorWidth + machine.screenWidth + 2 * unit
    readonly property int unit: fm.height
    readonly property int inspectorWidth: 20 * unit

    // A real Chumby's screen is 3.5 inches across (71 mm, 4:3); its size on
    // this display, unless --scale says otherwise or the display's size
    // isn't worth believing (a virtual display, a missing EDID).
    function realSizeScale() {
        const ppmm = Screen.pixelDensity
        if (!(ppmm >= 50 / 25.4 && ppmm <= 400 / 25.4))
            return 2
        return Math.max(1, Math.min(6, 71.12 * ppmm / 320))
    }
    readonly property real startScale: machine.scale > 0 ? machine.scale : realSizeScale()

    // The first size: the screen at startScale, the controls beside it,
    // and room for the start page. Fixed once shown (see onCompleted).
    width: Math.max(Math.round(machine.screenWidth * startScale) + (settings.inspector ? inspectorWidth : 0) + 2 * unit,
                    36 * unit)
    height: Math.max(Math.round(machine.screenHeight * startScale) + 6 * unit, 30 * unit)
    minimumWidth: 22 * unit
    minimumHeight: 18 * unit
    visible: true
    title: !active ? "Chumby" : machine.paused ? qsTr("Chumby (paused)") : "Chumby"

    FontMetrics { id: fm }
    Machine { id: machine }

    Settings {
        id: settings
        property bool inspector: true
        property bool sharp: true
        property string recents: "[]"
    }

    // The machines opened before, newest first: {kernel, nand, state, fast}.
    property var recents: {
        try { return JSON.parse(settings.recents) } catch (e) { return [] }
    }
    function remember(entry) {
        const key = JSON.stringify([entry.kernel, entry.nand, entry.state])
        const list = recents.filter(r => JSON.stringify([r.kernel, r.nand, r.state]) !== key)
        list.unshift(entry)
        settings.recents = JSON.stringify(list.slice(0, 8))
    }
    function forget(index) {
        const list = recents.slice()
        list.splice(index, 1)
        settings.recents = JSON.stringify(list)
    }

    Connections {
        target: machine
        function onPhaseChanged() {
            if (machine.phase === "running") {
                win.remember({ kernel: machine.kernel, nand: machine.nand,
                               state: machine.stateDir, fast: machine.fast })
                screenView.forceActiveFocus()
            }
        }
        function onNotice(text) { footerBar.show(text) }
    }

    Component.onCompleted: {
        width = width   // no longer bound: the user's size from here on
        height = height
        machine.startFromCommandLine()
    }
    onClosing: machine.powerOff()

    // -- shortcuts: Ctrl+Shift, so that the Chumby gets the rest ----------
    Shortcut { sequences: [StandardKey.Quit]; onActivated: win.close() }
    Shortcut { sequence: "Ctrl+Shift+P"; enabled: win.running; onActivated: machine.pause(!machine.paused) }
    Shortcut { sequence: "Ctrl+Shift+S"; enabled: win.running; onActivated: screenView.saveScreenshot() }
    Shortcut { sequence: "Ctrl+Shift+F"; onActivated: win.visibility = win.visibility === Window.FullScreen ? Window.Windowed : Window.FullScreen }
    Shortcut { sequence: "Ctrl+Shift+B"; onActivated: win.toggleInspector() }
    Shortcut { sequence: "Ctrl+Shift+T"; enabled: machine.consoleTty !== ""; onActivated: machine.openConsole() }

    function toggleInspector() {
        if (wide)
            settings.inspector = !settings.inspector
        else
            drawer.visible ? drawer.close() : drawer.open()
    }

    header: ToolBar {
        RowLayout {
            anchors.fill: parent
            spacing: 0
            ToolButton {
                visible: win.active
                enabled: win.running
                text: machine.paused ? qsTr("Resume") : qsTr("Pause")
                icon.name: machine.paused ? "media-playback-start" : "media-playback-pause"
                display: AbstractButton.TextBesideIcon
                ToolTip.text: qsTr("Stop or carry on the Chumby (Ctrl+Shift+P)")
                ToolTip.visible: hovered
                ToolTip.delay: 600
                onClicked: machine.pause(!machine.paused)
            }
            ToolButton {
                visible: win.active
                enabled: win.running && machine.hasButton
                text: qsTr("Squeeze")
                icon.name: "input-touchpad"
                display: AbstractButton.TextBesideIcon
                focusPolicy: Qt.NoFocus
                ToolTip.text: qsTr("The top button, held while pressed (F12 on the keyboard)")
                ToolTip.visible: hovered
                ToolTip.delay: 600
                onPressed: machine.pressButton(true)
                onReleased: machine.pressButton(false)
                onCanceled: machine.pressButton(false)
            }
            ToolButton {
                visible: win.active
                enabled: win.running
                text: qsTr("Screenshot")
                icon.name: "camera-photo"
                display: AbstractButton.TextBesideIcon
                ToolTip.text: qsTr("Save the screen as PNG (Ctrl+Shift+S)")
                ToolTip.visible: hovered
                ToolTip.delay: 600
                onClicked: screenView.saveScreenshot()
            }
            Item { Layout.fillWidth: true }
            ToolButton {
                visible: win.active
                text: qsTr("Controls")
                icon.name: "sidebar-show-right"
                display: AbstractButton.TextBesideIcon
                checkable: win.wide
                checked: win.wide ? settings.inspector : drawer.visible
                ToolTip.text: qsTr("Show or hide the controls (Ctrl+Shift+B)")
                ToolTip.visible: hovered
                ToolTip.delay: 600
                onClicked: win.toggleInspector()
            }
            ToolButton {
                id: menuButton
                // A glyph rather than an icon: icon themes disagree on the
                // menu icon's name (Breeze's application-menu, Adwaita's
                // open-menu-symbolic).
                text: "☰"
                font.pointSize: fm.font.pointSize * 1.25
                Accessible.name: qsTr("Menu")
                ToolTip.text: qsTr("Menu")
                ToolTip.visible: hovered
                ToolTip.delay: 600
                onClicked: appMenu.open()
                Menu {
                    id: appMenu
                    y: menuButton.height
                    MenuItem {
                        text: qsTr("Reset")
                        enabled: win.running
                        onTriggered: machine.reset()
                    }
                    MenuItem {
                        text: qsTr("Save state")
                        enabled: win.running && machine.stateDir !== ""
                        onTriggered: machine.saveState()
                    }
                    MenuItem {
                        text: qsTr("Restore state")
                        enabled: win.running && machine.stateDir !== ""
                        onTriggered: machine.loadState()
                    }
                    MenuSeparator {}
                    MenuItem {
                        text: qsTr("Console in a terminal")
                        enabled: machine.consoleTty !== ""
                        onTriggered: machine.openConsole()
                    }
                    MenuSeparator {}
                    MenuItem {
                        text: qsTr("Sharp pixels")
                        checkable: true
                        checked: settings.sharp
                        onToggled: settings.sharp = checked
                    }
                    MenuItem {
                        text: qsTr("Full screen")
                        checkable: true
                        checked: win.visibility === Window.FullScreen
                        onTriggered: win.visibility = checked ? Window.FullScreen : Window.Windowed
                    }
                    MenuSeparator {}
                    MenuItem {
                        text: qsTr("Power off")
                        enabled: win.active
                        onTriggered: machine.powerOff()
                    }
                    MenuItem {
                        text: qsTr("About")
                        onTriggered: about.open()
                    }
                    MenuItem {
                        text: qsTr("Quit")
                        onTriggered: win.close()
                    }
                }
            }
        }
    }

    RowLayout {
        anchors.fill: parent
        spacing: 0
        visible: win.active

        ScreenView {
            id: screenView
            machine: machine
            sharp: settings.sharp
            Layout.fillWidth: true
            Layout.fillHeight: true
        }
        Rectangle {
            visible: dock.visible
            Layout.fillHeight: true
            implicitWidth: 1
            color: palette.mid
            opacity: 0.5
        }
        Item {
            id: dock
            visible: win.wide && settings.inspector
            Layout.fillHeight: true
            Layout.preferredWidth: win.inspectorWidth
        }
    }

    Drawer {
        id: drawer
        edge: Qt.RightEdge
        width: Math.min(win.inspectorWidth, win.width * 0.8)
        height: win.height
        interactive: !win.wide && win.active
        onAboutToHide: screenView.forceActiveFocus()
    }

    Inspector {
        machine: machine
        parent: win.wide ? dock : drawer.contentItem
        anchors.fill: parent
        visible: win.active
    }

    StartPage {
        anchors.fill: parent
        visible: !win.active
        machine: machine
        recents: win.recents
        onForget: index => win.forget(index)
    }

    footer: Pane {
        id: footerBar
        padding: win.unit / 3
        leftPadding: win.unit / 2
        rightPadding: win.unit / 2
        visible: win.active || notice.text !== ""

        function show(text) {
            notice.text = text
            noticeTimer.restart()
        }
        Timer {
            id: noticeTimer
            interval: 6000
            onTriggered: notice.text = ""
        }
        RowLayout {
            anchors.fill: parent
            spacing: win.unit
            Rectangle {
                visible: win.active
                implicitWidth: win.unit * 0.6
                implicitHeight: implicitWidth
                radius: width / 2
                color: machine.phase === "starting" ? palette.mid
                     : machine.paused ? "#e0a020" : "#3daa5c"
            }
            Label {
                text: machine.phase === "starting" ? qsTr("Starting…")
                    : machine.paused ? qsTr("Paused") : qsTr("Running")
                font.bold: true
                visible: win.active
            }
            Label {
                id: notice
                Layout.fillWidth: true
                elide: Text.ElideRight
                text: ""
            }
            Label {
                visible: win.active && notice.text === ""
                Layout.fillWidth: true
                elide: Text.ElideRight
                opacity: 0.7
                text: screenView.activeFocus
                      ? qsTr("Keys go to the Chumby (Ctrl+Shift shortcuts stay here)")
                      : qsTr("Click the screen to type on the Chumby")
            }
            Label {
                visible: win.active
                opacity: 0.7
                text: qsTr("No network")
            }
        }
    }

    Dialog {
        id: about
        title: qsTr("About")
        anchors.centerIn: parent
        modal: true
        standardButtons: Dialog.Close
        width: Math.min(win.width - 2 * win.unit, 26 * win.unit)
        ColumnLayout {
            anchors.fill: parent
            spacing: win.unit / 2
            Image {
                Layout.alignment: Qt.AlignHCenter
                source: "qrc:/qt/qml/ChumbyDesktop/data/chumby-desktop.svg"
                sourceSize: Qt.size(4 * win.unit, 4 * win.unit)
            }
            Label {
                Layout.fillWidth: true
                horizontalAlignment: Text.AlignHCenter
                font.bold: true
                font.pointSize: fm.font.pointSize * 1.3
                text: qsTr("Chumby Classic emulator")
            }
            Label {
                Layout.fillWidth: true
                wrapMode: Text.Wrap
                horizontalAlignment: Text.AlignHCenter
                text: qsTr("QEMU's chumby-classic machine on your desktop. Free software under the GNU GPL, version 2 or later.\n\nAn independent project, not affiliated with or endorsed by Chumby Industries or anyone holding rights in Chumby; \"Chumby\" is a trademark of its owner, used only to say what hardware this models.")
            }
        }
    }
}
