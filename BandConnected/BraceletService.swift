// BraceletService.swift
import Foundation

// Frontière entre le front et le BLE. Le mock et l'implémentation CoreBluetooth
// respectent le même contrat, ce qui permet de remplacer l'un par l'autre à chaud.
@MainActor
protocol BraceletService: AnyObject {
    var name: String { get }
    var onStateChange: ((ConnectionState) -> Void)? { get set }
    // Uniquement quand un FrameDecoder a su lire la trame. Peut ne jamais être appelé.
    var onReading: ((Reading) -> Void)? { get set }
    // Tout le reste, y compris les paquets indéchiffrables : c'est ce flux qui
    // sert à prouver que la liaison fonctionne.
    var onEvent: ((BLEEvent) -> Void)? { get set }
    // Puissance du signal, rafraîchie en continu. Séparé de onEvent pour ne pas
    // noyer le journal sous une ligne toutes les 2 secondes.
    var onRSSI: ((Int) -> Void)? { get set }
    func startScan()
    func disconnect()
}
