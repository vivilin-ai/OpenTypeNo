import AppKit
import ApplicationServices
import AVFoundation
import Combine
import Foundation
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Localization Helper

/// Returns `zh` when the system's first preferred language is Chinese, otherwise `en`.
func L(_ en: String, _ zh: String) -> String {
    Locale.preferredLanguages.first.map { $0.hasPrefix("zh") } == true ? zh : en
}

// MARK: - Hotkey Configuration

enum HotkeyModifier: String, Codable, CaseIterable {
    case leftControl  = "LeftControl"
    case rightControl = "RightControl"
    case leftOption   = "LeftOption"
    case rightOption  = "RightOption"
    case leftCommand  = "LeftCommand"
    case rightCommand = "RightCommand"
    case leftShift    = "LeftShift"
    case rightShift   = "RightShift"

    var symbol: String {
        switch self {
        case .leftControl,  .rightControl: "⌃"
        case .leftOption,   .rightOption:  "⌥"
        case .leftCommand,  .rightCommand: "⌘"
        case .leftShift,    .rightShift:   "⇧"
        }
    }

    var label: String {
        switch self {
        case .leftControl:  L("⌃ Left Control",  "⌃ 左 Control")
        case .rightControl: L("⌃ Right Control", "⌃ 右 Control")
        case .leftOption:   L("⌥ Left Option",   "⌥ 左 Option")
        case .rightOption:  L("⌥ Right Option",  "⌥ 右 Option")
        case .leftCommand:  L("⌘ Left Command",  "⌘ 左 Command")
        case .rightCommand: L("⌘ Right Command", "⌘ 右 Command")
        case .leftShift:    L("⇧ Left Shift",    "⇧ 左 Shift")
        case .rightShift:   L("⇧ Right Shift",   "⇧ 右 Shift")
        }
    }

    var flag: NSEvent.ModifierFlags {
        switch self {
        case .leftControl,  .rightControl: .control
        case .leftOption,   .rightOption:  .option
        case .leftCommand,  .rightCommand: .command
        case .leftShift,    .rightShift:   .shift
        }
    }

    var keyCode: UInt16 {
        switch self {
        case .leftControl:  59
        case .rightControl: 62
        case .leftOption:   58
        case .rightOption:  61
        case .leftCommand:  55
        case .rightCommand: 54
        case .leftShift:    56
        case .rightShift:   60
        }
    }
}

enum TriggerMode: String, Codable, CaseIterable {
    case singleTap = "SingleTap"
    case doubleTap = "DoubleTap"

    var label: String {
        switch self {
        case .singleTap: L("1× Single Tap", "1× 单击")
        case .doubleTap: L("2× Double Tap", "2× 双击")
        }
    }
}

extension UserDefaults {
    private static let modifierKey   = "ai.marswave.opentypeno.hotkeyModifier"
    private static let triggerKey    = "ai.marswave.opentypeno.triggerMode"

    var hotkeyModifier: HotkeyModifier {
        get {
            guard let raw = string(forKey: Self.modifierKey),
                  let v = HotkeyModifier(rawValue: raw) else { return .leftControl }
            return v
        }
        set { set(newValue.rawValue, forKey: Self.modifierKey) }
    }

    var triggerMode: TriggerMode {
        get {
            guard let raw = string(forKey: Self.triggerKey),
                  let v = TriggerMode(rawValue: raw) else { return .singleTap }
            return v
        }
        set { set(newValue.rawValue, forKey: Self.triggerKey) }
    }
}

extension Array {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

extension Notification.Name {
    static let hotkeyConfigChanged = Notification.Name("ai.marswave.opentypeno.hotkeyConfigChanged")
}


@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let appState = AppState()
    private var statusItemController: StatusItemController?
    private var hotkeyMonitor: HotkeyMonitor?
    private var overlayController: OverlayPanelController?
    private var settingsController: SettingsWindowController?
    private var permissionsGranted = false
    private var pollTimer: Timer?
    private let updateService = UpdateService()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        overlayController = OverlayPanelController(appState: appState)
        statusItemController = StatusItemController(appState: appState)
        settingsController = SettingsWindowController()
        hotkeyMonitor = HotkeyMonitor(
            modifier: UserDefaults.standard.hotkeyModifier,
            triggerMode: UserDefaults.standard.triggerMode,
            onToggle: { [weak self] in self?.handleToggle() }
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(restartHotkeyMonitor),
            name: .hotkeyConfigChanged,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleOpenSettings),
            name: .openSettings,
            object: nil
        )

        appState.onToggleRequest = { [weak self] in
            self?.handleToggle()
        }

        appState.onOverlayRequest = { [weak self] visible in
            if visible {
                self?.overlayController?.show()
            } else {
                self?.overlayController?.hide()
            }
        }

        appState.onPermissionOpen = { [weak self] kind in
            self?.openPermissionSettings(for: kind)
        }

        appState.onColiInstallHelpRequest = { [weak self] in
            self?.openColiInstallHelp()
        }

        appState.onCancel = { [weak self] in
            self?.cancelFlow()
        }

        appState.onConfirm = { [weak self] in
            self?.appState.confirmInsert()
        }

        appState.onUpdateRequest = { [weak self] in
            self?.performUpdate()
        }

        // Auto-poll permissions and coli install status
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.pollStatus()
            }
        }

        hotkeyMonitor?.start()

        // Silent update check on launch
        Task {
            if let release = await updateService.checkForUpdate() {
                statusItemController?.setUpdateAvailable(release.version)
            }
        }
    }

    private func pollStatus() {
        switch appState.phase {
        case .permissions:
            let missing = PermissionManager.missingPermissions(requestMicrophoneIfNeeded: false)
            if missing.isEmpty {
                permissionsGranted = true
                appState.hidePermissions()
            } else {
                appState.showPermissions(missing)
            }
        case .missingColi:
            if ColiASRService.isInstalled {
                appState.hideColiGuidance()
            } else if ColiASRService.isNpmAvailable {
                // npm became available (user installed Node), trigger auto-install
                appState.autoInstallColi()
            }
        default:
            break
        }
    }

    private func handleToggle() {
        switch appState.phase {
        case .idle:
            startRecording()
        case .recording:
            stopRecording()
        case .done:
            appState.confirmInsert()
        case .transcribing, .postProcessing, .downloadingModels, .error:
            appState.cancel()
        case .permissions, .missingColi, .installingColi, .updating:
            break
        }
    }

    @objc private func restartHotkeyMonitor() {
        hotkeyMonitor?.stop()
        hotkeyMonitor = HotkeyMonitor(
            modifier: UserDefaults.standard.hotkeyModifier,
            triggerMode: UserDefaults.standard.triggerMode,
            onToggle: { [weak self] in self?.handleToggle() }
        )
        hotkeyMonitor?.start()
    }

    @objc private func handleOpenSettings() {
        settingsController?.show()
    }

    private func startRecording() {
        // Only check permissions if not previously granted this session
        if !permissionsGranted {
            let missing = PermissionManager.missingPermissions(requestMicrophoneIfNeeded: true, requestAccessibilityIfNeeded: true)
            if !missing.isEmpty {
                appState.showPermissions(missing)
                return
            }
            permissionsGranted = true
        }

        do {
            try appState.startRecording()
        } catch {
            appState.showError(error.localizedDescription)
        }
    }

    private func stopRecording() {
        Task { @MainActor in
            do {
                try await appState.stopRecording()
                await appState.transcribeAndInsert()
            } catch is CancellationError {
                // User canceled; keep app in reset state
            } catch {
                appState.showError(error.localizedDescription)
            }
        }
    }

    private func cancelFlow() {
        appState.cancel()
    }

    private func openPermissionSettings(for kind: PermissionKind) {
        PermissionManager.openPrivacySettings(for: [kind])
    }

    private func openColiInstallHelp() {
        guard let url = URL(string: "https://github.com/marswaveai/coli") else { return }
        NSWorkspace.shared.open(url)
    }

    private func performUpdate() {
        Task {
            appState.phase = .updating(L("Checking for updates...", "检查更新..."))
            appState.onOverlayRequest?(true)

            switch await updateService.checkForUpdateDetailed() {
            case .upToDate:
                appState.phase = .updating(L("Already up to date", "已是最新版本"))
                try? await Task.sleep(for: .seconds(2))
                appState.phase = .idle
                appState.onOverlayRequest?(false)

            case .rateLimited:
                appState.showError(L("GitHub rate limit — try again later", "GitHub 请求限制，请稍后重试"))

            case .failed:
                appState.showError(L("Could not check for updates", "无法检查更新"))

            case .updateAvailable(let release):
                appState.phase = .updating(L("v\(release.version) available", "v\(release.version) 可更新"))
                appState.onOverlayRequest?(true)
                try? await Task.sleep(for: .seconds(1.5))
                appState.phase = .idle
                appState.onOverlayRequest?(false)
                NSWorkspace.shared.open(URL(string: "https://github.com/\(UpdateService.repoOwner)/\(UpdateService.repoName)/releases/latest")!)
            }
        }
    }
}

