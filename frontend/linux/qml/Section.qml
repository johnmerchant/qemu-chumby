// SPDX-License-Identifier: GPL-2.0-or-later
// A group of controls under a heading, as in a settings page.
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

ColumnLayout {
    id: section
    property string title
    default property alias content: body.data

    Layout.fillWidth: true
    spacing: 6

    Label {
        text: section.title
        font.bold: true
        Layout.topMargin: 6
    }
    Rectangle {
        Layout.fillWidth: true
        implicitHeight: 1
        color: palette.mid
        opacity: 0.5
    }
    ColumnLayout {
        id: body
        Layout.fillWidth: true
        spacing: 6
    }
}
