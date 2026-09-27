//
//  CatalogStore.swift
//  КНАУФ AR — офлайн-каталог систем + обновление по Wi-Fi (build-fixed)
//

import Foundation

struct CatalogJSON: Codable {
    var version: String
    var updated: String
    var source: String
    var systems: [SystemJSON]
}

struct SystemJSON: Codable {
    var code: String
    var name: String
    var category: String
    var thicknessMM: Int
    var dropMM: Int
    var layers: Int
    var spacingMM: Double
    var frame: String
    var maxH: Double
    var rw: Int?
    var ei: Int?
    var composition: [String]
}

final class CatalogStore {

    static let shared = CatalogStore()

    private static var fileURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("catalog.json")
    }
    private static let urlKey = "knauf.catalog.remoteURL"

    private(set) var catalog: CatalogJSON

    private init() {
        var loaded: CatalogJSON?
        if let data = try? Data(contentsOf: CatalogStore.fileURL),
           let c = try? JSONDecoder().decode(CatalogJSON.self, from: data), !c.systems.isEmpty {
            loaded = c
        } else if let c = try? JSONDecoder().decode(CatalogJSON.self, from: Data(CatalogStore.embeddedJSON.utf8)) {
            loaded = c
        }
        catalog = loaded ?? CatalogJSON(version: "0", updated: "-", source: "-", systems: [])
    }

    var systems: [KnaufSystem] { catalog.systems.compactMap { KnaufSystem(json: $0) } }

    func systems(in category: SystemCategory) -> [KnaufSystem] {
        systems.filter { $0.category == category }
    }

    // MARK: Обновление по Wi-Fi

    var remoteURL: String? {
        UserDefaults.standard.string(forKey: CatalogStore.urlKey)
    }

    func setRemoteURL(_ s: String?) {
        UserDefaults.standard.set(s, forKey: CatalogStore.urlKey)
    }

    func refresh(completion: @escaping (Result<String, Error>) -> Void) {
        guard let s = remoteURL?.trimmingCharacters(in: .whitespacesAndNewlines),
              !s.isEmpty, let url = URL(string: s) else {
            completion(.failure(CatalogError.message(
                "Не задан адрес каталога. Пример:\nraw.githubusercontent.com/ЛОГИН/knauf-ar/main/catalog.json")))
            return
        }
        URLSession.shared.dataTask(with: url) { data, _, error in
            if let e = error {
                DispatchQueue.main.async { completion(.failure(e)) }
                return
            }
            guard let data = data,
                  let c = try? JSONDecoder().decode(CatalogJSON.self, from: data),
                  !c.systems.isEmpty else {
                DispatchQueue.main.async {
                    completion(.failure(CatalogError.message("Файл по ссылке — не корректный каталог КНАУФ")))
                }
                return
            }
            try? data.write(to: CatalogStore.fileURL)
            DispatchQueue.main.async {
                self.catalog = c
                completion(.success("Каталог обновлён.\nВерсия \(c.version) · \(c.updated)\nСистем: \(c.systems.count)"))
            }
        }.resume()
    }

    enum CatalogError: Error {
        case message(String)
        var localizedDescription: String {
            if case .message(let m) = self { return m }
            return "Ошибка каталога"
        }
    }
}

// MARK: - Преобразование JSON → модель приложения

extension KnaufSystem {
    init?(json: SystemJSON) {
        let category: SystemCategory
        switch json.category {
        case "partition": category = .partition
        case "lining":    category = .lining
        case "ceiling":   category = .ceiling
        case "floor":     category = .floor
        default: return nil
        }
        let frame: Frame
        switch json.frame {
        case "cw50": frame = .cw50
        case "cw75": frame = .cw75
        case "doubleCW50": frame = .doubleCW50
        case "pp60": frame = .pp60
        case "doublePP": frame = .doublePP
        case "dryFloor": frame = .dryFloor
        default: return nil
        }
        self.init(code: json.code, name: json.name, category: category,
                  thicknessMM: json.thicknessMM, dropMM: json.dropMM,
                  layers: json.layers, spacingMM: json.spacingMM,
                  frame: frame, maxH: json.maxH, rw: json.rw, ei: json.ei,
                  composition: json.composition)
    }
}