// MARK: - Model

enum PermissionKind: CaseIterable, Hashable {
    case microphone
    case accessibility

    var title: String {
        switch self {
        case .microphone: L("Microphone", "麦克风")
        case .accessibility: L("Accessibility", "辅助功能")
        }
    }

    var explanation: String {
        switch self {
        case .microphone: L("Required to capture your voice", "用于捕获语音")
        case .accessibility: L("Required to type text into apps", "用于向应用输入文字")
        }
    }

    var icon: String {
        switch self {
        case .microphone: "mic.fill"
        case .accessibility: "hand.raised.fill"
        }
    }
}

enum AppPhase: Equatable {
    case idle
    case recording
    case transcribing(String = "Transcribing...")
    case postProcessing
    case downloadingModels
    case done(String)        // transcription result, waiting for user confirm
    case permissions(Set<PermissionKind>)
    case missingColi
    case installingColi(String) // progress message
    case updating(String)    // progress message
    case error(String)

    var subtitle: String {
        switch self {
        case .idle: L("Press Fn to start", "按 Fn 开始")
        case .recording: L("Listening...", "录音中...")
        case .transcribing(let message):
            message == "Transcribing..." ? L("Transcribing...", "转录中...") : message
        case .postProcessing: L("Optimizing...", "优化中...")
        case .downloadingModels: L("Downloading speech models...", "下载语音模型中...")
        case .done(let text): text
        case .permissions, .missingColi, .installingColi: ""
        case .updating(let message): message
        case .error(let message): message
        }
    }
}

// MARK: - App State

@MainActor
final class AppState: ObservableObject {
    @Published var phase: AppPhase = .idle
    @Published var transcript = ""

    var onOverlayRequest: ((Bool) -> Void)?
    var onPermissionOpen: ((PermissionKind) -> Void)?
    var onColiInstallHelpRequest: (() -> Void)?
    var onCancel: (() -> Void)?
    var onConfirm: (() -> Void)?
    var onToggleRequest: (() -> Void)?
    var onUpdateRequest: (() -> Void)?

    private let recorder = AudioRecorder()
    private var asrService: any ASRServiceProtocol = ColiASRService()
    private let postProcessor = PostProcessingService()
    private var currentRecordingURL: URL?
    private var previousApp: NSRunningApplication?
    private var recordingTimer: Timer?
    @Published var recordingElapsedSeconds: Int = 0

    var recordingElapsedStr: String {
        let m = recordingElapsedSeconds / 60
        let s = recordingElapsedSeconds % 60
        return String(format: "%d:%02d", m, s)
    }

    func startRecording() throws {
        transcript = ""
        previousApp = NSWorkspace.shared.frontmostApplication
        currentRecordingURL = try recorder.start()
        recordingElapsedSeconds = 0
        recordingTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.recordingElapsedSeconds += 1 }
        }
        phase = .recording
        onOverlayRequest?(true)
    }

    func stopRecording() async throws {
        recordingTimer?.invalidate()
        recordingTimer = nil
        phase = .transcribing()
        onOverlayRequest?(true)

        let url = try await recorder.stop()
        currentRecordingURL = url
    }

    func cancel() {
        recordingTimer?.invalidate()
        recordingTimer = nil
        recorder.cancel()
        (asrService as? ColiASRService)?.cancelCurrentProcess()
        if let currentRecordingURL {
            try? FileManager.default.removeItem(at: currentRecordingURL)
        }
        currentRecordingURL = nil
        transcript = ""
        phase = .idle
        onOverlayRequest?(false)
    }

    func showPermissions(_ missing: Set<PermissionKind>) {
        phase = .permissions(missing)
        onOverlayRequest?(true)
    }

    func hidePermissions() {
        phase = .idle
        onOverlayRequest?(false)
    }

    func showMissingColi() {
        // If npm is available, auto-install coli instead of showing manual guidance
        if ColiASRService.isNpmAvailable {
            autoInstallColi()
        } else {
            phase = .missingColi
            onOverlayRequest?(true)
        }
    }

    func autoInstallColi() {
        phase = .installingColi(L("Installing coli...", "安装中..."))
        onOverlayRequest?(true)

        Task {
            do {
                try await ColiASRService.installColi { [weak self] message in
                    self?.phase = .installingColi(message)
                }
                // Verify installation
                if ColiASRService.isInstalled {
                    // Start async model download in background
                    Task { [weak self] in
                        do {
                            self?.phase = .downloadingModels
                            self?.onOverlayRequest?(true)
                            try await ColiASRService.ensureModels { [weak self] message in
                                self?.phase = .downloadingModels
                            }
                            // Download complete
                            self?.phase = .idle
                            self?.onOverlayRequest?(false)
                        } catch {
                            // Model download failed, but coli is installed
                            // User can still use it (models will download on first use)
                            self?.phase = .idle
                            self?.onOverlayRequest?(false)
                        }
                    }
                } else {
                    // Fallback to manual guidance
                    phase = .missingColi
                }
            } catch {
                showError("Install failed: \(error.localizedDescription)")
            }
        }
    }

    func hideColiGuidance() {
        if case .missingColi = phase {
            phase = .idle
            onOverlayRequest?(false)
        }
    }

    func showError(_ message: String) {
        phase = .error(message)
        onOverlayRequest?(true)
    }

    func transcribeAndInsert() async {
        guard let url = currentRecordingURL else {
            showError("No recording")
            return
        }

        // Select ASR service based on user setting
        let isLocalMode = UserDefaults.standard.asrMode == .local

        // Check if models need to be downloaded (local mode only)
        if isLocalMode && !ColiASRService.isModelDownloaded {
            phase = .downloadingModels
            onOverlayRequest?(true)
            do {
                try await ColiASRService.ensureModels { [weak self] _ in
                    self?.phase = .downloadingModels
                }
            } catch {
                showError("Failed to download models: \(error.localizedDescription)")
                return
            }
        }

        phase = .transcribing()

        let service: any ASRServiceProtocol = isLocalMode
            ? ColiASRService()
            : CloudASRService()

        do {
            var text = try await service.transcribe(fileURL: url)
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)

            guard !text.isEmpty else {
                throw OpenTypeNoError.emptyTranscript
            }

            // Post-processing if enabled
            if UserDefaults.standard.postProcessingEnabled {
                phase = .postProcessing
                text = (try? await postProcessor.process(text)) ?? text
            }

            transcript = text
            phase = .done(transcript)
            onOverlayRequest?(true)
            confirmInsert()
        } catch OpenTypeNoError.coliNotInstalled {
            showMissingColi()
        } catch {
            showError(error.localizedDescription)
        }
    }

    func confirmInsert() {
        guard !transcript.isEmpty else {
            cancel()
            return
        }

        let text = transcript
        let targetApp = previousApp

        // Copy to clipboard
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)

        // Hide overlay
        onOverlayRequest?(false)

        // Activate previous app, then Cmd+V
        if let targetApp {
            targetApp.activate()
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            let source = CGEventSource(stateID: .hidSystemState)
            let vDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true)
            let vUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false)
            vDown?.flags = .maskCommand
            vUp?.flags = .maskCommand
            vDown?.post(tap: .cghidEventTap)
            vUp?.post(tap: .cghidEventTap)

            self?.resetState()
        }
    }

    private func resetState() {
        if let currentRecordingURL {
            try? FileManager.default.removeItem(at: currentRecordingURL)
        }
        currentRecordingURL = nil
        previousApp = nil
        transcript = ""
        phase = .idle
        onOverlayRequest?(false)
    }

    func transcribeFile(_ url: URL) async {
        previousApp = NSWorkspace.shared.frontmostApplication

        let isLocalMode = UserDefaults.standard.asrMode == .local

        // Check if models need to be downloaded (local mode only)
        if isLocalMode && !ColiASRService.isModelDownloaded {
            phase = .downloadingModels
            onOverlayRequest?(true)
            do {
                try await ColiASRService.ensureModels { [weak self] _ in
                    self?.phase = .downloadingModels
                }
            } catch {
                showError("Failed to download models: \(error.localizedDescription)")
                return
            }
        }

        phase = .transcribing()
        onOverlayRequest?(true)

        let service: any ASRServiceProtocol = isLocalMode
            ? ColiASRService()
            : CloudASRService()

        do {
            var text = try await service.transcribe(fileURL: url)
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)

            guard !text.isEmpty else {
                throw OpenTypeNoError.emptyTranscript
            }

            if UserDefaults.standard.postProcessingEnabled {
                phase = .postProcessing
                text = (try? await postProcessor.process(text)) ?? text
            }

            transcript = text
            phase = .done(transcript)
            onOverlayRequest?(true)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(transcript, forType: .string)
            try? await Task.sleep(for: .seconds(2))
            cancel()
        } catch OpenTypeNoError.coliNotInstalled {
            showMissingColi()
        } catch {
            showError(error.localizedDescription)
        }
    }
}

