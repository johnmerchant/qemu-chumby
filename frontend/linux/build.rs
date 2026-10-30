// SPDX-License-Identifier: GPL-2.0-or-later
use cxx_qt_build::{CxxQtBuilder, QmlModule};

fn main() {
    CxxQtBuilder::new_qml_module(
        QmlModule::new("ChumbyDesktop")
            .qml_files([
                "qml/Main.qml",
                "qml/Inspector.qml",
                "qml/ScreenView.qml",
                "qml/StartPage.qml",
                "qml/Section.qml",
            ])
            .depend("QtQuick"),
    )
    .qrc_resources(["data/chumby-desktop.svg"])
    .files(["src/machine.rs"])
    .include_dir("cpp")
    .cpp_files(["cpp/glue.cpp", "cpp/glue.h"])
    // QApplication (KDE's Qt Quick style needs it) and QQuickStyle.
    .qt_module("Widgets")
    .qt_module("Quick")
    .qt_module("QuickControls2")
    .qt_module("Network")
    .build();
}