extension CatalogStore {

    /// Встроенный каталог (офлайн-режим). Содержимое совпадает с catalog.json в репозитории.
    static let embeddedJSON = """
    {
      "version": "2025.06-RU",
      "updated": "2025-06-01",
      "source": "knauf.ru — альбом технических решений (типовые значения, сверить с актуальным альбомом)",
      "systems": [
        {"code":"W111","name":"ПС 50 · 1×ГКЛ с каждой стороны","category":"partition","thicknessMM":75,"dropMM":0,"layers":1,"spacingMM":600,"frame":"cw50","maxH":3.0,"rw":42,"ei":15,"composition":["ПН 50 (UW) — по полу и потолку","ПС 50 (CW) — шаг 600 мм","ГКЛ 12,5 мм — 1 слой с каждой стороны","Фуген + лента, Тифенгрунд"]},
        {"code":"W112","name":"ПС 50 · 2×ГКЛ с каждой стороны","category":"partition","thicknessMM":100,"dropMM":0,"layers":2,"spacingMM":600,"frame":"cw50","maxH":3.5,"rw":49,"ei":30,"composition":["ПН 50 + ПС 50, шаг 600 мм","ГКЛ 12,5 мм — 2 слоя с каждой стороны","Санузлы: ГКЛВ/Аква-Панель"]},
        {"code":"W113","name":"ПС 50 · 3×ГКЛ с каждой стороны","category":"partition","thicknessMM":125,"dropMM":0,"layers":3,"spacingMM":600,"frame":"cw50","maxH":4.0,"rw":52,"ei":45,"composition":["ПН 50 + ПС 50, шаг 600 мм","ГКЛ 12,5 мм — 3 слоя с каждой стороны"]},
        {"code":"W115","name":"ПС 75 · 2×ГКЛ с каждой стороны","category":"partition","thicknessMM":125,"dropMM":0,"layers":2,"spacingMM":600,"frame":"cw75","maxH":4.5,"rw":54,"ei":60,"composition":["ПН 75 + ПС 75, шаг 600 мм","ГКЛ 12,5 мм — 2 слоя с каждой стороны","Минвата КНАУФ Insulation"]},
        {"code":"W611","name":"Двойной каркас 2×ПС 50 · 1×ГКЛ","category":"partition","thicknessMM":135,"dropMM":0,"layers":1,"spacingMM":600,"frame":"doubleCW50","maxH":6.0,"rw":53,"ei":30,"composition":["Два независимых каркаса ПС 50, зазор 10 мм","ГКЛ 12,5 мм — 1 слой с каждой стороны"]},
        {"code":"W621","name":"Двойной каркас 2×ПС 50 · 2×ГКЛ","category":"partition","thicknessMM":160,"dropMM":0,"layers":2,"spacingMM":600,"frame":"doubleCW50","maxH":6.5,"rw":59,"ei":60,"composition":["Два независимых каркаса ПС 50","ГКЛ 12,5 мм — 2 слоя с каждой стороны"]},
        {"code":"C111","name":"Каркас ПП 60×27 · 1×ГКЛ","category":"lining","thicknessMM":40,"dropMM":0,"layers":1,"spacingMM":600,"frame":"pp60","maxH":4.0,"rw":40,"ei":15,"composition":["ПН 28 (UD) по полу и потолку","ПП 60×27 (CD) на подвесах П6, шаг 600 мм","ГКЛ 12,5 мм — 1 слой"]},
        {"code":"C112","name":"Каркас ПП 60×27 · 2×ГКЛ","category":"lining","thicknessMM":53,"dropMM":0,"layers":2,"spacingMM":600,"frame":"pp60","maxH":4.0,"rw":43,"ei":30,"composition":["ПН 28 (UD) по периметру","ПП 60×27 (CD), шаг 600 мм","ГКЛ 12,5 мм — 2 слоя"]},
        {"code":"C115","name":"Каркас ПС 50 · 1×ГКЛ","category":"lining","thicknessMM":63,"dropMM":0,"layers":1,"spacingMM":600,"frame":"cw50","maxH":4.0,"rw":42,"ei":15,"composition":["ПН 50 + ПС 50, шаг 600 мм","ГКЛ 12,5 мм — 1 слой","Зазор под коммуникации"]},
        {"code":"C117","name":"Каркас ПС 50 · 2×ГКЛ","category":"lining","thicknessMM":76,"dropMM":0,"layers":2,"spacingMM":600,"frame":"cw50","maxH":4.0,"rw":45,"ei":30,"composition":["ПН 50 + ПС 50, шаг 600 мм","ГКЛ 12,5 мм — 2 слоя"]},
        {"code":"C621","name":"Двойной каркас 2×ПП · 2×ГКЛ","category":"lining","thicknessMM":79,"dropMM":0,"layers":2,"spacingMM":600,"frame":"doublePP","maxH":6.0,"rw":50,"ei":30,"composition":["Двойной каркас 2×ПП 60×27","ГКЛ 12,5 мм — 2 слоя"]},
        {"code":"D111","name":"Одноуровневый на прямых подвесах","category":"ceiling","thicknessMM":15,"dropMM":100,"layers":1,"spacingMM":500,"frame":"pp60","maxH":99,"rw":52,"ei":15,"composition":["ПН 28 (UD) по периметру","ПП 60×27 (CD) шаг 500 мм","Подвес П6 + анкер-клин, шаг 900 мм","ГКЛ 12,5 мм — 1 слой"]},
        {"code":"D112","name":"Двухуровневый на подвесах","category":"ceiling","thicknessMM":15,"dropMM":250,"layers":1,"spacingMM":600,"frame":"pp60","maxH":99,"rw":54,"ei":15,"composition":["Двухуровневый каркас ПП 60×27","ГКЛ 12,5 мм — 1 слой"]},
        {"code":"D611","name":"Минимальный подвес (~40 мм)","category":"ceiling","thicknessMM":15,"dropMM":40,"layers":1,"spacingMM":500,"frame":"pp60","maxH":99,"rw":50,"ei":15,"composition":["ПП 60×27 крепится напрямую к перекрытию","ГКЛ 12,5 мм — 1 слой"]},
        {"code":"E111","name":"Элемент пола ГВЛВ 20 мм по плёнке","category":"floor","thicknessMM":20,"dropMM":0,"layers":1,"spacingMM":0,"frame":"dryFloor","maxH":99,"rw":null,"ei":15,"composition":["Плёнка ПЭ 0,2 мм","Элемент пола ГВЛВ 1200×600×20","Кромочная лента, клей + шурупы"]},
        {"code":"E611","name":"Суперпол: засыпка от 20 мм + ГВЛВ","category":"floor","thicknessMM":40,"dropMM":0,"layers":1,"spacingMM":0,"frame":"dryFloor","maxH":99,"rw":null,"ei":30,"composition":["Керамзитовая засыпка КНАУФ от 20 мм","Плёнка ПЭ 0,2 мм","Элемент пола ГВЛВ 1200×600×20"]},
        {"code":"E621","name":"Суперпол: засыпка от 50 мм + ГВЛВ","category":"floor","thicknessMM":70,"dropMM":0,"layers":1,"spacingMM":0,"frame":"dryFloor","maxH":99,"rw":null,"ei":45,"composition":["Керамзитовая засыпка от 50 мм","Плёнка ПЭ 0,2 мм","Элемент пола ГВЛВ 1200×600×20"]}
      ]
    }
    """
}
