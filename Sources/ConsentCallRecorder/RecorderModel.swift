import AppKit
import CoreGraphics
import Foundation
import ScreenCaptureKit
import UniformTypeIdentifiers

@MainActor
final class RecorderModel: ObservableObject {
    enum State: Equatable {
        case idle
        case preparing
        case recording
        case paused
        case readyToSave
        case processing
    }

    @Published var hasConsent = false
    @Published var speechCleanup = false
    @Published private(set) var state: State = .idle
    @Published private(set) var elapsedSeconds = 0
    @Published private(set) var audioLevel: Float = 0
    @Published private(set) var errorMessage: String?
    @Published private(set) var requiresCapturePermission = false
    @Published private(set) var lastRecordingURL: URL?

    private let recorder = SystemAudioRecorder()
    private var timer: Timer?
    private var rawRecordingURL: URL?
    private var finalRecordingURL: URL?
    private var pendingQuit = false

    var isRecording: Bool { state == .recording }
    var isPaused: Bool { state == .paused }
    var hasActiveRecording: Bool { isRecording || isPaused }
    var hasPendingRecording: Bool { state == .readyToSave }
    var isBusy: Bool { state == .preparing || state == .processing }
    var shouldBlockTermination: Bool { state != .idle }

    var menuTitle: String {
        hasActiveRecording ? "REC \(formattedElapsed)" : "Recorder"
    }

    var statusText: String {
        switch state {
        case .idle:
            return lastRecordingURL == nil ? "Ready" : "Recording saved"
        case .preparing:
            return "Requesting access…"
        case .recording:
            return "Recording \(formattedElapsed)"
        case .paused:
            return "Paused \(formattedElapsed)"
        case .readyToSave:
            return "Recording not saved"
        case .processing:
            return "Finishing speech cleanup…"
        }
    }

    var formattedElapsed: String {
        let hours = elapsedSeconds / 3_600
        let minutes = (elapsedSeconds % 3_600) / 60
        let seconds = elapsedSeconds % 60
        return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
    }

    init() {
        recorder.onUnexpectedStop = { [weak self] error in
            Task { @MainActor in
                self?.handleUnexpectedStop(error)
            }
        }
        recorder.onLevel = { [weak self] level in
            Task { @MainActor in
                guard let self, self.state == .recording else { return }
                self.audioLevel = max(level, self.audioLevel * 0.72)
            }
        }
    }

    func requestCapturePermissionIfNeeded() {
        guard !CGPreflightScreenCaptureAccess() else { return }
        _ = CGRequestScreenCaptureAccess()
    }

    func startRecording() {
        guard state == .idle, hasConsent else { return }

        errorMessage = nil
        requiresCapturePermission = false

        rawRecordingURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("Voxora-\(UUID().uuidString)")
            .appendingPathExtension("m4a")

        guard let rawRecordingURL else { return }
        state = .preparing

        Task {
            do {
                try await recorder.start(writingTo: rawRecordingURL)
                elapsedSeconds = 0
                audioLevel = 0
                startTimer()
                state = .recording
                if pendingQuit {
                    finishAndSave()
                }
            } catch {
                state = .idle
                errorMessage = friendlyMessage(for: error)
                try? FileManager.default.removeItem(at: rawRecordingURL)
                self.rawRecordingURL = nil
                if pendingQuit {
                    pendingQuit = false
                    NSApplication.shared.terminate(nil)
                }
            }
        }
    }

    func pauseRecording() {
        guard state == .recording else { return }
        stopTimer()
        Task {
            do {
                try await recorder.pause()
                state = .paused
                audioLevel = 0
            } catch {
                errorMessage = "Could not pause recording: \(error.localizedDescription)"
                startTimer()
            }
        }
    }

    func resumeRecording() {
        guard state == .paused else { return }
        Task {
            do {
                try await recorder.resume()
                state = .recording
                startTimer()
            } catch {
                errorMessage = "Could not resume recording: \(error.localizedDescription)"
            }
        }
    }

