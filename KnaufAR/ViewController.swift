//
//  ViewController.swift
//  КНАУФ AR Конструктор v3.0
//  AR-конструкции КНАУФ + сканирование помещений + 2D-планы + Rw/EI + каталог по Wi-Fi
//

import UIKit
import ARKit
import SceneKit

// MARK: - Категории и модель системы

enum SystemCategory: String, CaseIterable {
    case partition = "Перегородки"
    case lining    = "Облицовки"
    case ceiling   = "Потолки"
    case floor     = "Полы"
}

struct KnaufSystem {

    enum Frame {
        case cw50, cw75, doubleCW50, pp60, doublePP, dryFloor

        /// Глубина каркаса от базовой плоскости, мм
        var depthMM: Double {
            switch self {
            case .cw50: return 50
            case .cw75: return 75
            case .doubleCW50: return 100
            case .pp60: return 27
            case .doublePP: return 54
            case .dryFloor: return 0
            }
        }
        var title: String {
            switch self {
            case .cw50: return "каркас ПС 50 (CW 50)"
            case .cw75: return "каркас ПС 75 (CW 75)"
            case .doubleCW50: return "двойной каркас 2×ПС 50"
            case .pp60: return "каркас ПП 60×27 (CD)"
            case .doublePP: return "двойной каркас 2×ПП 60×27"
            case .dryFloor: return "сухое основание"
            }
        }
    }

    let code: String
    let name: String
    let category: SystemCategory
    let thicknessMM: Int
    let dropMM: Int
    let layers: Int
    let spacingMM: Double
    let frame: Frame
    var maxH: Double = 99.0      // допустимая высота, м
    var rw: Int?                 // звукоизоляция, дБ
    var ei: Int?                 // огнестойкость, мин
    let composition: [String]
}

// MARK: - Векторная математика

private func v(_ x: Float, _ y: Float, _ z: Float) -> SCNVector3 { SCNVector3(x, y, z) }
private func + (a: SCNVector3, b: SCNVector3) -> SCNVector3 { SCNVector3(a.x + b.x, a.y + b.y, a.z + b.z) }
private func - (a: SCNVector3, b: SCNVector3) -> SCNVector3 { SCNVector3(a.x - b.x, a.y - b.y, a.z - b.z) }
private func * (a: SCNVector3, s: Float) -> SCNVector3 { SCNVector3(a.x * s, a.y * s, a.z * s) }
private func len(_ a: SCNVector3) -> Float { sqrt(a.x * a.x + a.y * a.y + a.z * a.z) }
private func norm(_ a: SCNVector3) -> SCNVector3 { let l = len(a); return l > 0.0001 ? a * (1 / l) : SCNVector3(0, 1, 0) }
private func cross(_ a: SCNVector3, _ b: SCNVector3) -> SCNVector3 {
    SCNVector3(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x)
}
private func dist(_ a: SCNVector3, _ b: SCNVector3) -> Float { len(b - a) }
private func num(_ f: Float, _ d: Int = 2) -> String {
    String(format: "%.\(d)f", f).replacingOccurrences(of: ".", with: ",")
}

private struct SpecEntry { let item: String; let qty: Double; let unit: String }

/// Запас на подрезку листовых материалов
private let kSheetWaste = 0.10

// MARK: - Цвета (фирменный стиль KNAUF)

private enum Palette {
    // Интерфейс
    static let blue     = UIColor(red: 0.00, green: 0.42, blue: 0.71, alpha: 1)   // #006BB5
    static let ink      = UIColor(red: 0.11, green: 0.16, blue: 0.21, alpha: 1)
    static let inkSoft  = UIColor(red: 0.45, green: 0.52, blue: 0.58, alpha: 1)
    static let paper    = UIColor(red: 0.97, green: 0.98, blue: 0.99, alpha: 0.97)
    static let field    = UIColor(red: 0.94, green: 0.96, blue: 0.97, alpha: 1)
    static let line     = UIColor(red: 0.85, green: 0.89, blue: 0.92, alpha: 1)
    static let okGreen  = UIColor(red: 0.13, green: 0.62, blue: 0.35, alpha: 1)
    static let accent   = blue

    // 3D-материалы
    static let board    = UIColor(red: 0.92, green: 0.91, blue: 0.88, alpha: 1)
    static let gvl      = UIColor(red: 0.84, green: 0.85, blue: 0.86, alpha: 1)
    static let metal    = UIColor(red: 0.24, green: 0.26, blue: 0.29, alpha: 1)
    static let clay     = UIColor(red: 0.78, green: 0.48, blue: 0.28, alpha: 1)
    static let underlay = UIColor(red: 0.36, green: 0.40, blue: 0.46, alpha: 1)
}

// MARK: - Основной контроллер

class ViewController: UIViewController {

    private enum Mode { case build, measure, opening }
    private enum Phase { case idle, firstSet }
    private enum PlaneKind { case floor, wall, ceiling }

    /// Построенная конструкция: модель + параметры + проёмы + контур + спецификация
    private final class Construct {
        let kind: SystemCategory
        let sys: KnaufSystem
        let a: SCNVector3
        let b: SCNVector3
        let normal: SCNVector3
        let ceilingY: Float
        let height: Double
        var openings: [CGRect] = []       // в координатах стены: x 0..L, y 0..H
        var polygon: [SCNVector3]? = nil  // контур комнаты (пол/потолок по контуру)
        var polygonY: Float = 0
        var node: SCNNode?
        var specs: [SpecEntry] = []

        init(kind: SystemCategory, sys: KnaufSystem, a: SCNVector3, b: SCNVector3,
             normal: SCNVector3, ceilingY: Float, height: Double) {
            self.kind = kind; self.sys = sys
            self.a = a; self.b = b
            self.normal = normal; self.ceilingY = ceilingY; self.height = height
        }
    }

    private struct TotalItem { let item: String; let qty: Double; let unit: String }

    // Состояние
    private var mode: Mode = .build
    private var phase: Phase = .idle
    private var firstPoint: SCNVector3?
    private var firstNormal: SCNVector3 = SCNVector3(0, 1, 0)
    private var firstKind: PlaneKind = .floor
    private var secondKind: PlaneKind = .floor
    private var constructs: [Construct] = []
    private var openingFirst: (construct: Construct, world: SCNVector3)?
    private var lastOpeningConstruct: Construct?
    private var xrayOn = false
    private var partitionHeight: Double = 2.7
    private var liningHeight: Double = 2.7
    private var manualCeil: Double = 2.8
    private var currentCategory: SystemCategory = .partition
    private var selected: [SystemCategory: KnaufSystem] = [:]

    // AR
    private var sceneView: ARSCNView!
    private var planeNodes: [ARPlaneAnchor: SCNNode] = [:]
    private var planeKinds: [ARPlaneAnchor: PlaneKind] = [:]
    private var focusNode: SCNNode?
    private var focusTorus: SCNTorus?
    private var pointMarker: SCNNode?
    private var measureRoot: SCNNode?
    private var measureA: SCNVector3?
    private var roomNode: SCNNode?

    // UI
    private let statusLabel = UILabel()
    private let chipsStack = UIStackView()
    private let chipFloor = UILabel()
    private let chipWall = UILabel()
    private let chipCeil = UILabel()
    private var categoryButtons: [UIButton] = []
    private let codeLabel = UILabel()
    private let nameLabel = UILabel()
    private let dimsLabel = UILabel()
    private let chevron = UIImageView()
    private let systemsTable = UITableView()
    private var tableHC: NSLayoutConstraint!
    private var tableOpen = false
    private let slider = UISlider()
    private let sliderCaption = UILabel()
    private let sliderRow = UIStackView()
    private let xraySwitch = UISwitch()
    private var measureBtn: UIButton!
    private var openingBtn: UIButton!

    // MARK: Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()

        guard ARWorldTrackingConfiguration.isSupported else {
            let ac = UIAlertController(title: "AR недоступен",
                message: "Это устройство не поддерживает ARKit. Требуется iPad с чипом A9 или новее.",
                preferredStyle: .alert)
            ac.addAction(UIAlertAction(title: "OK", style: .default))
            present(ac, animated: true)
            return
        }

