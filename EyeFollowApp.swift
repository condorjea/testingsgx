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

            VStack {
                HStack(spacing: 12) {
                    Button {
                        tracker.requestEnrollment()
                    } label: {
                        Text(tracker.isEnrolled ? "Yüz Kaydedildi" : "Yüzümü Kaydet")
                            .foregroundColor(.white)
                    }

                    Button {
                        tracker.clearEnrollment()
                    } label: {
                        Text("Sıfırla")
                            .foregroundColor(.white)
                    }
                    .opacity(tracker.isEnrolled ? 1 : 0.4)
                    .disabled(!tracker.isEnrolled)
                }
                .font(.footnote.weight(.semibold))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.black.opacity(0.6))
                .clipShape(Capsule())
                .overlay(
                    Capsule().stroke(Color.white.opacity(0.2), lineWidth: 1)
                )
                Spacer()
            }
            .padding(.top, 12)
            .padding(.leading, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
    @State private var glowPulse: CGFloat = 0
    @State private var isPulsing: Bool = false

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
    private let pupilEdgePadding: CGFloat = 4
    private let verticalGain: CGFloat = 0.6
    private let headFollowGain: CGFloat = 0.25
    private let eyeWidthScale: CGFloat = 1.6
    private let eyeHeightScale: CGFloat = 0.65
    private let eyeSlantScale: CGFloat = 0.12
    private let irisOffsetScale: CGFloat = 0.08
    private let pulseDuration: Double = 2.6

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

            let eyeWidth = irisSizePx * eyeWidthScale
            let eyeHeight = irisSizePx * eyeHeightScale
            let eyeSize = CGSize(width: eyeWidth, height: eyeHeight)
            let eyeSlant = eyeHeight * eyeSlantScale

            let irisOffset = CGPoint(
                x: gaze.x * eyeHeight * irisOffsetScale,
                y: gaze.y * eyeHeight * irisOffsetScale
            )

            // yakınlık -> pupil ratio (siyah iç kısım büyür/küçülür)
            let t = normalize(displayedFaceWidthN, faceWMin, faceWMax)
            let pupilRatio = lerp(pupilMinRatio, pupilMaxRatio, t)

            let pupilSize = eyeHeight * pupilRatio
            let maxPupilOffsetX = max(0, eyeWidth / 2 - pupilSize / 2 - pupilEdgePadding)
            let maxPupilOffsetY = max(0, eyeHeight / 2 - pupilSize / 2 - pupilEdgePadding)
            let pupilOffset = CGPoint(
                x: gaze.x * maxPupilOffsetX,
                y: gaze.y * maxPupilOffsetY
            )

            // sabit mesafe + az head hareketi
            let leftEye = CGPoint(x: headCenter.x - interEyeDistancePx / 2, y: headCenter.y)
            let rightEye = CGPoint(x: headCenter.x + interEyeDistancePx / 2, y: headCenter.y)

            FixedIrisPupil(
                eyeSize: eyeSize,
                pupilRatio: pupilRatio,
                irisOffset: irisOffset,
                pupilOffset: pupilOffset,
                slant: -eyeSlant,
                glowPulse: glowPulse
            )
            .position(leftEye)
            .animation(.spring(response: 0.22, dampingFraction: 0.82), value: pupilRatio)

            FixedIrisPupil(
                eyeSize: eyeSize,
                pupilRatio: pupilRatio,
                irisOffset: irisOffset,
                pupilOffset: pupilOffset,
                slant: eyeSlant,
                glowPulse: glowPulse
            )
            .position(rightEye)
            .animation(.spring(response: 0.22, dampingFraction: 0.82), value: pupilRatio)
        }
        .onAppear { startPulse() }
        .onDisappear { stopPulse() }
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

    private func startPulse() {
        guard !isPulsing else { return }
        isPulsing = true
        glowPulse = 0
        withAnimation(.easeInOut(duration: pulseDuration).repeatForever(autoreverses: true)) {
            glowPulse = 1
        }
    }

    private func stopPulse() {
        isPulsing = false
        glowPulse = 0
    }
}

struct FixedIrisPupil: View {
    let eyeSize: CGSize
    let pupilRatio: CGFloat   // 0..1 relative (we use as fraction of iris)
    let irisOffset: CGPoint
    let pupilOffset: CGPoint
    let slant: CGFloat
    let glowPulse: CGFloat