// MARK: - Errors

enum OpenTypeNoError: LocalizedError {
    case noRecording
    case emptyTranscript
    case coliNotInstalled
    case npmNotFound
    case coliInstallFailed(String)
    case transcriptionFailed(String)

    var errorDescription: String? {
        switch self {
        case .noRecording: "No recording"
        case .emptyTranscript: "No speech detected"
        case .coliNotInstalled: "OpenTypeNo needs the local Coli engine. Install it with: npm install -g @marswave/coli"
        case .npmNotFound: "Node.js is required. Install it from https://nodejs.org"
        case .coliInstallFailed(let message): "Coli install failed: \(message)"
        case .transcriptionFailed(let message): message
        }
    }
}

// MARK: - Permission Manager

enum PermissionManager {
    static func missingPermissions(requestMicrophoneIfNeeded: Bool, requestAccessibilityIfNeeded: Bool = false) -> Set<PermissionKind> {
        var missing = Set<PermissionKind>()

        switch microphoneStatus(requestIfNeeded: requestMicrophoneIfNeeded) {
        case .authorized:
            break
        default:
            missing.insert(.microphone)
        }

        if !accessibilityStatus(requestIfNeeded: requestAccessibilityIfNeeded) {
            missing.insert(.accessibility)
        }

        return missing
    }

    static func microphoneStatus(requestIfNeeded: Bool) -> AVAuthorizationStatus {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        if status == .notDetermined, requestIfNeeded {
            AVCaptureDevice.requestAccess(for: .audio) { _ in }
        }
        return status
    }