    func finishAndSave() {
        guard hasActiveRecording else { return }
        stopTimer()
        state = .processing

        let rawURL = rawRecordingURL

        Task {
            do {
                try await recorder.stop()
                guard rawURL != nil else {
                    throw RecorderError.missingDestination
                }
                state = .readyToSave
                audioLevel = 0
                savePendingRecording()
            } catch {
                errorMessage = recoveryMessage(for: error, rawURL: rawURL, finalURL: finalRecordingURL)
                resetAfterRecording()
            }
        }
    }

    func savePendingRecording(quitAfterSave: Bool = false) {
        guard state == .readyToSave, let rawURL = rawRecordingURL else { return }
        guard let finalURL = chooseSaveDestination() else {
            pendingQuit = false
            return
        }

        finalRecordingURL = finalURL
        state = .processing
        let shouldClean = speechCleanup

        Task {
            do {
                if shouldClean {
                    try await Task.detached(priority: .userInitiated) {
                        try SpeechEnhancer.enhance(input: rawURL, output: finalURL)
                    }.value
                    try? FileManager.default.removeItem(at: rawURL)
                } else {
                    if FileManager.default.fileExists(atPath: finalURL.path) {
                        try FileManager.default.removeItem(at: finalURL)
                    }
                    try FileManager.default.moveItem(at: rawURL, to: finalURL)
                }
                lastRecordingURL = finalURL
                errorMessage = nil
                requiresCapturePermission = false
                resetAfterRecording()
                if quitAfterSave || pendingQuit {
                    pendingQuit = false
                    NSApplication.shared.terminate(nil)
                }
            } catch {
                if shouldClean {
                    errorMessage = recoveryMessage(for: error, rawURL: rawURL, finalURL: finalURL)
                    resetAfterRecording()
                } else if FileManager.default.fileExists(atPath: rawURL.path) {
                    finalRecordingURL = nil
                    state = .readyToSave
                    errorMessage = "The recording could not be saved: \(error.localizedDescription). It is still available in Voxora."
                } else {
                    errorMessage = "The recording could not be saved: \(error.localizedDescription)"
                    resetAfterRecording()
                }
                pendingQuit = false
            }
        }
    }

    func discardPendingRecording(quitAfterDiscard: Bool = false, requiresConfirmation: Bool = true) {
        guard state == .readyToSave, let rawURL = rawRecordingURL else { return }

        if requiresConfirmation {
            let alert = NSAlert()
            alert.messageText = "Discard this recording?"
            alert.informativeText = "This recording cannot be recovered after it is discarded."
            alert.addButton(withTitle: "Discard")
            alert.addButton(withTitle: "Cancel")
            alert.alertStyle = .warning
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }

        try? FileManager.default.removeItem(at: rawURL)
        resetAfterRecording()
        if quitAfterDiscard {
            NSApplication.shared.terminate(nil)
        }
    }

    private func chooseSaveDestination() -> URL? {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.title = "Save Recording"
        panel.message = ""
        panel.prompt = "Save"
        panel.showsTagField = false

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let stem = "Voxora \(formatter.string(from: Date()))"
        panel.allowedContentTypes = speechCleanup ? [.wav] : [.mpeg4Audio]
        panel.nameFieldStringValue = speechCleanup ? "\(stem).wav" : "\(stem).m4a"
        return panel.runModal() == .OK ? panel.url : nil
    }

    private func resetAfterRecording() {
        hasConsent = false
        audioLevel = 0
        rawRecordingURL = nil
        finalRecordingURL = nil
        elapsedSeconds = 0
        state = .idle
    }

    func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func clearError() {
        errorMessage = nil
        requiresCapturePermission = false
    }

