// DebugLog.swift
import Foundation
import OSLog

// Journal du lien BLE. Il n'a plus d'écran dédié : il sert au développement
// conjoint firmware ↔ app via os.Logger (Console.app / Xcode, Mac branché) et
// garde les derniers événements en mémoire, prêts à être réaffichés si on
// remet un écran de diagnostic un jour.
@MainActor
@Observable
final class DebugLog {

    // Au-delà, on jette les plus anciens : une session de debug dure des heures,
    // la mémoire ne doit pas croître indéfiniment.
    static let capacity = 500

    private(set) var events: [BLEEvent] = []

    private(set) var packetCount = 0
    private(set) var byteCount = 0
    private(set) var decodeErrorCount = 0
    private(set) var lastPacketAt: Date?
    // Renseigné en continu par le service BLE : c'est le seul indicateur de
    // portée disponible, et il sert de témoin de vie du lien.
    var rssi: Int?

    // Horodatage des paquets des 10 dernières secondes, pour le débit instantané.
    private var recentPackets: [Date] = []

    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "BandConnected",
        category: "ble"
    )

    func append(_ event: BLEEvent) {
        events.append(event)
        if events.count > Self.capacity {
            events.removeFirst(events.count - Self.capacity)
        }

        if let payload = event.payload {
            packetCount += 1
            byteCount += payload.count
            lastPacketAt = event.timestamp
            recentPackets.append(event.timestamp)
        }
        if event.level == .error { decodeErrorCount += 1 }

        // Doublon dans Console.app / Xcode quand le Mac est branché.
        switch event.level {
        case .error: logger.error("\(event.message, privacy: .public)")
        // .notice et pas .debug : le niveau debug n'est pas persisté par le
        // système, la trame ne serait visible qu'en `log stream` en direct et
        // introuvable après coup dans un `log collect`.
        case .data:  logger.notice("\(event.message, privacy: .public) [\(event.hex ?? "", privacy: .public)]")
        case .info:  logger.info("\(event.message, privacy: .public)")
        }
    }

    // Raccourcis d'écriture, pour que les appelants restent lisibles.
    func info(_ message: String) { append(BLEEvent(level: .info, message: message)) }
    func error(_ message: String) { append(BLEEvent(level: .error, message: message)) }
    func data(_ message: String, payload: Data, characteristic: String?) {
        append(BLEEvent(level: .data, message: message, payload: payload, characteristic: characteristic))
    }

    // Paquets/s sur une fenêtre glissante de 10 s. Vaut 0 dès que ça décroche.
    var packetsPerSecond: Double {
        let cutoff = Date.now.addingTimeInterval(-10)
        return Double(recentPackets.filter { $0 > cutoff }.count) / 10.0
    }

    var secondsSinceLastPacket: TimeInterval? {
        lastPacketAt.map { Date.now.timeIntervalSince($0) }
    }

    func clear() {
        events.removeAll()
        recentPackets.removeAll()
        packetCount = 0
        byteCount = 0
        decodeErrorCount = 0
        lastPacketAt = nil
    }

    // Purge la fenêtre glissante. Appelé par la vue à chaque tick d'affichage :
    // sinon le tableau grossit sans fin pendant une session longue.
    func trimRecent() {
        let cutoff = Date.now.addingTimeInterval(-10)
        recentPackets.removeAll { $0 <= cutoff }
    }

    // MARK: - Export

    private static let stamp: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    var plainText: String {
        let header = """
        # BandConnected — journal BLE
        # export: \(Self.stamp.string(from: .now))
        # paquets: \(packetCount)  octets: \(byteCount)  erreurs: \(decodeErrorCount)
        # timestamp | niveau | caractéristique | longueur | hex | message

        """
        let lines = events.map { e in
            [Self.stamp.string(from: e.timestamp),
             e.level.rawValue,
             e.characteristic ?? "-",
             e.payload.map { String($0.count) } ?? "-",
             e.hex ?? "-",
             e.message].joined(separator: " | ")
        }
        return header + lines.joined(separator: "\n") + "\n"
    }

    // Fichier temporaire à partager (AirDrop, Mail, Fichiers…) directement depuis
    // l'iPhone, sans Mac branché. Écrase l'export précédent, un seul suffit.
    func writeExportFile() -> URL? {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("bandconnected-ble-log.txt")
        do {
            try plainText.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            logger.error("export impossible : \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}
