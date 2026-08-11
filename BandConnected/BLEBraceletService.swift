// BLEBraceletService.swift
import CoreBluetooth
import Foundation

// Transport BLE réel. L'ESP32 est périphérique (il annonce et attend), l'iPhone est
// central (il scanne, se connecte, s'abonne). Tout est asynchrone : on déclenche une
// action, la réponse arrive plus tard dans un délégué.
//
// Cette classe ne suppose rien du contenu des trames : elle les remonte brutes au
// DebugLog et passe une copie au décodeur, qui a le droit d'échouer.
@MainActor
final class BLEBraceletService: NSObject, BraceletService {

    let name = "BLE réel"

    var onStateChange: ((ConnectionState) -> Void)?
    var onReading: ((Reading) -> Void)?
    var onEvent: ((BLEEvent) -> Void)?
    var onRSSI: ((Int) -> Void)?

    // Le service annoncé par le firmware (src/config.h). L'UUID a été vérifié sur
    // le matériel : on peut filtrer le scan dessus, iOS ne réveille alors l'app
    // que pour le bracelet au lieu de tous les appareils BLE de la salle.
    static let serviceUUID = CBUUID(string: "12345678-1234-1234-1234-123456789abc")

    // Second critère de reconnaissance, gardé parce que le nom n'est PAS garanti :
    // il voyage dans le scan response, pas dans l'annonce (voir didDiscover).
    static let namePrefix = "BraceletTest"

    private let decoder = VitalsDecoder()

    private var central: CBCentralManager?
    // Référence forte obligatoire : CoreBluetooth ne retient PAS le peripheral.
    // Sans elle il est désalloué et didConnect n'arrive jamais, sans message d'erreur.
    private var peripheral: CBPeripheral?

    private var wantsScan = false
    private var announced: Set<UUID> = []   // périphériques déjà loggés, le scan répète
    private var rssiTimer: Timer?

    // Le lien est-il chiffré ? iOS n'expose AUCUNE API pour le savoir : pas de
    // propriété d'état de sécurité sur CBPeripheral. La seule preuve accessible
    // au central est indirecte — une lecture/notification qui aboutit sur une
    // caractéristique marquée READ_ENC prouve que l'appairage est passé.
    private var isSecured = false
    // Nom retenu à la connexion : à la première trame reçue on repasse en
    // .connected et il faut le rappeler.
    private var connectedName = "bracelet"

    func startScan() {
        wantsScan = true
        if central == nil {
            // Instancier le manager déclenche la demande de permission Bluetooth.
            central = CBCentralManager(delegate: self, queue: nil)
            emit(.info, "Initialisation du Bluetooth…")
            return   // la suite se fait dans centralManagerDidUpdateState
        }
        scanIfPossible()
    }

    func disconnect() {
        wantsScan = false
        stopRSSIPolling()
        central?.stopScan()
        if let peripheral {
            central?.cancelPeripheralConnection(peripheral)
        }
        self.peripheral = nil
        announced.removeAll()
        isSecured = false
        decoder.reset()
        emit(.info, "Déconnexion demandée")
        onStateChange?(.disconnected)
    }

    // MARK: - Interne

    private func scanIfPossible() {
        guard let central, central.state == .poweredOn, wantsScan else { return }
        // Filtre sur le service : c'est le seul critère fiable (le nom peut
        // manquer) et ça évite de traiter tous les appareils BLE de la salle.
        // allowDuplicates : on veut voir le RSSI bouger, pas une seule annonce.
        central.scanForPeripherals(
            withServices: [Self.serviceUUID],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]
        )
        emit(.info, "Scan démarré (service \(Self.serviceUUID.uuidString))")
        onStateChange?(.scanning)
    }

    // Le RSSI de l'advertising disparaît une fois connecté : il faut le redemander.
    private func startRSSIPolling() {
        rssiTimer?.invalidate()
        // Le timer se déclenche sur la runloop principale, d'où assumeIsolated.
        rssiTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.peripheral?.readRSSI()
            }
        }
    }

    private func stopRSSIPolling() {
        rssiTimer?.invalidate()
        rssiTimer = nil
    }

    private func emit(_ level: BLEEvent.Level,
                      _ message: String,
                      payload: Data? = nil,
                      characteristic: CBUUID? = nil) {
        onEvent?(BLEEvent(level: level,
                          message: message,
                          payload: payload,
                          characteristic: characteristic.map { Self.shortUUID($0) }))
    }

    // "…789AB1" → "AB1" : lisible dans une liste, suffisant pour distinguer 3 caractéristiques.
    static func shortUUID(_ uuid: CBUUID) -> String {
        let s = uuid.uuidString
        return s.count <= 6 ? s : String(s.suffix(4))
    }

    // Les erreurs GATT liées au chiffrement arrivent avec un localizedDescription
    // en anglais et sans indication de ce qu'il faut faire. Or la cause est
    // presque toujours la même en démo : code refusé, ou bond périmé après un
    // reflash de la carte (elle régénère ses clés). D'où ce message maison.
    private static func securityHint(for error: Error) -> String? {
        guard let att = error as? CBATTError else { return nil }
        switch att.code {
        case .insufficientEncryption, .insufficientAuthentication, .insufficientAuthorization:
            return "appairage requis ou refusé — Réglages > Bluetooth > « Oublier cet appareil », puis réessaie"
        default:
            return nil
        }
    }

    private static func describe(_ p: CBCharacteristicProperties) -> String {
        var parts: [String] = []
        if p.contains(.read)              { parts.append("read") }
        if p.contains(.write)             { parts.append("write") }
        if p.contains(.writeWithoutResponse) { parts.append("writeNR") }
        if p.contains(.notify)            { parts.append("notify") }
        if p.contains(.indicate)          { parts.append("indicate") }
        return parts.isEmpty ? "—" : parts.joined(separator: "/")
    }
}