    static func accessibilityStatus(requestIfNeeded: Bool) -> Bool {
        guard requestIfNeeded else {
            return AXIsProcessTrusted()
        }
        let options = [
            "AXTrustedCheckOptionPrompt": true
        ] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    static func openPrivacySettings(for permissions: Set<PermissionKind>) {
        let urlString: String
        if permissions.contains(.accessibility) {
            urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        } else if permissions.contains(.microphone) {
            urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
        } else {
            urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy"
        }

        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - Audio Recorder

@MainActor
final class AudioRecorder: NSObject, AVAudioRecorderDelegate {
    private var recorder: AVAudioRecorder?
    private var recordingURL: URL?
    private var stopContinuation: CheckedContinuation<URL, Error>?

    func start() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("OpenTypeNo", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let url = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension("m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]

        let recorder = try AVAudioRecorder(url: url, settings: settings)
        recorder.delegate = self
        recorder.record()

        self.recorder = recorder
        self.recordingURL = url
        return url
    }

    func stop() async throws -> URL {
        guard let recordingURL else {
            throw OpenTypeNoError.noRecording
        }
        guard let recorder else {
            return recordingURL
        }

        return try await withCheckedThrowingContinuation { continuation in
            stopContinuation = continuation
            recorder.stop()
            self.recorder = nil
        }
    }

    func cancel() {
        finishStop(with: .failure(CancellationError()))
        recorder?.stop()
        recorder = nil
        if let recordingURL {
            try? FileManager.default.removeItem(at: recordingURL)
        }
        recordingURL = nil
    }

    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        Task { @MainActor in
            if flag, let recordingURL {
                finishStop(with: .success(recordingURL))
            } else {
                finishStop(with: .failure(OpenTypeNoError.noRecording))
            }
            recordingURL = nil
        }
    }

    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: (any Error)?) {
        Task { @MainActor in
            finishStop(with: .failure(error ?? OpenTypeNoError.noRecording))
            recordingURL = nil
        }
    }

    private func finishStop(with result: Result<URL, Error>) {
        guard let stopContinuation else { return }
        self.stopContinuation = nil
        switch result {
        case .success(let url): stopContinuation.resume(returning: url)
        case .failure(let err): stopContinuation.resume(throwing: err)
        }
    }
}

// MARK: - ASR Service

/// Thread-safe mutable data buffer for pipe reading.
private final class LockedData: @unchecked Sendable {
    private var data = Data()
    private let lock = NSLock()
    func append(_ chunk: Data) { lock.lock(); data.append(chunk); lock.unlock() }
    func read() -> Data { lock.lock(); defer { lock.unlock() }; return data }
}

final class ColiASRService: @unchecked Sendable {
    static var isInstalled: Bool {
        findColiPath() != nil
    }

    static var isNpmAvailable: Bool {
        findNpmPath() != nil
    }

    /// Check if SenseVoice model is downloaded
    static var isModelDownloaded: Bool {
        let home = ProcessInfo.processInfo.environment["HOME"] ?? ""
        let modelPath = (home as NSString).appendingPathComponent(".coli/models/sensevoice")
        return FileManager.default.fileExists(atPath: modelPath)
    }

    /// Download models in background using Node.js script
    static func ensureModels(onProgress: @MainActor @Sendable @escaping (String) -> Void) async throws {
        guard let nodePath = findNodePath() else {
            throw OpenTypeNoError.npmNotFound
        }

        await onProgress(L("Downloading speech models...", "下载语音模型中..."))

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    // Create temporary Node.js script
                    let script = """
                    const { ensureModels } = require('@marswave/coli');
                    (async () => {
                      try {
                        await ensureModels(['sensevoice']);
                        process.exit(0);
                      } catch (err) {
                        console.error(err);
                        process.exit(1);
                      }
                    })();
                    """
                    let tempDir = FileManager.default.temporaryDirectory
                    let scriptPath = tempDir.appendingPathComponent("ensure_models_\(UUID().uuidString).js")
                    try script.write(to: scriptPath, atomically: true, encoding: .utf8)

                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: nodePath)
                    process.arguments = [scriptPath.path]

                    // Set up environment
                    let nodeDir = (nodePath as NSString).deletingLastPathComponent
                    let env = ProcessInfo.processInfo.environment
                    let home = env["HOME"] ?? ""
                    let extraPaths = [
                        nodeDir,
                        "/opt/homebrew/bin",
                        "/usr/local/bin",
                        home + "/.nvm/current/bin",
                        home + "/.volta/bin",
                        home + "/.local/share/fnm/aliases/default/bin"
                    ]
                    var processEnv = env
                    let existingPath = env["PATH"] ?? "/usr/bin:/bin"
                    processEnv["PATH"] = (extraPaths + [existingPath]).joined(separator: ":")
                    process.environment = processEnv

                    let stdout = Pipe()
                    let stderr = Pipe()
                    process.standardOutput = stdout
                    process.standardError = stderr

                    let stderrBuf = LockedData()
                    let stderrHandle = stderr.fileHandleForReading
                    stderrHandle.readabilityHandler = { handle in
                        let data = handle.availableData
                        if !data.isEmpty { stderrBuf.append(data) }
                    }

                    try process.run()

                    // 10-minute timeout for model download
                    let timeoutItem = DispatchWorkItem {
                        if process.isRunning { process.terminate() }
                    }
                    DispatchQueue.global().asyncAfter(deadline: .now() + 600, execute: timeoutItem)

                    process.waitUntilExit()
                    timeoutItem.cancel()
                    stderrHandle.readabilityHandler = nil

                    // Clean up temp script
                    try? FileManager.default.removeItem(at: scriptPath)

                    guard process.terminationStatus == 0 else {
                        let errorOutput = String(data: stderrBuf.read(), encoding: .utf8) ?? ""
                        throw OpenTypeNoError.transcriptionFailed("Model download failed: \(errorOutput)")
                    }

                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Auto-install coli via npm. Reports progress via callback.
    static func installColi(onProgress: @MainActor @Sendable @escaping (String) -> Void) async throws {
        guard let npmPath = findNpmPath() else {
            throw OpenTypeNoError.npmNotFound
        }

        await onProgress("Installing coli...")

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: npmPath)
                    process.arguments = ["install", "-g", "@marswave/coli"]

                    // Set up PATH so npm can find node
                    let npmDir = (npmPath as NSString).deletingLastPathComponent
                    let env = ProcessInfo.processInfo.environment
                    let home = env["HOME"] ?? ""
                    let extraPaths = [
                        npmDir,
                        "/opt/homebrew/bin",
                        "/usr/local/bin",
                        home + "/.nvm/current/bin",
                        home + "/.volta/bin",
                        home + "/.local/share/fnm/aliases/default/bin"
                    ]
                    var processEnv = env
                    let existingPath = env["PATH"] ?? "/usr/bin:/bin"
                    processEnv["PATH"] = (extraPaths + [existingPath]).joined(separator: ":")
                    process.environment = processEnv

                    let stdout = Pipe()
                    let stderr = Pipe()
                    process.standardOutput = stdout
                    process.standardError = stderr

                    // Read pipe data asynchronously to avoid deadlock
                    let stderrBuf = LockedData()
                    let stderrHandle = stderr.fileHandleForReading

                    stderrHandle.readabilityHandler = { handle in
                        let data = handle.availableData
                        if !data.isEmpty { stderrBuf.append(data) }
                    }

                    try process.run()

                    // 120-second timeout for install
                    let timeoutItem = DispatchWorkItem {
                        if process.isRunning { process.terminate() }
                    }
                    DispatchQueue.global().asyncAfter(deadline: .now() + 120, execute: timeoutItem)

                    process.waitUntilExit()
                    timeoutItem.cancel()

                    stderrHandle.readabilityHandler = nil

                    guard process.terminationStatus == 0 else {
                        let errorOutput = String(data: stderrBuf.read(), encoding: .utf8) ?? ""
                        let msg = errorOutput.trimmingCharacters(in: .whitespacesAndNewlines)
                        throw OpenTypeNoError.coliInstallFailed(msg.isEmpty ? "npm install failed" : msg)
                    }

                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private var currentProcess: Process?
    private let processLock = NSLock()

    func cancelCurrentProcess() {
        processLock.lock()
        let proc = currentProcess
        currentProcess = nil
        processLock.unlock()
        if let proc, proc.isRunning {
            proc.terminate()
        }
    }

    func transcribe(fileURL: URL) async throws -> String {
        guard let coliPath = Self.findColiPath() else {
            throw OpenTypeNoError.coliNotInstalled
        }

        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                do {
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: coliPath)
                    process.arguments = ["asr", fileURL.path]

                    // Inherit a proper PATH so node/bun can be found
                    var env = ProcessInfo.processInfo.environment
                    let home = env["HOME"] ?? ""
                    let extraPaths = [
                        "/opt/homebrew/bin",
                        "/usr/local/bin",
                        home + "/.nvm/versions/node/",  // nvm
                        home + "/.bun/bin",
                        home + "/.npm-global/bin",
                        "/opt/homebrew/opt/node/bin"
                    ]
                    let existingPath = env["PATH"] ?? "/usr/bin:/bin"
                    env["PATH"] = (extraPaths + [existingPath]).joined(separator: ":")

                    // Inject macOS system proxy settings so Node.js fetch (undici) can reach
                    // the internet when a system proxy is configured (e.g. via System Settings).
                    // GUI apps don't source shell profiles, so HTTP_PROXY / HTTPS_PROXY are
                    // typically unset even when the system proxy is active.
                    if env["HTTP_PROXY"] == nil && env["HTTPS_PROXY"] == nil && env["http_proxy"] == nil {
                        if let proxyURL = Self.systemHTTPSProxyURL() {
                            env["HTTPS_PROXY"] = proxyURL
                            env["HTTP_PROXY"] = proxyURL
                            env["https_proxy"] = proxyURL
                            env["http_proxy"] = proxyURL
                        }
                    }

                    process.environment = env

                    let stdout = Pipe()
                    let stderr = Pipe()
                    process.standardOutput = stdout
                    process.standardError = stderr

                    // Read pipe data asynchronously to avoid deadlock when buffer fills up
                    let stdoutBuf = LockedData()
                    let stderrBuf = LockedData()
                    let stdoutHandle = stdout.fileHandleForReading
                    let stderrHandle = stderr.fileHandleForReading

                    stdoutHandle.readabilityHandler = { handle in
                        let data = handle.availableData
                        if !data.isEmpty { stdoutBuf.append(data) }
                    }
                    stderrHandle.readabilityHandler = { handle in
                        let data = handle.availableData
                        if !data.isEmpty { stderrBuf.append(data) }
                    }

                    self?.processLock.lock()
                    self?.currentProcess = process
                    self?.processLock.unlock()

                    try process.run()

                    // Dynamic timeout: 2x audio duration, minimum 120s (covers model download on first run)
                    var audioTimeout: TimeInterval = 120
                    if let audioFile = try? AVAudioFile(forReading: fileURL) {
                        let durationSeconds = Double(audioFile.length) / audioFile.processingFormat.sampleRate
                        audioTimeout = max(120, durationSeconds * 2.0)
                    }
                    let timeoutItem = DispatchWorkItem {
                        if process.isRunning {
                            process.terminate()
                        }
                    }
                    DispatchQueue.global().asyncAfter(deadline: .now() + audioTimeout, execute: timeoutItem)

                    process.waitUntilExit()
                    timeoutItem.cancel()

                    // Stop reading handlers
                    stdoutHandle.readabilityHandler = nil
                    stderrHandle.readabilityHandler = nil

                    self?.processLock.lock()
                    self?.currentProcess = nil
                    self?.processLock.unlock()

                    guard process.terminationReason != .uncaughtSignal else {
                        throw OpenTypeNoError.transcriptionFailed("Transcription timed out")
                    }

                    let output = String(data: stdoutBuf.read(), encoding: .utf8) ?? ""
                    let errorOutput = String(data: stderrBuf.read(), encoding: .utf8) ?? ""

                    guard process.terminationStatus == 0 else {
                        let msg = errorOutput.trimmingCharacters(in: .whitespacesAndNewlines)
                        throw OpenTypeNoError.transcriptionFailed(msg.isEmpty ? "coli failed" : msg)
                    }

                    continuation.resume(returning: output.trimmingCharacters(in: .whitespacesAndNewlines))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Returns the macOS system HTTPS proxy as an "http://host:port" string, or nil if none is set.
    static func systemHTTPSProxyURL() -> String? {
        guard let proxySettings = CFNetworkCopySystemProxySettings()?.takeRetainedValue() as? [String: Any] else {
            return nil
        }
        // Check HTTPS proxy first, fall back to HTTP proxy
        if let httpsEnabled = proxySettings[kCFNetworkProxiesHTTPSEnable as String] as? Int, httpsEnabled == 1,
           let host = proxySettings[kCFNetworkProxiesHTTPSProxy as String] as? String,
           let port = proxySettings[kCFNetworkProxiesHTTPSPort as String] as? Int, !host.isEmpty {
            return "http://\(host):\(port)"
        }
        if let httpEnabled = proxySettings[kCFNetworkProxiesHTTPEnable as String] as? Int, httpEnabled == 1,
           let host = proxySettings[kCFNetworkProxiesHTTPProxy as String] as? String,
           let port = proxySettings[kCFNetworkProxiesHTTPPort as String] as? Int, !host.isEmpty {
            return "http://\(host):\(port)"
        }
        return nil
    }

    static func findNpmPath() -> String? {
        let env = ProcessInfo.processInfo.environment
        let home = env["HOME"] ?? ""

        if let pathInEnv = executableInPath(named: "npm", path: env["PATH"]) {
            return pathInEnv
        }

        let candidates = [
            "/opt/homebrew/bin/npm",
            "/usr/local/bin/npm",
            home + "/.nvm/current/bin/npm",
            home + "/.volta/bin/npm",
            home + "/.local/share/fnm/aliases/default/bin/npm",
            home + "/.bun/bin/npm"
        ]

        if let found = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return found
        }

        return resolveViaShell("npm")
    }

    static func findNodePath() -> String? {
        let env = ProcessInfo.processInfo.environment
        let home = env["HOME"] ?? ""

        if let pathInEnv = executableInPath(named: "node", path: env["PATH"]) {
            return pathInEnv
        }

        let candidates = [
            "/opt/homebrew/bin/node",
            "/usr/local/bin/node",
            home + "/.nvm/current/bin/node",
            home + "/.volta/bin/node",
            home + "/.local/share/fnm/aliases/default/bin/node",
            home + "/.bun/bin/node"
        ]

        if let found = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return found
        }

        return resolveViaShell("node")
    }

    private static func findColiPath() -> String? {
        let env = ProcessInfo.processInfo.environment
        let home = env["HOME"] ?? ""

        // Check current environment PATH first
        if let pathInEnv = executableInPath(named: "coli", path: env["PATH"]) {
            return pathInEnv
        }

        let candidates = [
            home + "/.local/bin/coli",
            "/opt/homebrew/bin/coli",
            "/usr/local/bin/coli",
            home + "/.npm-global/bin/coli",
            home + "/.bun/bin/coli",
            home + "/.volta/bin/coli",
            home + "/.nvm/current/bin/coli",
            "/opt/homebrew/opt/node/bin/coli"
        ]

        if let found = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return found
        }

        // Check fnm/nvm managed Node installs
        let managedRoots: [(root: String, rel: String)] = [
            (home + "/.local/share/fnm/node-versions", "installation/bin/coli"),
            (home + "/.nvm/versions/node", "bin/coli")
        ]
        for managed in managedRoots {
            if let path = newestManagedBinary(under: managed.root, relativePath: managed.rel) {
                return path
            }
        }

        // Use npm to find global bin directory (works even when coli is in a custom prefix)
        if let npmGlobalBin = resolveNpmGlobalBin(), !npmGlobalBin.isEmpty {
            let coliViaNpm = npmGlobalBin + "/coli"
            if FileManager.default.isExecutableFile(atPath: coliViaNpm) {
                return coliViaNpm
            }
        }

        // GUI apps don't inherit terminal PATH, so spawn a login shell to resolve coli
        return resolveViaShell("coli")
    }

