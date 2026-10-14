import SwiftUI
import AppKit
import Foundation

@main struct ZenVoiceApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @ObservedObject private var model = AppDelegate.model
    var body: some Scene {
        MenuBarExtra("ZenVoice", systemImage: model.active ? "waveform.circle.fill" : "waveform.circle") {
            Text(model.status)
            Button(model.active ? "Disattiva" : "Attiva") {
                if model.active { model.deactivate() } else { model.activate() }
            }
            .disabled(model.closing)
            if let request = model.menuPermission {
                Divider()
                Text("Permesso · \(request.project)")
                Text(request.details).lineLimit(12)
                Button("Esamina e consenti una volta…") { model.respondToMenuPermission(id: request.id, allow: true) }.disabled(model.closing)
                Button("Rifiuta") { model.respondToMenuPermission(id: request.id, allow: false) }
            }
            if let request = model.desktopPermission {
                Divider()
                Text("Permesso · Desktop")
                Text(request.details).lineLimit(8)
                Button("Esamina e consenti una volta…") { model.respondToDesktopPermission(id: request.id, allow: true) }.disabled(model.closing)
                Button("Rifiuta operazione Desktop") { model.respondToDesktopPermission(id: request.id, allow: false) }
            }
            Divider()
            Button("Configurazione…") { delegate.openSetup() }.disabled(model.closing)
            Button("Esci") { model.quit() }.disabled(model.closing)
        }
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    static let model = VoiceModel()
    private var setupWindow: NSWindow?
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)
        if Self.model.settings.projects.isEmpty && !Self.model.settings.desktopEnabled { openSetup() }
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if Self.model.quitting { return .terminateNow }
        Self.model.quit(); return .terminateCancel
    }
    func openSetup() {
        guard !Self.model.closing else { return }
        if let setupWindow { setupWindow.makeKeyAndOrderFront(nil); NSApplication.shared.activate(ignoringOtherApps: true); return }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 580), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Configurazione ZenVoice"; window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: SetupView(model: Self.model))
        window.center(); setupWindow = window
        window.makeKeyAndOrderFront(nil); NSApplication.shared.activate(ignoringOtherApps: true)
    }
}

private struct SetupView: View {
    @ObservedObject var model: VoiceModel
    @State private var projects: [RegisteredProject] = []
    @State private var selectedProjects: Set<String> = []
    @State private var desktopEnabled = false
    @State private var message = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Progetti consentiti").font(.title2)
            Text("Seleziona i progetti rilevati da ZenCODE. Una sottocartella Git consente l'intero checkout.")
                .font(.callout)
            if projects.isEmpty {
                Text("Nessun progetto disponibile. Apri e salva un progetto in ZenCODE, poi aggiorna la lista.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(projects) { project in
                    Toggle(isOn: Binding(
                        get: { selectedProjects.contains(project.path) },
                        set: { selected in
                            if selected { selectedProjects.insert(project.path) }
                            else { selectedProjects.remove(project.path) }
                        }
                    )) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(project.name)
                            Text(project.path).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.checkbox)
                }
            }
            Divider()
            Toggle("Abilita Desktop nel vocale ChatGPT Subscription", isOn: $desktopEnabled)
                .toggleStyle(.checkbox)
            Text("ZenVoice esegue il tool direttamente, senza agenti ZenCODE. Ogni operazione richiede conferma dal menu; i dati consultati possono essere inviati al provider. Richiede Desktop Tools già installato e i permessi macOS pertinenti. Screenshot e controllo visivo non sono disponibili in questa modalità.")
                .font(.caption).foregroundStyle(.secondary)
            if let reason = model.desktopAvailability {
                Text(reason).font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button("Aggiorna") { reloadProjects() }
                Text("\(selectedProjects.count) progetti selezionati").font(.caption)
                Spacer()
                Button("Salva") {
                    do {
                        guard !model.closing, !model.hasTasks else {
                            throw VoiceError.invalid("Attendi i task prima di cambiare i progetti consentiti")
                        }
                        let settings = try Settings(projects: Array(selectedProjects), desktopEnabled: desktopEnabled).validated(requiresProjects: false)
                        model.deactivate()
                        try settings.save()
                        model.settings = settings
                        message = "Configurazione salvata. Scegli Attiva dal menu per usare ZenVoice."
                    } catch { message = error.localizedDescription }
                }
                .keyboardShortcut(.defaultAction)
            }
            if !message.isEmpty { Text(message).font(.caption) }
        }
        .padding(20)
        .disabled(model.closing || model.hasTasks)
        .onAppear {
            desktopEnabled = model.settings.desktopEnabled
            selectedProjects = Set(model.settings.projects.compactMap { try? Settings.canonicalProject($0) })
            reloadProjects()
        }
    }

    private func reloadProjects() {
        do {
            projects = try ZenCODEConfiguration.loadProjects(including: model.settings.projects)
            selectedProjects.formIntersection(Set(projects.map(\.path)))
            message = ""
        } catch { message = error.localizedDescription }
    }
}
