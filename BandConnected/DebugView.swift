// DebugView.swift
import SwiftUI
import UIKit

// Écran de travail du développement firmware ↔ app. Il répond à trois questions :
// est-ce que des trames arrivent, à quel rythme, et à quoi ressemblent les octets.
// Le décodage n'est volontairement pas nécessaire pour que cet écran serve.
@MainActor
struct DebugView: View {
    let vm: BraceletViewModel

    @State private var levelFilter: BLEEvent.Level?
    @State private var tick = Date.now
    @State private var exportFile: ExportFile?

    private var events: [BLEEvent] {
        let all = vm.log.events
        guard let levelFilter else { return all.reversed() }
        return all.filter { $0.level == levelFilter }.reversed()
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                counters
                Divider()
                security
                Divider()
                filterBar
                eventList
            }
            .navigationTitle("Debug BLE")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button("Exporter", systemImage: "square.and.arrow.up") {
                        exportFile = vm.log.writeExportFile().map(ExportFile.init)
                    }
                    Button("Vider", systemImage: "trash") { vm.log.clear() }
                }
            }
            .sheet(item: $exportFile) { file in
                ShareSheet(items: [file.url])
            }
        }
        // Rafraîchit le « depuis N s » et purge la fenêtre glissante du débit.
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { now in
            tick = now
            vm.log.trimRecent()
        }
    }

    // MARK: - Compteurs

    private var counters: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 3), spacing: 10) {
            Counter(title: "Paquets", value: "\(vm.log.packetCount)")
            Counter(title: "Octets", value: "\(vm.log.byteCount)")
            Counter(title: "Débit", value: String(format: "%.1f/s", vm.log.packetsPerSecond))
            Counter(title: "Dernier",
                    value: vm.log.secondsSinceLastPacket.map { String(format: "%.0f s", $0) } ?? "—",
                    // Rouge dès qu'on a décroché : c'est le chiffre qu'on regarde en premier.
                    tint: (vm.log.secondsSinceLastPacket ?? .infinity) > 10 ? .red : .green)
            Counter(title: "Erreurs", value: "\(vm.log.decodeErrorCount)",
                    tint: vm.log.decodeErrorCount > 0 ? .orange : nil)
            Counter(title: "RSSI", value: vm.log.rssi.map { "\($0) dBm" } ?? "—")
        }
        .padding()
    }

    private struct Counter: View {
        let title: String
        let value: String
        var tint: Color?

        var body: some View {
            VStack(spacing: 2) {
                Text(value)
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                    .foregroundStyle(tint ?? .primary)
                    .lineLimit(1).minimumScaleFactor(0.7)
                Text(title).font(.caption2).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: - État du lien

    // Le lien est chiffré dès qu'une trame est passée : le firmware expose ses
    // caractéristiques en READ_ENC, donc recevoir quoi que ce soit prouve
    // l'appairage. iOS n'offre pas de moyen plus direct de le savoir.
    private var security: some View {
        HStack {
            Label(securityLabel, systemImage: securityIcon)
                .font(.caption).foregroundStyle(securityColor)
            Spacer()
        }
        .padding(.horizontal)
        .padding(.bottom, 10)
    }

    private var securityLabel: String {
        switch vm.state {
        case .connected:    return "Lien chiffré (appairé)"
        case .pairing:      return "Appairage en cours — code attendu"
        default:            return "Lien non établi"
        }
    }

    private var securityIcon: String {
        switch vm.state {
        case .connected:    return "lock.fill"
        case .pairing:      return "lock.open.fill"
        default:            return "lock.slash"
        }
    }

    private var securityColor: Color {
        switch vm.state {
        case .connected:    return .green
        case .pairing:      return .orange
        default:            return .secondary
        }
    }

    // MARK: - Journal

    private var filterBar: some View {
        Picker("Niveau", selection: $levelFilter) {
            Text("Tout").tag(BLEEvent.Level?.none)
            ForEach(BLEEvent.Level.allCases, id: \.self) { level in
                Text(level.label).tag(BLEEvent.Level?.some(level))
            }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    private var eventList: some View {
        List(events) { event in
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Circle().fill(color(event.level)).frame(width: 7, height: 7)
                    Text(event.timestamp, format: .dateTime.hour().minute().second())
                        .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                    if let c = event.characteristic {
                        Text(c).font(.caption2.monospaced())
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(.quaternary, in: Capsule())
                    }
                    Spacer()
                    if let n = event.payload?.count {
                        Text("\(n) o").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Text(event.message).font(.caption)
                if let hex = event.hex {
                    // Le même hexa que LightBlue / nRF Connect : c'est ce qu'on compare.
                    Text(hex).font(.caption.monospaced()).foregroundStyle(.blue)
                        .textSelection(.enabled)
                }
            }
            .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
        }
        .listStyle(.plain)
        .overlay {
            if events.isEmpty {
                ContentUnavailableView("Aucun événement",
                                       systemImage: "antenna.radiowaves.left.and.right",
                                       description: Text("Lance la connexion depuis l'écran Mesures."))
            }
        }
    }

    private func color(_ level: BLEEvent.Level) -> Color {
        switch level {
        case .info:  return .gray
        case .data:  return .green
        case .error: return .red
        }
    }
}

// Enveloppe Identifiable pour présenter la feuille de partage via `.sheet(item:)`.
struct ExportFile: Identifiable {
    let id = UUID()
    let url: URL
}

// Partage du journal (.txt) vers AirDrop, Mail, Fichiers… depuis l'iPhone,
// donc sans Mac branché.
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