    private static func executableInPath(named name: String, path: String?) -> String? {
        guard let path else { return nil }
        for dir in path.split(separator: ":") {
            let full = String(dir) + "/\(name)"
            if FileManager.default.isExecutableFile(atPath: full) { return full }
        }
        return nil
    }

    private static func newestManagedBinary(under rootPath: String, relativePath: String) -> String? {
        let fm = FileManager.default
        let rootURL = URL(fileURLWithPath: rootPath, isDirectory: true)
        guard let entries = try? fm.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        let sorted = entries
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted {
                let d1 = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let d2 = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return d1 != d2 ? d1 > d2 : $0.lastPathComponent > $1.lastPathComponent
            }

        for dir in sorted {
            let path = dir.path + "/" + relativePath
            if fm.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }

    private static func resolveViaShell(_ command: String) -> String? {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        // Use -i (interactive) so nvm/fnm/volta init scripts in .zshrc are loaded
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-l", "-i", "-c", "command -v \(command)"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()

            guard process.terminationStatus == 0 else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let path = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)

            guard let path, !path.isEmpty,
                  FileManager.default.isExecutableFile(atPath: path) else {
                return nil
            }
            return path
        } catch {
            return nil
        }
    }

    /// Resolve the npm global bin directory by asking npm itself via a login shell.
    private static func resolveNpmGlobalBin() -> String? {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-l", "-i", "-c", "npm bin -g 2>/dev/null || npm prefix -g 2>/dev/null"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()

            guard process.terminationStatus == 0 else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            // npm bin -g returns the bin path directly
            // npm prefix -g returns the prefix, bin is prefix/bin
            if output.hasSuffix("/bin") {
                return output
            } else if !output.isEmpty {
                return output + "/bin"
            }
            return nil
        } catch {
            return nil
        }
    }
}

// MARK: - Hotkey Monitor

@MainActor
final class HotkeyMonitor {
    private let modifier: HotkeyModifier
    private let triggerMode: TriggerMode
    private let onToggle: () -> Void
    private var flagsMonitor: Any?
    private var keyMonitor: Any?
    private var localFlagsMonitor: Any?
    private var localKeyMonitor: Any?
    private var keyDownAt: Date?
    private var firstTapAt: Date?
    private var otherKeyPressed = false

    init(modifier: HotkeyModifier = .leftControl, triggerMode: TriggerMode = .singleTap, onToggle: @escaping () -> Void) {
        self.modifier = modifier
        self.triggerMode = triggerMode
        self.onToggle = onToggle
    }

    func stop() {
        [flagsMonitor, keyMonitor, localFlagsMonitor, localKeyMonitor]
            .compactMap { $0 }
            .forEach { NSEvent.removeMonitor($0) }
        flagsMonitor = nil; keyMonitor = nil
        localFlagsMonitor = nil; localKeyMonitor = nil
    }

    func start() {
        // Track key presses while modifier is held (both global and local)
        keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] _ in
            self?.otherKeyPressed = true
        }
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            self?.otherKeyPressed = true
            return event
        }

        flagsMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            Task { @MainActor in self?.handle(event: event) }
        }
        localFlagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            Task { @MainActor in self?.handle(event: event) }
            return event
        }
    }

    private static let modifierKeyCodes: Set<UInt16> = [54, 55, 56, 58, 59, 60, 61, 62]

    private func handle(event: NSEvent) {
        var others: NSEvent.ModifierFlags = [.shift, .option, .command, .control, .function]
        others.remove(modifier.flag)
        let hasOtherModifier = !event.modifierFlags.intersection(others).isEmpty

        if event.keyCode == modifier.keyCode {
            if keyDownAt == nil {
                // Key press — modifier flag becomes set
                if event.modifierFlags.contains(modifier.flag) && !hasOtherModifier {
                    keyDownAt = Date()
                    otherKeyPressed = false
                }
            } else if let downAt = keyDownAt {
                // Key release — modifier flag clears
                let elapsed = Date().timeIntervalSince(downAt)
                let isQuickRelease = elapsed < 0.3 && !otherKeyPressed && !hasOtherModifier
                if isQuickRelease {
                    switch triggerMode {
                    case .singleTap:
                        onToggle()
                    case .doubleTap:
                        if let firstTap = firstTapAt {
                            if Date().timeIntervalSince(firstTap) < 0.5 {
                                onToggle()
                                firstTapAt = nil
                            } else {
                                firstTapAt = Date()
                            }
                        } else {
                            firstTapAt = Date()
                        }
                    }
                }
                keyDownAt = nil
                otherKeyPressed = false
            }
        } else if keyDownAt != nil && Self.modifierKeyCodes.contains(event.keyCode) {
            // Another modifier pressed while ours is held — mark as chord, don't trigger
            otherKeyPressed = true
        }
    }
}

// MARK: - Status Item

@MainActor
final class StatusItemController: NSObject {
    private let statusItem = NSStatusBar.system.statusItem(withLength: 28)
    private var cancellable: AnyCancellable?
    private weak var appState: AppState?

    init(appState: AppState) {
        self.appState = appState
        super.init()
        configureMenu()
        configureDragDrop()
        updateTitle(for: appState.phase)
        cancellable = appState.$phase.sink { [weak self] phase in
            self?.updateTitle(for: phase)
            self?.updateRecordMenuItem(for: phase)
        }
    }

    private func configureDragDrop() {
        guard let button = statusItem.button else { return }
        button.window?.registerForDraggedTypes([.fileURL])
        button.window?.delegate = self
    }

