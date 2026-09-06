import SwiftUI
@preconcurrency import AVFoundation
import UIKit

struct QRScannerView: UIViewControllerRepresentable {
    let onCode: @MainActor (String) -> Void
    func makeUIViewController(context: Context) -> QRScannerController {
        QRScannerController(onCode: onCode)
    }
    func updateUIViewController(_ uiViewController: QRScannerController, context: Context) {}
    static func dismantleUIViewController(_ uiViewController: QRScannerController, coordinator: ()) {
        uiViewController.stop()
    }
}

@MainActor final class QRScannerController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    private let session = AVCaptureSession()
    private let workQueue = DispatchQueue(label: "StreamTranslate.phone.camera")
    private let onCode: @MainActor (String) -> Void
    private var preview: AVCaptureVideoPreviewLayer?
    private var delivered = false
    private var stopped = false

    init(onCode: @escaping @MainActor (String) -> Void) {
        self.onCode = onCode
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        Task { [weak self] in
            let allowed = await AVCaptureDevice.requestAccess(for: .video)
            guard let self, !self.stopped else { return }
            guard allowed else { self.showMessage("请在系统设置允许相机，或返回粘贴配对链接。"); return }
            self.configure()
        }
    }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        preview?.frame = view.bounds
    }
    private func configure() {
        guard let camera = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: camera), session.canAddInput(input) else {
            showMessage("无法使用相机，请返回粘贴配对链接。"); return
        }
        session.addInput(input)
        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else { showMessage("无法扫描二维码。"); return }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        output.metadataObjectTypes = [.qr]
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        layer.frame = view.bounds
        view.layer.addSublayer(layer)
        preview = layer
        let session = session
        workQueue.async { session.startRunning() }
    }
    nonisolated func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject],
                                    from connection: AVCaptureConnection) {
        guard let value = (metadataObjects.first as? AVMetadataMachineReadableCodeObject)?.stringValue,
              value.hasPrefix("streamtranslate://pair") else { return }
        Task { @MainActor [weak self] in
            guard let self, !self.delivered, !self.stopped else { return }
            self.delivered = true
            self.stop()
            self.onCode(value)
        }
    }
    func stop() {
        stopped = true
        let session = session
        workQueue.async { session.stopRunning() }
    }
    private func showMessage(_ message: String) {
        let label = UILabel()
        label.text = message
        label.textColor = .white
        label.numberOfLines = 0
        label.textAlignment = .center
        label.frame = view.bounds.insetBy(dx: 30, dy: 100)
        label.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(label)
    }
}
