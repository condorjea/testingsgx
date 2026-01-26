import SwiftUI
import AVFoundation
import Vision

@main
struct EyeFollowApp: App {
    var body: some Scene {
        WindowGroup { ContentView() }
    }
}

struct ContentView: View {
    @StateObject private var tracker = FaceTracker()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            // Debug yüz kutusu
            FaceBoxOverlay(faceBoxNormalized: tracker.faceBoxNormalized)
                .ignoresSafeArea()

            PupilsFixedIrisView(
                faceBoxNormalized: tracker.faceBoxNormalized,
                hasFace: tracker.hasFace
            )
            .ignoresSafeArea()
        }
        .onAppear { tracker.start() }
        .onDisappear { tracker.stop() }
    }
}

// MARK: - Fixed iris size, iris moves slightly, pupil moves more

struct PupilsFixedIrisView: View {
    let faceBoxNormalized: CGRect?
    let hasFace: Bool

    @State private var displayedCenter: CGPoint? = nil
    @State private var displayedFaceWidthN: CGFloat = 0

    private let deadbandPx: CGFloat = 10
    private let smoothingPos: CGFloat = 0.18
    private let smoothingSize: CGFloat = 0.20

    // Gözler arası mesafe sabit
    private let interEyeDistancePx: CGFloat = 240

    // Iris boyutu sabit
    private let irisSizePx: CGFloat = 140

    // Sadece siyah pupil ölçeklenecek (yakın/uzak)
    private let pupilMinRatio: CGFloat = 0.34  // iris'in yüzdesi
    private let pupilMaxRatio: CGFloat = 0.58

    // Yakınlık faceCenterPx (bb.width)
    private let faceWMin: CGFloat = 0.16
    private let faceWMax: CGFloat = 0.45

    // Gerçekçilik için hareket katsayıları
    private let irisMaxOffsetPx: CGFloat = 8
    private let pupilEdgePadding: CGFloat = 4
    private let verticalGain: CGFloat = 0.6
    private let headFollowGain: CGFloat = 0.25

    var body: some View {
        GeometryReader { geo in
            let W = geo.size.width
            let H = geo.size.height

            let faceCenterPx: CGPoint? = {
                guard hasFace, let bb = faceBoxNormalized else { return nil }
                let cx = bb.midX
                let cy = 1.0 - bb.midY
                let x = cx * W
                return CGPoint(x: (W - x), y: cy * H) // yatay eksen tersini düzelt
            }()

            let faceWidthN: CGFloat? = {
                guard hasFace, let bb = faceBoxNormalized else { return nil }
                return bb.width
            }()

            Color.clear
                .onChange(of: faceCenterPx?.x ?? -1) { _ in updateDisplayed(center: faceCenterPx, faceWidthN: faceWidthN) }
                .onChange(of: faceCenterPx?.y ?? -1) { _ in updateDisplayed(center: faceCenterPx, faceWidthN: faceWidthN) }
                .onChange(of: faceWidthN ?? -1) { _ in updateDisplayed(center: faceCenterPx, faceWidthN: faceWidthN) }

            let screenCenter = CGPoint(x: W / 2, y: H / 2)
            let faceCenter = displayedCenter ?? screenCenter
            let headCenter = CGPoint(
                x: screenCenter.x + (faceCenter.x - screenCenter.x) * headFollowGain,
                y: screenCenter.y + (faceCenter.y - screenCenter.y) * headFollowGain
            )

            let nx = clamp((faceCenter.x - screenCenter.x) / (W / 2), -1, 1)
            let ny = clamp((faceCenter.y - screenCenter.y) / (H / 2), -1, 1) * verticalGain
            let gaze = CGPoint(x: nx, y: ny)

            let irisOffset = CGPoint(
                x: gaze.x * irisMaxOffsetPx,
                y: gaze.y * irisMaxOffsetPx
            )

            // yakınlık -> pupil ratio (siyah iç kısım büyür/küçülür)
            let t = normalize(displayedFaceWidthN, faceWMin, faceWMax)
            let pupilRatio = lerp(pupilMinRatio, pupilMaxRatio, t)

            let irisRadius = irisSizePx / 2
            let pupilRadius = (irisSizePx * pupilRatio) / 2
            let maxPupilOffset = max(0, irisRadius - pupilRadius - pupilEdgePadding)
            let pupilOffset = CGPoint(
                x: gaze.x * maxPupilOffset,
                y: gaze.y * maxPupilOffset
            )

            // sabit mesafe + az head hareketi
            let leftEye = CGPoint(x: headCenter.x - interEyeDistancePx / 2, y: headCenter.y)
            let rightEye = CGPoint(x: headCenter.x + interEyeDistancePx / 2, y: headCenter.y)

            FixedIrisPupil(
                irisSize: irisSizePx,
                pupilRatio: pupilRatio,
                irisOffset: irisOffset,
                pupilOffset: pupilOffset
            )
            .position(leftEye)
            .animation(.spring(response: 0.22, dampingFraction: 0.82), value: pupilRatio)

            FixedIrisPupil(
                irisSize: irisSizePx,
                pupilRatio: pupilRatio,
                irisOffset: irisOffset,
                pupilOffset: pupilOffset
            )
            .position(rightEye)
            .animation(.spring(response: 0.22, dampingFraction: 0.82), value: pupilRatio)
        }
    }

