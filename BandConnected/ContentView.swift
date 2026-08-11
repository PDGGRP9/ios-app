// ContentView.swift
import SwiftUI
import Charts

// Écran unique de l'app : les mesures du bracelet, un témoin de connexion, et
// de quoi vider ce qui est affiché. Tout le reste (journal, décodage) tourne
// en arrière-plan.
@MainActor
struct ContentView: View {
    @State private var vm = BraceletViewModel()
    @State private var showDebug = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    ConnectionStatus(vm: vm)

                    HStack(spacing: 12) {
                        MetricCard(title: "BPM",
                                   value: vm.latest.map { $0.bpm > 0 ? "\($0.bpm)" : "--" } ?? "--",
                                   unit: "bpm", icon: "heart.fill", color: .red)
                        MetricCard(title: "SpO2",
                                   value: vm.latest.map { $0.spo2 > 0 ? "\($0.spo2)" : "--" } ?? "--",
                                   unit: "%", icon: "lungs.fill", color: .blue)
                    }

                    MetricCard(title: "Pas", value: vm.latest.map { "\($0.steps)" } ?? "--",
                               unit: "pas", icon: "figure.walk", color: .green)

                    BpmChart(history: vm.history)

                    Button(vm.isConnected || vm.isBusy ? "Arrêter" : "Connecter") {
                        vm.toggleConnection()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(vm.isConnected || vm.isBusy ? .red : .accentColor)

                    // Ne coupe pas la connexion : les tuiles se remplissent à
                    // nouveau au cycle suivant du bracelet (~4 s).
                    Button("Vider l'historique", systemImage: "trash") {
                        vm.clearHistory()
                    }
                    .buttonStyle(.bordered)
                    .disabled(vm.history.isEmpty)

                    // 0 = pas de mesure côté capteur (doigt absent), pas une
                    // panne de liaison : le dire ici évite la fausse alerte.
                    Text("« -- » signifie que le capteur ne voit pas le poignet.")
                        .font(.caption2).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding()
            }
            .navigationTitle("Bracelet")
            // Le journal n'a pas d'autre porte d'entrée : sans ça il faut un Mac
            // branché et Console.app pour savoir si des trames arrivent.
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Debug", systemImage: "ladybug") { showDebug = true }
                }
            }
            // Même `vm` que les tuiles : un second BraceletViewModel() ouvrirait
            // une deuxième connexion BLE et le journal serait vide.
            .sheet(isPresented: $showDebug) { DebugView(vm: vm) }
        }
    }
}

// Témoin de connexion : la pastille d'état, le RSSI quand il est connu, et la
// seule consigne utile à l'utilisateur (saisir le code, ou oublier l'appareil).
@MainActor
struct ConnectionStatus: View {
    let vm: BraceletViewModel

    var body: some View {
        VStack(spacing: 8) {
            StatusBadge(state: vm.state)

            if vm.isPairing {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Saisis le code à 6 chiffres affiché sur le terminal série de la carte.")
                        .font(.caption)
                }
            } else if vm.isConnected {
                HStack(spacing: 10) {
                    Label("Lien chiffré", systemImage: "lock.fill")
                        .font(.caption).foregroundStyle(.green)
                    if let rssi = vm.log.rssi {
                        Text("RSSI \(rssi) dBm")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            } else if vm.hasFailed {
                // iOS ne permet pas de supprimer un appairage par programme :
                // après un reflash la carte a de nouvelles clés, et seul
                // l'utilisateur peut oublier l'ancien appairage.
                Text("Si l'appairage échoue : Réglages > Bluetooth > « Oublier cet appareil », puis réessaie.")
                    .font(.caption2).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
    }
}

// Pastille d'état de connexion, en haut de l'écran.
struct StatusBadge: View {
    let state: ConnectionState

    private var label: String {
        switch state {
        case .disconnected:            return "Déconnecté"
        case .scanning:                return "Recherche…"
        case .connecting:              return "Connexion…"
        case .pairing:                 return "Appairage… saisis le code"
        case .connected(let name):     return "Connecté à \(name) · chiffré"
        case .failed(let msg):         return "Erreur : \(msg)"
        }
    }

    private var color: Color {
        switch state {
        case .connected:               return .green
        case .scanning, .connecting, .pairing: return .orange
        case .failed:                  return .red
        case .disconnected:            return .gray
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(color).frame(width: 10, height: 10)
            Text(label).font(.subheadline)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(color.opacity(0.12), in: Capsule())
    }
}

// Tuile réutilisable pour une mesure.
struct MetricCard: View {
    let title: String
    let value: String
    let unit: String
    let icon: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: icon)
                .font(.caption).foregroundStyle(color)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value).font(.system(size: 34, weight: .semibold, design: .rounded))
                Text(unit).font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 16))
    }
}

// Courbe du BPM sur les dernières minutes.
struct BpmChart: View {
    let history: [Reading]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("BPM (dernières minutes)").font(.caption).foregroundStyle(.secondary)
            Chart(history) { r in
                LineMark(x: .value("Temps", r.timestamp),
                         y: .value("BPM", r.bpm))
                .foregroundStyle(.red)
            }
            // Plage physiologique large : évite que l'axe saute à chaque mesure.
            .chartYScale(domain: 40...140)
            .frame(height: 160)
            .overlay {
                if history.isEmpty {
                    Text("Aucune mesure reçue")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding()
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 16))
    }
}
