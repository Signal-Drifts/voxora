import AppKit
import SwiftUI

@main
struct VoxoraApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = RecorderModel()

    var body: some Scene {
        WindowGroup("Voxora", id: "main") {
            RecorderWindow(model: model)
                .onAppear { appDelegate.model = model }
        }
        .defaultSize(width: 620, height: 202)
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .newItem) { }
        }

        MenuBarExtra {
            RecorderMenu(model: model)
        } label: {
            Label(
                model.menuTitle,
                systemImage: model.isRecording ? "record.circle.fill" : "waveform"
            )
        }
        .menuBarExtraStyle(.menu)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: RecorderModel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model, model.shouldBlockTermination else {
            return .terminateNow
        }
        model.quit()
        return .terminateCancel
    }
}

private struct RecorderWindow: View {
    @ObservedObject var model: RecorderModel

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                HStack {
                    Toggle("I have permission to record", isOn: $model.hasConsent)
                        .toggleStyle(.checkbox)

                    Spacer()

                    Toggle("Reduce Noise", isOn: $model.speechCleanup)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .help("Reduce quiet background noise and rumble")
                }

                VStack(spacing: 1) {
                    Text("Voxora")
                        .font(.system(size: 15, weight: .semibold))
                    Text("Record Meetings and Browser Audio")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
            }
            .font(.callout)
            .disabled(model.hasActiveRecording || model.hasPendingRecording || model.isBusy)
            .padding(.horizontal, 22)
            .frame(height: 60)
            .background(Color.black)

            Divider()

            HStack(spacing: 22) {
                Text(model.formattedElapsed)
                    .font(.system(size: 31, weight: .light, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .frame(width: 146, alignment: .leading)
                    .accessibilityLabel("Elapsed time \(model.formattedElapsed)")

                Waveform(level: model.audioLevel, active: model.isRecording)
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .accessibilityHidden(true)

                recordControl
                    .frame(width: 205, alignment: .trailing)
            }
            .padding(.horizontal, 22)
            .frame(height: 90)

            Text("* Without Noise Filter: M4A  •  With Noise Filter: WAV")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
                .frame(height: 21)
        }
        .frame(width: 620, height: 172)
        .background(Color.black)
        .preferredColorScheme(.dark)
        .onAppear {
            model.requestCapturePermissionIfNeeded()
        }
        .alert("Voxora", isPresented: errorIsPresented) {
            if model.requiresCapturePermission {
                Button("Open System Settings") {
                    model.openCapturePrivacySettings()
                }
            }
            Button("OK", role: .cancel) {
                model.clearError()
            }
        } message: {
            Text(model.errorMessage ?? "An unknown error occurred.")
        }
    }

    private var errorIsPresented: Binding<Bool> {
        Binding(
            get: { model.errorMessage != nil },
            set: { presented in
                if !presented { model.clearError() }
            }
        )
    }

    @ViewBuilder
    private var recordControl: some View {
        if model.hasPendingRecording {
            HStack(spacing: 16) {
                Button("Discard") { model.discardPendingRecording() }
                    .buttonStyle(.plain)
                Button("Save") { model.savePendingRecording() }
                    .buttonStyle(.borderedProminent)
                    .tint(.white)
                    .foregroundStyle(.black)
            }
        } else if model.isRecording {
            HStack(spacing: 16) {
                Button {
                    model.pauseRecording()
                } label: {
                    Label("Pause", systemImage: "pause.fill")
                }
                .buttonStyle(.plain)
                Button("Finish & Save") { model.finishAndSave() }
                    .buttonStyle(.borderedProminent)
                    .tint(.white)
                    .foregroundStyle(.black)
            }
            .accessibilityLabel("Pause recording")
        } else if model.isPaused {
            HStack(spacing: 16) {
                Button {
                    model.resumeRecording()
                } label: {
                    Label("Resume", systemImage: "play.fill")
                }
                .buttonStyle(.plain)
                Button("Finish & Save") { model.finishAndSave() }
                    .buttonStyle(.borderedProminent)
                    .tint(.white)
                    .foregroundStyle(.black)
            }
            .accessibilityLabel("Resume recording")
        } else if model.isBusy {
            HStack(spacing: 9) {
                ProgressView().controlSize(.small)
                Text(model.state == .processing ? "Saving" : "Starting")
                    .font(.callout)
            }
            .foregroundStyle(.secondary)
        } else {
            Button {
                model.startRecording()
            } label: {
                HStack(spacing: 10) {
                    ZStack {
                        Circle()
                            .stroke(Color.white.opacity(model.hasConsent ? 0.9 : 0.35), lineWidth: 1.5)
                            .frame(width: 42, height: 42)
                        Circle()
                            .fill(Color.white.opacity(model.hasConsent ? 1 : 0.40))
                            .frame(width: 29, height: 29)
                    }
                    Text("Start")
                }
            }
            .buttonStyle(.plain)
            .disabled(!model.hasConsent)
            .keyboardShortcut("r", modifiers: [.command, .shift])
            .accessibilityLabel("Start recording")
        }
    }
}

private struct Waveform: View {
    let level: Float
    let active: Bool

    var body: some View {
        GeometryReader { geometry in
            HStack(alignment: .center, spacing: 2) {
                ForEach(0..<45, id: \.self) { index in
                    let centerDistance = abs(Double(index - 22)) / 22
                    let envelope = max(0.22, 1 - centerDistance * 0.62)
                    let pattern = 0.42 + 0.58 * abs(sin(Double(index) * 1.71))
                    let activity = active ? max(0.16, Double(level)) : 0.08
                    let barHeight = max(2, geometry.size.height * envelope * pattern * activity)

                    Capsule()
                        .fill(active ? Color.white.opacity(0.82) : Color.white.opacity(0.25))
                        .frame(maxWidth: .infinity)
                        .frame(height: barHeight)
                }
            }
            .frame(maxHeight: .infinity)
            .animation(.easeOut(duration: 0.10), value: level)
        }
    }
}

private struct RecorderMenu: View {
    @Environment(\.openWindow) private var openWindow
    @ObservedObject var model: RecorderModel

    var body: some View {
        Button("Open Voxora") {
            openWindow(id: "main")
            NSApplication.shared.activate(ignoringOtherApps: true)
        }

        Divider()

        Text(model.statusText)

        if model.hasActiveRecording {
            Button(model.isPaused ? "Resume Recording" : "Pause Recording") {
                if model.isPaused {
                    model.resumeRecording()
                } else {
                    model.pauseRecording()
                }
            }
            Button("Finish & Save") {
                model.finishAndSave()
            }
        } else if model.hasPendingRecording {
            Button("Save Recording") {
                model.savePendingRecording()
            }
            Button("Discard Recording") {
                model.discardPendingRecording()
            }
        }

        if let recording = model.lastRecordingURL {
            Button("Show Last Recording") {
                model.reveal(recording)
            }
        }

        Divider()

        Button("Quit Voxora") {
            model.quit()
        }
        .disabled(model.isBusy)
    }
}
