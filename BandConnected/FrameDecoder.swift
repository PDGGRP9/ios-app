// FrameDecoder.swift
import CoreBluetooth
import Foundation

// Décodage des trames du bracelet. Le format est figé côté firmware
// (../firmware/docs/ble-contract.md) : trois caractéristiques qui notifient
// chacune une valeur, toutes les 4 s.
//
//   …AB1  1 octet   uint8            BPM
//   …AB2  1 octet   uint8            SpO2 en %
//   …AB3  4 octets  uint32 little-endian  pas depuis le boot
//
// Une notification ne porte donc qu'UNE valeur : le décodeur garde les deux
// autres en mémoire et renvoie une mesure complète à chaque trame. D'où la
// classe (avec état) plutôt qu'une fonction.
@MainActor
final class VitalsDecoder {

    let name = "3 caractéristiques"

    static let hrUUID    = CBUUID(string: "12345678-1234-1234-1234-123456789ab1")
    static let spo2UUID  = CBUUID(string: "12345678-1234-1234-1234-123456789ab2")
    static let stepsUUID = CBUUID(string: "12345678-1234-1234-1234-123456789ab3")

    private var bpm = 0
    private var spo2 = 0
    private var steps = 0

    // Retourne nil quand la trame vient d'une caractéristique inconnue : le
    // firmware peut en exposer de nouvelles avant que l'app les gère, ce n'est
    // pas une erreur. Lance une erreur quand la trame est trop courte, ça c'est
    // un vrai désaccord de contrat qu'il faut voir dans le journal.
    func decode(_ data: Data, from characteristic: CBUUID) throws -> Reading? {
        switch characteristic {
        case Self.hrUUID:
            guard data.count >= 1 else { throw DecodeError.tooShort(expected: 1, got: data.count) }
            bpm = Int(data[data.startIndex])
        case Self.spo2UUID:
            guard data.count >= 1 else { throw DecodeError.tooShort(expected: 1, got: data.count) }
            spo2 = Int(data[data.startIndex])
        case Self.stepsUUID:
            guard data.count >= 4 else { throw DecodeError.tooShort(expected: 4, got: data.count) }
            steps = Int(data.readUInt32LE(at: 0))
        default:
            return nil
        }
        // L'ESP32 n'a pas d'horloge sauvegardée : c'est l'iPhone qui date la mesure.
        return Reading(timestamp: .now, bpm: bpm, spo2: spo2, steps: steps)
    }

    // À la déconnexion : sinon la première mesure de la session suivante
    // recyclerait les valeurs de l'ancienne.
    func reset() {
        bpm = 0; spo2 = 0; steps = 0
    }
}

enum DecodeError: LocalizedError {
    case tooShort(expected: Int, got: Int)

    var errorDescription: String? {
        switch self {
        case .tooShort(let expected, let got):
            return "trame trop courte : \(got) octet(s), \(expected) attendu(s)"
        }
    }
}

// MARK: -

extension Data {
    // L'ESP32 est little-endian : lire les 4 octets dans l'autre sens donnerait
    // des valeurs absurdes (1234 pas → 3 523 215 360).
    func readUInt32LE(at offset: Int) -> UInt32 {
        let i = startIndex + offset
        return UInt32(self[i])
            | UInt32(self[i + 1]) << 8
            | UInt32(self[i + 2]) << 16
            | UInt32(self[i + 3]) << 24
    }
}
