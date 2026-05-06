@preconcurrency import AVFoundation
import SwiftUI
import UIKit

struct CameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession
    var onTapDevicePoint: ((CGPoint) -> Void)?
    var onExposureBiasChanged: ((Float) -> Void)?
    var onExposureBiasDragEnded: ((Float) -> Void)?
    var currentExposureBias: Float = 0.0

    func makeUIView(context: Context) -> PreviewContainerView {
        let view = PreviewContainerView()
        view.previewLayer.session = session
        view.onTapDevicePoint = onTapDevicePoint
        view.onExposureBiasChanged = onExposureBiasChanged
        view.onExposureBiasDragEnded = onExposureBiasDragEnded
        view.currentExposureBias = currentExposureBias
        return view
    }

    func updateUIView(_ uiView: PreviewContainerView, context: Context) {
        uiView.previewLayer.session = session
        uiView.onTapDevicePoint = onTapDevicePoint
        uiView.onExposureBiasChanged = onExposureBiasChanged
        uiView.onExposureBiasDragEnded = onExposureBiasDragEnded
        uiView.currentExposureBias = currentExposureBias
    }
}

final class PreviewContainerView: UIView {
    override class var layerClass: AnyClass {
        AVCaptureVideoPreviewLayer.self
    }

    var previewLayer: AVCaptureVideoPreviewLayer {
        layer as! AVCaptureVideoPreviewLayer
    }

    var onTapDevicePoint: ((CGPoint) -> Void)?
    var onExposureBiasChanged: ((Float) -> Void)?
    var onExposureBiasDragEnded: ((Float) -> Void)?
    var currentExposureBias: Float = 0.0

    private var exposureBoxLayer: CAShapeLayer?
    private var exposureBoxDismissWork: DispatchWorkItem?
    private var gridLayer: CAShapeLayer?
    private var exposureBiasCircleLayer: CAShapeLayer?

    private var biasDragStartY: CGFloat = 0
    private var biasAtDragStart: Float = 0
    private let pointsPerStop: CGFloat = 150.0
    private let rightColumnFraction: CGFloat = 2.0 / 3.0
    private let topButtonZone: CGFloat = 60
    private let bottomButtonZone: CGFloat = 150

    override init(frame: CGRect) {
        super.init(frame: frame)
        previewLayer.videoGravity = .resizeAspectFill
        backgroundColor = .black

        setupGridLayer()
        setupExposureBiasCircleLayer()

        let tapGesture = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        addGestureRecognizer(tapGesture)

        let panGesture = UIPanGestureRecognizer(target: self, action: #selector(handleExposureBiasPan(_:)))
        panGesture.delegate = self
        addGestureRecognizer(panGesture)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        updateGridLayer()
    }

    private func setupGridLayer() {
        let shapeLayer = CAShapeLayer()
        shapeLayer.fillColor = UIColor.clear.cgColor
        shapeLayer.strokeColor = UIColor.white.cgColor
        shapeLayer.lineWidth = 1.0 / UIScreen.main.scale
        shapeLayer.opacity = 0.5
        shapeLayer.compositingFilter = "differenceBlendMode"
        layer.addSublayer(shapeLayer)
        gridLayer = shapeLayer
    }

    private func setupExposureBiasCircleLayer() {
        let size: CGFloat = 28
        let circleLayer = CAShapeLayer()
        circleLayer.path = UIBezierPath(ovalIn: CGRect(x: -size / 2, y: -size / 2, width: size, height: size)).cgPath
        circleLayer.fillColor = UIColor.yellow.cgColor
        circleLayer.strokeColor = nil
        circleLayer.opacity = 0.35
        circleLayer.isHidden = true
        layer.addSublayer(circleLayer)
        exposureBiasCircleLayer = circleLayer
    }

    private func updateGridLayer() {
        guard let gridLayer else { return }
        let size = bounds.size
        guard size.width > 0, size.height > 0 else { return }

        let path = UIBezierPath()
        path.move(to: CGPoint(x: size.width / 3, y: 0))
        path.addLine(to: CGPoint(x: size.width / 3, y: size.height))
        path.move(to: CGPoint(x: size.width * 2 / 3, y: 0))
        path.addLine(to: CGPoint(x: size.width * 2 / 3, y: size.height))
        path.move(to: CGPoint(x: 0, y: size.height / 3))
        path.addLine(to: CGPoint(x: size.width, y: size.height / 3))
        path.move(to: CGPoint(x: 0, y: size.height * 2 / 3))
        path.addLine(to: CGPoint(x: size.width, y: size.height * 2 / 3))

        gridLayer.path = path.cgPath
        gridLayer.frame = bounds
    }

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        let viewPoint = gesture.location(in: self)
        let devicePoint = previewLayer.captureDevicePointConverted(fromLayerPoint: viewPoint)

        onTapDevicePoint?(devicePoint)
        showExposureBox(at: viewPoint)
    }