// MARK: - État du Bluetooth de l'iPhone

extension BLEBraceletService: CBCentralManagerDelegate {

    // Les délégués CoreBluetooth arrivent sur la queue passée à l'init : nil = main.
    // assumeIsolated documente ce fait au compilateur sans détour par un Task.
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        MainActor.assumeIsolated {
            switch central.state {
            case .poweredOn:
                emit(.info, "Bluetooth prêt")
                scanIfPossible()
            case .poweredOff:
                emit(.error, "Bluetooth désactivé")
                onStateChange?(.failed("Bluetooth désactivé"))
            case .unauthorized:
                emit(.error, "Permission Bluetooth refusée")
                onStateChange?(.failed("Permission refusée"))
            case .unsupported:
                // C'est le cas du simulateur : il ne fait pas de Bluetooth.
                emit(.error, "Bluetooth indisponible (simulateur ?)")
                onStateChange?(.failed("Bluetooth indisponible"))
            default:
                emit(.info, "État Bluetooth : \(central.state.rawValue)")
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager,
                                    didDiscover peripheral: CBPeripheral,
                                    advertisementData: [String: Any],
                                    rssi RSSI: NSNumber) {
        MainActor.assumeIsolated {
            let advName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
            let label = advName ?? peripheral.name ?? "sans nom"

            // Une seule ligne de log par appareil, sinon allowDuplicates noie le journal.
            if !announced.contains(peripheral.identifier) {
                announced.insert(peripheral.identifier)
                emit(.info, "Découvert : \(label)  RSSI \(RSSI) dBm")
            }
            onRSSI?(RSSI.intValue)

            // Le scan est déjà filtré sur le service, donc tout ce qui arrive ici
            // est un bracelet. On regarde quand même le nom : savoir lequel des
            // deux critères a matché évite une demi-heure de debug le jour où le
            // nom n'est pas annoncé (il voyage dans le scan response, l'annonce
            // de 31 octets étant déjà pleine avec l'UUID 128 bits).
            let advertised = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
            let matchesService = advertised.contains(Self.serviceUUID)
            let matchesName = label.lowercased().hasPrefix(Self.namePrefix.lowercased())
            guard matchesService || matchesName, self.peripheral == nil else { return }

            central.stopScan()
            self.peripheral = peripheral   // référence forte AVANT connect()
            // Savoir lequel des deux a matché évite une demi-heure de debug le
            // jour où le nom n'arrive pas : le lien marche, l'affichage ment.
            let reason = matchesService ? "UUID de service annoncé" : "préfixe de nom"
            emit(.info, "Connexion à \(label) (RSSI \(RSSI) dBm) — \(reason)…")
            onStateChange?(.connecting)
            central.connect(peripheral)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager,
                                    didConnect peripheral: CBPeripheral) {
        MainActor.assumeIsolated {
            let label = peripheral.name ?? "bracelet"
            let mtu = peripheral.maximumWriteValueLength(for: .withoutResponse)
            emit(.info, "Connecté à \(label) — payload max \(mtu) octets")
            // Connecté ≠ utilisable : le firmware réclame l'appairage dès la
            // connexion, iOS va afficher son clavier. On n'annonce .connected
            // qu'une fois une trame réellement reçue (donc lien chiffré).
            connectedName = label
            isSecured = false
            emit(.info, "Appairage en cours — saisis le code à 6 chiffres")
            onStateChange?(.pairing(deviceName: label))
            peripheral.delegate = self
            // nil = découverte totale : on inspecte le GATT réel du firmware au lieu
            // de supposer les UUID, qui bougent encore.
            peripheral.discoverServices(nil)
            startRSSIPolling()
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager,
                                    didFailToConnect peripheral: CBPeripheral,
                                    error: Error?) {
        MainActor.assumeIsolated {
            let reason = error?.localizedDescription ?? "raison inconnue"
            emit(.error, "Échec de connexion : \(reason)")
            self.peripheral = nil
            onStateChange?(.failed(reason))
            scanIfPossible()
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager,
                                    didDisconnectPeripheral peripheral: CBPeripheral,
                                    error: Error?) {
        MainActor.assumeIsolated {
            let reason = error?.localizedDescription ?? "déconnexion propre"
            emit(.error, "Déconnecté : \(reason)")
            // Coupé avant d'avoir été chiffré : c'est la signature d'un appairage
            // annulé ou refusé — le firmware raccroche lui-même dans ce cas.
            if !isSecured {
                emit(.error, "Le lien n'a jamais été chiffré — code d'appairage annulé ou refusé ?")
            }
            stopRSSIPolling()
            self.peripheral = nil
            announced.removeAll()
            isSecured = false
            decoder.reset()
            onStateChange?(.disconnected)
            // Hors de portée ou reset de l'ESP32 : sans relance, l'app reste muette.
            scanIfPossible()
        }
    }
}

// MARK: - Découverte du GATT et réception des trames

extension BLEBraceletService: CBPeripheralDelegate {

    nonisolated func peripheral(_ peripheral: CBPeripheral,
                                didDiscoverServices error: Error?) {
        MainActor.assumeIsolated {
            if let error {
                emit(.error, "Découverte des services : \(error.localizedDescription)")
                return
            }
            let services = peripheral.services ?? []
            emit(.info, "\(services.count) service(s) trouvé(s)")
            for service in services {
                emit(.info, "Service \(service.uuid.uuidString)")
                peripheral.discoverCharacteristics(nil, for: service)
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral,
                                didDiscoverCharacteristicsFor service: CBService,
                                error: Error?) {
        MainActor.assumeIsolated {
            if let error {
                emit(.error, "Découverte des caractéristiques : \(error.localizedDescription)")
                return
            }
            for c in service.characteristics ?? [] {
                emit(.info, "  caractéristique \(c.uuid.uuidString) [\(Self.describe(c.properties))]")
                // La lecture AVANT l'abonnement, et pas l'inverse : côté firmware
                // seule la lecture porte l'exigence de chiffrement (READ_ENC ;
                // NimBLE 2.x n'a pas d'équivalent pour la souscription). C'est
                // donc elle qui fait apparaître le prompt d'appairage si le
                // firmware ne l'a pas déjà réclamé de lui-même.
                if c.properties.contains(.read) {
                    peripheral.readValue(for: c)
                }
                // S'abonner une fois : ensuite le firmware pousse tout seul à chaque
                // notify(), inutile de relire en boucle.
                if c.properties.contains(.notify) || c.properties.contains(.indicate) {
                    peripheral.setNotifyValue(true, for: c)
                }
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral,
                                didReadRSSI RSSI: NSNumber,
                                error: Error?) {
        MainActor.assumeIsolated {
            guard error == nil else { return }
            onRSSI?(RSSI.intValue)
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral,
                                didUpdateNotificationStateFor characteristic: CBCharacteristic,
                                error: Error?) {
        MainActor.assumeIsolated {
            if let error {
                let hint = Self.securityHint(for: error) ?? error.localizedDescription
                emit(.error, "Abonnement \(Self.shortUUID(characteristic.uuid)) refusé : \(hint)")
            } else {
                emit(.info, "Abonné à \(Self.shortUUID(characteristic.uuid)) : \(characteristic.isNotifying)")
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral,
                                didUpdateValueFor characteristic: CBCharacteristic,
                                error: Error?) {
        MainActor.assumeIsolated {
            if let error {
                let hint = Self.securityHint(for: error) ?? error.localizedDescription
                emit(.error, "Lecture \(Self.shortUUID(characteristic.uuid)) : \(hint)")
                return
            }
            guard let data = characteristic.value else { return }

            // Première donnée qui passe : le lien est forcément chiffré, puisque
            // la caractéristique est en READ_ENC côté firmware. C'est le seul
            // signal de sécurité disponible sur iOS (cf. `isSecured`).
            if !isSecured {
                isSecured = true
                emit(.info, "Lien chiffré — appairage réussi")
                onStateChange?(.connected(deviceName: connectedName))
            }

            // La trame brute part au journal quoi qu'il arrive — c'est la preuve que
            // la liaison fonctionne, indépendamment du format.
            emit(.data, "\(data.count) octet(s) reçu(s)",
                 payload: data, characteristic: characteristic.uuid)

            // Le décodage, lui, a le droit d'échouer sans interrompre le flux.
            do {
                if let reading = try decoder.decode(data, from: characteristic.uuid) {
                    // Le seul endroit qui prouve que la chaîne va jusqu'au bout :
                    // sans cette ligne, « des octets arrivent » et « l'app en tire
                    // une mesure » sont indiscernables dans le journal.
                    emit(.info, "Reading bpm=\(reading.bpm) spo2=\(reading.spo2) steps=\(reading.steps)")
                    onReading?(reading)
                } else {
                    // Retour nil = UUID hors contrat. Ce n'est pas une faute (on
                    // s'abonne à tout le GATT), mais tant que ça reste muet on ne
                    // peut pas distinguer « UUID désynchronisé » de « rien ne vient ».
                    emit(.error, "Caractéristique inconnue \(Self.shortUUID(characteristic.uuid)) — non décodée")
                }
            } catch {
                emit(.error, "Décodage \(Self.shortUUID(characteristic.uuid)) : \(error.localizedDescription)")
            }
        }
    }
}