    private func configureMenu() {
        let menu = NSMenu()

        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let aboutItem = NSMenuItem(title: "OpenTypeNo  v\(version)", action: nil, keyEquivalent: "")
        aboutItem.isEnabled = false
        menu.addItem(aboutItem)

        menu.addItem(NSMenuItem.separator())

        let mod = UserDefaults.standard.hotkeyModifier
        let recordItem = NSMenuItem(title: L("Record  \(mod.symbol)", "录音  \(mod.symbol)"), action: #selector(toggleRecording), keyEquivalent: "")
        recordItem.target = self
        recordItem.tag = 100
        menu.addItem(recordItem)

        let transcribeItem = NSMenuItem(title: L("Transcribe File to Clipboard...", "转录文件到剪贴板..."), action: #selector(transcribeFile), keyEquivalent: "")
        transcribeItem.target = self
        menu.addItem(transcribeItem)

        menu.addItem(NSMenuItem.separator())

        // Hotkey sub-menu
        let hotkeyItem = NSMenuItem(title: L("Hotkey", "快捷键"), action: nil, keyEquivalent: "")
        let hotkeySub = NSMenu()
        for (i, m) in HotkeyModifier.allCases.enumerated() {
            let item = NSMenuItem(title: m.label, action: #selector(changeHotkey(_:)), keyEquivalent: "")
            item.target = self
            item.tag = 300 + i
            item.state = m == mod ? .on : .off
            hotkeySub.addItem(item)
        }
        menu.setSubmenu(hotkeySub, for: hotkeyItem)
        menu.addItem(hotkeyItem)

        // Trigger Mode sub-menu
        let triggerItem = NSMenuItem(title: L("Trigger Mode", "触发方式"), action: nil, keyEquivalent: "")
        let triggerSub = NSMenu()
        let curTrigger = UserDefaults.standard.triggerMode
        for (i, t) in TriggerMode.allCases.enumerated() {
            let item = NSMenuItem(title: t.label, action: #selector(changeTriggerMode(_:)), keyEquivalent: "")
            item.target = self
            item.tag = 400 + i
            item.state = t == curTrigger ? .on : .off
            triggerSub.addItem(item)
        }
        menu.setSubmenu(triggerSub, for: triggerItem)
        menu.addItem(triggerItem)

        menu.addItem(NSMenuItem.separator())

        let settingsItem = NSMenuItem(title: L("Settings...", "设置..."), action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        let updateItem = NSMenuItem(title: L("Check for Updates...", "检查更新..."), action: #selector(checkForUpdates), keyEquivalent: "")
        updateItem.target = self
        updateItem.tag = 200
        menu.addItem(updateItem)

        menu.addItem(NSMenuItem(title: L("Open Privacy Settings", "打开隐私设置"), action: #selector(openPrivacySettings), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: L("Quit OpenTypeNo", "退出 OpenTypeNo"), action: #selector(quit), keyEquivalent: "q"))

        menu.items.forEach { $0.target = self }
        statusItem.menu = menu
    }

    private func updateRecordMenuItem(for phase: AppPhase) {
        guard let item = statusItem.menu?.item(withTag: 100) else { return }
        let sym = UserDefaults.standard.hotkeyModifier.symbol
        switch phase {
        case .recording:
            item.title = L("Stop Recording", "停止录音")
        default:
            item.title = L("Record  \(sym)", "录音  \(sym)")
        }
    }

    private func makeSymbolImage(_ symbol: String) -> NSImage {
        let size = NSSize(width: 22, height: 22)
        let img = NSImage(size: size, flipped: false) { rect in
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 16, weight: .medium),
                .foregroundColor: NSColor.black
            ]
            let str = symbol as NSString
            let strSize = str.size(withAttributes: attrs)
            let pt = NSPoint(
                x: (rect.width - strSize.width) / 2,
                y: (rect.height - strSize.height) / 2
            )
            str.draw(at: pt, withAttributes: attrs)
            return true
        }
        img.isTemplate = true
        return img
    }

    private func updateTitle(for phase: AppPhase) {
        guard let button = statusItem.button else { return }
        switch phase {
        case .idle:
            button.image = makeSymbolImage("◎")
            button.imagePosition = .imageOnly
            button.title = ""
        default:
            button.image = nil
            button.imagePosition = .noImage
            button.title = switch phase {
            case .recording: "Rec"
            case .transcribing: "..."
            case .done: "✓"
            case .updating: "↓"
            default: "!"
            }
        }
    }

    @objc private func changeHotkey(_ sender: NSMenuItem) {
        let idx = sender.tag - 300
        guard let mod = HotkeyModifier.allCases[safe: idx] else { return }
        UserDefaults.standard.hotkeyModifier = mod
        // Update checkmarks
        sender.menu?.items.forEach { $0.state = $0.tag == sender.tag ? .on : .off }
        // Refresh title + record item
        if let phase = appState?.phase {
            updateTitle(for: phase)
            updateRecordMenuItem(for: phase)
        }
        NotificationCenter.default.post(name: .hotkeyConfigChanged, object: nil)
    }

    @objc private func changeTriggerMode(_ sender: NSMenuItem) {
        let idx = sender.tag - 400
        guard let mode = TriggerMode.allCases[safe: idx] else { return }
        UserDefaults.standard.triggerMode = mode
        sender.menu?.items.forEach { $0.state = $0.tag == sender.tag ? .on : .off }
        NotificationCenter.default.post(name: .hotkeyConfigChanged, object: nil)
    }

    @objc private func openSettings() {
        NotificationCenter.default.post(name: .openSettings, object: nil)
    }

    @objc private func openPrivacySettings() {
        PermissionManager.openPrivacySettings(for: [])
    }

    @objc private func toggleRecording() {
        appState?.onToggleRequest?()
    }

    @objc private func checkForUpdates() {
        appState?.onUpdateRequest?()
    }

    func setUpdateAvailable(_ version: String) {
        guard let item = statusItem.menu?.item(withTag: 200) else { return }
        item.title = L("Update Available (v\(version))", "有新版本 (v\(version))")
    }

    @objc private func transcribeFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [
            .init(filenameExtension: "m4a")!,
            .init(filenameExtension: "mp3")!,
            .init(filenameExtension: "wav")!,
            .init(filenameExtension: "aac")!
        ]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose an audio file — result will be copied to clipboard"

        if panel.runModal() == .OK, let url = panel.url {
            Task { @MainActor in
                await appState?.transcribeFile(url)
            }
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

extension StatusItemController: NSWindowDelegate {
    func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard let items = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL],
              let url = items.first,
              ["m4a", "mp3", "wav", "aac"].contains(url.pathExtension.lowercased()) else {
            return []
        }
        return .copy
    }

    func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let items = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL],
              let url = items.first else {
            return false
        }

        Task { @MainActor in
            await appState?.transcribeFile(url)
        }
        return true
    }
}

// MARK: - Overlay Panel

@MainActor
final class OverlayPanelController {
    private let panel: NSPanel
    private let hostingView: NSHostingView<OverlayView>
    private let appState: AppState

    init(appState: AppState) {
        self.appState = appState
        let overlayView = OverlayView(appState: appState)
        hostingView = NSHostingView(rootView: overlayView)

        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.contentView = hostingView
    }

    func show() {
        hostingView.invalidateIntrinsicContentSize()
        let idealSize = hostingView.fittingSize
        let width = max(idealSize.width, 240)
        let height = max(idealSize.height, 44)

        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            let x: CGFloat
            let y: CGFloat

            if case .permissions = appState.phase {
                // Onboarding: top-right corner, below menu bar
                x = frame.maxX - width - 16
                y = frame.maxY - height - 16
            } else if case .missingColi = appState.phase {
                x = frame.maxX - width - 16
                y = frame.maxY - height - 16
            } else if case .installingColi = appState.phase {
                x = frame.maxX - width - 16
                y = frame.maxY - height - 16
            } else {
                // Recording/transcription bar: center bottom
                x = frame.midX - width / 2
                y = frame.minY + 48
            }

            panel.setFrame(NSRect(x: x, y: y, width: width, height: height), display: true)
        } else {
            panel.setContentSize(NSSize(width: width, height: height))
        }
        panel.orderFrontRegardless()
    }

    func hide() {
        panel.orderOut(nil)
    }
}

// MARK: - Overlay View

struct OverlayView: View {
    @ObservedObject var appState: AppState

    var body: some View {
        Group {
            switch appState.phase {
            case .permissions(let missing):
                permissionView(missing: missing)
            case .missingColi:
                missingColiView
            case .installingColi(let message):
                installingColiView(message: message)
            case .idle:
                EmptyView()
            default:
                compactView
            }
        }
        .fixedSize()
    }

    var compactView: some View {
        HStack(spacing: 10) {
            if case .recording = appState.phase {
                Circle()
                    .fill(Color.primary.opacity(0.3))
                    .frame(width: 6, height: 6)
            }

            if case .transcribing = appState.phase {
                ProgressView()
                    .controlSize(.small)
            }

            if case .postProcessing = appState.phase {
                ProgressView()
                    .controlSize(.small)
            }

            if case .downloadingModels = appState.phase {
                ProgressView()
                    .controlSize(.small)
            }

            if case .updating = appState.phase {
                ProgressView()
                    .controlSize(.small)
            }

            if case .done(let text) = appState.phase {
                Image(systemName: "doc.on.clipboard")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)

                Text(text)
                    .font(.system(size: 13))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
            } else if case .recording = appState.phase {
                let nearLimit = appState.recordingElapsedSeconds >= 105  // 1:45
                Text(nearLimit
                     ? L("⚠ \(appState.recordingElapsedStr)", "⚠ \(appState.recordingElapsedStr)")
                     : appState.recordingElapsedStr)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(nearLimit ? Color.orange : Color.primary)
            } else {
                Text(appState.phase.subtitle)
                    .font(.system(size: 13))
                    .foregroundStyle(.primary)
            }

            if case .error = appState.phase {
                Button(L("OK", "好")) {
                    appState.onCancel?()
                }
                .buttonStyle(.borderless)
                .font(.system(size: 12))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
    }

    func permissionView(missing: Set<PermissionKind>) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(missing.sorted { $0.title < $1.title }), id: \.self) { kind in
                HStack(spacing: 12) {
                    Image(systemName: kind.icon)
                        .font(.system(size: 16))
                        .foregroundStyle(.secondary)
                        .frame(width: 24)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(kind.title)
                            .font(.system(size: 13, weight: .medium))
                        Text(kind.explanation)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Button(L("Open Settings", "打开设置")) {
                        appState.onPermissionOpen?(kind)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            }

            HStack {
                Text(L("Checking automatically...", "自动检测中..."))
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                Spacer()
                Button(L("Cancel", "取消")) {
                    appState.onCancel?()
                }
                .buttonStyle(.borderless)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(width: 380)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
        )
    }

    var missingColiView: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 16))
                    .foregroundStyle(.orange)
                    .frame(width: 24)

                VStack(alignment: .leading, spacing: 2) {
                    Text(L("Node.js Required", "需要 Node.js"))
                        .font(.system(size: 13, weight: .medium))
                    Text(L("Install Node.js first, then OpenTypeNo will set up automatically.", "请先安装 Node.js，OpenTypeNo 将自动配置。"))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }

            HStack(spacing: 8) {
                Text("https://nodejs.org")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 36)

                Button(action: {
                    if let url = URL(string: "https://nodejs.org") {
                        NSWorkspace.shared.open(url)
                    }
                }) {
                    Image(systemName: "arrow.up.right.square")
                        .font(.system(size: 10))
                }
                .buttonStyle(.borderless)
                .help("Open nodejs.org")
            }

            HStack {
                Text(L("Checking automatically...", "自动检测中..."))
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                Spacer()
                Button(L("Cancel", "取消")) {
                    appState.onCancel?()
                }
                .buttonStyle(.borderless)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(width: 400)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
        )
    }

