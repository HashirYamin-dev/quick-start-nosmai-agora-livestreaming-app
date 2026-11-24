import UIKit
import AVFoundation
import AgoraRtcKit

/// Host:     Nosmai owns the camera -> filtered CVPixelBuffers -> Agora external video source.
/// Audience: plain Agora subscriber rendering the host's stream.
final class LiveViewController: UIViewController {
    enum Role { case host, audience }

    private let role: Role
    private let config: DemoConfig
    private var isHost: Bool { role == .host }

    private var rtc: AgoraRtcEngineKit?
    private let frameQueue = DispatchQueue(label: "com.nosmai.agora.demo.frames")
    private var cameraRunning = false
    private var stopped = false
    /// Read from Nosmai's processing thread and the frame queue.
    private let pushLock = NSLock()
    private var _pushing = false
    private var pushing: Bool {
        get { pushLock.lock(); defer { pushLock.unlock() }; return _pushing }
        set { pushLock.lock(); _pushing = newValue; pushLock.unlock() }
    }

    private var liveStatus = "Preparing…"
    private var toastToken = 0

    private let videoView = UIView()
    private let statusLabel = PaddedLabel()
    private let fpsLabel = PaddedLabel()
    /// Host: frames handed to Agora since the last tick. Guarded by pushLock.
    private var framesSinceTick = 0
    private var fpsTimer: Timer?
    private let controls = UIStackView()
    private let effectsPanel = EffectsPanelView()

