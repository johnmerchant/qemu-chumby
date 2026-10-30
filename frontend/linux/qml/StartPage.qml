// SPDX-License-Identifier: GPL-2.0-or-later
// No Chumby running: open one (an images folder, or a kernel and a NAND
// image), or one opened before.
import QtQuick
import QtQuick.Controls
import QtQuick.Dialogs
import QtQuick.Layouts
import ChumbyDesktop

Pane {
    id: page
    required property Machine machine
    property var recents: []
    signal forget(int index)

    property string kernel: ""
    property string nand: ""
    property string stateDir: ""

    function local(url) { return decodeURIComponent(url.toString().replace(/^file:\/\//, "")) }
    function base(path) { return path.replace(/\/+$/, "").replace(/.*\//, "") }
    function start(kernel, nand, state, fast) {
        page.machine.start(kernel, nand, state, fast, writeBox.checked)
    }

    ScrollView {
        anchors.fill: parent
        contentWidth: availableWidth

        ColumnLayout {
            width: Math.min(parent.width, 34 * fm.height)
            x: (parent.width - width) / 2
            spacing: fm.height * 0.6

            FontMetrics { id: fm }

            Item { implicitHeight: fm.height }

            Image {
                Layout.alignment: Qt.AlignHCenter
                source: "qrc:/qt/qml/ChumbyDesktop/data/chumby-desktop.svg"
                sourceSize: Qt.size(5 * fm.height, 5 * fm.height)
            }
            Label {
                Layout.alignment: Qt.AlignHCenter
                text: qsTr("Chumby Classic")
                font.pointSize: fm.font.pointSize * 1.6
                font.bold: true
            }
            Label {
                Layout.fillWidth: true
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.Wrap
                opacity: 0.7
                text: qsTr("Open a folder with a zImage (and a nand.img), or a kernel on its own.")
            }

            // Why the last one stopped.
            Frame {
                Layout.fillWidth: true
                visible: page.machine.phase === "stopped" && page.machine.exitInfo !== ""
                background: Rectangle {
                    radius: 4
                    color: Qt.rgba(0.85, 0.2, 0.2, 0.12)
                    border.color: Qt.rgba(0.85, 0.2, 0.2, 0.6)
                }
                Label {
                    width: parent.width
                    wrapMode: Text.Wrap
                    text: page.machine.exitInfo
                }
            }

            RowLayout {
                Layout.alignment: Qt.AlignHCenter
                spacing: fm.height / 2
                Button {
                    text: qsTr("Open Folder…")
                    icon.name: "document-open-folder"
                    highlighted: true
                    onClicked: imagesDialog.open()
                }
                Button {
                    text: qsTr("Open Kernel…")
                    icon.name: "document-open"
                    onClicked: kernelDialog.open()
                }
            }

            GroupBox {
                Layout.fillWidth: true
                title: qsTr("Options")
                GridLayout {
                    anchors.fill: parent
                    columns: 3
                    columnSpacing: fm.height / 2

                    Label { text: qsTr("NAND image") }
                    Label {
                        Layout.fillWidth: true
                        elide: Text.ElideMiddle
                        opacity: page.nand ? 1 : 0.6
                        text: page.nand || qsTr("the folder's nand.img, if any")
                    }
                    RowLayout {
                        ToolButton {
                            icon.name: "document-open"
                            text: qsTr("Choose\u2026")
                            ToolTip.text: qsTr("Choose a NAND image")
                            ToolTip.visible: hovered
                            onClicked: nandDialog.open()
                        }
                        ToolButton {
                            icon.name: "edit-clear"
                            text: qsTr("Clear")
                            enabled: page.nand !== ""
                            onClicked: page.nand = ""
                        }
                    }

                    Label { text: qsTr("State folder") }
                    Label {
                        Layout.fillWidth: true
                        elide: Text.ElideMiddle
                        opacity: page.stateDir ? 1 : 0.6
                        text: page.stateDir || qsTr("none: nothing is kept")
                    }
                    RowLayout {
                        ToolButton {
                            icon.name: "folder"
                            text: qsTr("Choose\u2026")
                            ToolTip.text: qsTr("Keep the flash's writes and the saved state here")
                            ToolTip.visible: hovered
                            onClicked: stateDialog.open()
                        }
                        ToolButton {
                            icon.name: "edit-clear"
                            text: qsTr("Clear")
                            enabled: page.stateDir !== ""
                            onClicked: page.stateDir = ""
                        }
                    }

                    CheckBox {
                        id: fastBox
                        Layout.columnSpan: 3
                        text: qsTr("Fast boot (emulated time runs ahead; sound comes in bursts)")
                    }
                    CheckBox {
                        id: writeBox
                        Layout.columnSpan: 3
                        enabled: page.stateDir === ""
                        text: qsTr("Write to the NAND image itself")
                    }
                }
            }

            Label {
                visible: page.recents.length > 0
                text: qsTr("Recent")
                font.bold: true
            }
            Repeater {
                model: page.recents
                ItemDelegate {
                    id: recent
                    required property var modelData
                    required property int index
                    Layout.fillWidth: true
                    onClicked: page.start(modelData.kernel, modelData.nand || "", modelData.state || "",
                                          !!modelData.fast)
                    contentItem: RowLayout {
                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: 0
                            Label {
                                Layout.fillWidth: true
                                elide: Text.ElideMiddle
                                text: recent.modelData.state ? page.base(recent.modelData.state)
                                    : recent.modelData.nand ? page.base(recent.modelData.nand.replace(/\/[^/]*$/, ""))
                                    : page.base(recent.modelData.kernel)
                            }
                            Label {
                                Layout.fillWidth: true
                                elide: Text.ElideMiddle
                                opacity: 0.6
                                font.pointSize: fm.font.pointSize * 0.9
                                text: recent.modelData.kernel
                                      + (recent.modelData.nand ? " · " + page.base(recent.modelData.nand) : "")
                                      + (recent.modelData.state ? " · " + qsTr("saved state") : "")
                                      + (recent.modelData.fast ? " · " + qsTr("fast") : "")
                            }
                        }
                        ToolButton {
                            icon.name: "edit-delete-remove"
                            text: "✕"
                            display: AbstractButton.TextOnly
                            ToolTip.text: qsTr("Forget")
                            ToolTip.visible: hovered
                            onClicked: page.forget(recent.index)
                        }
                    }
                }
            }
            Item { implicitHeight: fm.height }
        }
    }

    FolderDialog {
        id: imagesDialog
        title: qsTr("Open a folder with zImage and nand.img")
        onAccepted: page.start(page.local(selectedFolder), page.nand, page.stateDir, fastBox.checked)
    }
    FileDialog {
        id: kernelDialog
        title: qsTr("Open a kernel (zImage)")
        onAccepted: page.start(page.local(selectedFile), page.nand, page.stateDir, fastBox.checked)
    }
    FileDialog {
        id: nandDialog
        title: qsTr("Choose a NAND image")
        nameFilters: [qsTr("NAND images (*.img *.bin *.qcow2)"), qsTr("All files (*)")]
        onAccepted: page.nand = page.local(selectedFile)
    }
    FolderDialog {
        id: stateDialog
        title: qsTr("Choose a folder for the saved state")
        onAccepted: page.stateDir = page.local(selectedFolder)
    }
}
