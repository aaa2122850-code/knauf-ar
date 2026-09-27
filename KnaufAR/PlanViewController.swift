//
//  PlanViewController.swift
//  КНАУФ AR — 2D-план, размеры, площадь и объём
//

import UIKit
import SceneKit

final class PlanViewController: UIViewController {

    private let room: RoomModel?
    private let partitions: [(code: String, a: SCNVector3, b: SCNVector3)]
    private let imageView = UIImageView()
    private var rendered = false

    init(room: RoomModel?, partitions: [(code: String, a: SCNVector3, b: SCNVector3)]) {
        self.room = room
        self.partitions = partitions
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) не используется") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(red: 0.94, green: 0.96, blue: 0.97, alpha: 1)
        title = "План помещения"

        imageView.contentMode = .scaleAspectFit
        imageView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(imageView)

        func btn(_ title: String, _ sel: Selector) -> UIButton {
            let b = UIButton(type: .system)
            b.setTitle(title, for: .normal)
            b.titleLabel?.font = .systemFont(ofSize: 15, weight: .semibold)
            b.backgroundColor = UIColor(red: 0, green: 0.42, blue: 0.71, alpha: 1)
            b.setTitleColor(.white, for: .normal)
            b.layer.cornerRadius = 12
            b.contentEdgeInsets = UIEdgeInsets(top: 10, left: 18, bottom: 10, right: 18)
            b.addTarget(self, action: sel, for: .touchUpInside)
            return b
        }
        let close = btn("✕  Закрыть", #selector(closeTapped))
        let pdf = btn("Экспорт PDF", #selector(pdfTapped))
        let bar = UIStackView(arrangedSubviews: [close, UIView(), pdf])
        bar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(bar)

        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            bar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            bar.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            imageView.topAnchor.constraint(equalTo: bar.bottomAnchor, constant: 8),
            imageView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            imageView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            imageView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -8)
        ])
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard !rendered, view.bounds.width > 0 else { return }
        rendered = true
        imageView.image = drawPlanImage(size: view.bounds.size)
    }

    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        coordinator.animate(alongsideTransition: { _ in
            self.imageView.image = self.drawPlanImage(size: size)
        })
    }

    @objc private func closeTapped() { dismiss(animated: true) }

    @objc private func pdfTapped() {
        let page = CGRect(x: 0, y: 0, width: 842, height: 595) // A4 landscape
        let renderer = UIGraphicsPDFRenderer(bounds: page)
        let data = renderer.pdfData { ctx in
            ctx.beginPage()
            drawPlan(ctx: ctx.cgContext, rect: page.insetBy(dx: 20, dy: 20))
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("KNAUF_AR_plan.pdf")
        try? data.write(to: url)
        let av = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        av.popoverPresentationController?.sourceView = view
        present(av, animated: true)
    }

    private func drawPlanImage(size: CGSize) -> UIImage {
        UIGraphicsImageRenderer(size: size).image { _ in
            drawPlan(ctx: UIGraphicsGetCurrentContext()!,
                     rect: CGRect(origin: .zero, size: size).insetBy(dx: 12, dy: 12))
        }
    }

    // MARK: Отрисовка плана (экран и PDF)

    private func drawPlan(ctx: CGContext, rect: CGRect) {
        UIColor.white.setFill()
        ctx.fill(rect)

        drawText("ПЛАН ПОМЕЩЕНИЯ · размеры в мм · КНАУФ AR",
                 at: CGPoint(x: rect.minX, y: rect.minY - 2), size: 11, weight: .semibold,
                 color: .darkGray, ctx: ctx, align: .left)

        guard let room = room, room.corners.count >= 3 else {
            drawText("Помещение не отсканировано.\nМеню «Помещение» → «Сканировать / обновить помещение».",
                     at: CGPoint(x: rect.midX, y: rect.midY), size: 16, color: .darkGray, ctx: ctx)
            return
        }

        let pts = room.corners
        let n = pts.count
        let b = room.bounds
        let w = CGFloat(max(b.maxX - b.minX, 0.01))
        let h = CGFloat(max(b.maxZ - b.minZ, 0.01))
        let margin: CGFloat = 110
        let s = min((rect.width - 2 * margin) / w, (rect.height - 2 * margin) / h)
        let ox = rect.midX - (CGFloat(b.minX) + w / 2) * s
        let oy = rect.midY - (CGFloat(b.minZ) + h / 2) * s
        func P(_ c: RoomPoint) -> CGPoint { CGPoint(x: CGFloat(c.x) * s + ox, y: CGFloat(c.z) * s + oy) }

        // Полигон комнаты
        let path = UIBezierPath()
        path.move(to: P(pts[0]))
        for c in pts.dropFirst() { path.addLine(to: P(c)) }
        path.close()
        UIColor(red: 0.88, green: 0.94, blue: 1, alpha: 1).setFill()
        path.fill()
        UIColor(white: 0.15, alpha: 1).setStroke()
        path.lineWidth = 4
        path.stroke()

        // Центроид (для выносок наружу)
        var ccx: Float = 0, ccz: Float = 0
        for c in pts { ccx += c.x; ccz += c.z }
        ccx /= Float(n); ccz /= Float(n)
        let pc = CGPoint(x: CGFloat(ccx) * s + ox, y: CGFloat(ccz) * s + oy)

        // Размерные линии по каждой стене
        let lengths = room.wallLengths
        for i in 0..<n {
            let pa = P(pts[i]), pb = P(pts[(i + 1) % n])
            let mid = CGPoint(x: (pa.x + pb.x) / 2, y: (pa.y + pb.y) / 2)
            var dir = CGPoint(x: mid.x - pc.x, y: mid.y - pc.y)
            let dl = max(0.001, hypot(dir.x, dir.y))
            dir = CGPoint(x: dir.x / dl, y: dir.y / dl)
            let off: CGFloat = 36
            let a2 = CGPoint(x: pa.x + dir.x * off, y: pa.y + dir.y * off)
            let b2 = CGPoint(x: pb.x + dir.x * off, y: pb.y + dir.y * off)
            UIColor(white: 0.35, alpha: 1).setStroke()
            let dim = UIBezierPath()
            dim.move(to: a2); dim.addLine(to: b2)
            dim.move(to: pa); dim.addLine(to: a2)
            dim.move(to: pb); dim.addLine(to: b2)
            dim.lineWidth = 1
            dim.stroke()
            drawText("\(Int((lengths[i] * 100).rounded()))",
                     at: CGPoint(x: (a2.x + b2.x) / 2 + dir.x * 16, y: (a2.y + b2.y) / 2 + dir.y * 16),
                     size: 11, weight: .semibold, color: .black, ctx: ctx)
        }

        // Конструкции КНАУФ (перегородки/облицовки) — синие линии
        for part in partitions {
            let p1 = CGPoint(x: CGFloat(part.a.x) * s + ox, y: CGFloat(part.a.z) * s + oy)
            let p2 = CGPoint(x: CGFloat(part.b.x) * s + ox, y: CGFloat(part.b.z) * s + oy)
            UIColor(red: 0, green: 0.42, blue: 0.71, alpha: 1).setStroke()
            let l = UIBezierPath()
            l.move(to: p1); l.addLine(to: p2)
            l.lineWidth = 6
            l.stroke()
            drawText(part.code, at: CGPoint(x: (p1.x + p2.x) / 2, y: (p1.y + p2.y) / 2 - 12),
                     size: 11, weight: .bold,
                     color: UIColor(red: 0, green: 0.42, blue: 0.71, alpha: 1), ctx: ctx)
        }

        // Блок характеристик
        var info: [String] = []
        info.append("ВЫСОТА: \(Int(room.height * 100)) мм")
        info.append("ПЛОЩАДЬ ПОЛА: \(fmt(room.floorArea)) м²")
        info.append("ПЛОЩАДЬ СТЕН: \(fmt(room.wallArea)) м² (без проёмов)")
        info.append("СТРОИТЕЛЬНЫЙ ОБЪЁМ: \(fmt(room.volume)) м³")
        info.append("СТЕНЫ (мм): " + lengths.map { "\(Int(($0 * 100).rounded()))" }.joined(separator: " · "))
        for part in partitions.prefix(8) {
            info.append("КНАУФ \(part.code): \(fmt(Double(rdist(part.a, part.b)))) м.п.")
        }

        let lineH: CGFloat = 16
        let blockW: CGFloat = 330
        let blockH = CGFloat(info.count) * lineH + 16
        let blockRect = CGRect(x: rect.minX + 8, y: rect.maxY - blockH - 6, width: blockW, height: blockH)
        UIColor(white: 1, alpha: 0.94).setFill()
        UIBezierPath(roundedRect: blockRect, cornerRadius: 8).fill()
        let frame = UIBezierPath(roundedRect: blockRect, cornerRadius: 8)
        UIColor(white: 0.7, alpha: 1).setStroke()
        frame.lineWidth = 1
        frame.stroke()
        for (i, s2) in info.enumerated() {
            drawText(s2, at: CGPoint(x: blockRect.minX + 10, y: blockRect.minY + 12 + CGFloat(i) * lineH),
                     size: 10.5, weight: .medium, color: .black, ctx: ctx, align: .left)
        }
    }

    private func drawText(_ s: String, at p: CGPoint, size: CGFloat, weight: UIFont.Weight = .regular,
                          color: UIColor, ctx: CGContext, align: NSTextAlignment = .center) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: size, weight: weight),
            .foregroundColor: color
        ]
        let sz = (s as NSString).size(withAttributes: attrs)
        var origin = p
        if align == .center { origin.x -= sz.width / 2; origin.y -= sz.height / 2 }
        else { origin.y -= sz.height / 2 }
        (s as NSString).draw(at: origin, withAttributes: attrs)
    }

    private func fmt(_ v: Double) -> String {
        String(format: "%.1f", v).replacingOccurrences(of: ".", with: ",")
    }
}