    init(role: Role, config: DemoConfig) {
        self.role = role
        self.config = config
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        title = isHost ? "Live" : "Watching"
        view.backgroundColor = .black
        buildUI()
        setUpAgora()
        if isHost {
            requestPermissions { [weak self] in self?.startNosmaiCamera() }
        } else {
            joinChannel()
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        UIApplication.shared.isIdleTimerDisabled = true
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        UIApplication.shared.isIdleTimerDisabled = false
        if isMovingFromParent || isBeingDismissed { stopSession() }
    }

    // MARK: - UI

    private func buildUI() {
        videoView.backgroundColor = .black
        videoView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(videoView)

        statusLabel.text = "Preparing…"
        statusLabel.textColor = .white
        statusLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        statusLabel.backgroundColor = UIColor.black.withAlphaComponent(0.55)
        statusLabel.layer.cornerRadius = 10
        statusLabel.clipsToBounds = true
        statusLabel.numberOfLines = 2
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(statusLabel)

        fpsLabel.text = "-- FPS"
        fpsLabel.textColor = .systemGreen
        fpsLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .bold)
        fpsLabel.backgroundColor = UIColor.black.withAlphaComponent(0.55)
        fpsLabel.layer.cornerRadius = 10
        fpsLabel.clipsToBounds = true
        fpsLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(fpsLabel)

        controls.axis = .vertical
        controls.spacing = 10
        controls.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(controls)

        if isHost {
            effectsPanel.onStatus = { [weak self] text in self?.showToast(text) }
            controls.addArrangedSubview(effectsPanel)
        }

        let buttons = UIStackView()
        buttons.axis = .horizontal
        buttons.spacing = 12
        buttons.distribution = .fillEqually
        if isHost {
            buttons.addArrangedSubview(makeButton(title: "Flip", color: .darkGray, action: #selector(flipCamera)))
            buttons.addArrangedSubview(makeButton(title: "Effects", color: .systemPink, action: #selector(toggleEffects)))
        }
        buttons.addArrangedSubview(makeButton(title: isHost ? "End Live" : "Leave", color: .systemRed, action: #selector(close)))
        buttons.heightAnchor.constraint(equalToConstant: 48).isActive = true
        controls.addArrangedSubview(buttons)

        let safe = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            videoView.topAnchor.constraint(equalTo: view.topAnchor),
            videoView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            videoView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            videoView.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            statusLabel.topAnchor.constraint(equalTo: safe.topAnchor, constant: 10),
            statusLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            fpsLabel.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 6),
            fpsLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            statusLabel.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 16),

            controls.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            controls.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            controls.bottomAnchor.constraint(equalTo: safe.bottomAnchor, constant: -12),
        ])
    }

    private func makeButton(title: String, color: UIColor, action: Selector) -> UIButton {
        let button = UIButton(type: .system)
        button.setTitle(title, for: .normal)
        button.setTitleColor(.white, for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 16, weight: .semibold)
        button.backgroundColor = color
        button.layer.cornerRadius = 12
        button.addTarget(self, action: action, for: .touchUpInside)
        return button
    }

    private func setStatus(_ text: String) {
        DispatchQueue.main.async {
            self.liveStatus = text
            self.statusLabel.text = text
        }
    }

    /// Briefly shows effect feedback in the status pill, then restores the live status.
    private func showToast(_ text: String) {
        toastToken += 1
        let token = toastToken
        statusLabel.text = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            guard let self, self.toastToken == token else { return }
            self.statusLabel.text = self.liveStatus
        }
    }

    // MARK: - Agora

    private func setUpAgora() {
        let engine = AgoraRtcEngineKit.sharedEngine(withAppId: config.agoraAppID, delegate: self)
        engine.setChannelProfile(.liveBroadcasting)
        engine.setClientRole(isHost ? .broadcaster : .audience)
        engine.enableVideo()
        engine.enableAudio()
        if isHost {
            // Nosmai owns the camera, so Agora must take frames from us.
            // This has to be configured before joining the channel.
            engine.setExternalVideoSource(true, useTexture: true, sourceType: .videoFrame)
            let encoder = AgoraVideoEncoderConfiguration(size: CGSize(width: 720, height: 1280),
                                                         frameRate: AgoraVideoFrameRate.fps30.rawValue,
                                                         bitrate: AgoraVideoBitrateStandard,
                                                         orientationMode: .fixedPortrait,
                                                         mirrorMode: .disabled)
            engine.setVideoEncoderConfiguration(encoder)
        }
        rtc = engine
    }

    private func joinChannel() {
        guard let rtc else { return }
        let options = AgoraRtcChannelMediaOptions()
        options.clientRoleType = isHost ? .broadcaster : .audience
        options.publishCameraTrack = false
        options.publishCustomVideoTrack = isHost
        options.publishMicrophoneTrack = isHost
        options.autoSubscribeVideo = !isHost
        options.autoSubscribeAudio = !isHost

        let result = rtc.joinChannel(byToken: config.token, channelId: config.channel, uid: 0, mediaOptions: options)
        setStatus(result == 0 ? "Joining \(config.channel)…" : "Agora join failed (\(result))")
    }

    // MARK: - Nosmai (host only)

    private func requestPermissions(then start: @escaping () -> Void) {
        AVCaptureDevice.requestAccess(for: .video) { [weak self] camera in
            guard camera else { self?.setStatus("Camera permission denied"); return }
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] mic in
                guard mic else { self?.setStatus("Microphone permission denied"); return }
                DispatchQueue.main.async(execute: start)
            }
        }
    }

    private func startNosmaiCamera() {
        guard !stopped else { return }
        setStatus("Starting Nosmai…")
        NosmaiCore.shared().initialize(withAPIKey: config.nosmaiAPIKey) { [weak self] success, error in
            DispatchQueue.main.async {
                guard let self, !self.stopped else { return }
                guard success else {
                    self.setStatus("Nosmai init failed: \(error?.localizedDescription ?? "unknown")")
                    return
                }
                guard let camera = NosmaiCore.shared().camera else {
                    self.setStatus("Nosmai camera unavailable")
                    return
                }
                let cameraConfig = NosmaiCameraConfig()
                cameraConfig.position = .front
                cameraConfig.sessionPreset = AVCaptureSession.Preset.hd1280x720.rawValue
                cameraConfig.frameRate = 30
                camera.updateConfiguration(cameraConfig)
                camera.attach(to: self.videoView)

                guard camera.startCapture() else {
                    self.setStatus("Nosmai camera failed to start")
                    return
                }
                // Required for beauty / filters to render.
                NosmaiSDK.sharedInstance()?.startProcessing()
                self.cameraRunning = true
                self.effectsPanel.nosmaiReady()
                self.joinChannel()
            }
        }
    }

    /// Forward every filtered frame from Nosmai to Agora.
    private func startPushingFrames() {
        guard cameraRunning, !pushing else { return }
        pushing = true
        // Host FPS = filtered frames Nosmai actually delivers to Agora each second.
        fpsTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.pushLock.lock()
            let frames = self.framesSinceTick
            self.framesSinceTick = 0
            self.pushLock.unlock()
            self.fpsLabel.text = "\(frames) FPS"
        }
        NosmaiCore.shared().liveFrameStreamCallback = { [weak self] pixelBuffer, timestamp in
            guard let self, self.pushing else { return }
            self.pushLock.lock()
            self.framesSinceTick += 1
            self.pushLock.unlock()
            // Swift retains the buffer for the lifetime of the closure below.
            self.frameQueue.async {
                guard self.pushing, let rtc = self.rtc else { return }
                let frame = AgoraVideoFrame()
                frame.format = 12 // CVPixelBuffer
                frame.textureBuf = pixelBuffer
                frame.time = CMTime(seconds: timestamp, preferredTimescale: 1000)
                rtc.pushExternalVideoFrame(frame, videoTrackId: 0)
            }
        }
    }

    // MARK: - Actions

    @objc private func toggleEffects() {
        UIView.animate(withDuration: 0.2) {
            self.effectsPanel.isHidden.toggle()
            self.effectsPanel.alpha = self.effectsPanel.isHidden ? 0 : 1
        }
    }

    @objc private func flipCamera() {
        guard cameraRunning else { return }
        _ = NosmaiCore.shared().camera?.switch()
    }

    @objc private func close() {
        navigationController?.popViewController(animated: true)
    }

    private func stopSession() {
        guard !stopped else { return }
        stopped = true
        fpsTimer?.invalidate()
        fpsTimer = nil
        pushing = false
        if isHost {
            NosmaiCore.shared().liveFrameStreamCallback = nil
            frameQueue.sync {} // drain frames already queued before tearing Agora down
        }
        rtc?.leaveChannel(nil)
        rtc = nil
        AgoraRtcEngineKit.destroy()

        if cameraRunning {
            cameraRunning = false
            let core = NosmaiCore.shared()
            core.effects?.clearAll() // the SDK is a singleton; don't leak effects into the next session
            core.camera?.stopCapture()
            core.camera?.detachFromView()
            core.cleanup()
        }
    }
}