    private func updateDisplayed(center: CGPoint?, faceWidthN: CGFloat?) {
        guard let center, let faceWidthN else {
            displayedFaceWidthN += (0 - displayedFaceWidthN) * smoothingSize
            return
        }

        if displayedCenter == nil {
            displayedCenter = center
            displayedFaceWidthN = faceWidthN
            return
        }

        if let cur = displayedCenter {
            let dx = center.x - cur.x
            let dy = center.y - cur.y
            let dist = sqrt(dx * dx + dy * dy)
            if dist > deadbandPx {
                displayedCenter = CGPoint(
                    x: cur.x + dx * smoothingPos,
                    y: cur.y + dy * smoothingPos
                )
            }
        }

        displayedFaceWidthN += (faceWidthN - displayedFaceWidthN) * smoothingSize
    }

    private func clamp(_ v: CGFloat, _ a: CGFloat, _ b: CGFloat) -> CGFloat { min(max(v, a), b) }
    private func lerp(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat { a + (b - a) * t }
    private func normalize(_ v: CGFloat, _ minV: CGFloat, _ maxV: CGFloat) -> CGFloat {
        if maxV <= minV { return 0 }
        return clamp((v - minV) / (maxV - minV), 0, 1)
    }
}

struct FixedIrisPupil: View {
    let irisSize: CGFloat
    let pupilRatio: CGFloat   // 0..1 relative (we use as fraction of iris)
    let irisOffset: CGPoint
    let pupilOffset: CGPoint

    var body: some View {
        let irisDark = Color(red: 0.45, green: 0.02, blue: 0.02)
        let irisMid = Color(red: 0.8, green: 0.05, blue: 0.05)
        let irisBright = Color(red: 0.95, green: 0.1, blue: 0.1)
        let outerRingWidth = irisSize * 0.06
        let innerRingWidth = irisSize * 0.03
        let innerRingScale = min(0.65, max(0.42, pupilRatio + 0.12))
        let tickCount = 36
        let tickBaseRadius = irisSize * 0.18
        let tickWidth = irisSize * 0.012
        let tickLong = irisSize * 0.12
        let tickShort = irisSize * 0.08
        let tomoeRadius = irisSize * 0.26
        let tomoeRotation = Angle.degrees(0)

        ZStack {
            ZStack {
                // Sharingan iris base
                Circle()
                    .fill(
                        RadialGradient(
                            gradient: Gradient(colors: [irisBright, irisMid, irisDark]),
                            center: .center,
                            startRadius: 0,
                            endRadius: irisSize * 0.52
                        )
                    )
                    .frame(width: irisSize, height: irisSize)

                ForEach(0..<tickCount, id: \.self) { i in
                    let isLong = i % 2 == 0
                    Capsule()
                        .fill(Color.black.opacity(isLong ? 0.55 : 0.35))
                        .frame(width: tickWidth, height: isLong ? tickLong : tickShort)
                        .offset(y: -tickBaseRadius)
                        .rotationEffect(
                            Angle.degrees(Double(i) * (360.0 / Double(tickCount)))
                        )
                }

                Circle()
                    .strokeBorder(Color.black.opacity(0.85), lineWidth: innerRingWidth)
                    .frame(width: irisSize, height: irisSize)
                    .scaleEffect(innerRingScale)

                ForEach(0..<3, id: \.self) { i in
                    Tomoe(irisSize: irisSize, color: .black)
                        .offset(y: -tomoeRadius)
                        .rotationEffect(Angle.degrees(Double(i) * 120) + tomoeRotation)
                }

                Circle()
                    .strokeBorder(Color.black, lineWidth: outerRingWidth)
                    .frame(width: irisSize, height: irisSize)
            }
            .frame(width: irisSize, height: irisSize)
            .clipShape(Circle())
            .offset(x: irisOffset.x, y: irisOffset.y)

            // pupil daha fazla hareket eder
            Circle()
                .fill(Color.black)
                .frame(width: irisSize * pupilRatio, height: irisSize * pupilRatio)
                .offset(x: irisOffset.x + pupilOffset.x,
                        y: irisOffset.y + pupilOffset.y)

            // highlight pupil ile beraber kayar
            Circle()
                .fill(Color.white.opacity(0.85))
                .frame(width: irisSize * 0.18, height: irisSize * 0.18)
                .offset(
                    x: irisOffset.x + pupilOffset.x - irisSize * 0.18,
                    y: irisOffset.y + pupilOffset.y - irisSize * 0.18
                )
        }
    }
}

struct Tomoe: View {
    let irisSize: CGFloat
    let color: Color

