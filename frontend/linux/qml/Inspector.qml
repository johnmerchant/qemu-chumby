// SPDX-License-Identifier: GPL-2.0-or-later
// The controls for what the screen can't do: the top button, tilt and
// shake, the headphones, the board's outputs, the console and the
// machine's state. Controls the running QEMU lacks are disabled.
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import ChumbyDesktop

ScrollView {
    id: inspector
    required property Machine machine
    readonly property bool running: machine.phase === "running"

    contentWidth: availableWidth
    clip: true
    focusPolicy: Qt.NoFocus

    background: Rectangle { color: palette.window }

    ColumnLayout {
        width: inspector.availableWidth
        spacing: 12

        Item { implicitHeight: 2 }

        Section {
            title: qsTr("Top button")
            Layout.leftMargin: 12
            Layout.rightMargin: 12
            Button {
                Layout.fillWidth: true
                text: inspector.machine.buttonDown ? qsTr("Squeezed") : qsTr("Squeeze")
                enabled: inspector.running && inspector.machine.hasButton
                focusPolicy: Qt.NoFocus
                onPressed: inspector.machine.pressButton(true)
                onReleased: inspector.machine.pressButton(false)
                onCanceled: inspector.machine.pressButton(false)
            }
            Label {
                Layout.fillWidth: true
                wrapMode: Text.Wrap
                opacity: 0.7
                font.pointSize: Qt.application.font.pointSize * 0.9
                text: qsTr("Held while pressed; F12 on the keyboard does the same.")
            }
        }

        Section {
            title: qsTr("Motion")
            Layout.leftMargin: 12
            Layout.rightMargin: 12
            enabled: inspector.running && inspector.machine.hasAccel

            Label { text: qsTr("Tilt forward or back: %1°").arg(Math.round(pitch.value)) }
            Slider {
                id: pitch
                Layout.fillWidth: true
                from: -90
                to: 90
                stepSize: 1
                value: inspector.machine.pitch
                focusPolicy: Qt.NoFocus
                onMoved: inspector.machine.tilt(value, roll.value)
            }
            Label { text: qsTr("Tilt left or right: %1°").arg(Math.round(roll.value)) }
            Slider {
                id: roll
                Layout.fillWidth: true
                from: -180
                to: 180
                stepSize: 1
                value: inspector.machine.roll
                focusPolicy: Qt.NoFocus
                onMoved: inspector.machine.tilt(pitch.value, value)
            }
            Flow {
                Layout.fillWidth: true
                spacing: 6
                Repeater {
                    model: [
                        { name: qsTr("Upright"), p: 0, r: 0 },
                        { name: qsTr("Face up"), p: -90, r: 0 },
                        { name: qsTr("On its side"), p: 0, r: 90 },
                        { name: qsTr("Upside down"), p: 0, r: 180 }
                    ]
                    Button {
                        required property var modelData
                        text: modelData.name
                        focusPolicy: Qt.NoFocus
                        onClicked: inspector.machine.tilt(modelData.p, modelData.r)
                    }
                }
                Button {
                    text: qsTr("Shake")
                    icon.name: "transform-move"
                    focusPolicy: Qt.NoFocus
                    onClicked: inspector.machine.shake()
                }
            }
            Label {
                font.family: "monospace"
                opacity: 0.7
                text: inspector.machine.hasAccel
                      ? "x %1  y %2  z %3 mg".arg(inspector.machine.accelX)
                            .arg(inspector.machine.accelY).arg(inspector.machine.accelZ)
                      : qsTr("No accelerometer in this machine")
            }
        }

        Section {
            title: qsTr("Jacks and outputs")
            Layout.leftMargin: 12
            Layout.rightMargin: 12

            Switch {
                text: qsTr("Headphones plugged in")
                enabled: inspector.running && inspector.machine.hasHeadphones
                checked: inspector.machine.headphones
                focusPolicy: Qt.NoFocus
                onToggled: inspector.machine.plugHeadphones(checked)
            }
            GridLayout {
                columns: 2
                columnSpacing: 12
                rowSpacing: 6
                Layout.fillWidth: true

                Label { text: qsTr("Backlight"); opacity: 0.7 }
                RowLayout {
                    Layout.fillWidth: true
                    ProgressBar {
                        Layout.fillWidth: true
                        from: 0
                        to: 100
                        value: inspector.machine.backlight
                    }
                    Label { text: inspector.machine.backlight + "%" }
                }
                Label { text: qsTr("Screen"); opacity: 0.7 }
                Label { text: inspector.machine.lcdOn ? qsTr("On") : qsTr("Off") }
                Label { text: qsTr("Speaker"); opacity: 0.7 }
                Label { text: inspector.machine.speakerMute ? qsTr("Muted") : qsTr("On") }
                Label { text: qsTr("Sound"); opacity: 0.7 }
                Label { text: inspector.machine.audio || "—" }
            }
        }

        Section {
            title: qsTr("Console")
            Layout.leftMargin: 12
            Layout.rightMargin: 12

            Button {
                Layout.fillWidth: true
                text: qsTr("Open in a terminal")
                icon.name: "utilities-terminal"
                enabled: inspector.machine.consoleTty !== ""
                focusPolicy: Qt.NoFocus
                onClicked: inspector.machine.openConsole()
            }
            TextEdit {
                Layout.fillWidth: true
                readOnly: true
                selectByMouse: true
                wrapMode: Text.Wrap
                color: palette.windowText
                opacity: 0.7
                font.pointSize: Qt.application.font.pointSize * 0.9
                text: inspector.machine.consoleTty !== ""
                      ? qsTr("Also a serial port for any terminal program: tio %1").arg(inspector.machine.consoleTty)
                      : qsTr("No console")
            }
        }

        Section {
            title: qsTr("Saved state")
            Layout.leftMargin: 12
            Layout.rightMargin: 12

            RowLayout {
                Layout.fillWidth: true
                enabled: inspector.running && inspector.machine.stateDir !== ""
                Button {
                    Layout.fillWidth: true
                    text: qsTr("Save")
                    icon.name: "document-save"
                    focusPolicy: Qt.NoFocus
                    onClicked: inspector.machine.saveState()
                }
                Button {
                    Layout.fillWidth: true
                    text: qsTr("Restore")
                    icon.name: "document-revert"
                    focusPolicy: Qt.NoFocus
                    onClicked: inspector.machine.loadState()
                }
            }
            Label {
                Layout.fillWidth: true
                wrapMode: Text.Wrap
                opacity: 0.7
                font.pointSize: Qt.application.font.pointSize * 0.9
                text: inspector.machine.stateDir !== ""
                      ? qsTr("In %1; the next start resumes from it.").arg(inspector.machine.stateDir)
                      : qsTr("Start with a state folder (and a NAND image) to save the running Chumby.")
            }
        }

        Item { Layout.fillHeight: true }
    }
}