    var body: some View {
        let baseColor = Color(red: 0.08, green: 0.6, blue: 1.0)
        let brightColor = Color(red: 0.25, green: 0.85, blue: 1.0)
        let glowColor = Color(red: 0.1, green: 0.5, blue: 1.0)
        let shape = EyeShape(slant: slant, openness: 0.85)
        let pupilSize = eyeSize.height * pupilRatio
        let highlightSize = pupilSize * 0.35
        let glowOpacity: CGFloat = 0.35 + 0.25 * glowPulse
        let strokeOpacity: CGFloat = 0.8 + 0.2 * glowPulse
        let shadowOpacity: CGFloat = 0.6 + 0.4 * glowPulse

        ZStack {
            shape
                .fill(glowColor.opacity(Double(glowOpacity)))
                .frame(width: eyeSize.width, height: eyeSize.height)
                .blur(radius: 10 + 6 * glowPulse)

            shape
                .fill(
                    LinearGradient(
                        gradient: Gradient(colors: [brightColor, baseColor]),
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .frame(width: eyeSize.width, height: eyeSize.height)
                .overlay(
                    shape
                        .stroke(glowColor.opacity(Double(strokeOpacity)),
                                lineWidth: eyeSize.height * 0.08)
                )
                .shadow(color: glowColor.opacity(Double(shadowOpacity)),
                        radius: 10 + 8 * glowPulse)

            ZStack {
                Circle()
                    .fill(
                        RadialGradient(
                            gradient: Gradient(colors: [Color.white.opacity(0.35), Color.clear]),
                            center: .center,
                            startRadius: 0,
                            endRadius: eyeSize.height * 0.55
                        )
                    )
                    .frame(width: eyeSize.height * 0.9, height: eyeSize.height * 0.9)
                    .offset(x: irisOffset.x * 0.6, y: irisOffset.y * 0.6)

                Circle()
                    .fill(Color.black)
                    .frame(width: pupilSize, height: pupilSize)
                    .offset(x: irisOffset.x + pupilOffset.x,
                            y: irisOffset.y + pupilOffset.y)

                Circle()
                    .fill(Color.white.opacity(0.8))
                    .frame(width: highlightSize, height: highlightSize)
                    .offset(
                        x: irisOffset.x + pupilOffset.x - highlightSize * 0.6,
                        y: irisOffset.y + pupilOffset.y - highlightSize * 0.6
                    )
            }
            .frame(width: eyeSize.width, height: eyeSize.height)
            .mask(shape)
        }
        .frame(width: eyeSize.width, height: eyeSize.height)
    }
}

struct EyeShape: Shape {
    var slant: CGFloat
    var openness: CGFloat

    func path(in rect: CGRect) -> Path {
        let clamped = min(max(openness, 0.2), 1.0)
        let height = rect.height * clamped
        let centerY = rect.midY
        let topY = centerY - height / 2
        let bottomY = centerY + height / 2

        let left = CGPoint(x: rect.minX, y: centerY + slant)
        let right = CGPoint(x: rect.maxX, y: centerY - slant)

        let upperControl = CGPoint(x: rect.midX, y: topY - abs(slant) * 0.2)
        let lowerControl = CGPoint(x: rect.midX, y: bottomY + abs(slant) * 0.2)

        var path = Path()
        path.move(to: left)
        path.addQuadCurve(to: right, control: upperControl)
        path.addQuadCurve(to: left, control: lowerControl)
        path.closeSubpath()
        return path
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
    private struct FaceCandidate {
        let boundingBox: CGRect
        let faceprint: VNFeaturePrintObservation?
    }

    let session = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let visionQueue = DispatchQueue(label: "vision.queue")
    private var lockedFaceBox: CGRect? = nil
    private var missingFrames: Int = 0
    private var pendingEnrollment: Bool = false
    private var enrolledFaceprint: VNFeaturePrintObservation? = nil

    private let lockIoUThreshold: CGFloat = 0.06
    private let lockCenterThreshold: CGFloat = 0.35
    private let lockHoldFrames: Int = 3
    private let lockReleaseFrames: Int = 12
    private let matchDistanceThreshold: Float = 0.35

    @Published var faceBoxNormalized: CGRect? = nil
    @Published var hasFace: Bool = false
    @Published var isEnrolled: Bool = false

    func start() {
        configureSessionIfNeeded()
        session.startRunning()
    }

    func stop() { session.stopRunning() }

    func requestEnrollment() {
        visionQueue.async {
            self.pendingEnrollment = true
            self.enrolledFaceprint = nil
            self.lockedFaceBox = nil
            self.missingFrames = 0
        }
        DispatchQueue.main.async {
            self.isEnrolled = false
        }
    }

    func clearEnrollment() {
        visionQueue.async {
            self.pendingEnrollment = false
            self.enrolledFaceprint = nil
            self.lockedFaceBox = nil
            self.missingFrames = 0
        }
        DispatchQueue.main.async {
            self.isEnrolled = false
        }
    }

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

        let detectRequest = VNDetectFaceRectanglesRequest()
        let handler = VNImageRequestHandler(
            cvPixelBuffer: pixelBuffer,
            orientation: .rightMirrored,
            options: [:]
        )

        do {
            try handler.perform([detectRequest])
        } catch {
            return
        }

        let faces = (detectRequest.results as? [VNFaceObservation]) ?? []
        let candidates = makeCandidates(from: faces, pixelBuffer: pixelBuffer)
        tryEnrollIfNeeded(from: candidates)
        let selected = selectLockedFace(from: candidates)

        DispatchQueue.main.async {
            if let selected {
                self.faceBoxNormalized = selected
                self.hasFace = true
            } else {
                self.faceBoxNormalized = nil
                self.hasFace = false
            }
        }
    }

    private func makeCandidates(from faces: [VNFaceObservation],
                                pixelBuffer: CVPixelBuffer) -> [FaceCandidate] {
        guard !faces.isEmpty else { return [] }

        if enrolledFaceprint != nil || pendingEnrollment {
            if #available(iOS 13.0, *) {
                let faceprintRequest = VNGenerateFaceprintRequest()
                faceprintRequest.inputFaceObservations = faces

                let faceprintHandler = VNImageRequestHandler(
                    cvPixelBuffer: pixelBuffer,
                    orientation: .rightMirrored,
                    options: [:]
                )

                do {
                    try faceprintHandler.perform([faceprintRequest])
                } catch {
                    return faces.map { FaceCandidate(boundingBox: $0.boundingBox, faceprint: nil) }
                }

                let faceprintFaces = (faceprintRequest.results as? [VNFaceObservation]) ?? []
                let withPrints = faceprintFaces.compactMap { observation -> FaceCandidate? in
                    guard let faceprint = observation.faceprint else { return nil }
                    return FaceCandidate(boundingBox: observation.boundingBox, faceprint: faceprint)
                }
                if !withPrints.isEmpty {
                    return withPrints
                }
            }
        }

        return faces.map { FaceCandidate(boundingBox: $0.boundingBox, faceprint: nil) }
    }

    private func tryEnrollIfNeeded(from candidates: [FaceCandidate]) {
        guard pendingEnrollment else { return }
        guard let candidate = candidates.max(by: { area($0.boundingBox) < area($1.boundingBox) }) else { return }
        guard let faceprint = candidate.faceprint else { return }

        enrolledFaceprint = faceprint
        pendingEnrollment = false
        lockedFaceBox = candidate.boundingBox
        missingFrames = 0

        DispatchQueue.main.async {
            self.isEnrolled = true
        }
    }

    private func selectLockedFace(from candidates: [FaceCandidate]) -> CGRect? {
        if let enrolledFaceprint {
            return selectMatchingFace(enrolledFaceprint, from: candidates)
        }
        return selectAutoFace(from: candidates)
    }

    private func selectMatchingFace(_ enrolled: VNFeaturePrintObservation,
                                    from candidates: [FaceCandidate]) -> CGRect? {
        guard !candidates.isEmpty else {
            missingFrames += 1
            if missingFrames <= lockHoldFrames {
                return lockedFaceBox
            }
            lockedFaceBox = nil
            return nil
        }

        var bestCandidate: FaceCandidate? = nil
        var bestDistance: Float = .greatestFiniteMagnitude

        for candidate in candidates {
            guard let faceprint = candidate.faceprint else { continue }
            var distance: Float = 0
            do {
                try enrolled.computeDistance(&distance, to: faceprint)
            } catch {
                continue
            }
            if distance < bestDistance {
                bestDistance = distance
                bestCandidate = candidate
            }
        }

        if let bestCandidate, bestDistance <= matchDistanceThreshold {
            lockedFaceBox = bestCandidate.boundingBox
            missingFrames = 0
            return bestCandidate.boundingBox
        }

        missingFrames += 1
        if missingFrames <= lockHoldFrames {
            return lockedFaceBox
        }
        lockedFaceBox = nil
        return nil
    }

    private func selectAutoFace(from candidates: [FaceCandidate]) -> CGRect? {
        let boxes = candidates.map { $0.boundingBox }
        guard !boxes.isEmpty else {
            missingFrames += 1
            if missingFrames <= lockHoldFrames {
                return lockedFaceBox
            }
            if missingFrames >= lockReleaseFrames {
                lockedFaceBox = nil
            }
            return nil
        }

        if let locked = lockedFaceBox {
            let best = boxes.min { centerDistance($0, locked) < centerDistance($1, locked) } ?? locked
            let bestIoU = iou(locked, best)
            let bestDist = centerDistance(locked, best)

            if bestIoU >= lockIoUThreshold || bestDist <= lockCenterThreshold {
                lockedFaceBox = best
                missingFrames = 0
                return best
            }

            missingFrames += 1
            if missingFrames <= lockHoldFrames {
                return lockedFaceBox
            }
            if missingFrames >= lockReleaseFrames {
                lockedFaceBox = nil
            }
            return nil
        }

        let best = boxes.max { area($0) < area($1) }
        lockedFaceBox = best
        missingFrames = 0
        return best
    }

    private func area(_ rect: CGRect) -> CGFloat {
        rect.width * rect.height
    }

    private func centerDistance(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let dx = a.midX - b.midX
        let dy = a.midY - b.midY
        return sqrt(dx * dx + dy * dy)
    }

    private func iou(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let intersection = a.intersection(b)
        guard !intersection.isNull else { return 0 }
        let interArea = intersection.width * intersection.height
        let unionArea = area(a) + area(b) - interArea
        if unionArea <= 0 { return 0 }
        return interArea / unionArea
    }
}