    private func showExposureBox(at point: CGPoint) {
        exposureBoxDismissWork?.cancel()

        if let existing = exposureBoxLayer {
            existing.removeFromSuperlayer()
            exposureBoxLayer = nil
        }

        let boxSize: CGFloat = 80
        let boxRect = CGRect(
            x: point.x - boxSize / 2,
            y: point.y - boxSize / 2,
            width: boxSize,
            height: boxSize
        )
        let path = UIBezierPath(roundedRect: CGRect(origin: .zero, size: boxRect.size), cornerRadius: 8)
        let newLayer = CAShapeLayer()
        newLayer.path = path.cgPath
        newLayer.strokeColor = UIColor.yellow.cgColor
        newLayer.fillColor = UIColor.clear.cgColor
        newLayer.lineWidth = 2
        newLayer.frame = boxRect
        newLayer.opacity = 0
        newLayer.transform = CATransform3DMakeScale(0.6, 0.6, 1)

        layer.addSublayer(newLayer)
        exposureBoxLayer = newLayer

        CATransaction.begin()
        CATransaction.setAnimationDuration(0.15)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))

        let scaleAnimation = CASpringAnimation(keyPath: "transform.scale")
        scaleAnimation.fromValue = 0.6
        scaleAnimation.toValue = 1.0
        scaleAnimation.damping = 12
        scaleAnimation.initialVelocity = 4
        scaleAnimation.duration = scaleAnimation.settlingDuration

        let opacityAnimation = CABasicAnimation(keyPath: "opacity")
        opacityAnimation.fromValue = 0
        opacityAnimation.toValue = 1
        opacityAnimation.duration = 0.15

        newLayer.add(scaleAnimation, forKey: "scale")
        newLayer.add(opacityAnimation, forKey: "opacity")

        newLayer.transform = CATransform3DIdentity
        newLayer.opacity = 1

        CATransaction.commit()

        let dismissWork = DispatchWorkItem { [weak self] in
            guard let self, let boxLayer = self.exposureBoxLayer else { return }
            let fadeOut = CABasicAnimation(keyPath: "opacity")
            fadeOut.fromValue = 1
            fadeOut.toValue = 0
            fadeOut.duration = 0.3
            fadeOut.fillMode = .forwards
            fadeOut.isRemovedOnCompletion = false

            CATransaction.begin()
            CATransaction.setCompletionBlock {
                boxLayer.removeFromSuperlayer()
                if self.exposureBoxLayer === boxLayer {
                    self.exposureBoxLayer = nil
                }
            }
            boxLayer.add(fadeOut, forKey: "dismiss")
            CATransaction.commit()
        }

        exposureBoxDismissWork = dismissWork
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: dismissWork)
    }

    @objc private func handleExposureBiasPan(_ gesture: UIPanGestureRecognizer) {
        let location = gesture.location(in: self)

        switch gesture.state {
        case .began:
            let inRightColumn = location.x > bounds.width * rightColumnFraction
            let inValidY = location.y > topButtonZone && location.y < bounds.height - bottomButtonZone
            if !inRightColumn || !inValidY {
                gesture.state = .cancelled
                return
            }
            biasDragStartY = location.y
            biasAtDragStart = currentExposureBias
            showBiasIndicator(at: location)
            CameraHaptics.light()

        case .changed:
            let deltaY = biasDragStartY - location.y
            let deltaEV = Float(deltaY / pointsPerStop)
            let newBias = biasAtDragStart + deltaEV
            onExposureBiasChanged?(newBias)
            moveBiasIndicator(to: location)

        case .ended:
            let deltaY = biasDragStartY - location.y
            let finalBias = biasAtDragStart + Float(deltaY / pointsPerStop)
            onExposureBiasDragEnded?(finalBias)
            hideBiasIndicator()
            CameraHaptics.light()

        case .cancelled:
            hideBiasIndicator()

        default:
            break
        }
    }

    private func showBiasIndicator(at point: CGPoint) {
        guard let circle = exposureBiasCircleLayer else { return }
        circle.position = point
        circle.isHidden = false
        circle.opacity = 0
        let fadeIn = CABasicAnimation(keyPath: "opacity")
        fadeIn.fromValue = 0
        fadeIn.toValue = 0.35
        fadeIn.duration = 0.12
        fadeIn.fillMode = .forwards
        fadeIn.isRemovedOnCompletion = false
        circle.add(fadeIn, forKey: "biasFadeIn")
        circle.opacity = 0.35
    }

    private func moveBiasIndicator(to point: CGPoint) {
        guard let circle = exposureBiasCircleLayer else { return }
        var clamped = point
        clamped.x = max(14, min(bounds.width - 14, clamped.x))
        clamped.y = max(14, min(bounds.height - 14, clamped.y))
        circle.position = clamped
    }

    private func hideBiasIndicator() {
        guard let circle = exposureBiasCircleLayer else { return }
        let fadeOut = CABasicAnimation(keyPath: "opacity")
        fadeOut.fromValue = circle.opacity
        fadeOut.toValue = 0
        fadeOut.duration = 0.25
        fadeOut.fillMode = .forwards
        fadeOut.isRemovedOnCompletion = false
        circle.add(fadeOut, forKey: "biasFadeOut")
        circle.opacity = 0
        circle.isHidden = true
    }
}

extension PreviewContainerView: UIGestureRecognizerDelegate {
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        if gestureRecognizer is UIPanGestureRecognizer || other is UIPanGestureRecognizer {
            return true
        }
        return false
    }

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer is UIPanGestureRecognizer else { return true }
        let location = gestureRecognizer.location(in: self)
        let inRightColumn = location.x > bounds.width * rightColumnFraction
        let inValidY = location.y > topButtonZone && location.y < bounds.height - bottomButtonZone
        return inRightColumn && inValidY
    }
}
