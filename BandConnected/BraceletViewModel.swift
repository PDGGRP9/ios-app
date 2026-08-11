// BraceletViewModel.swift
import Foundation

@MainActor
@Observable
final class BraceletViewModel {
    private(set) var state: ConnectionState = .disconnected
    private(set) var latest: Reading?
    private(set) var history: [Reading] = []

    // Journal interne : pas d'écran dédié, mais tout passe par os.Logger et
    // reste lisible dans Console.app / Xcode quand le Mac est branché.
    let log = DebugLog()

    private let service: BraceletService

    init() {
        self.service = BLEBraceletService()
        bind(service)
    }

    // MARK: - Câblage

    private func bind(_ service: BraceletService) {
        service.onStateChange = { [weak self] in self?.state = $0 }
        service.onEvent = { [weak self] in self?.log.append($0) }
        service.onRSSI = { [weak self] in self?.log.rssi = $0 }
        service.onReading = { [weak self] reading in
            guard let self else { return }
            self.latest = reading
            self.history.append(reading)
            // Le firmware envoie 3 notifications par cycle de 4 s, donc 3 points :
            // 180 en garde ~4 min à l'écran, sans laisser la mémoire filer.
            if self.history.count > 180 { self.history.removeFirst() }
        }
    }

    // MARK: - État exposé à la vue

    var isConnected: Bool {
        if case .connected = state { return true }
        return false
    }

    // L'appairage en fait partie : le bouton doit rester « Arrêter » pendant que
    // le clavier de saisie du code est à l'écran.
    var isBusy: Bool {
        switch state {
        case .scanning, .connecting, .pairing: return true
        default: return false
        }
    }

    var isPairing: Bool {
        if case .pairing = state { return true }
        return false
    }

    var hasFailed: Bool {
        if case .failed = state { return true }
        return false
    }

    // MARK: - Actions

    func toggleConnection() {
        (isConnected || isBusy) ? service.disconnect() : service.startScan()
    }

    // Vide seulement ce qui est affiché. La connexion, elle, n'est pas touchée :
    // les tuiles se remplissent à nouveau au cycle suivant (~4 s).
    func clearHistory() {
        history.removeAll()
        latest = nil
    }
}