    func openCapturePrivacySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    func quit() {
        if hasPendingRecording {
            let alert = NSAlert()
            alert.messageText = "Save recording before quitting?"
            alert.informativeText = "Your recording has not been saved."
            alert.addButton(withTitle: "Save")
            alert.addButton(withTitle: "Discard")
            alert.addButton(withTitle: "Cancel")
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                savePendingRecording(quitAfterSave: true)
            case .alertSecondButtonReturn:
                discardPendingRecording(quitAfterDiscard: true, requiresConfirmation: false)
            default:
                break
            }
            return
        }
        if hasActiveRecording {
            let alert = NSAlert()
            alert.messageText = "Save recording before quitting?"
            alert.informativeText = "The current recording has not been saved."
            alert.addButton(withTitle: "Save")
            alert.addButton(withTitle: "Discard")
            alert.addButton(withTitle: "Cancel")
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                pendingQuit = true
                finishAndSave()
            case .alertSecondButtonReturn:
                discardActiveRecordingAndQuit()
            default:
                break
            }
            return
        }
        if isBusy {
            pendingQuit = true
            return
        }
        NSApplication.shared.terminate(nil)
    }

    private func discardActiveRecordingAndQuit() {
        guard hasActiveRecording else { return }
        stopTimer()
        state = .processing
        let rawURL = rawRecordingURL

        Task {
            try? await recorder.stop()
            if let rawURL { try? FileManager.default.removeItem(at: rawURL) }
            resetAfterRecording()
            NSApplication.shared.terminate(nil)
        }
    }

    private func startTimer() {
        stopTimer()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.elapsedSeconds += 1
            }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func handleUnexpectedStop(_ error: Error) {
        guard state == .recording || state == .paused || state == .preparing else { return }
        stopTimer()
        let rawURL = rawRecordingURL
        state = .processing

        Task {
            do {
                try await recorder.stop()
                guard let rawURL, FileManager.default.fileExists(atPath: rawURL.path) else {
                    throw error
                }
                state = .readyToSave
                audioLevel = 0
                errorMessage = "Recording stopped unexpectedly: \(error.localizedDescription). The captured audio is still available to save."
                if pendingQuit {
                    savePendingRecording(quitAfterSave: true)
                }
            } catch {
                if let rawURL { try? FileManager.default.removeItem(at: rawURL) }
                resetAfterRecording()
                errorMessage = "Recording stopped unexpectedly and could not be recovered: \(error.localizedDescription)"
                if pendingQuit {
                    pendingQuit = false
                    NSApplication.shared.terminate(nil)
                }
            }
        }
    }

    private func friendlyMessage(for error: Error) -> String {
        let nsError = error as NSError
        if case RecorderError.capturePermissionDenied = error {
            requiresCapturePermission = true
            return error.localizedDescription
        }
        if nsError.domain == SCStreamErrorDomain, nsError.code == -3801 {
            requiresCapturePermission = true
            return "Screen & System Audio Recording access was declined. Enable Voxora in System Settings, then quit and reopen Voxora."
        }
        if nsError.domain == SCStreamErrorDomain {
            requiresCapturePermission = false
            return "ScreenCaptureKit error \(nsError.code): \(nsError.localizedDescription)"
        }
        requiresCapturePermission = false
        return "Could not start recording: \(error.localizedDescription)"
    }

    private func recoveryMessage(for error: Error, rawURL: URL?, finalURL: URL?) -> String {
        guard speechCleanup, let rawURL, FileManager.default.fileExists(atPath: rawURL.path) else {
            return "Could not finish the recording: \(error.localizedDescription)"
        }

        let recoveryURL = (finalURL?.deletingPathExtension() ?? rawURL.deletingPathExtension())
            .appendingPathExtension("unprocessed.m4a")

        do {
            if FileManager.default.fileExists(atPath: recoveryURL.path) {
                try FileManager.default.removeItem(at: recoveryURL)
            }
            try FileManager.default.moveItem(at: rawURL, to: recoveryURL)
            lastRecordingURL = recoveryURL
            return "Speech cleanup failed, but the original recording was saved as \(recoveryURL.lastPathComponent)."
        } catch {
            return "Could not finish the recording. The temporary audio may remain at \(rawURL.path)."
        }
    }
}