    func installingColiView(message: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 24)

                VStack(alignment: .leading, spacing: 2) {
                    Text(L("Setting up speech engine", "配置语音引擎"))
                        .font(.system(size: 13, weight: .medium))
                    Text(message)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }
        }
        .padding(16)
        .frame(width: 400)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
        )
    }
}

// MARK: - Update Service

final class UpdateService: @unchecked Sendable {
    static let repoOwner = "vivilin-ai"
    static let repoName = "OpenTypeNo"
    static let assetName = "OpenTypeNo.app.zip"

    struct ReleaseInfo {
        let version: String
        let downloadURL: URL
    }

    enum CheckResult {
        case updateAvailable(ReleaseInfo)
        case upToDate
        case rateLimited
        case failed
    }

    func checkForUpdate() async -> ReleaseInfo? {
        switch await checkForUpdateDetailed() {
        case .updateAvailable(let info): return info
        default: return nil
        }
    }

    func checkForUpdateDetailed() async -> CheckResult {
        guard let url = URL(string: "https://api.github.com/repos/\(Self.repoOwner)/\(Self.repoName)/releases/latest") else {
            return .failed
        }

        do {
            var request = URLRequest(url: url)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("OpenTypeNo/\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0")", forHTTPHeaderField: "User-Agent")
            let (data, _) = try await URLSession.shared.data(for: request)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return .failed
            }

            // GitHub rate limit error
            if json["message"] as? String != nil && json["tag_name"] == nil {
                return .rateLimited
            }

            guard let tagName = json["tag_name"] as? String,
                  let assets = json["assets"] as? [[String: Any]] else {
                return .failed
            }

            let remoteVersion = tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName
            let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"

            guard Self.isNewer(remote: remoteVersion, current: currentVersion) else {
                return .upToDate
            }

            guard let asset = assets.first(where: { ($0["name"] as? String) == Self.assetName }),
                  let downloadURLString = asset["browser_download_url"] as? String,
                  let downloadURL = URL(string: downloadURLString) else {
                return .failed
            }

            return .updateAvailable(ReleaseInfo(version: remoteVersion, downloadURL: downloadURL))
        } catch {
            return .failed
        }
    }

    func downloadAndInstall(from downloadURL: URL, onProgress: @MainActor @Sendable (String) -> Void) async throws {
        await onProgress(L("Downloading update...", "下载更新..."))

        // Download zip to temp
        let (zipURL, _) = try await URLSession.shared.download(from: downloadURL)
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("OpenTypeNo-update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let zipDest = tempDir.appendingPathComponent(Self.assetName)
        if FileManager.default.fileExists(atPath: zipDest.path) {
            try FileManager.default.removeItem(at: zipDest)
        }
        try FileManager.default.moveItem(at: zipURL, to: zipDest)

        await onProgress(L("Installing update...", "安装更新..."))

        // Use ditto --noqtn to unzip the app bundle — ditto is the macOS-native tool
        // for copying app bundles and --noqtn prevents quarantine from being propagated
        // to the extracted app (unlike /usr/bin/unzip which inherits quarantine).
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-x", "-k", "--noqtn", zipDest.path, tempDir.path]
        ditto.standardOutput = FileHandle.nullDevice
        ditto.standardError = FileHandle.nullDevice
        try ditto.run()
        ditto.waitUntilExit()

        guard ditto.terminationStatus == 0 else {
            throw UpdateError.unzipFailed
        }

        let newAppURL = tempDir.appendingPathComponent("OpenTypeNo.app")
        guard FileManager.default.fileExists(atPath: newAppURL.path) else {
            throw UpdateError.appNotFound
        }

        // Belt-and-suspenders: also remove quarantine recursively from the extracted app
        let xattr = Process()
        xattr.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        xattr.arguments = ["-rd", "com.apple.quarantine", newAppURL.path]
        xattr.standardOutput = FileHandle.nullDevice
        xattr.standardError = FileHandle.nullDevice
        try? xattr.run()
        xattr.waitUntilExit()

        // Replace current app
        let currentAppURL = Bundle.main.bundleURL
        let appParent = currentAppURL.deletingLastPathComponent()
        let backupURL = appParent.appendingPathComponent("OpenTypeNo.app.bak")

        // Remove old backup if exists
        if FileManager.default.fileExists(atPath: backupURL.path) {
            try FileManager.default.removeItem(at: backupURL)
        }

        // Move current → backup
        try FileManager.default.moveItem(at: currentAppURL, to: backupURL)

        // Move new → current
        do {
            try FileManager.default.moveItem(at: newAppURL, to: currentAppURL)
        } catch {
            // Rollback if move fails
            try? FileManager.default.moveItem(at: backupURL, to: currentAppURL)
            throw UpdateError.replaceFailed
        }

        // Remove quarantine from the final location AFTER the move.
        // Some macOS versions re-add quarantine during FileManager.moveItem;
        // cleaning here ensures the relocated app is trusted when opened.
        let xattrFinal = Process()
        xattrFinal.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        xattrFinal.arguments = ["-cr", currentAppURL.path]   // -c clears all xattrs, -r recursive
        xattrFinal.standardOutput = FileHandle.nullDevice
        xattrFinal.standardError = FileHandle.nullDevice
        try? xattrFinal.run()
        xattrFinal.waitUntilExit()

        // Clean up backup and temp
        try? FileManager.default.removeItem(at: backupURL)
        try? FileManager.default.removeItem(at: tempDir)

        await onProgress("Restarting...")

        // Relaunch: strip quarantine one final time right before open so
        // any attribute reapplied between here and the actual launch is cleared.
        let appPath = currentAppURL.path
        let script = Process()
        script.executableURL = URL(fileURLWithPath: "/bin/sh")
        script.arguments = ["-c", "sleep 1 && xattr -cr \"\(appPath)\" && open \"\(appPath)\""]
        try script.run()

        await MainActor.run {
            NSApp.terminate(nil)
        }
    }

    private static func isNewer(remote: String, current: String) -> Bool {
        let r = remote.split(separator: ".").compactMap { Int($0) }
        let c = current.split(separator: ".").compactMap { Int($0) }
        for i in 0..<max(r.count, c.count) {
            let rv = i < r.count ? r[i] : 0
            let cv = i < c.count ? c[i] : 0
            if rv > cv { return true }
            if rv < cv { return false }
        }
        return false
    }
}

enum UpdateError: LocalizedError {
    case unzipFailed
    case appNotFound
    case replaceFailed

    var errorDescription: String? {
        switch self {
        case .unzipFailed: "Failed to unzip update"
        case .appNotFound: "Update package is invalid"
        case .replaceFailed: "Failed to replace app"
        }
    }
}

// MARK: - Settings

enum ASRMode: String, Codable, CaseIterable {
    case local = "Local"
    case cloud = "Cloud"

    var label: String {
        switch self {
        case .local: L("Local (coli)", "本地 (coli)")
        case .cloud: L("Cloud (OpenAI Whisper)", "云端 (OpenAI Whisper)")
        }
    }
}

enum LLMProvider: String, Codable, CaseIterable {
    case deepseek = "DeepSeek"
    case kimi     = "Kimi"
    case custom   = "Custom"

    var label: String {
        switch self {
        case .custom: L("Custom (OpenAI-compatible)", "自定义 (OpenAI 兼容)")
        default: rawValue
        }
    }