// MARK: - AgoraRtcEngineDelegate

extension LiveViewController: AgoraRtcEngineDelegate {
    func rtcEngine(_ engine: AgoraRtcEngineKit, didJoinChannel channel: String, withUid uid: UInt, elapsed: Int) {
        if isHost {
            setStatus("🔴 LIVE on \(channel)")
            DispatchQueue.main.async { self.startPushingFrames() }
        } else {
            setStatus("Connected — waiting for host")
        }
    }

    func rtcEngine(_ engine: AgoraRtcEngineKit, didJoinedOfUid uid: UInt, elapsed: Int) {
        // Only broadcasters trigger this callback, so for the audience `uid` is the host.
        guard !isHost else { return }
        let canvas = AgoraRtcVideoCanvas()
        canvas.uid = uid
        canvas.view = videoView
        canvas.renderMode = .hidden
        engine.setupRemoteVideo(canvas)
        setStatus("🔴 Watching host")
    }

    /// Audience FPS = frames actually rendered from the host's stream (reported every 2s).
    func rtcEngine(_ engine: AgoraRtcEngineKit, remoteVideoStats stats: AgoraRtcRemoteVideoStats) {
        guard !isHost else { return }
        DispatchQueue.main.async { self.fpsLabel.text = "\(stats.rendererOutputFrameRate) FPS" }
    }

    func rtcEngine(_ engine: AgoraRtcEngineKit, didOfflineOfUid uid: UInt, reason: AgoraUserOfflineReason) {
        if !isHost { setStatus("Host left the stream") }
    }

    func rtcEngine(_ engine: AgoraRtcEngineKit, didOccurError errorCode: AgoraErrorCode) {
        setStatus("Agora error \(errorCode.rawValue) — check AppID / token / channel")
    }

    func rtcEngine(_ engine: AgoraRtcEngineKit, tokenPrivilegeWillExpire token: String) {
        setStatus("Agora token is about to expire")
    }
}

private final class PaddedLabel: UILabel {
    private let insets = UIEdgeInsets(top: 6, left: 12, bottom: 6, right: 12)

    override func drawText(in rect: CGRect) {
        super.drawText(in: rect.inset(by: insets))
    }

    override var intrinsicContentSize: CGSize {
        let size = super.intrinsicContentSize
        return CGSize(width: size.width + insets.left + insets.right,
                      height: size.height + insets.top + insets.bottom)
    }
}
