//
//  RoomModel.swift
//  КНАУФ AR — модель отсканированного помещения
//

import Foundation
import SceneKit

extension Notification.Name {
    static let roomDidUpdate = Notification.Name("knauf.room.didUpdate")
}

struct RoomPoint: Codable {
    var x: Float
    var z: Float
}

struct RoomModel: Codable {
    var corners: [RoomPoint]   // углы пола, мировые XZ, по порядку обхода
    var height: Float          // высота помещения, м
    var floorY: Float = 0      // уровень пола в мировых координатах
    var createdAt: Date = Date()

    var floorArea: Double {
        guard corners.count >= 3 else { return 0 }
        var s = 0.0
        for i in 0..<corners.count {
            let a = corners[i], b = corners[(i + 1) % corners.count]
            s += Double(a.x * b.z - b.x * a.z)
        }
        return abs(s) / 2
    }

    var wallLengths: [Double] {
        (0..<corners.count).map { i in
            let a = corners[i], b = corners[(i + 1) % corners.count]
            return Double(hypotf(b.x - a.x, b.z - a.z))
        }
    }

    var perimeter: Double { wallLengths.reduce(0, +) }

    var bounds: (minX: Float, minZ: Float, maxX: Float, maxZ: Float) {
        var r = (minX: corners[0].x, minZ: corners[0].z, maxX: corners[0].x, maxZ: corners[0].z)
        for c in corners {
            r.minX = min(r.minX, c.x); r.maxX = max(r.maxX, c.x)
            r.minZ = min(r.minZ, c.z); r.maxZ = max(r.maxZ, c.z)
        }
        return r
    }

    /// Площадь стен без вычета проёмов, м²
    var wallArea: Double { perimeter * Double(height) }

    /// Строительный объём, м³
    var volume: Double { floorArea * Double(height) }
}

final class RoomStore {
    static let shared = RoomStore()
    private let key = "knauf.room.model.v1"
    private(set) var room: RoomModel?

    private init() {
        if let d = UserDefaults.standard.data(forKey: key),
           let m = try? JSONDecoder().decode(RoomModel.self, from: d) {
            room = m
        }
    }

    func save(_ m: RoomModel) {
        room = m
        if let d = try? JSONEncoder().encode(m) {
            UserDefaults.standard.set(d, forKey: key)
        }
        NotificationCenter.default.post(name: .roomDidUpdate, object: nil)
    }

    func clear() {
        room = nil
        UserDefaults.standard.removeObject(forKey: key)
    }
}

// MARK: - Геометрия (используется сканером, планом и основным экраном)

func rnorm(_ a: SCNVector3) -> SCNVector3 {
    let l = sqrtf(a.x * a.x + a.y * a.y + a.z * a.z)
    return l > 0.0001 ? SCNVector3(a.x / l, a.y / l, a.z / l) : SCNVector3(0, 1, 0)
}

func rcross(_ a: SCNVector3, _ b: SCNVector3) -> SCNVector3 {
    SCNVector3(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x)
}

func rdist(_ a: SCNVector3, _ b: SCNVector3) -> Float {
    sqrtf((b.x - a.x) * (b.x - a.x) + (b.y - a.y) * (b.y - a.y) + (b.z - a.z) * (b.z - a.z))
}

func roomPointInPolygon(_ p: RoomPoint, _ poly: [RoomPoint]) -> Bool {
    var inside = false
    var j = poly.count - 1
    for i in 0..<poly.count {
        let a = poly[i], b = poly[j]
        if (a.z > p.z) != (b.z > p.z),
           p.x < (b.x - a.x) * (p.z - a.z) / (b.z - a.z) + a.x {
            inside.toggle()
        }
        j = i
    }
    return inside
}

func roomPolygonArea(_ pts: [SCNVector3]) -> Double {
    var s = 0.0
    for i in 0..<pts.count {
        let a = pts[i], b = pts[(i + 1) % pts.count]
        s += Double(a.x * b.z - b.x * a.z)
    }
    return abs(s) / 2
}

func roomPolygonPerimeter(_ pts: [SCNVector3]) -> Double {
    (0..<pts.count).reduce(0.0) { $0 + Double(rdist(pts[$1], pts[($1 + 1) % pts.count])) }
}

func boundsOfPolygon(_ pts: [SCNVector3]) -> (minX: Float, minZ: Float, maxX: Float, maxZ: Float) {
    var r = (minX: pts[0].x, minZ: pts[0].z, maxX: pts[0].x, maxZ: pts[0].z)
    for c in pts {
        r.minX = min(r.minX, c.x); r.maxX = max(r.maxX, c.x)
        r.minZ = min(r.minZ, c.z); r.maxZ = max(r.maxZ, c.z)
    }
    return r
}

/// Полигональная плита (пол/потолок). Экструзия — вверх от позиции узла.
func roomPolygonSlab(_ pts: [SCNVector3], thickness: CGFloat, color: UIColor) -> SCNNode {
    let path = UIBezierPath()
    if let first = pts.first {
        path.move(to: CGPoint(x: CGFloat(first.x), y: CGFloat(-first.z)))
        for c in pts.dropFirst() {
            path.addLine(to: CGPoint(x: CGFloat(c.x), y: CGFloat(-c.z)))
        }
        path.close()
    }
    let shape = SCNShape(path: path, extrusionDepth: thickness)
    let m = SCNMaterial()
    m.diffuse.contents = color
    m.isDoubleSided = true
    shape.materials = [m]
    let node = SCNNode(geometry: shape)
    node.eulerAngles.x = -.pi / 2
    return node
}
