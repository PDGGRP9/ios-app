// Models.swift
import Foundation

// Une mesure envoyée par le bracelet. Correspond au payload firmware (BPM/SpO2/pas).
struct Reading: Identifiable, Equatable {
    let id = UUID()
    let timestamp: Date
    let bpm: Int        // 0 = pas de doigt/poignet détecté par le MAX30102
    let spo2: Int       // en %
    let steps: Int      // cumul depuis le boot du bracelet
}

// État du lien BLE. Un seul enum pour éviter les booléens qui se contredisent.
// `pairing` = le lien radio est établi mais pas encore chiffré : le firmware a
// demandé l'appairage et iOS attend le code à 6 chiffres. `connected` signifie
// donc « connecté ET chiffré » — c'est le seul état où des trames arrivent.
enum ConnectionState: Equatable {
    case disconnected
    case scanning
    case connecting
    case pairing(deviceName: String)
    case connected(deviceName: String)
    case failed(String)
}

// Une ligne du journal de debug. Volontairement agnostique du format des trames :
// on garde les octets bruts, on ne suppose rien de leur signification.
struct BLEEvent: Identifiable {
    enum Level: String, CaseIterable {
        case info   // scan, connexion, découverte du GATT
        case data   // un paquet reçu
        case error  // échec de connexion, décodage impossible

        var label: String {
            switch self {
            case .info:  return "Info"
            case .data:  return "Data"
            case .error: return "Erreur"
            }
        }
    }

    let id = UUID()
    let timestamp: Date
    let level: Level
    let message: String
    let payload: Data?            // nil pour les events qui ne transportent pas de trame
    let characteristic: String?   // UUID court, ex. "AB1"

    init(level: Level,
         message: String,
         payload: Data? = nil,
         characteristic: String? = nil,
         timestamp: Date = .now) {
        self.timestamp = timestamp
        self.level = level
        self.message = message
        self.payload = payload
        self.characteristic = characteristic
    }

    // "4A 62 D2 04" — le format qu'on compare à l'écran de LightBlue.
    var hex: String? {
        payload.map { $0.map { String(format: "%02X", $0) }.joined(separator: " ") }
    }
}
