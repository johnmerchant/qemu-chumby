// SPDX-License-Identifier: GPL-2.0-or-later
// The few things the Rust side asks of Qt in C++: the application object
// (a QApplication, which KDE's Qt Quick style needs) and, for tests,
// synthetic input and window grabs.
#pragma once

#include <cstdint>
#include "rust/cxx.h"

namespace chumby {

// Runs the app: QApplication, the QML engine with Main.qml, the event
// loop. Returns the exit code.
int run_app(rust::Str app_id, rust::Str version);

// Test hooks: a key or mouse event to the app's window (kind 0 press,
// 1 move, 2 release), and the window's image to a file.
void send_key(int key, int modifiers, std::uint32_t scan_code, rust::Str text, bool press);
void send_mouse(double x, double y, int kind);
bool grab_window(rust::Str path);
rust::String window_title();
void quit_app();

} // namespace chumby
