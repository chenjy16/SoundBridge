import SwiftUI

struct BasicEQView: View {
    @ObservedObject var eqController: EQController

    var body: some View {
        VStack(spacing: 6) {
            // EQ toggle (sub-task 3.2)
            HStack {
                Text("EQ")
                    .font(.system(size: 12, weight: .medium))
                Spacer()
                Toggle("", isOn: $eqController.isEnabled)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()
            }
            .padding(.horizontal, 16)
            .padding(.top, 6)

            // Sliders area with bypass visual feedback (sub-tasks 3.3, 3.5)
            VStack(spacing: 4) {
                EQSliderRow(
                    label: "Bass",
                    value: $eqController.bass,
                    onEditingChanged: { editing in
                        if !editing { eqController.flushToSharedMemory() }
                    }
                )
                EQSliderRow(
                    label: "Mids",
                    value: $eqController.mids,
                    onEditingChanged: { editing in
                        if !editing { eqController.flushToSharedMemory() }
                    }
                )
                EQSliderRow(
                    label: "Treble",
                    value: $eqController.treble,
                    onEditingChanged: { editing in
                        if !editing { eqController.flushToSharedMemory() }
                    }
                )
            }
            .padding(.horizontal, 16)
            .opacity(eqController.isEnabled ? 1.0 : 0.4)
            .disabled(!eqController.isEnabled)

            // Reset button (sub-task 3.4)
            HStack {
                Spacer()
                Button(action: { eqController.reset() }) {
                    Text("Reset")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .disabled(!eqController.isEnabled)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 6)
        }
    }
}

// MARK: - EQ Slider Row

private struct EQSliderRow: View {
    let label: String
    @Binding var value: Float
    let onEditingChanged: (Bool) -> Void

    var body: some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .frame(width: 40, alignment: .leading)

            Slider(
                value: Binding(
                    get: { Double(value) },
                    set: { value = Float($0) }
                ),
                in: -12.0...12.0,
                onEditingChanged: onEditingChanged
            )

            Text(String(format: "%.1f dB", value))
                .font(.system(size: 11).monospacedDigit())
                .foregroundColor(.secondary)
                .frame(width: 52, alignment: .trailing)
        }
    }
}
