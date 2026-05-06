@preconcurrency import AVFoundation
import SwiftUI
import UIKit

struct CameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession
    var onTapDevicePoint: ((CGPoint) -> Void)?

    func makeUIView(context: Context) -> PreviewContainerView {
        let view = PreviewContainerView()
        view.previewLayer.session = session
        view.onTapDevicePoint = onTapDevicePoint
        return view
    }

    func updateUIView(_ uiView: PreviewContainerView, context: Context) {
        uiView.previewLayer.session = session
        uiView.onTapDevicePoint = onTapDevicePoint
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

    private var exposureBoxLayer: CAShapeLayer?
    private var exposureBoxDismissWork: DispatchWorkItem?
    private var gridLayer: CAShapeLayer?

    override init(frame: CGRect) {
        super.init(frame: frame)
        previewLayer.videoGravity = .resizeAspectFill
        backgroundColor = .black

        setupGridLayer()

        let tapGesture = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        addGestureRecognizer(tapGesture)
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
}