        setupAR()
        setupUI()
        selectCategory(.partition)
        updateStatus()
        NotificationCenter.default.addObserver(forName: .roomDidUpdate, object: nil, queue: .main) { [weak self] _ in
            self?.presentRoomModel()
        }
    }

    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        runSession()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.placeRoomInFront() }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        sceneView?.session.pause()
    }

    private func runSession() {
        let config = ARWorldTrackingConfiguration()
        config.planeDetection = [.horizontal, .vertical]
        sceneView.session.run(config)
    }

    // MARK: AR

    private func setupAR() {
        sceneView = ARSCNView(frame: view.bounds)
        sceneView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        sceneView.delegate = self
        sceneView.scene = SCNScene()
        sceneView.automaticallyUpdatesLighting = true
        sceneView.autoenablesDefaultLighting = true
        view.addSubview(sceneView)

        focusNode = makeFocusNode()
        sceneView.scene.rootNode.addChildNode(focusNode!)

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        sceneView.addGestureRecognizer(tap)
    }

    private func makeFocusNode() -> SCNNode {
        let node = SCNNode()
        let torus = SCNTorus(ringRadius: 0.045, pipeRadius: 0.0035)
        let m = SCNMaterial()
        m.diffuse.contents = Palette.accent
        m.emission.contents = Palette.accent
        torus.materials = [m]
        let ring = SCNNode(geometry: torus)
        let dotGeo = SCNSphere(radius: 0.006)
        let dm = SCNMaterial(); dm.diffuse.contents = UIColor.white
        dotGeo.materials = [dm]
        let dot = SCNNode(geometry: dotGeo)
        node.addChildNode(ring)
        node.addChildNode(dot)
        node.isHidden = true
        focusTorus = torus
        return node
    }

    private func planeInfo(from result: ARHitTestResult) -> (pos: SCNVector3, normal: SCNVector3, kind: PlaneKind)? {
        let t = result.worldTransform
        let pos = v(t.columns.3.x, t.columns.3.y, t.columns.3.z)
        if let anchor = result.anchor as? ARPlaneAnchor {
            let n = simd_make_float3(t.columns.2.x, t.columns.2.y, t.columns.2.z)
            if anchor.alignment == .horizontal {
                return n.y > 0 ? (pos, v(0, 1, 0), .floor) : (pos, v(0, -1, 0), .ceiling)
            }
            return (pos, v(n.x, n.y, n.z), .wall)
        }
        return (pos, v(0, 1, 0), .floor)
    }

    // MARK: Обработка касаний

    @objc private func handleTap(_ g: UITapGestureRecognizer) {
        let p = g.location(in: sceneView)
        switch mode {
        case .measure: handleMeasureTap(p)
        case .opening: handleOpeningTap(p)
        case .build:   handleBuildTap(p)
        }
    }

    private func handleBuildTap(_ p: CGPoint) {
        guard let system = selected[currentCategory] else { return }

        let hits = sceneView.hitTest(p, types: [.existingPlaneUsingGeometry, .estimatedHorizontalPlane])
        guard let hit = hits.first, let info = planeInfo(from: hit) else {
            setStatus("Наведите планшет на обнаруженную плоскость"); return
        }

        switch system.category {
        case .partition:
            guard info.kind == .floor else { setStatus("Для перегородки коснитесь плоскости пола"); return }
            acceptPoint(info.pos, info.normal, .floor, system)
        case .lining:
            guard info.kind == .wall else { setStatus("Для облицовки коснитесь вертикальной плоскости стены"); return }
            acceptPoint(info.pos, info.normal, .wall, system)
        case .floor:
            guard info.kind == .floor else { setStatus("Коснитесь плоскости пола"); return }
            acceptPoint(info.pos, info.normal, .floor, system)
        case .ceiling:
            switch info.kind {
            case .ceiling:
                acceptPoint(info.pos, info.normal, .ceiling, system)
            case .floor:
                let p2 = v(info.pos.x, Float(manualCeil), info.pos.z)
                acceptPoint(p2, v(0, -1, 0), .floor, system)
            default:
                setStatus("Коснитесь потолка; если он не найден — коснитесь пола (высота \(num(Float(manualCeil))) м)")
            }
        }
    }

    private func acceptPoint(_ pos: SCNVector3, _ normal: SCNVector3, _ kind: PlaneKind,
                             _ system: KnaufSystem) {
        if phase == .idle {
            firstPoint = pos
            firstNormal = normal
            firstKind = kind
            placeMarker(at: pos)
            phase = .firstSet
            updateStatus()
        } else {
            guard let a = firstPoint else { return }
            secondKind = kind
            clearMarker()
            phase = .idle
            build(from: a, to: pos, firstKind: firstKind, secondKind: kind, normal: firstNormal, sys: system)
            updateStatus()
        }
    }

    private func placeMarker(at pos: SCNVector3) {
        clearMarker()
        let geo = SCNSphere(radius: 0.02)
        let m = SCNMaterial()
        m.diffuse.contents = Palette.accent
        m.emission.contents = Palette.accent
        geo.materials = [m]
        pointMarker = SCNNode(geometry: geo)
        pointMarker?.position = pos
        sceneView.scene.rootNode.addChildNode(pointMarker!)
    }

    private func clearMarker() {
        pointMarker?.removeFromParentNode()
        pointMarker = nil
    }

    // MARK: Создание конструкций

    private func build(from a: SCNVector3, to b: SCNVector3,
                       firstKind: PlaneKind, secondKind: PlaneKind,
                       normal: SCNVector3, sys: KnaufSystem) {
        switch sys.category {
        case .partition:
            let dx = b.x - a.x, dz = b.z - a.z
            guard sqrt(dx * dx + dz * dz) > 0.15 else {
                setStatus("Слишком короткий участок — укажите точки дальше"); return
            }
            addConstruct(Construct(kind: .partition, sys: sys, a: a, b: b, normal: normal,
                                   ceilingY: 0, height: partitionHeight))
        case .lining:
            guard dist(a, b) > 0.15 else { setStatus("Слишком короткий участок"); return }
            addConstruct(Construct(kind: .lining, sys: sys, a: a, b: b, normal: normal,
                                   ceilingY: 0, height: liningHeight))
        case .ceiling:
            guard abs(b.x - a.x) > 0.3, abs(b.z - a.z) > 0.3 else { setStatus("Участок слишком мал"); return }
            let ceilY: Float = firstKind == .ceiling ? a.y
                             : (secondKind == .ceiling ? b.y : Float(manualCeil))
            addConstruct(Construct(kind: .ceiling, sys: sys, a: a, b: b, normal: normal,
                                   ceilingY: ceilY, height: 0))
        case .floor:
            guard abs(b.x - a.x) > 0.3, abs(b.z - a.z) > 0.3 else { setStatus("Участок слишком мал"); return }
            addConstruct(Construct(kind: .floor, sys: sys, a: a, b: b, normal: normal,
                                   ceilingY: 0, height: 0))
        }
    }

    private func addConstruct(_ c: Construct) {
        rebuildNode(c)
        constructs.append(c)
        lastOpeningConstruct = nil
    }

    /// Пересобирает модель и спецификацию конструкции (используется и при вырезании проёмов)
    private func rebuildNode(_ c: Construct) {
        c.node?.removeFromParentNode()
        let node: SCNNode
        switch c.kind {
        case .partition: node = makePartitionNode(c)
        case .lining:    node = makeLiningNode(c)
        case .ceiling:   node = makeCeilingNode(c)
        case .floor:     node = makeFloorNode(c)
        }
        c.node = node
        sceneView.scene.rootNode.addChildNode(node)
        applyXray(to: node)
        switch c.kind {
        case .partition: c.specs = partitionSpecs(c)
        case .lining:    c.specs = liningSpecs(c)
        case .ceiling:   c.specs = ceilingSpecs(c)
        case .floor:     c.specs = floorSpecs(c)
        }
    }

    private func constructLength(_ c: Construct) -> Double {
        let dx = c.b.x - c.a.x, dz = c.b.z - c.a.z
        return Double(sqrt(dx * dx + dz * dz))
    }

    private func construct(for node: SCNNode) -> Construct? {
        var cur: SCNNode? = node
        while let n = cur {
            if let c = constructs.first(where: { $0.node === n }) { return c }
            cur = n.parent
        }
        return nil
    }

    // MARK: Геометрия

    private func boxGeo(width: CGFloat, height: CGFloat, length: CGFloat, color: UIColor) -> SCNGeometry {
        let geo = SCNBox(width: width, height: height, length: length, chamferRadius: 0)
        let m = SCNMaterial()
        m.diffuse.contents = color
        if color == Palette.metal { m.metalness = 0.5; m.roughness = 0.45 }
        geo.materials = [m]
        return geo
    }

    private func addBox(_ parent: SCNNode, _ w: CGFloat, _ h: CGFloat, _ d: CGFloat,
                        _ color: UIColor, at p: SCNVector3, role: String) {
        let n = SCNNode(geometry: boxGeo(width: w, height: h, length: d, color: color))
        n.position = p
        n.name = role
        parent.addChildNode(n)
    }

    /// Лист обшивки с прямоугольными вырезами (SCNShape + even-odd path)
    private func sheetNode(width: CGFloat, height: CGFloat, thickness: CGFloat,
                           openings: [CGRect], color: UIColor, center: SCNVector3) -> SCNNode {
        let sheetRect = CGRect(x: -width / 2, y: -height / 2, width: width, height: height)
        let valid = openings.map { $0.intersection(sheetRect) }
                            .filter { !$0.isNull && $0.width > 0.02 && $0.height > 0.02 }
        let node: SCNNode
        if valid.isEmpty {
            node = SCNNode(geometry: boxGeo(width: width, height: height, length: thickness, color: color))
            node.position = center
        } else {
            let path = UIBezierPath(rect: sheetRect)
            for o in valid {
                path.append(UIBezierPath(rect: o))
            }
            path.usesEvenOddFillRule = true
            let shape = SCNShape(path: path, extrusionDepth: thickness)
            let m = SCNMaterial()
            m.diffuse.contents = color
            m.isDoubleSided = true
            shape.materials = [m]
            node = SCNNode(geometry: shape)
            let bb = node.boundingBox
            let cx = (bb.min.x + bb.max.x) / 2
            let cy = (bb.min.y + bb.max.y) / 2
            let cz = (bb.min.z + bb.max.z) / 2
            node.position = v(center.x - cx, center.y - cy, center.z - cz)
        }
        return node
    }

    /// Проёмы конструкции → координаты листа (лист строится от центра)
    private func sheetOpenings(_ c: Construct, L: CGFloat, H: CGFloat) -> [CGRect] {
        c.openings.map { CGRect(x: $0.minX - L / 2, y: $0.minY - H / 2,
                                width: $0.width, height: $0.height) }
    }

    // MARK: Раскрой листовых материалов

    /// Стены/перегородки: вертикальная раскладка полосами 1,2 м, лист 1,2×2,5 м, +10 % запаса
    private func wallSheets(length: Double, height: Double, openings: [CGRect],
                            layers: Int, sides: Int) -> Int {
        let sheetW = 1.2, sheetH = 2.5
        let strips = max(1, Int((length / sheetW).rounded(.up)))
        var total = 0
        for i in 0..<strips {
            let x0 = Double(i) * sheetW
            let x1 = x0 + sheetW
            var segs: [(Double, Double)] = [(0, height)]
            for o in openings {
                guard Double(o.minX) < x1 && Double(o.maxX) > x0 else { continue }
                var next: [(Double, Double)] = []
                for s in segs {
                    let a = Double(o.minY), b = Double(o.maxY)
                    if b <= s.0 || a >= s.1 { next.append(s); continue }
                    if a > s.0 { next.append((s.0, min(a, s.1))) }
                    if b < s.1 { next.append((max(b, s.0), s.1)) }
                }
                segs = next
            }
            total += segs.reduce(0) { $0 + max(1, Int((($1.1 - $1.0) / sheetH).rounded(.up))) }
        }
        return Int((Double(total * layers * sides) * (1 + kSheetWaste)).rounded(.up))
    }

    /// Потолки: полосы 1,2 м поперёк короткой стороны, +10 %
    private func ceilingSheets(w: Double, d: Double) -> Int {
        let along = max(w, d), across = min(w, d)
        let strips = max(1, Int((across / 1.2).rounded(.up)))
        let perStrip = max(1, Int((along / 2.5).rounded(.up)))
        return Int((Double(strips * perStrip) * (1 + kSheetWaste)).rounded(.up))
    }

    /// Полы: элементы ГВЛВ 1200×600 (0,72 м²), +10 %
    private func floorElements(area: Double) -> Int {
        Int((area / 0.72 * (1 + kSheetWaste)).rounded(.up))
    }

    // MARK: Построение: перегородка

    private func makePartitionNode(_ c: Construct) -> SCNNode {
        let dx = c.b.x - c.a.x, dz = c.b.z - c.a.z
        let L = CGFloat(sqrt(dx * dx + dz * dz))
        let H = CGFloat(c.height)
        let t = CGFloat(c.sys.thicknessMM) / 100
        let sheetT = CGFloat(c.sys.layers) * 0.0125
        let fw = CGFloat(0.05)
        let openings = sheetOpenings(c, L: L, H: H)

        let root = SCNNode()
        root.name = c.sys.code
        root.position = c.a
        root.eulerAngles.y = atan2(-Float(dz), Float(dx))

        for side: Float in [-1, 1] {
            let z = side * (Float(t) - Float(sheetT)) / 2
            let s = sheetNode(width: L, height: H, thickness: sheetT, openings: openings,
                              color: Palette.board, center: v(Float(L) / 2, Float(H) / 2, z))
            s.name = "sheet"
            root.addChildNode(s)
        }
        addBox(root, L, 0.045, fw, Palette.metal, at: v(Float(L) / 2, 0.0225, 0), role: "frame")
        addBox(root, L, 0.045, fw, Palette.metal, at: v(Float(L) / 2, Float(H) - 0.0225, 0), role: "frame")
        let count = max(2, Int((Double(L) / (c.sys.spacingMM / 1000)).rounded(.up)) + 1)
        for i in 0..<count {
            let x = Float(L) * Float(i) / Float(count - 1)
            addBox(root, fw, H - 0.09, fw, Palette.metal, at: v(x, Float(H) / 2, 0), role: "frame")
        }
        addLabel("\(c.sys.code) · \(num(Float(L)))×\(num(Float(H))) м · \(c.sys.thicknessMM) мм",
                 to: root, at: v(Float(L) / 2, Float(H) + 0.15, 0))
        return root
    }

    private func partitionSpecs(_ c: Construct) -> [SpecEntry] {
        let L = constructLength(c)
        let H = c.height
        let opArea = c.openings.reduce(0.0) { $0 + Double($1.width * $1.height) }
        let net = max(0, L * H - opArea)
        let sheets = wallSheets(length: L, height: H, openings: c.openings,
                                layers: c.sys.layers, sides: 2)
        let count = max(2, Int((L / (c.sys.spacingMM / 1000)).rounded(.up)) + 1)
        let cwName = c.sys.frame == .cw75 ? "Профиль ПС 75 (CW 75)" : "Профиль ПС 50 (CW 50)"
        let uwName = c.sys.frame == .cw75 ? "Профиль ПН 75 (UW 75)" : "Профиль ПН 50 (UW 50)"
        var specs = [
            SpecEntry("Лист ГКЛ 12,5 мм (1200×2500)", Double(sheets), "шт"),
            SpecEntry(cwName, Double(count) * H, "м.п."),
            SpecEntry(uwName, 2 * L, "м.п."),
            SpecEntry("Шуруп ТН 3,5×25", net * 17, "шт"),
            SpecEntry("Лента КНАУФ (армирующая)", net * 0.9, "м"),
            SpecEntry("КНАУФ-Фуген", net * 0.35, "кг"),
            SpecEntry("Грунтовка КНАУФ-Тифенгрунд", net * 0.12, "л"),
            SpecEntry("Минвата КНАУФ Insulation (опция)", net, "м²")
        ]
        if !c.openings.isEmpty {
            let heads = c.openings.reduce(0.0) { $0 + Double($1.width) }
            let jambs = c.openings.reduce(0.0) { $0 + Double(2 * $1.height) }
            let perim = c.openings.reduce(0.0) { $0 + Double(2 * ($1.width + $1.height)) }
            specs.append(SpecEntry("Профиль ПН — перемычки проёмов", heads, "м.п."))
            specs.append(SpecEntry("Профиль ПС — усиление откосов", jambs, "м.п."))
            specs.append(SpecEntry("Лента КНАУФ — примыкания проёмов", perim, "м"))
        }
        return specs
    }

    // MARK: Построение: облицовка

    private func makeLiningNode(_ c: Construct) -> SCNNode {
        let L = CGFloat(constructLength(c))
        let H = CGFloat(c.height)
        let frameD = CGFloat(c.sys.frame.depthMM) / 100
        let sheetT = CGFloat(c.sys.layers) * 0.0125
        let openings = sheetOpenings(c, L: L, H: H)

        let mid = (c.a + c.b) * 0.5
        let zA = norm(c.normal)
        let xA = norm(cross(v(0, 1, 0), zA))
        let root = SCNNode()
        root.name = c.sys.code
        root.simdTransform = simd_float4x4(
            simd_float4(xA.x, xA.y, xA.z, 0),
            simd_float4(0, 1, 0, 0),
            simd_float4(zA.x, zA.y, zA.z, 0),
            simd_float4(mid.x, mid.y, mid.z, 1)
        )

        addBox(root, L, 0.027, frameD, Palette.metal, at: v(0, 0.0135, frameD / 2), role: "frame")
        addBox(root, L, 0.027, frameD, Palette.metal, at: v(0, H - 0.0135, frameD / 2), role: "frame")
        let count = max(2, Int((Double(L) / (c.sys.spacingMM / 1000)).rounded(.up)) + 1)
        for i in 0..<count {
            let x = Float(L) * Float(i) / Float(count - 1)
            addBox(root, 0.05, H - 0.054, frameD, Palette.metal,
                   at: v(x, Float(H) / 2, Float(frameD) / 2), role: "frame")
        }
        for layer in 0..<c.sys.layers {
            let z = Float(frameD) + Float(sheetT) * (Float(layer) + 0.5)
            let s = sheetNode(width: L, height: H, thickness: sheetT, openings: openings,
                              color: Palette.board, center: v(0, Float(H) / 2, z))
            s.name = "sheet"
            root.addChildNode(s)
        }
        addLabel("\(c.sys.code) · \(num(Float(L)))×\(num(Float(H))) м",
                 to: root, at: v(0, Float(H) + 0.15, Float(frameD)))
        return root
    }

    private func liningSpecs(_ c: Construct) -> [SpecEntry] {
        let L = constructLength(c)
        let H = c.height
        let opArea = c.openings.reduce(0.0) { $0 + Double($1.width * $1.height) }
        let net = max(0, L * H - opArea)
        let sheets = wallSheets(length: L, height: H, openings: c.openings,
                                layers: c.sys.layers, sides: 1)
        let nStud = max(2, Int((L / 0.6).rounded(.up)) + 1)
        var specs: [SpecEntry]
        if c.sys.frame == .pp60 || c.sys.frame == .doublePP {
            let perStud = max(1, Int((H / 0.75).rounded(.up)))
            specs = [
                SpecEntry("Лист ГКЛ 12,5 мм (1200×2500)", Double(sheets), "шт"),
                SpecEntry("Профиль ПН 28 (UD)", 2 * L, "м.п."),
                SpecEntry("Профиль ПП 60×27 (CD)", Double(nStud) * H, "м.п."),
                SpecEntry("Подвес прямой П6", Double(nStud * perStud), "шт"),
                SpecEntry("Шуруп ТН 3,5×25", net * 17, "шт"),
                SpecEntry("Лента КНАУФ (армирующая)", net * 0.9, "м"),
                SpecEntry("КНАУФ-Фуген", net * 0.35, "кг"),
                SpecEntry("Грунтовка КНАУФ-Тифенгрунд", net * 0.12, "л")
            ]
        } else {
            specs = [
                SpecEntry("Лист ГКЛ 12,5 мм (1200×2500)", Double(sheets), "шт"),
                SpecEntry("Профиль ПН 50 (UW 50)", 2 * L, "м.п."),
                SpecEntry("Профиль ПС 50 (CW 50)", Double(nStud) * H, "м.п."),
                SpecEntry("Шуруп ТН 3,5×25", net * 17, "шт"),
                SpecEntry("Лента КНАУФ (армирующая)", net * 0.9, "м"),
                SpecEntry("КНАУФ-Фуген", net * 0.35, "кг"),
                SpecEntry("Грунтовка КНАУФ-Тифенгрунд", net * 0.12, "л")
            ]
        }
        if !c.openings.isEmpty {
            let perim = c.openings.reduce(0.0) { $0 + Double(2 * ($1.width + $1.height)) }
            specs.append(SpecEntry("Профиль ПН — обрамление проёмов", perim, "м.п."))
            specs.append(SpecEntry("Лента КНАУФ — примыкания проёмов", perim, "м"))
        }
        return specs
    }

    // MARK: Построение: потолок

    private func makeCeilingNode(_ c: Construct) -> SCNNode {
        // Потолок по контуру отсканированной комнаты
        if let poly = c.polygon {
            let root = SCNNode()
            root.name = c.sys.code
            let drop = Float(c.sys.dropMM) / 100
            let y0 = c.ceilingY - drop
            let sheet = roomPolygonSlab(poly, thickness: 0.0125, color: Palette.board)
            sheet.position = SCNVector3(0, y0, 0)
            sheet.name = "sheet"
            root.addChildNode(sheet)
            let yProf = y0 + 0.0125 + 0.0135
            for i in 0..<poly.count {
                let a2 = poly[i], b2 = poly[(i + 1) % poly.count]
                let dx = b2.x - a2.x, dz = b2.z - a2.z
                let ln = sqrtf(dx * dx + dz * dz)
                guard ln > 0.05 else { continue }
                let g = SCNBox(width: CGFloat(ln), height: 0.027, length: 0.027, chamferRadius: 0)
                let m = SCNMaterial(); m.diffuse.contents = Palette.metal; m.metalness = 0.5; m.roughness = 0.45
                g.materials = [m]
                let wn = SCNNode(geometry: g)
                wn.position = SCNVector3((a2.x + b2.x) / 2, yProf, (a2.z + b2.z) / 2)
                wn.eulerAngles.y = atan2(-dz, dx)
                root.addChildNode(wn)
            }
            let bnd = boundsOfPolygon(poly)
            var z = bnd.minZ + 0.45
            while z < bnd.maxZ {
                var x = bnd.minX + 0.45
                while x < bnd.maxX {
                    if roomPointInPolygon(RoomPoint(x: x, z: z),
                                          poly.map { RoomPoint(x: $0.x, z: $0.z) }) {
                        let bot = yProf + 0.0135, top = c.ceilingY
                        if top - bot > 0.02 {
                            addBox(root, 0.02, CGFloat(top - bot), 0.02, Palette.metal,
                                   at: v(x, (top + bot) / 2, z), role: "frame")
                        }
                    }
                    x += 0.9
                }
                z += 0.9
            }
            addLabel("\(c.sys.code) · \(num(Float(roomPolygonArea(poly)), 1)) м² · подвес \(c.sys.dropMM) мм",
                     to: root, at: v((bnd.minX + bnd.maxX) / 2, y0 - 0.15, (bnd.minZ + bnd.maxZ) / 2))
            return root
        }

        let w = abs(c.b.x - c.a.x), d = abs(c.b.z - c.a.z)
        let drop = Float(c.sys.dropMM) / 100
        let sheetY = c.ceilingY - drop

        let root = SCNNode()
        root.name = c.sys.code
        root.position = v(min(c.a.x, c.b.x), sheetY, min(c.a.z, c.b.z))

        addBox(root, CGFloat(w), 0.0125, CGFloat(d), Palette.board,
               at: v(w / 2, -0.00625, d / 2), role: "sheet")

        let yProf: Float = 0.0125 + 0.0135
        addBox(root, CGFloat(w), 0.027, 0.027, Palette.metal, at: v(w / 2, yProf, 0.0135), role: "frame")
        addBox(root, CGFloat(w), 0.027, 0.027, Palette.metal, at: v(w / 2, yProf, d - 0.0135), role: "frame")
        addBox(root, 0.027, 0.027, CGFloat(d - 0.054), Palette.metal, at: v(0.0135, yProf, d / 2), role: "frame")
        addBox(root, 0.027, 0.027, CGFloat(d - 0.054), Palette.metal, at: v(w - 0.0135, yProf, d / 2), role: "frame")

        let nP = max(2, Int((Double(d) / (c.sys.spacingMM / 1000)).rounded(.up)) + 1)
        for i in 0..<nP {
            let z = d * Float(i) / Float(nP - 1)
            addBox(root, CGFloat(w), 0.027, 0.06, Palette.metal, at: v(w / 2, yProf, z), role: "frame")
            let nH = max(2, Int((Double(w) / 0.9).rounded(.up)) + 1)
            for j in 0..<nH {
                let x = w * Float(j) / Float(nH - 1)
                let top = yProf + 0.0135
                let lenH = c.ceilingY - (sheetY + top)
                guard lenH > 0.02 else { continue }
                addBox(root, 0.02, CGFloat(lenH), 0.02, Palette.metal,
                       at: v(x, top + lenH / 2, z), role: "frame")
            }
        }
        addLabel("\(c.sys.code) · \(num(w))×\(num(d)) м · подвес \(c.sys.dropMM) мм",
                 to: root, at: v(w / 2, -0.12, d / 2))
        return root
    }

    private func ceilingSpecs(_ c: Construct) -> [SpecEntry] {
        // Потолок по контуру отсканированной комнаты
        if let poly = c.polygon {
            let area = roomPolygonArea(poly)
            let per = roomPolygonPerimeter(poly)
            let bnd = boundsOfPolygon(poly)
            let w = Double(bnd.maxX - bnd.minX), d = Double(bnd.maxZ - bnd.minZ)
            let fill = (w * d) > 0 ? area / (w * d) : 1
            let nP = max(2, Int((d / (c.sys.spacingMM / 1000)).rounded(.up)) + 1)
            var hangers = 0
            var z = bnd.minZ + 0.45
            while z < bnd.maxZ {
                var x = bnd.minX + 0.45
                while x < bnd.maxX {
                    if roomPointInPolygon(RoomPoint(x: x, z: z),
                                          poly.map { RoomPoint(x: $0.x, z: $0.z) }) { hangers += 1 }
                    x += 0.9
                }
                z += 0.9
            }
            let nCrab = max(0, nP - 2) * max(1, Int(w / 1.2) + 1)
            return [
                SpecEntry("Лист ГКЛ 12,5 мм (1200×2500)", Double(ceilingSheets(w: w, d: d)), "шт"),
                SpecEntry("Профиль ПН 28 (UD)", per, "м.п."),
                SpecEntry("Профиль ПП 60×27 (CD) ≈", Double(nP) * w * fill, "м.п."),
                SpecEntry("Подвес прямой П6", Double(hangers), "шт"),
                SpecEntry("Анкер-клин КНАУФ", Double(hangers), "шт"),
                SpecEntry("Соединитель «краб»", Double(nCrab), "шт"),
                SpecEntry("Шуруп ТН 3,5×25", area * 23, "шт"),
                SpecEntry("Лента КНАУФ (армирующая)", area * 0.8, "м"),
                SpecEntry("КНАУФ-Фуген", area * 0.45, "кг"),
                SpecEntry("Грунтовка КНАУФ-Тифенгрунд", area * 0.15, "л")
            ]
        }

        let w = Double(abs(c.b.x - c.a.x)), d = Double(abs(c.b.z - c.a.z))
        let s = w * d
        let perim = 2 * (w + d)
        let nP = max(2, Int((d / (c.sys.spacingMM / 1000)).rounded(.up)) + 1)
        let nH = max(2, Int((w / 0.9).rounded(.up)) + 1)
        let hangers = nP * nH
        let nCrab = max(0, nP - 2) * max(1, Int(w / 1.2) + 1)
        let sheets = ceilingSheets(w: w, d: d)
        return [
            SpecEntry("Лист ГКЛ 12,5 мм (1200×2500)", Double(sheets), "шт"),
            SpecEntry("Профиль ПН 28 (UD)", perim, "м.п."),
            SpecEntry("Профиль ПП 60×27 (CD)", Double(nP) * w, "м.п."),
            SpecEntry("Подвес прямой П6", Double(hangers), "шт"),
            SpecEntry("Анкер-клин КНАУФ", Double(hangers), "шт"),
            SpecEntry("Соединитель «краб»", Double(nCrab), "шт"),
            SpecEntry("Шуруп ТН 3,5×25", s * 23, "шт"),
            SpecEntry("Лента КНАУФ (армирующая)", s * 0.8, "м"),
            SpecEntry("КНАУФ-Фуген", s * 0.45, "кг"),
            SpecEntry("Грунтовка КНАУФ-Тифенгрунд", s * 0.15, "л")
        ]
    }

    // MARK: Построение: пол

    private func makeFloorNode(_ c: Construct) -> SCNNode {
        let root = SCNNode()
        root.name = c.sys.code

        // Пол по контуру отсканированной комнаты
        if let poly = c.polygon {
            let hSand = Float(c.sys.thicknessMM - 20) / 100
            if hSand > 0.005 {
                let sand = roomPolygonSlab(poly, thickness: CGFloat(hSand), color: Palette.clay)
                sand.position = SCNVector3(0, c.polygonY, 0)
                root.addChildNode(sand)
            } else {
                let film = roomPolygonSlab(poly, thickness: 0.003, color: Palette.underlay)
                film.position = SCNVector3(0, c.polygonY, 0)
                root.addChildNode(film)
            }
            let top = c.polygonY + max(hSand, 0.003)
            let slab = roomPolygonSlab(poly, thickness: 0.02, color: Palette.gvl)
            slab.position = SCNVector3(0, top, 0)
            slab.name = "sheet"
            root.addChildNode(slab)
            let bnd = boundsOfPolygon(poly)
            addLabel("\(c.sys.code) · \(num(Float(roomPolygonArea(poly)), 1)) м² · \(c.sys.thicknessMM) мм",
                     to: root, at: v((bnd.minX + bnd.maxX) / 2, top + 0.1, (bnd.minZ + bnd.maxZ) / 2))
            return root
        }

        let w = abs(c.b.x - c.a.x), d = abs(c.b.z - c.a.z)
        root.position = v(min(c.a.x, c.b.x), 0, min(c.a.z, c.b.z))
        var topY: Float = 0
        let hSand = Float(c.sys.thicknessMM - 20) / 100
        if hSand > 0.005 {
            addBox(root, CGFloat(w), CGFloat(hSand), CGFloat(d), Palette.clay,
                   at: v(w / 2, hSand / 2, d / 2), role: "frame")
            topY = hSand
        } else {
            addBox(root, CGFloat(w), 0.003, CGFloat(d), Palette.underlay,
                   at: v(w / 2, 0.0015, d / 2), role: "frame")
            topY = 0.003
        }
        addBox(root, CGFloat(w), 0.020, CGFloat(d), Palette.gvl,
               at: v(w / 2, topY + 0.010, d / 2), role: "sheet")
        addLabel("\(c.sys.code) · \(num(w))×\(num(d)) м · \(c.sys.thicknessMM) мм",
                 to: root, at: v(w / 2, topY + 0.1, d / 2))
        return root
    }

    private func floorSpecs(_ c: Construct) -> [SpecEntry] {
        let area: Double, per: Double
        if let poly = c.polygon {
            area = roomPolygonArea(poly)
            per = roomPolygonPerimeter(poly)
        } else {
            let w = Double(abs(c.b.x - c.a.x)), d = Double(abs(c.b.z - c.a.z))
            area = w * d
            per = 2 * (w + d)
        }
        let hSand = Double(c.sys.thicknessMM - 20) / 100
        var specs = [
            SpecEntry("Элемент пола КНАУФ ГВЛВ 1200×600×20", Double(floorElements(area: area)), "шт"),
            SpecEntry("Лента кромочная КНАУФ", per, "м"),
            SpecEntry("Клей для стыков (ПВА)", area * 0.05, "кг"),
            SpecEntry("Шуруп ГВЛ 3,9×30", area * 16, "шт"),
            SpecEntry("Плёнка ПЭ 0,2 мм", area, "м²")
        ]
        if hSand > 0.005 {
            specs.insert(SpecEntry("Засыпка керамзитовая КНАУФ", area * hSand, "м³"), at: 0)
        }
        return specs
    }

    // MARK: Проёмы

    @objc private func toggleOpening(_ btn: UIButton) {
        mode = (mode == .opening) ? .build : .opening
        setIconActive(btn, mode == .opening)
        openingFirst = nil
        clearMarker()
        if mode == .opening {
            phase = .idle
            firstPoint = nil
        }
        updateStatus()
    }

    private func handleOpeningTap(_ p: CGPoint) {
        let hits = sceneView.hitTest(p, options: nil)
        guard let hit = hits.first(where: { $0.node.name == "sheet" }),
              let c = construct(for: hit.node),
              c.kind == .partition || c.kind == .lining,
              let node = c.node else {
            setStatus("Коснитесь обшивки построенной перегородки или облицовки")
            return
        }

        let L = constructLength(c)
        let H = c.height
        let local = node.convertPosition(hit.worldCoordinates, from: nil)
        let x = min(max(0, Double(local.x) + (c.kind == .lining ? L / 2 : 0)), L)
        let y = min(max(0, Double(local.y)), H)

        guard let first = openingFirst else {
            openingFirst = (c, hit.worldCoordinates)
            placeMarker(at: hit.worldCoordinates)
            updateStatus()
            return
        }
        guard first.construct === c else {
            setStatus("Второй угол должен быть на той же конструкции")
            return
        }

        let l1 = node.convertPosition(first.world, from: nil)
        let x1 = min(max(0, Double(l1.x) + (c.kind == .lining ? L / 2 : 0)), L)
        let y1 = min(max(0, Double(l1.y)), H)

        let rect = CGRect(x: min(x, x1), y: min(y, y1),
                          width: abs(x - x1), height: abs(y - y1))
        openingFirst = nil
        clearMarker()
        guard rect.width >= 0.25, rect.height >= 0.25 else {
            setStatus("Проём слишком мал — минимум 0,25 × 0,25 м")
            return
        }

        c.openings.append(rect)
        rebuildNode(c)
        lastOpeningConstruct = c
        let wStr = String(format: "%.2f", rect.width).replacingOccurrences(of: ".", with: ",")
        let hStr = String(format: "%.2f", rect.height).replacingOccurrences(of: ".", with: ",")
        setStatus("Проём вырезан: \(wStr) × \(hStr) м (всего: \(c.openings.count)). Материалы пересчитаны")
    }

    // MARK: Рентген каркаса

    private func applyXray(to node: SCNNode) {
        node.enumerateChildNodes { n, _ in
            guard n.name == "sheet", let geo = n.geometry else { return }
            geo.materials.forEach { $0.transparency = self.xrayOn ? 0.28 : 1.0 }
        }
    }

    @objc private func xrayChanged() {
        xrayOn = xraySwitch.isOn
        constructs.compactMap { $0.node }.forEach { applyXray(to: $0) }
    }

    // MARK: Измерение

    @objc private func toggleMeasure(_ btn: UIButton) {
        mode = (mode == .measure) ? .build : .measure
        setIconActive(btn, mode == .measure)
        measureRoot?.removeFromParentNode()
        measureRoot = nil
        measureA = nil
        clearMarker()
        phase = .idle
        firstPoint = nil
        openingFirst = nil
        updateStatus()
    }

    private func handleMeasureTap(_ p: CGPoint) {
        let hits = sceneView.hitTest(p, types: [.existingPlaneUsingGeometry, .estimatedHorizontalPlane])
        guard let hit = hits.first else { return }
        let t = hit.worldTransform
        let pos = v(t.columns.3.x, t.columns.3.y, t.columns.3.z)

        if measureA == nil {
            measureA = pos
            updateStatus()
            return
        }
        let a = measureA!
        measureA = nil

        measureRoot?.removeFromParentNode()
        let root = SCNNode()
        let d = dist(a, pos)
        guard d > 0.02 else { updateStatus(); return }

        let cyl = SCNCylinder(radius: 0.004, height: CGFloat(d))
        let m = SCNMaterial()
        m.diffuse.contents = Palette.accent
        m.emission.contents = Palette.accent
        cyl.materials = [m]
        let line = SCNNode(geometry: cyl)
        line.position = (a + pos) * 0.5
        let dir = norm(pos - a)
        let axis = cross(v(0, 1, 0), dir)
        if len(axis) > 0.001 {
            let angle = acos(max(-1, min(1, dir.y)))
            line.rotation = SCNVector4(axis.x, axis.y, axis.z, angle)
        }
        root.addChildNode(line)

        func dotNode(_ p: SCNVector3) {
            let g = SCNSphere(radius: 0.012)
            g.materials = [m]
            let n = SCNNode(geometry: g)
            n.position = p
            root.addChildNode(n)
        }
        dotNode(a); dotNode(pos)

        let lbl = makeLabel("\(num(d)) м", scale: 0.005)
        lbl.position = (a + pos) * 0.5
        root.addChildNode(lbl)

        sceneView.scene.rootNode.addChildNode(root)
        measureRoot = root
        updateStatus()
    }

    // MARK: Отмена / очистка

    @objc private func undoAction() {
        if mode == .opening {
            if openingFirst != nil {
                openingFirst = nil
                clearMarker()
                setStatus("Первая точка проёма отменена")
            } else if let c = lastOpeningConstruct, !c.openings.isEmpty {
                c.openings.removeLast()
                rebuildNode(c)
                lastOpeningConstruct = c.openings.isEmpty ? nil : c
                setStatus("Последний проём восстановлен, материалы пересчитаны")
            } else {
                setStatus("Нет проёмов для отмены")
            }
            return
        }
        if phase == .firstSet {
            firstPoint = nil
            clearMarker()
            phase = .idle
            updateStatus()
            return
        }
        guard let last = constructs.popLast() else { return }
        last.node?.removeFromParentNode()
        if lastOpeningConstruct === last { lastOpeningConstruct = nil }
    }

    @objc private func clearAction() {
        constructs.forEach { $0.node?.removeFromParentNode() }
        constructs.removeAll()
        lastOpeningConstruct = nil
        measureRoot?.removeFromParentNode()
        measureRoot = nil
        clearMarker()
        openingFirst = nil
        phase = .idle
        firstPoint = nil
        updateStatus()
    }

    // MARK: Спецификация и PDF

    private func currentTotals() -> [TotalItem] {
        var dict: [String: (qty: Double, unit: String)] = [:]
        for e in constructs.flatMap({ $0.specs }) {
            if var t = dict[e.item] { t.qty += e.qty; dict[e.item] = t }
            else { dict[e.item] = (e.qty, e.unit) }
        }
        return dict.sorted { $0.key < $1.key }
            .map { TotalItem(item: $0.key, qty: $0.value.qty, unit: $0.value.unit) }
    }

    private func formatQty(_ qty: Double, unit: String) -> String {
        if unit == "шт" { return String(Int(qty.rounded(.up))) }
        return String(format: "%.1f", qty).replacingOccurrences(of: ".", with: ",")
    }

    @objc private func specAction(_ sender: UIButton) {
        let totals = currentTotals()
        guard !totals.isEmpty else {
            setStatus("Постройте конструкции — спецификация соберётся автоматически")
            return
        }
        let ac = UIAlertController(title: "Спецификация материалов",
                                   message: "Позиций: \(totals.count) · конструкций: \(constructs.count)",
                                   preferredStyle: .actionSheet)
        ac.addAction(UIAlertAction(title: "Показать на экране", style: .default) { _ in
            self.showSpecDialog(totals)
        })
        ac.addAction(UIAlertAction(title: "Экспорт PDF…", style: .default) { _ in
            self.exportPDF(totals)
        })
        ac.addAction(UIAlertAction(title: "Сбросить расчёт (модели останутся)", style: .destructive) { _ in
            self.constructs.forEach { $0.specs = [] }
            self.setStatus("Расчёт сброшен")
        })
        ac.addAction(UIAlertAction(title: "Отмена", style: .cancel))
        ac.popoverPresentationController?.sourceView = sender
        present(ac, animated: true)
    }

    private func showSpecDialog(_ totals: [TotalItem]) {
        var lines = ["Оценка по построенным объектам:", ""]
        for t in totals {
            lines.append("· \(t.item) — \(formatQty(t.qty, unit: t.unit)) \(t.unit)")
        }
        lines.append("")
        lines.append("Листы: раскладка 1200×2500 (пол 1200×600), запас 10 %. Проёмы учтены.")
        lines.append("Уточняйте по альбому технических решений КНАУФ.")
        let ac = UIAlertController(title: "Спецификация", message: lines.joined(separator: "\n"),
                                   preferredStyle: .alert)
        ac.addAction(UIAlertAction(title: "Закрыть", style: .cancel))
        present(ac, animated: true)
    }

    private func exportPDF(_ totals: [TotalItem]) {
        let pageRect = CGRect(x: 0, y: 0, width: 595, height: 842) // A4
        let renderer = UIGraphicsPDFRenderer(bounds: pageRect)
        let df = DateFormatter()
        df.locale = Locale(identifier: "ru_RU")
        df.dateStyle = .long

        let data = renderer.pdfData { ctx in
            var y: CGFloat = 0
            func newPage() { ctx.beginPage(); y = 48 }
            func draw(_ s: String, size: CGFloat, weight: UIFont.Weight = .regular, color: UIColor = .black) {
                let attrs: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: size, weight: weight),
                                                            .foregroundColor: color]
                let h = s.size(withAttributes: attrs).height
                if y == 0 || y + h > 794 { newPage() }
                s.draw(at: CGPoint(x: 48, y: y), withAttributes: attrs)
                y += h + 6
            }
            draw("КНАУФ AR — спецификация материалов", size: 18, weight: .bold)
            draw("Дата: \(df.string(from: Date())) · конструкций: \(self.constructs.count)",
                 size: 10, color: .darkGray)
            let byCode = Dictionary(grouping: self.constructs, by: { $0.sys.code })
            for (code, list) in byCode.sorted(by: { $0.key < $1.key }) {
                guard let s = list.first?.sys else { continue }
                var line = "• \(code) — \(s.name)"
                if let rw = s.rw { line += " · Rw \(rw) дБ" }
                if let ei = s.ei { line += " · EI \(ei)" }
                draw(line + "  (\(list.count) шт.)", size: 10, color: .darkGray)
            }
            draw(" ", size: 6)
            for t in totals {
                draw("• \(t.item) — \(self.formatQty(t.qty, unit: t.unit)) \(t.unit)", size: 12)
            }
            draw(" ", size: 6)
            draw("Листовые материалы посчитаны по раскладке 1200×2500 мм (элементы пола 1200×600 мм) с запасом 10 % на подрезку.",
                 size: 9, color: .gray)
            draw("Проёмы учтены: площадь вычтена, добавлено усиление каркаса.", size: 9, color: .gray)
            draw("Значения ориентировочные. Точные нормы и характеристики — в альбоме технических решений КНАУФ (knauf.ru).",
                 size: 9, color: .gray)
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("KNAUF_AR_specification.pdf")
        try? data.write(to: url)
        let av = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        av.popoverPresentationController?.sourceView = view
        present(av, animated: true)
    }

    @objc private func snapshotAction() {
        let img = sceneView.snapshot()
        let av = UIActivityViewController(activityItems: [img], applicationActivities: nil)
        av.popoverPresentationController?.sourceView = view
        present(av, animated: true)
    }

    // MARK: Помещение (скан, план, контурные конструкции, каталог)

    @objc private func roomAction(_ sender: UIButton) {
        let hasRoom = RoomStore.shared.room != nil
        let ac = UIAlertController(title: "Помещение",
                                   message: hasRoom ? "Модель отсканирована" : "Помещение ещё не отсканировано",
                                   preferredStyle: .actionSheet)
        ac.addAction(UIAlertAction(title: "Сканировать / обновить помещение", style: .default) { _ in
            self.present(RoomScanController(), animated: true)
        })
        if hasRoom {
            ac.addAction(UIAlertAction(title: "2D-план, размеры, площадь и объём", style: .default) { _ in
                self.showPlan()
            })
            ac.addAction(UIAlertAction(title: "Пол КНАУФ по контуру комнаты", style: .default) { _ in
                self.buildRoomSlab(floor: true)
            })
            ac.addAction(UIAlertAction(title: "Потолок КНАУФ по контуру комнаты", style: .default) { _ in
                self.buildRoomSlab(floor: false)
            })
            ac.addAction(UIAlertAction(title: "Удалить модель помещения", style: .destructive) { _ in
                RoomStore.shared.clear()
                self.removeRoomNodes()
                self.setStatus("Модель помещения удалена")
            })
        }
        ac.addAction(UIAlertAction(title: "Обновить каталог КНАУФ (Wi-Fi)", style: .default) { _ in
            self.refreshCatalog()
        })
        ac.addAction(UIAlertAction(title: "Отмена", style: .cancel))
        ac.popoverPresentationController?.sourceView = sender
        present(ac, animated: true)
    }

    private func showPlan() {
        let parts = constructs.compactMap { c -> (code: String, a: SCNVector3, b: SCNVector3)? in
            guard c.kind == .partition || c.kind == .lining else { return nil }
            return (c.sys.code, c.a, c.b)
        }
        present(PlanViewController(room: RoomStore.shared.room, partitions: parts), animated: true)
    }

    private func buildRoomSlab(floor: Bool) {
        guard let room = RoomStore.shared.room, room.corners.count >= 3 else { return }
        guard let sys = selected[floor ? .floor : .ceiling] else { return }
        let fy = room.floorY
        let c = Construct(kind: floor ? .floor : .ceiling, sys: sys,
                          a: SCNVector3(0, 0, 0), b: SCNVector3(0, 0, 0),
                          normal: SCNVector3(0, floor ? 1 : -1, 0),
                          ceilingY: floor ? 0 : fy + Float(room.height), height: 0)
        c.polygon = room.corners.map { SCNVector3($0.x, 0, $0.z) }
        c.polygonY = fy
        addConstruct(c)
        let nf = NumberFormatter(); nf.maximumFractionDigits = 1; nf.decimalSeparator = ","
        setStatus("\(floor ? "Пол" : "Потолок") \(sys.code) построен по контуру: "
                 + "\(nf.string(from: NSNumber(value: room.floorArea)) ?? "-") м². Материалы в спецификации")
    }

    private func refreshCatalog() {
        if CatalogStore.shared.remoteURL == nil {
            let ac = UIAlertController(title: "Адрес каталога",
                message: "Введите ссылку на catalog.json:\nraw.githubusercontent.com/ВАШ_ЛОГИН/knauf-ar/main/catalog.json",
                preferredStyle: .alert)
            ac.addTextField { $0.text = "https://raw.githubusercontent.com/" }
            ac.addAction(UIAlertAction(title: "Сохранить и обновить", style: .default) { _ in
                CatalogStore.shared.setRemoteURL(ac.textFields?.first?.text)
                self.refreshCatalog()
            })
            ac.addAction(UIAlertAction(title: "Отмена", style: .cancel))
            present(ac, animated: true)
            return
        }
        setStatus("Обновление каталога…")
        CatalogStore.shared.refresh { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let msg):
                if let cur = self.selected[self.currentCategory] {
                    let list = CatalogStore.shared.systems(in: self.currentCategory)
                    self.selected[self.currentCategory] = list.first { $0.code == cur.code } ?? list.first
                }
                self.systemsTable.reloadData()
                self.refreshSummary()
                self.setStatus(msg)
            case .failure(let err):
                self.setStatus("Ошибка: \(err.localizedDescription)")
            }
        }
    }

    private func removeRoomNodes() {
        roomNode?.removeFromParentNode()
        roomNode = nil
    }

    private func roomLabel(_ text: String) -> SCNNode {
        let geo = SCNText(string: text, extrusionDepth: 0)
        geo.font = UIFont.systemFont(ofSize: 8, weight: .semibold)
        geo.flatness = 0.2
        let m = SCNMaterial()
        m.diffuse.contents = Palette.blue
        m.isDoubleSided = true
        geo.materials = [m]
        let n = SCNNode(geometry: geo)
        let bb = n.boundingBox
        n.pivot = SCNMatrix4MakeTranslation((bb.min.x + bb.max.x) / 2, (bb.min.y + bb.max.y) / 2, 0)
        n.scale = SCNVector3(0.006, 0.006, 0.006)
        let bc = SCNBillboardConstraint(); bc.freeAxes = .all
        n.constraints = [bc]
        let c = SCNNode(); c.addChildNode(n)
        return c
    }

    private func presentRoomModel() {
        removeRoomNodes()
        guard let room = RoomStore.shared.room, room.corners.count >= 3 else { return }
        let root = SCNNode()
        root.name = "roomModel"
        let slab = roomPolygonSlab(room.corners.map { SCNVector3($0.x, 0, $0.z) },
                                   thickness: 0.005,
                                   color: UIColor(red: 0.55, green: 0.72, blue: 0.90, alpha: 0.35))
        root.addChildNode(slab)
        let h = room.height
        let fy = room.floorY
        let n = room.corners.count
        for i in 0..<n {
            let a = room.corners[i], b = room.corners[(i + 1) % n]
            let dx = b.x - a.x, dz = b.z - a.z
            let ln = sqrtf(dx * dx + dz * dz)
            guard ln > 0.05 else { continue }
            let plane = SCNPlane(width: CGFloat(ln), height: CGFloat(h))
            let m = SCNMaterial()
            m.diffuse.contents = UIColor(red: 0.55, green: 0.72, blue: 0.90, alpha: 0.18)
            m.isDoubleSided = true
            plane.materials = [m]
            let wall = SCNNode(geometry: plane)
            wall.position = v((a.x + b.x) / 2, fy + h / 2, (a.z + b.z) / 2)
            wall.eulerAngles.y = atan2(-dz, dx)
            root.addChildNode(wall)
            let lbl = roomLabel("\(Int(ln * 100))")
            lbl.position = v((a.x + b.x) / 2, fy + 0.06, (a.z + b.z) / 2)
            root.addChildNode(lbl)
        }
        let bnd = room.bounds
        let nf = NumberFormatter(); nf.maximumFractionDigits = 1; nf.decimalSeparator = ","
        let summary = roomLabel("H \(Int(h * 100)) · S \(nf.string(from: NSNumber(value: room.floorArea)) ?? "-") м² · V \(nf.string(from: NSNumber(value: room.volume)) ?? "-") м³")
        summary.position = v((bnd.minX + bnd.maxX) / 2, fy + h / 2, (bnd.minZ + bnd.maxZ) / 2)
        root.addChildNode(summary)
        sceneView.scene.rootNode.addChildNode(root)
        roomNode = root
    }

    /// Восстановление модели после перезапуска: перед планшетом (ориентация приблизительная)
    private func placeRoomInFront() {
        guard roomNode == nil, RoomStore.shared.room != nil else { return }
        guard let frame = sceneView.session.currentFrame else { return }
        let camT = frame.camera.transform
        let camPos = simd_float3(camT.columns.3.x, camT.columns.3.y, camT.columns.3.z)
        var fwd = -simd_float3(camT.columns.2.x, camT.columns.2.y, camT.columns.2.z)
        fwd.y = 0
        if simd_length(fwd) < 0.001 { fwd = simd_float3(0, 0, -1) }
        fwd = simd_normalize(fwd)

        presentRoomModel()
        guard let root = roomNode, let room = RoomStore.shared.room else { return }
        let bnd = room.bounds
        let cx = (bnd.minX + bnd.maxX) / 2
        let cz = (bnd.minZ + bnd.maxZ) / 2
        let target = camPos + fwd * 3.0
        let wrapper = SCNNode()
        sceneView.scene.rootNode.addChildNode(wrapper)
        wrapper.position = SCNVector3(target.x, room.floorY, target.z)
        wrapper.eulerAngles.y = atan2(fwd.x, fwd.z)
        root.removeFromParentNode()
        wrapper.addChildNode(root)
        root.position = SCNVector3(-cx, -room.floorY, -cz)
        roomNode = wrapper
    }

    // MARK: Статус

    private func setStatus(_ text: String) {
        statusLabel.text = text
    }

    private func updateStatus() {
        guard ARWorldTrackingConfiguration.isSupported else { return }

        let hasFloor = planeKinds.values.contains(.floor)
        let hasWall  = planeKinds.values.contains(.wall)
        let hasCeil  = planeKinds.values.contains(.ceiling)

        func chip(_ l: UILabel, _ ok: Bool, _ okText: String, _ waitText: String) {
            l.text = ok ? "  ✓  \(okText)  " : "  •  \(waitText)  "
            l.textColor = ok ? Palette.okGreen : Palette.inkSoft
        }
        chip(chipFloor, hasFloor, "Пол — найден", "Пол — ищем…")
        chip(chipWall,  hasWall,  "Стены — найдены", "Стены — ищем…")
        chip(chipCeil,  hasCeil,  "Потолок — найден", "Потолок — ищем…")

        if mode == .measure {
            setStatus(measureA == nil ? "Измерение: коснитесь первой точки" : "Коснитесь второй точки")
            return
        }
        if mode == .opening {
            setStatus(openingFirst == nil
                ? "Проёмы: коснитесь обшивки построенной перегородки или облицовки — первый угол"
                : "Коснитесь противоположного угла проёма (на той же конструкции)")
            return
        }
        if planeKinds.isEmpty {
            setStatus("Сканируйте помещение: медленно ведите планшет,\nчтобы обнаружить плоскости")
            return
        }
        guard let sys = selected[currentCategory] else { return }

        switch (currentCategory, phase) {
        case (.partition, .idle):
            setStatus(hasFloor ? "Перегородка \(sys.code): коснитесь пола — начало конструкции"
                               : "Найдите плоскость пола и коснитесь её")
        case (.partition, .firstSet):
            setStatus("Теперь коснитесь пола — конец перегородки")
        case (.lining, .idle):
            setStatus(hasWall ? "Облицовка \(sys.code): коснитесь стены — начало участка"
                              : "Найдите вертикальную плоскость (стену)")
        case (.lining, .firstSet):
            setStatus("Теперь коснитесь стены — конец участка облицовки")
        case (.ceiling, .idle):
            setStatus(hasCeil ? "Потолок \(sys.code): коснитесь потолка — первый угол"
                              : "Потолок не найден — коснитесь пола, высота \(num(Float(manualCeil))) м")
        case (.ceiling, .firstSet):
            setStatus("Коснитесь противоположного угла потолка")
        case (.floor, .idle):
            setStatus("Пол \(sys.code): коснитесь пола — первый угол участка")
        case (.floor, .firstSet):
            setStatus("Коснитесь противоположного угла участка")
        }
    }

    // MARK: Интерфейс

    private func setupUI() {
        // Статусная карточка
        let statusCard = UIView()
        statusCard.backgroundColor = Palette.paper
        statusCard.layer.cornerRadius = 14
        statusCard.layer.shadowColor = UIColor.black.cgColor
        statusCard.layer.shadowOpacity = 0.12
        statusCard.layer.shadowRadius = 8
        statusCard.layer.shadowOffset = CGSize(width: 0, height: 3)
        statusCard.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(statusCard)
        statusLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        statusLabel.textColor = Palette.ink
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 2
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusCard.addSubview(statusLabel)
        NSLayoutConstraint.activate([
            statusCard.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 10),
            statusCard.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            statusLabel.topAnchor.constraint(equalTo: statusCard.topAnchor, constant: 8),
            statusLabel.bottomAnchor.constraint(equalTo: statusCard.bottomAnchor, constant: -8),
            statusLabel.leadingAnchor.constraint(equalTo: statusCard.leadingAnchor, constant: 16),
            statusLabel.trailingAnchor.constraint(equalTo: statusCard.trailingAnchor, constant: -16)
        ])

        // Чипы обнаруженных плоскостей
        chipsStack.axis = .vertical
        chipsStack.alignment = .leading
        chipsStack.spacing = 6
        chipsStack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(chipsStack)
        for l in [chipFloor, chipWall, chipCeil] {
            l.font = .systemFont(ofSize: 12, weight: .semibold)
            l.textColor = Palette.inkSoft
            l.backgroundColor = Palette.paper
            l.layer.cornerRadius = 10
            l.clipsToBounds = true
            l.text = "  •  "
            chipsStack.addArrangedSubview(l)
        }
        NSLayoutConstraint.activate([
            chipsStack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            chipsStack.topAnchor.constraint(equalTo: statusCard.bottomAnchor, constant: 10)
        ])

        // Правая колонка кнопок
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)

        measureBtn = makeIcon("ruler", action: #selector(toggleMeasure(_:)))
        let roomBtn = makeIcon("house", action: #selector(roomAction(_:)))
        openingBtn = makeIcon("door.fill", action: #selector(toggleOpening(_:)))
        let specBtn = makeIcon("doc.text", action: #selector(specAction(_:)))
        let undoBtn = makeIcon("arrow.uturn.backward", action: #selector(undoAction))
        let clearBtn = makeIcon("trash", action: #selector(clearAction))
        let shotBtn = makeIcon("camera.viewfinder", action: #selector(snapshotAction))
        [measureBtn, roomBtn, openingBtn, specBtn, undoBtn, clearBtn, shotBtn].forEach { stack.addArrangedSubview($0) }
        NSLayoutConstraint.activate([
            stack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -14),
            stack.topAnchor.constraint(equalTo: statusCard.bottomAnchor, constant: 14)
        ])

        // Нижняя белая панель
        let drawer = UIView()
        drawer.backgroundColor = Palette.paper
        drawer.layer.cornerRadius = 20
        drawer.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        drawer.layer.shadowColor = UIColor.black.cgColor
        drawer.layer.shadowOpacity = 0.10
        drawer.layer.shadowRadius = 10
        drawer.layer.shadowOffset = CGSize(width: 0, height: -3)
        drawer.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(drawer)

        // Категории
        let cats = UIStackView()
        cats.axis = .horizontal
        cats.distribution = .fillEqually
        cats.translatesAutoresizingMaskIntoConstraints = false
        drawer.addSubview(cats)
        for c in SystemCategory.allCases {
            let b = UIButton(type: .system)
            b.setTitle(c.rawValue, for: .normal)
            b.titleLabel?.font = .systemFont(ofSize: 13, weight: .semibold)
            b.layer.cornerRadius = 12
            b.addTarget(self, action: #selector(categoryTapped(_:)), for: .touchUpInside)
            categoryButtons.append(b)
            cats.addArrangedSubview(b)
        }

        // Сводка выбранной системы
        let summary = UIView()
        summary.translatesAutoresizingMaskIntoConstraints = false
        summary.backgroundColor = Palette.field
        summary.layer.cornerRadius = 12
        drawer.addSubview(summary)
        let sumTap = UITapGestureRecognizer(target: self, action: #selector(toggleTable))
        summary.addGestureRecognizer(sumTap)

        codeLabel.font = .monospacedSystemFont(ofSize: 18, weight: .bold)
        codeLabel.textColor = Palette.blue
        nameLabel.font = .systemFont(ofSize: 13, weight: .medium)
        nameLabel.textColor = Palette.ink
        nameLabel.numberOfLines = 2
        dimsLabel.font = .systemFont(ofSize: 12)
        dimsLabel.textColor = Palette.inkSoft
        chevron.image = UIImage(systemName: "chevron.up")
        chevron.tintColor = Palette.inkSoft
        [codeLabel, nameLabel, dimsLabel, chevron].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            summary.addSubview($0)
        }

        // Слайдер
        sliderCaption.font = .systemFont(ofSize: 12, weight: .medium)
        sliderCaption.textColor = Palette.ink
        slider.minimumTrackTintColor = Palette.blue
        slider.maximumTrackTintColor = Palette.line
        slider.addTarget(self, action: #selector(sliderChanged), for: .valueChanged)
        sliderRow.axis = .vertical
        sliderRow.spacing = 2
        sliderRow.translatesAutoresizingMaskIntoConstraints = false
        [sliderCaption, slider].forEach { sliderRow.addArrangedSubview($0) }
        drawer.addSubview(sliderRow)

        // Рентген
        let xr = UIStackView()
        xr.axis = .horizontal
        xr.translatesAutoresizingMaskIntoConstraints = false
        let xrLabel = UILabel()
        xrLabel.text = "Показать каркас (рентген)"
        xrLabel.font = .systemFont(ofSize: 13, weight: .medium)
        xrLabel.textColor = Palette.ink
        xraySwitch.onTintColor = Palette.blue
        xraySwitch.addTarget(self, action: #selector(xrayChanged), for: .valueChanged)
        xr.addArrangedSubview(xrLabel)
        xr.addArrangedSubview(UIView())
        xr.addArrangedSubview(xraySwitch)
        drawer.addSubview(xr)

        NSLayoutConstraint.activate([
            drawer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            drawer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            drawer.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            drawer.heightAnchor.constraint(equalToConstant: 208),

            cats.topAnchor.constraint(equalTo: drawer.topAnchor, constant: 10),
            cats.leadingAnchor.constraint(equalTo: drawer.leadingAnchor, constant: 16),
            cats.trailingAnchor.constraint(equalTo: drawer.trailingAnchor, constant: -16),
            cats.heightAnchor.constraint(equalToConstant: 32),

            summary.topAnchor.constraint(equalTo: cats.bottomAnchor, constant: 8),
            summary.leadingAnchor.constraint(equalTo: drawer.leadingAnchor, constant: 16),
            summary.trailingAnchor.constraint(equalTo: drawer.trailingAnchor, constant: -16),
            summary.heightAnchor.constraint(equalToConstant: 58),

            codeLabel.topAnchor.constraint(equalTo: summary.topAnchor, constant: 8),
            codeLabel.leadingAnchor.constraint(equalTo: summary.leadingAnchor, constant: 12),
            nameLabel.centerYAnchor.constraint(equalTo: summary.centerYAnchor),
            nameLabel.leadingAnchor.constraint(equalTo: codeLabel.trailingAnchor, constant: 10),
            nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: chevron.leadingAnchor, constant: -8),
            dimsLabel.topAnchor.constraint(equalTo: codeLabel.bottomAnchor, constant: 2),
            dimsLabel.leadingAnchor.constraint(equalTo: summary.leadingAnchor, constant: 12),
            chevron.centerYAnchor.constraint(equalTo: summary.centerYAnchor),
            chevron.trailingAnchor.constraint(equalTo: summary.trailingAnchor, constant: -12),

            sliderRow.topAnchor.constraint(equalTo: summary.bottomAnchor, constant: 8),
            sliderRow.leadingAnchor.constraint(equalTo: drawer.leadingAnchor, constant: 16),
            sliderRow.trailingAnchor.constraint(equalTo: drawer.trailingAnchor, constant: -16),

            xr.topAnchor.constraint(equalTo: sliderRow.bottomAnchor, constant: 8),
            xr.leadingAnchor.constraint(equalTo: drawer.leadingAnchor, constant: 20),
            xr.trailingAnchor.constraint(equalTo: drawer.trailingAnchor, constant: -20)
        ])

        // Таблица систем
        systemsTable.dataSource = self
        systemsTable.delegate = self
        systemsTable.backgroundColor = Palette.paper
        systemsTable.layer.cornerRadius = 16
        systemsTable.clipsToBounds = true
        systemsTable.separatorColor = Palette.line
        systemsTable.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(systemsTable)
        tableHC = systemsTable.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            systemsTable.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            systemsTable.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            systemsTable.bottomAnchor.constraint(equalTo: drawer.topAnchor, constant: -8),
            tableHC
        ])
    }

    private func makeLabel(_ text: String, scale: Float = 0.004) -> SCNNode {
        let container = SCNNode()
        func textNode(color: UIColor) -> SCNNode {
            let geo = SCNText(string: text, extrusionDepth: 0)
            geo.font = UIFont.systemFont(ofSize: 8, weight: .semibold)
            geo.flatness = 0.2
            let m = SCNMaterial()
            m.diffuse.contents = color
            m.isDoubleSided = true
            geo.materials = [m]
            let n = SCNNode(geometry: geo)
            let bb = n.boundingBox
            n.pivot = SCNMatrix4MakeTranslation((bb.min.x + bb.max.x) / 2,
                                                (bb.min.y + bb.max.y) / 2, 0)
            return n
        }
        let shadow = textNode(color: UIColor(white: 0, alpha: 0.85))
        shadow.position = v(0.14, -0.14, -0.05)
        container.addChildNode(shadow)
        container.addChildNode(textNode(color: .white))
        container.scale = SCNVector3(scale, scale, scale)
        let bc = SCNBillboardConstraint()
        bc.freeAxes = .all
        container.constraints = [bc]
        return container
    }

    private func addLabel(_ text: String, to parent: SCNNode, at p: SCNVector3, scale: Float = 0.004) {
        let l = makeLabel(text, scale: scale)
        l.position = p
        parent.addChildNode(l)
    }

    private func makeIcon(_ symbol: String, action: Selector) -> UIButton {
        let b = UIButton(type: .system)
        b.setImage(UIImage(systemName: symbol), for: .normal)
        b.tintColor = Palette.blue
        b.backgroundColor = Palette.paper
        b.layer.cornerRadius = 23
        b.layer.shadowColor = UIColor.black.cgColor
        b.layer.shadowOpacity = 0.12
        b.layer.shadowRadius = 6
        b.layer.shadowOffset = CGSize(width: 0, height: 2)
        b.translatesAutoresizingMaskIntoConstraints = false
        b.widthAnchor.constraint(equalToConstant: 46).isActive = true
        b.heightAnchor.constraint(equalToConstant: 46).isActive = true
        b.addTarget(self, action: action, for: .touchUpInside)
        return b
    }

    private func setIconActive(_ b: UIButton, _ active: Bool) {
        b.backgroundColor = active ? Palette.blue : Palette.paper
        b.tintColor = active ? .white : Palette.blue
    }

    @objc private func categoryTapped(_ sender: UIButton) {
        guard let idx = categoryButtons.firstIndex(of: sender),
              idx < SystemCategory.allCases.count else { return }
        selectCategory(SystemCategory.allCases[idx])
    }

    private func selectCategory(_ c: SystemCategory) {
        currentCategory = c
        if selected[c] == nil {
            selected[c] = CatalogStore.shared.systems(in: c).first
        }
        for (i, b) in categoryButtons.enumerated() {
            let on = SystemCategory.allCases[i] == c
            b.backgroundColor = on ? Palette.blue : Palette.field
            b.setTitleColor(on ? .white : Palette.ink, for: .normal)
        }
        closeTable()
        refreshSummary()
        refreshSlider()
        updateStatus()
    }

    private func refreshSummary() {
        guard let sys = selected[currentCategory] else { return }
        codeLabel.text = sys.code
        nameLabel.text = sys.name
        var dims: String
        switch sys.category {
        case .ceiling: dims = "подвес \(sys.dropMM) мм · \(sys.frame.title)"
        case .floor:   dims = "высота \(sys.thicknessMM) мм · \(sys.frame.title)"
        default:       dims = "толщина \(sys.thicknessMM) мм · \(sys.frame.title)"
        }
        var chars = ""
        if let rw = sys.rw { chars += " · Rw \(rw) дБ" }
        if let ei = sys.ei { chars += " · EI \(ei) мин" }
        dimsLabel.text = dims + chars
    }

    private func refreshSlider() {
        let maxH = selected[currentCategory]?.maxH ?? 99.0
        var warn = ""
        switch currentCategory {
        case .partition:
            slider.isHidden = false; sliderCaption.isHidden = false
            slider.minimumValue = 2.2; slider.maximumValue = 4.0; slider.value = Float(partitionHeight)
            sliderCaption.text = "Высота перегородки · \(num(Float(partitionHeight))) м"
            if partitionHeight > maxH {
                warn = "  ⚠ выше допустимых \(num(Float(maxH), 1)) м — сверьте с альбомом"
            }
        case .lining:
            slider.isHidden = false; sliderCaption.isHidden = false
            slider.minimumValue = 2.2; slider.maximumValue = 4.0; slider.value = Float(liningHeight)
            sliderCaption.text = "Высота облицовки · \(num(Float(liningHeight))) м"
            if liningHeight > maxH {
                warn = "  ⚠ выше допустимых \(num(Float(maxH), 1)) м — сверьте с альбомом"
            }
        case .ceiling:
            slider.isHidden = false; sliderCaption.isHidden = false
            slider.minimumValue = 2.2; slider.maximumValue = 4.5; slider.value = Float(manualCeil)
            sliderCaption.text = "Высота потолка (если не найден) · \(num(Float(manualCeil))) м"
        case .floor:
            slider.isHidden = true; sliderCaption.isHidden = true
        }
        sliderCaption.text = (sliderCaption.text ?? "") + warn
    }

    @objc private func sliderChanged() {
        switch currentCategory {
        case .partition: partitionHeight = Double(slider.value)
        case .lining:    liningHeight = Double(slider.value)
        case .ceiling:   manualCeil = Double(slider.value)
        case .floor:     break
        }
        refreshSlider()
    }

    @objc private func toggleTable() {
        tableOpen.toggle()
        let items = CGFloat(CatalogStore.shared.systems(in: currentCategory).count)
        tableHC.constant = tableOpen ? min(340, items * 58 + 16) : 0
        systemsTable.alpha = tableOpen ? 1 : 0
        chevron.transform = tableOpen ? CGAffineTransform(rotationAngle: .pi) : .identity
        UIView.animate(withDuration: 0.25) { self.view.layoutIfNeeded() }
    }

    private func closeTable() {
        guard tableOpen else { return }
        tableOpen = false
        tableHC.constant = 0
        systemsTable.alpha = 0
        chevron.transform = .identity
        UIView.animate(withDuration: 0.25) { self.view.layoutIfNeeded() }
    }
}

// MARK: - Таблица систем

extension ViewController: UITableViewDataSource, UITableViewDelegate {

    func tableView(_ tv: UITableView, numberOfRowsInSection section: Int) -> Int {
        CatalogStore.shared.systems(in: currentCategory).count
    }

    func tableView(_ tv: UITableView, cellForRowAt ip: IndexPath) -> UITableViewCell {
        let id = "sys"
        let cell: UITableViewCell
        if let c = tv.dequeueReusableCell(withIdentifier: id) { cell = c }
        else { cell = UITableViewCell(style: .subtitle, reuseIdentifier: id) }
        let sys = CatalogStore.shared.systems(in: currentCategory)[ip.row]
        cell.backgroundColor = .clear
        cell.textLabel?.text = "\(sys.code) — \(sys.name)"
        cell.textLabel?.textColor = Palette.ink
        cell.textLabel?.font = .systemFont(ofSize: 14, weight: .semibold)
        var sub: String
        switch sys.category {
        case .ceiling: sub = "подвес \(sys.dropMM) мм · шаг \(Int(sys.spacingMM)) мм"
        case .floor:   sub = "высота \(sys.thicknessMM) мм · \(sys.frame.title)"
        default:       sub = "толщина \(sys.thicknessMM) мм · шаг \(Int(sys.spacingMM)) мм"
        }
        if let rw = sys.rw { sub += " · Rw \(rw)" }
        if let ei = sys.ei { sub += " · EI \(ei)" }
        cell.detailTextLabel?.text = sub
        cell.detailTextLabel?.textColor = Palette.inkSoft
        cell.detailTextLabel?.font = .systemFont(ofSize: 12)
        cell.accessoryType = selected[currentCategory]?.code == sys.code ? .checkmark : .none
        cell.tintColor = Palette.blue
        return cell
    }

    func tableView(_ tv: UITableView, didSelectRowAt ip: IndexPath) {
        tv.deselectRow(at: ip, animated: true)
        let sys = CatalogStore.shared.systems(in: currentCategory)[ip.row]
        selected[currentCategory] = sys
        refreshSummary()
        closeTable()
        updateStatus()
    }
}

// MARK: - ARSCNViewDelegate

extension ViewController: ARSCNViewDelegate {

    func renderer(_ renderer: SCNSceneRenderer, didAdd node: SCNNode, for anchor: ARAnchor) {
        guard let pa = anchor as? ARPlaneAnchor else { return }
        let n = SCNNode()
        n.eulerAngles.x = -.pi / 2
        let plane = SCNPlane(width: CGFloat(pa.extent.x), height: CGFloat(pa.extent.z))
        let m = SCNMaterial()
        switch worldNormal(of: node).y {
        case ..<(-0.5): m.diffuse.contents = UIColor(white: 1, alpha: 0.10)
        case 0.5...:   m.diffuse.contents = UIColor(red: 0.99, green: 0.80, blue: 0.25, alpha: 0.14)
        default:       m.diffuse.contents = UIColor(red: 0.55, green: 0.72, blue: 0.90, alpha: 0.10)
        }
        m.isDoubleSided = true
        plane.materials = [m]
        n.geometry = plane
        n.position = SCNVector3(pa.center.x, pa.center.y, pa.center.z)
        n.opacity = 0
        node.addChildNode(n)
        n.runAction(SCNAction.fadeOpacity(to: 1, duration: 0.3))
        planeNodes[pa] = n
        planeKinds[pa] = worldNormal(of: node).y < -0.5 ? .ceiling
                       : (worldNormal(of: node).y > 0.5 ? .floor : .wall)
        DispatchQueue.main.async { self.updateStatus() }
    }

    func renderer(_ renderer: SCNSceneRenderer, didUpdate node: SCNNode, for anchor: ARAnchor) {
        guard let pa = anchor as? ARPlaneAnchor, let n = planeNodes[pa],
              let plane = n.geometry as? SCNPlane else { return }
        plane.width = CGFloat(pa.extent.x)
        plane.height = CGFloat(pa.extent.z)
        n.position = SCNVector3(pa.center.x, pa.center.y, pa.center.z)
    }

    func renderer(_ renderer: SCNSceneRenderer, didRemove node: SCNNode, for anchor: ARAnchor) {
        guard let pa = anchor as? ARPlaneAnchor else { return }
        planeNodes[pa] = nil
        planeKinds[pa] = nil
        DispatchQueue.main.async { self.updateStatus() }
    }

    private func worldNormal(of node: SCNNode) -> SCNVector3 {
        norm(node.convertVector(SCNVector3(0, 0, 1), to: nil))
    }

    func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
        guard ARWorldTrackingConfiguration.isSupported else { return }
        let center = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
        let hits = sceneView.hitTest(center, types: [.existingPlaneUsingGeometry, .estimatedHorizontalPlane])
        guard let hit = hits.first else {
            focusNode?.isHidden = true
            return
        }
        focusNode?.isHidden = false
        focusNode?.simdTransform = hit.worldTransform

        var valid = false
        if let info = planeInfo(from: hit) {
            switch selected[currentCategory]?.category {
            case .partition, .floor: valid = info.kind == .floor
            case .lining:            valid = info.kind == .wall
            case .ceiling:           valid = info.kind == .ceiling || info.kind == .floor
            case .none:              valid = false
            }
        }
        let color: UIColor
        if mode == .build { color = valid ? Palette.accent : .lightGray }
        else { color = Palette.accent }
        focusTorus?.materials.first?.diffuse.contents = color
        focusTorus?.materials.first?.emission.contents = color
    }
}
