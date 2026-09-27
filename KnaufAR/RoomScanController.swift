//
//  RoomScanController.swift
//  КНАУФ AR — сканирование помещения
//

import UIKit
import ARKit
import SceneKit

final class RoomScanController: UIViewController {

    private var sceneView: ARSCNView!
    private let statusLabel = UILabel()
    private let draftNode = SCNNode()
    private var corners: [SCNVector3] = []
    private var heightMode = false
    private var doneButton: UIButton!

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        sceneView = ARSCNView(frame: view.bounds)
        sceneView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        sceneView.autoenablesDefaultLighting = true
        view.addSubview(sceneView)

        let config = ARWorldTrackingConfiguration()
        config.planeDetection = [.horizontal, .vertical]
        sceneView.session.run(config)
        sceneView.scene.rootNode.addChildNode(draftNode)

        sceneView.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(onTap(_:))))

        setupUI()
        setStatus("Коснитесь каждого угла пола (минимум 3),\nзатем нажмите «Готово»")
    }

    private func setupUI() {
        let card = UIView()
        card.backgroundColor = UIColor(white: 1, alpha: 0.96)
        card.layer.cornerRadius = 14
        card.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(card)
        statusLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        statusLabel.textColor = .black
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 3
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(statusLabel)
        NSLayoutConstraint.activate([
            card.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 10),
            card.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            statusLabel.topAnchor.constraint(equalTo: card.topAnchor, constant: 8),
            statusLabel.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -8),
            statusLabel.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
            statusLabel.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14)
        ])

        func btn(_ title: String, _ sel: Selector) -> UIButton {
            let b = UIButton(type: .system)
            b.setTitle(title, for: .normal)
            b.titleLabel?.font = .systemFont(ofSize: 14, weight: .semibold)
            b.backgroundColor = UIColor(white: 1, alpha: 0.96)
            b.setTitleColor(UIColor(red: 0, green: 0.42, blue: 0.71, alpha: 1), for: .normal)
            b.layer.cornerRadius = 18
            b.translatesAutoresizingMaskIntoConstraints = false
            b.heightAnchor.constraint(equalToConstant: 40).isActive = true
            b.contentEdgeInsets = UIEdgeInsets(top: 0, left: 14, bottom: 0, right: 14)
            b.addTarget(self, action: sel, for: .touchUpInside)
            return b
        }
        doneButton = btn("Готово (0)", #selector(doneTapped))
        let undo = btn("Отменить угол", #selector(undoTapped))
        let close = btn("Выход", #selector(closeTapped))
        let row = UIStackView(arrangedSubviews: [undo, doneButton, close])
        row.axis = .horizontal
        row.spacing = 10
        row.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(row)
        NSLayoutConstraint.activate([
            row.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            row.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16)
        ])
    }

    private func setStatus(_ s: String) { statusLabel.text = s }

    private func floorY() -> Float { corners.first?.y ?? 0 }

    @objc private func onTap(_ g: UITapGestureRecognizer) {
        let p = g.location(in: sceneView)
        if !heightMode {
            let hits = sceneView.hitTest(p, types: [.existingPlaneUsingGeometry, .estimatedHorizontalPlane])
            guard let hit = hits.first,
                  let anchor = hit.anchor as? ARPlaneAnchor,
                  anchor.alignment == .horizontal else {
                setStatus("Коснитесь обнаруженной плоскости пола")
                return
            }
            let t = hit.worldTransform
            corners.append(SCNVector3(t.columns.3.x, t.columns.3.y, t.columns.3.z))
            redrawDraft()
            doneButton.setTitle("Готово (\(corners.count))", for: .normal)
            setStatus(corners.count >= 3
                      ? "Угол \(corners.count) зафиксирован. Продолжайте или нажмите «Готово»"
                      : "Угол \(corners.count) зафиксирован. Нужно ещё \(3 - corners.count)")
        } else {
            let hits = sceneView.hitTest(p, types: [.existingPlaneUsingGeometry])
            guard let hit = hits.first,
                  let anchor = hit.anchor as? ARPlaneAnchor,
                  anchor.alignment == .horizontal,
                  hit.worldTransform.columns.3.y > floorY() + 0.2 else {
                setStatus("Коснитесь обнаруженной плоскости потолка")
                return
            }
            finish(height: hit.worldTransform.columns.3.y - floorY())
        }
    }

    @objc private func undoTapped() {
        guard !heightMode else { return }
        if corners.popLast() != nil {
            redrawDraft()
            doneButton.setTitle("Готово (\(corners.count))", for: .normal)
            setStatus("Угол отменён")
        }
    }

    @objc private func doneTapped() {
        if !heightMode {
            guard corners.count >= 3 else {
                setStatus("Нужно минимум 3 угла пола")
                return
            }
            heightMode = true
            doneButton.setTitle("Готово (ввод высоты)", for: .normal)
            setStatus("Коснитесь потолка — высота определится автоматически,\nили нажмите «Готово» для ввода вручную")
        } else {
            let ac = UIAlertController(title: "Высота помещения",
                                       message: "Введите высоту от пола до потолка, м",
                                       preferredStyle: .alert)
            ac.addTextField { $0.text = "2,70"; $0.keyboardType = .decimalPad }
            ac.addAction(UIAlertAction(title: "Сохранить", style: .default) { _ in
                let s = (ac.textFields?.first?.text ?? "2.7").replacingOccurrences(of: ",", with: ".")
                let h = Float(s) ?? 2.7
                self.finish(height: max(1.8, min(5.0, h)))
            })
            ac.addAction(UIAlertAction(title: "Отмена", style: .cancel))
            present(ac, animated: true)
        }
    }

    @objc private func closeTapped() {
        let ac = UIAlertController(title: "Выйти без сохранения?",
                                   message: corners.isEmpty ? nil : "Зафиксированные углы будут потеряны",
                                   preferredStyle: .alert)
        ac.addAction(UIAlertAction(title: "Выйти", style: .destructive) { _ in self.dismiss(animated: true) })
        ac.addAction(UIAlertAction(title: "Продолжить", style: .cancel))
        present(ac, animated: true)
    }

    private func finish(height: Float) {
        guard corners.count >= 3 else { return }
        let fy = corners.map { $0.y }.reduce(0, +) / Float(corners.count)
        let room = RoomModel(corners: corners.map { RoomPoint(x: $0.x, z: $0.z) },
                             height: height, floorY: fy)
        RoomStore.shared.save(room)
        let nf = NumberFormatter()
        nf.numberStyle = .decimal
        nf.maximumFractionDigits = 1
        nf.decimalSeparator = ","
        let ac = UIAlertController(title: "Помещение сохранено",
            message: "Площадь пола: \(nf.string(from: NSNumber(value: room.floorArea)) ?? "-") м²\n"
                   + "Высота: \(Int(height * 100)) мм\n"
                   + "Строительный объём: \(nf.string(from: NSNumber(value: room.volume)) ?? "-") м³",
            preferredStyle: .alert)
        ac.addAction(UIAlertAction(title: "Готово", style: .default) { _ in
            self.dismiss(animated: true)
        })
        present(ac, animated: true)
    }

    private func redrawDraft() {
        draftNode.childNodes.forEach { $0.removeFromParentNode() }
        let yellow = UIColor(red: 1.00, green: 0.78, blue: 0.10, alpha: 1)
        let m = SCNMaterial()
        m.diffuse.contents = yellow
        m.emission.contents = yellow

        for c in corners {
            let g = SCNSphere(radius: 0.025)
            g.materials = [m]
            let node = SCNNode(geometry: g)
            node.position = c
            draftNode.addChildNode(node)
        }
        for i in 1..<corners.count {
            addDraftLine(from: corners[i - 1], to: corners[i], color: yellow)
        }
        if corners.count >= 3 {
            addDraftLine(from: corners.last!, to: corners[0], color: UIColor.white.withAlphaComponent(0.6))
        }
    }

    private func addDraftLine(from a: SCNVector3, to b: SCNVector3, color: UIColor) {
        let d = rdist(a, b)
        guard d > 0.01 else { return }
        let cyl = SCNCylinder(radius: 0.005, height: CGFloat(d))
        let m = SCNMaterial()
        m.diffuse.contents = color
        m.emission.contents = color
        cyl.materials = [m]
        let line = SCNNode(geometry: cyl)
        line.position = SCNVector3((a.x + b.x) / 2, (a.y + b.y) / 2, (a.z + b.z) / 2)
        let dir = rnorm(SCNVector3(b.x - a.x, b.y - a.y, b.z - a.z))
        if abs(dir.y) < 0.999 {
            let axis = rnorm(rcross(SCNVector3(0, 1, 0), dir))
            line.rotation = SCNVector4(axis.x, axis.y, axis.z, acos(max(-1, min(1, dir.y))))
        }
        draftNode.addChildNode(line)
    }
}