    var defaultBaseURL: String {
        switch self {
        case .deepseek: "https://api.deepseek.com/v1/chat/completions"
        case .kimi:     "https://api.moonshot.cn/v1/chat/completions"
        case .custom:   ""
        }
    }

    var defaultModel: String {
        switch self {
        case .deepseek: "deepseek-chat"
        case .kimi:     "moonshot-v1-8k"
        case .custom:   "deepseek-chat"
        }
    }

    var baseURL: String {
        if self == .custom {
            let custom = UserDefaults.standard.customLLMBaseURL
            return custom.isEmpty ? defaultBaseURL : custom
        }
        return defaultBaseURL
    }

    var model: String {
        if self == .custom {
            let custom = UserDefaults.standard.customLLMModel
            return custom.isEmpty ? defaultModel : custom
        }
        return defaultModel
    }
}

extension UserDefaults {
    private static let asrModeKey               = "ai.marswave.opentypeno.asrMode"
    private static let openAIAPIKeyKey          = "ai.marswave.opentypeno.openAIAPIKey"
    private static let postProcessingEnabledKey = "ai.marswave.opentypeno.postProcessingEnabled"
    private static let llmProviderKey           = "ai.marswave.opentypeno.llmProvider"
    private static let llmAPIKeyKey             = "ai.marswave.opentypeno.llmAPIKey"

    var asrMode: ASRMode {
        get {
            guard let raw = string(forKey: Self.asrModeKey),
                  let v = ASRMode(rawValue: raw) else { return .local }
            return v
        }
        set { set(newValue.rawValue, forKey: Self.asrModeKey) }
    }

    var openAIAPIKey: String {
        get { string(forKey: Self.openAIAPIKeyKey) ?? "" }
        set { set(newValue, forKey: Self.openAIAPIKeyKey) }
    }

    var postProcessingEnabled: Bool {
        get { bool(forKey: Self.postProcessingEnabledKey) }
        set { set(newValue, forKey: Self.postProcessingEnabledKey) }
    }

    var llmProvider: LLMProvider {
        get {
            guard let raw = string(forKey: Self.llmProviderKey),
                  let v = LLMProvider(rawValue: raw) else { return .deepseek }
            return v
        }
        set { set(newValue.rawValue, forKey: Self.llmProviderKey) }
    }

    var llmAPIKey: String {
        get { string(forKey: Self.llmAPIKeyKey) ?? "" }
        set { set(newValue, forKey: Self.llmAPIKeyKey) }
    }

    private static let customLLMBaseURLKey = "ai.marswave.opentypeno.customLLMBaseURL"
    private static let customLLMModelKey   = "ai.marswave.opentypeno.customLLMModel"

    var customLLMBaseURL: String {
        get { string(forKey: Self.customLLMBaseURLKey) ?? "" }
        set { set(newValue, forKey: Self.customLLMBaseURLKey) }
    }

    var customLLMModel: String {
        get { string(forKey: Self.customLLMModelKey) ?? "" }
        set { set(newValue, forKey: Self.customLLMModelKey) }
    }
}

// MARK: - ASR Protocol

protocol ASRServiceProtocol: Sendable {
    func transcribe(fileURL: URL) async throws -> String
}

extension ColiASRService: ASRServiceProtocol {}

// MARK: - Cloud ASR Service (OpenAI Whisper)

final class CloudASRService: ASRServiceProtocol, @unchecked Sendable {
    func transcribe(fileURL: URL) async throws -> String {
        let apiKey = UserDefaults.standard.openAIAPIKey
        guard !apiKey.isEmpty else {
            throw OpenTypeNoError.transcriptionFailed(L(
                "OpenAI API Key not set. Please configure it in Settings.",
                "未设置 OpenAI API Key，请在设置中填写。"
            ))
        }

        guard let url = URL(string: "https://api.openai.com/v1/audio/transcriptions") else {
            throw OpenTypeNoError.transcriptionFailed("Invalid API URL")
        }

        let boundary = UUID().uuidString
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        let audioData = try Data(contentsOf: fileURL)
        var body = Data()

        func append(_ string: String) {
            if let data = string.data(using: .utf8) { body.append(data) }
        }

        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"model\"\r\n\r\n")
        append("whisper-1\r\n")

        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"language\"\r\n\r\n")
        append("zh\r\n")

        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"file\"; filename=\"audio.m4a\"\r\n")
        append("Content-Type: audio/m4a\r\n\r\n")
        body.append(audioData)
        append("\r\n")
        append("--\(boundary)--\r\n")

        request.httpBody = body

        let (data, response) = try await URLSession.shared.data(for: request)

        if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode != 200 {
            let msg = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])
                .flatMap { ($0["error"] as? [String: Any])?["message"] as? String }
                ?? "HTTP \(httpResponse.statusCode)"
            throw OpenTypeNoError.transcriptionFailed(msg)
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = json["text"] as? String else {
            throw OpenTypeNoError.transcriptionFailed(L("Failed to parse transcription response", "解析转录结果失败"))
        }

        return text
    }
}

// MARK: - Post Processing Service

final class PostProcessingService: @unchecked Sendable {
    func process(_ text: String) async throws -> String {
        let apiKey   = UserDefaults.standard.llmAPIKey
        let baseURL  = UserDefaults.standard.customLLMBaseURL
        let model    = UserDefaults.standard.customLLMModel
        guard !apiKey.isEmpty, !baseURL.isEmpty else { return text }

        guard let url = URL(string: baseURL) else { return text }

        let prompt = """
你是一个文字后处理助手。对以下语音转录文本进行：
1. 添加合适的标点符号
2. 删除语助词（嗯、啊、那个、就是、然后、这个等）
3. 纠正明显的错别字
只返回处理后的文本，不要解释，不要加引号。

原文：\(text)
"""

        let body: [String: Any] = [
            "model": model.isEmpty ? "deepseek-chat" : model,
            "messages": [["role": "user", "content": prompt]],
            "max_tokens": 2048,
            "temperature": 0.1
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else {
            return text
        }

        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Settings Window

extension Notification.Name {
    static let openSettings = Notification.Name("ai.marswave.opentypeno.openSettings")
}

@MainActor
final class SettingsWindowController: NSObject {
    private var window: NSWindow?

    func show() {
        if let existing = window, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let hosting = NSHostingView(rootView: SettingsView())
        hosting.frame = NSRect(x: 0, y: 0, width: 420, height: 340)

        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 340),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        win.title = L("OpenTypeNo Settings", "OpenTypeNo 设置")
        win.contentView = hosting
        win.center()
        win.isReleasedWhenClosed = false
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = win
    }
}

struct SettingsView: View {
    @State private var asrMode: ASRMode         = UserDefaults.standard.asrMode
    @State private var openAIKey: String        = UserDefaults.standard.openAIAPIKey
    @State private var postEnabled: Bool        = UserDefaults.standard.postProcessingEnabled
    @State private var llmProvider: LLMProvider = UserDefaults.standard.llmProvider
    @State private var llmKey: String           = UserDefaults.standard.llmAPIKey
    @State private var customBaseURL: String    = UserDefaults.standard.customLLMBaseURL
    @State private var customModel: String      = UserDefaults.standard.customLLMModel

    var body: some View {
        Form {
            Section(L("Transcription", "转录")) {
                Picker(L("Mode", "模式"), selection: $asrMode) {
                    ForEach(ASRMode.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .onChange(of: asrMode) { _, new in UserDefaults.standard.asrMode = new }

                if asrMode == .cloud {
                    SecureField("OpenAI API Key", text: $openAIKey)
                        .onChange(of: openAIKey) { _, new in UserDefaults.standard.openAIAPIKey = new }
                }
            }

            Section(L("Post-Processing", "后处理")) {
                Toggle(L("Enable (punctuation, cleanup, correction)", "启用（标点、去语助词、纠错）"), isOn: $postEnabled)
                    .onChange(of: postEnabled) { _, new in UserDefaults.standard.postProcessingEnabled = new }

                if postEnabled {
                    TextField(L("API Base URL", "API 地址"), text: $customBaseURL, prompt: Text("https://api.deepseek.com/v1/chat/completions"))
                        .onChange(of: customBaseURL) { _, new in UserDefaults.standard.customLLMBaseURL = new }
                        .textFieldStyle(.roundedBorder)

                    TextField(L("Model Name", "模型名称"), text: $customModel, prompt: Text("deepseek-chat"))
                        .onChange(of: customModel) { _, new in UserDefaults.standard.customLLMModel = new }
                        .textFieldStyle(.roundedBorder)

                    SecureField("API Key", text: $llmKey)
                        .onChange(of: llmKey) { _, new in UserDefaults.standard.llmAPIKey = new }
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(width: 420)
    }
}

// MARK: - Entry Point

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
