// SPDX-License-Identifier: GPL-2.0-or-later
//
// The inspector beside the screen: what the Chumby's case has besides its
// screen (the top button, the accelerometer, the headphone jack) and what
// the board drives (backlight, LCD, speaker).

import ChumbyKit
import SwiftUI

struct InspectorView: View {
    @ObservedObject var session: Session

    var body: some View {
        Form {
            Section("Top Button") {
                HoldButton(down: session.buttonDown) { session.setButton($0) }
                    .disabled(!session.has("button"))
                Text("Hold to squeeze it, or press F12 on the screen.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Motion") {
                Group {
                    LabeledContent("Forward/Back") {
                        Slider(value: tiltBinding(\.pitch), in: -90...90)
                    }
                    LabeledContent("Left/Right") {
                        Slider(value: tiltBinding(\.roll), in: -180...180)
                    }
                }
                .disabled(session.following)
                HStack {
                    Menu {
                        ForEach(Tilt.poses, id: \.0) { name, t in
                            Button(name) { session.setTilt(t) }
                        }
                    } label: {
                        Label("Pose", systemImage: "rotate.3d")
                    }
                    .disabled(session.following)
                    .fixedSize()
                    Spacer()
                    Button { session.shake() } label: {
                        Label("Shake", systemImage: "iphone.gen1.radiowaves.left.and.right")
                    }
                }
                if session.motionAvailable {
                    Toggle("Follow This Mac's Motion", isOn: Binding(
                        get: { session.following }, set: { session.setFollow($0) }))
                        .help("Tilt or shake the Mac's base and the Chumby feels it; the Mac lying flat is the Chumby standing upright")
                }
                LabeledContent("Acceleration") {
                    Text(String(format: "%+d  %+d  %+d mg", session.accel[0], session.accel[1], session.accel[2]))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .disabled(!session.has("accel-x", "accel-y", "accel-z"))

            Section("Jacks") {
                Toggle(isOn: Binding(get: { session.headphones }, set: { session.setHeadphones($0) })) {
                    Label("Headphones", systemImage: "headphones")
                }
                .disabled(!session.has("headphones"))
            }

            Section("Outputs") {
                LabeledContent {
                    if let b = session.backlight {
                        Gauge(value: b) { EmptyView() } currentValueLabel: {
                            Text(b, format: .percent.precision(.fractionLength(0)))
                        }
                        .gaugeStyle(.accessoryLinearCapacity)
                        .frame(maxWidth: 120)
                    } else {
                        Text("—").foregroundStyle(.secondary)
                    }
                } label: {
                    Label("Backlight", systemImage: "sun.max")
                }
                LabeledContent {
                    Text(onOff(session.lcdOn, on: "On", off: "Off"))
                } label: {
                    Label("LCD", systemImage: session.lcdOn == false ? "display.trianglebadge.exclamationmark" : "display")
                }
                LabeledContent {
                    Text(onOff(session.speakerMuted, on: "Muted", off: "On"))
                } label: {
                    Label("Speaker", systemImage: session.speakerMuted == true ? "speaker.slash" : "speaker.wave.2")
                }
            }

            Section("Machine") {
                LabeledContent("Sound", value: session.audio == "coreaudio" ? "Core Audio" : session.audio)
                LabeledContent("Network", value: "None")
                LabeledContent("Keyboard", value: keyboard)
                if let tty = session.ttyPath {
                    LabeledContent("Serial Port") {
                        Text(tty).textSelection(.enabled).font(.callout.monospaced())
                    }
                    .help("The console, for any terminal program: tio \(tty), screen \(tty)")
                }
            }
        }
        .formStyle(.grouped)
        .controlSize(.small)
    }

    private var keyboard: String {
        session.machineHasKeyboard ? "USB, on first key" : "Only if given (-device usb-kbd)"
    }

    private func onOff(_ v: Bool?, on: String, off: String) -> String {
        guard let v else { return "—" }
        return v ? on : off
    }

    private func tiltBinding(_ kp: WritableKeyPath<Tilt, Double>) -> Binding<Double> {
        Binding(get: { session.tilt[keyPath: kp] }, set: { v in
            var t = session.tilt
            t[keyPath: kp] = v.rounded()
            if t != session.tilt { session.setTilt(t) }
        })
    }
}

/// Whether the mouse is down on a HoldButton (no @State: SwiftPM without
/// Xcode has no SwiftUI macros).
final class PressTracker {
    var pressing = false
}

/// A button held while the mouse is down on it.
struct HoldButton: View {
    var down: Bool
    var changed: (Bool) -> Void
    private let tracker = PressTracker()
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Label(down ? "Squeezed" : "Squeeze", systemImage: "button.programmable")
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 7)
                .fill(down ? Color.accentColor : Color(nsColor: .controlColor)))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(.separator))
            .foregroundStyle(down ? Color.white : Color.primary)
            .opacity(enabled ? 1 : 0.5)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    if !tracker.pressing { tracker.pressing = true; changed(true) }
                }
                .onEnded { _ in
                    tracker.pressing = false
                    changed(false)
                })
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel("Top button")
            .accessibilityAction { changed(true); DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { changed(false) } }
    }
}