    var body: some View {
        let headSize = irisSize * 0.14
        let tailWidth = irisSize * 0.1
        let tailHeight = irisSize * 0.28

        ZStack {
            Capsule()
                .fill(color)
                .frame(width: tailWidth, height: tailHeight)
                .offset(y: -irisSize * 0.01)

            Circle()
                .fill(color)
                .frame(width: headSize, height: headSize)
                .offset(y: -irisSize * 0.23)
        }
    }
}

// MARK: - Face box overlay (debug)

struct FaceBoxOverlay: View {
    let faceBoxNormalized: CGRect?

    var body: some View {
        GeometryReader { geo in
            if let bb = faceBoxNormalized {
                let w = bb.size.width * geo.size.width
                let h = bb.size.height * geo.size.height
                let x = bb.origin.x * geo.size.width
                let yFromBottom = bb.origin.y * geo.size.height
                let y = geo.size.height - yFromBottom - h

                Rectangle()
                    .stroke(Color.black, lineWidth: 3)
                    .frame(width: w, height: h)
                    .position(x: x + w / 2, y: y + h / 2)
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - FaceTracker (Vision)

final class FaceTracker: NSObject, ObservableObject {
    let session = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let visionQueue = DispatchQueue(label: "vision.queue")

    @Published var faceBoxNormalized: CGRect? = nil
    @Published var hasFace: Bool = false

    func start() {
        configureSessionIfNeeded()
        session.startRunning()
    }

    func stop() { session.stopRunning() }

    private func configureSessionIfNeeded() {
        guard session.inputs.isEmpty else { return }

        session.beginConfiguration()
        session.sessionPreset = .high

        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else {
            session.commitConfiguration()
            return
        }
        session.addInput(input)

        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(self, queue: visionQueue)

        guard session.canAddOutput(videoOutput) else {
            session.commitConfiguration()
            return
        }
        session.addOutput(videoOutput)

        if let conn = videoOutput.connection(with: .video) {
            conn.videoOrientation = .portrait
            conn.isVideoMirrored = true
        }

        session.commitConfiguration()
    }
}

extension FaceTracker: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let request = VNDetectFaceRectanglesRequest { [weak self] req, err in
            guard let self else { return }
            guard err == nil else { return }

            let faces = (req.results as? [VNFaceObservation]) ?? []
            guard let face = faces.first else {
                DispatchQueue.main.async {
                    self.faceBoxNormalized = nil
                    self.hasFace = false
                }
                return
            }

            DispatchQueue.main.async {
                self.faceBoxNormalized = face.boundingBox
                self.hasFace = true
            }
        }

        let handler = VNImageRequestHandler(
            cvPixelBuffer: pixelBuffer,
            orientation: .rightMirrored,
            options: [:]
        )

        do { try handler.perform([request]) } catch { }
    }
}
