import Foundation
import Combine
import WebKit
import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import CryptoKit

@MainActor
final class ExtensionManager: ObservableObject {
    private struct PresentedInteractionContext {
        let returnModule: ActiveModule?
    }

    static let shared = ExtensionManager()

    @Published private(set) var installed: [ExtensionManifest] = []
    @Published private(set) var runtimes: [String: ExtensionJSRuntime] = [:]
    @Published private(set) var extensionStates: [String: ExtensionViewState] = [:]
    @Published private(set) var settingsSchemas: [String: SettingsSchema] = [:]

    let localExtensionsDirectory: URL
    let developmentExtensionsDirectory: URL
    let installedExtensionsDirectory: URL
    let bundledExtensionsDirectory: URL?
    private let fallbackRepoExtensionsDirectory: URL?

    var discoveryDirectories: [URL] {
        var orderedPaths: [URL] = []
        var seen = Set<String>()
        for directory in [
            installedExtensionsDirectory,
            developmentExtensionsDirectory,
            localExtensionsDirectory,
            fallbackRepoExtensionsDirectory,
            bundledExtensionsDirectory
        ].compactMap({ $0 }) {
            if seen.insert(directory.path).inserted {
                orderedPaths.append(directory)
            }
        }
        return orderedPaths
    }

    var availableModules: [ActiveModule] {
        installed
            .filter { manifest in
                runtimes[manifest.id] != nil && !manifest.capabilities.notificationFeed
            }
            .map { ActiveModule.extension_($0.id) }
    }

    func isNotificationFeedExtension(_ extensionID: String) -> Bool {
        installed.first(where: { $0.id == extensionID })?.capabilities.notificationFeed == true
    }

    private var refreshTokens: [String: ModuleRefreshToken] = [:]
    private var immediateRefreshWorkItems: [String: DispatchWorkItem] = [:]
    private var presentedInteractionContexts: [String: PresentedInteractionContext] = [:]
    private let fileManager = FileManager.default

    private init() {
        let cwd = URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true)
        localExtensionsDirectory = cwd.appendingPathComponent("Extensions", isDirectory: true)
        developmentExtensionsDirectory = cwd.appendingPathComponent("ExtensionsDev", isDirectory: true)
        fallbackRepoExtensionsDirectory = Self.resolveRepoExtensionsDirectory()
        bundledExtensionsDirectory = Bundle.main.resourceURL?.appendingPathComponent("BundledExtensions", isDirectory: true)

        let appSupportBase = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        installedExtensionsDirectory = appSupportBase
            .appendingPathComponent("SuperIsland", isDirectory: true)
            .appendingPathComponent("Extensions", isDirectory: true)

        try? fileManager.createDirectory(at: installedExtensionsDirectory, withIntermediateDirectories: true)
    }

    private static func resolveRepoExtensionsDirectory() -> URL? {
        // In local development builds, #filePath resolves to this source file path.
        // That lets us reliably find "<repo>/Extensions" even if process CWD differs.
        let sourceFileURL = URL(fileURLWithPath: #filePath)
        let extensionHostDirectory = sourceFileURL.deletingLastPathComponent()
        let repoRoot = extensionHostDirectory.deletingLastPathComponent()
        let repoExtensions = repoRoot.appendingPathComponent("Extensions", isDirectory: true)

        if FileManager.default.fileExists(atPath: repoExtensions.path) {
            return repoExtensions
        }
        return nil
    }

    func discoverExtensions() {
        var discovered: [String: ExtensionManifest] = [:]
        var discoveredSchemas: [String: SettingsSchema] = [:]

        for directory in discoveryDirectories {
            guard fileManager.fileExists(atPath: directory.path) else {
                continue
            }

            let manifests = loadManifests(in: directory)
            for manifest in manifests {
                if let existing = discovered[manifest.id] {
                    // In dev builds the same extension legitimately appears in
                    // both BundledExtensions (inside the built .app) and the
                    // repo's Extensions/ directory. Same id + same version is
                    // a harmless mirror — don't cry wolf. Different versions
                    // means something is genuinely stale and worth surfacing.
                    if existing.version != manifest.version {
                        ExtensionLogger.shared.log(
                            manifest.id,
                            .warning,
                            "Duplicate extension ID in discovery paths with differing versions " +
                            "(keeping \(existing.version) at \(existing.bundleURL.path), " +
                            "ignoring \(manifest.version) at \(manifest.bundleURL.path))"
                        )
                    }
                } else {
                    discovered[manifest.id] = manifest
                }

                if let settingsURL = manifest.settingsURL,
                   let schema = try? SettingsSchema.load(from: settingsURL) {
                    discoveredSchemas[manifest.id] = schema
                }
            }
        }

        let manifests = discovered.values.sorted { lhs, rhs in
            lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
        installed = manifests
        settingsSchemas = discoveredSchemas

        // Deactivate runtimes that are no longer present.
        let activeIDs = Set(runtimes.keys)
        let discoveredIDs = Set(manifests.map(\.id))
        let removedIDs = activeIDs.subtracting(discoveredIDs)
        for id in removedIDs {
            deactivate(extensionID: id)
        }
    }

    // MARK: - User-disabled persistence

    private static let userDisabledExtensionsKey = "extensions.userDisabled"
    private static let seenExtensionsKey = "extensions.seenIDs"

    private func userDisabledIDs() -> Set<String> {
        let array = UserDefaults.standard.stringArray(forKey: Self.userDisabledExtensionsKey) ?? []
        return Set(array)
    }

    private func persistUserDisabledIDs(_ ids: Set<String>) {
        UserDefaults.standard.set(Array(ids), forKey: Self.userDisabledExtensionsKey)
    }

    func isUserDisabled(extensionID: String) -> Bool {
        userDisabledIDs().contains(extensionID)
    }

    /// Deactivates the extension and persists the disabled state so it stays off after restart.
    func disableByUser(extensionID: String) {
        var ids = userDisabledIDs()
        ids.insert(extensionID)
        persistUserDisabledIDs(ids)
        deactivate(extensionID: extensionID)
    }

    /// Tracks which extension IDs the host has already seen.
    ///
    /// Used to default-disable extensions that ship in a new version. The very
    /// first run with this code path has no key yet; that case seeds the set
    /// with whatever is currently installed *without* touching userDisabled, so
    /// upgrading users keep their existing extensions running. Any extension
    /// that appears in a later update is genuinely new and lands in
    /// userDisabled until the user opts in via Settings.
    private func registerNewlyDiscoveredExtensions() {
        let installedIDs = Set(installed.map(\.id))
        let optOutIDs = Set(installed.filter { !$0.defaultEnabled }.map(\.id))
        let defaults = UserDefaults.standard
        let storedSeen = defaults.array(forKey: Self.seenExtensionsKey) as? [String]

        guard let storedSeen else {
            defaults.set(Array(installedIDs), forKey: Self.seenExtensionsKey)
            if !optOutIDs.isEmpty {
                var disabled = userDisabledIDs()
                for id in optOutIDs {
                    disabled.insert(id)
                    ExtensionLogger.shared.log(id, .info, "First-run seed: defaultEnabled=false, leaving disabled until user opts in.")
                }
                persistUserDisabledIDs(disabled)
            }
            return
        }

        let seen = Set(storedSeen)
        let newIDs = installedIDs.subtracting(seen)
        if !newIDs.isEmpty {
            var disabled = userDisabledIDs()
            for id in newIDs {
                disabled.insert(id)
                ExtensionLogger.shared.log(id, .info, "New extension discovered; defaulting to disabled until user opts in.")
            }
            persistUserDisabledIDs(disabled)
        }

        let updatedSeen = seen.union(installedIDs)
        if updatedSeen != seen {
            defaults.set(Array(updatedSeen), forKey: Self.seenExtensionsKey)
        }
    }

    func activateDiscoveredExtensions() {
        registerNewlyDiscoveredExtensions()
        let disabled = userDisabledIDs()
        for manifest in installed where !disabled.contains(manifest.id) {
            activate(extensionID: manifest.id)
        }
    }

    func activate(extensionID: String) {
        // When a user explicitly activates an extension, clear any persisted disabled state.
        var ids = userDisabledIDs()
        if ids.remove(extensionID) != nil {
            persistUserDisabledIDs(ids)
        }

        guard runtimes[extensionID] == nil else { return }
        guard let manifest = installed.first(where: { $0.id == extensionID }) else { return }

        do {
            let runtime = try ExtensionJSRuntime(manifest: manifest, manager: self)
            runtimes[extensionID] = runtime

            runtime.activate()

            startRefreshTimer(for: manifest)
            syncRuntimeEnergyState()
            refreshState(extensionID: extensionID)

            ExtensionLogger.shared.log(extensionID, .info, "Activated extension")
        } catch {
            ExtensionLogger.shared.log(extensionID, .error, error.localizedDescription)
        }
    }

    func reload(extensionID: String) {
        deactivate(extensionID: extensionID)
        activate(extensionID: extensionID)
    }

    func deactivate(extensionID: String) {
        stopRefreshTimer(for: extensionID)
        immediateRefreshWorkItems[extensionID]?.cancel()
        immediateRefreshWorkItems.removeValue(forKey: extensionID)
        presentedInteractionContexts.removeValue(forKey: extensionID)
        runtimes[extensionID]?.deactivate()
        runtimes.removeValue(forKey: extensionID)
        extensionStates.removeValue(forKey: extensionID)

        ExtensionLogger.shared.log(extensionID, .info, "Deactivated extension")
    }

    func refreshState(extensionID: String) {
        guard let runtime = runtimes[extensionID] else { return }
        if let state = runtime.fetchState() {
            extensionStates[extensionID] = state
        }
    }

    func syncRuntimeEnergyState() {
        for manifest in installed {
            guard let runtime = runtimes[manifest.id] else { continue }
            runtime.setTimersSuspended(shouldSuspendRuntimeTimers(for: manifest))
        }
    }

    /// Routes a settings change into the extension's JS `onSettingsChanged`
    /// hook. Called by `ExtensionSettingsStore.set` whenever a toggle/slider
    /// writes a new value. We intentionally don't kick an immediate
    /// refreshState here — that re-publishes `extensionStates` mid-tap,
    /// which caused the settings view to re-render while the Toggle was
    /// still animating, snapping it back to the previous value. The
    /// extension's next timer-driven refresh will pick up any visible
    /// changes a few hundred ms later.
    func notifySettingsChanged(extensionID: String, key: String, value: Any?) {
        guard let runtime = runtimes[extensionID] else { return }
        runtime.notifySettingsChanged(key: key, value: value)
    }

    func scheduleImmediateRefresh(extensionID: String, delay: TimeInterval = 0.05) {
        guard runtimes[extensionID] != nil else { return }
        guard immediateRefreshWorkItems[extensionID] == nil else { return }

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.immediateRefreshWorkItems.removeValue(forKey: extensionID)
            self.refreshState(extensionID: extensionID)
        }

        immediateRefreshWorkItems[extensionID] = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, delay), execute: workItem)
    }

    func handleAction(extensionID: String, actionID: String, value: Any? = nil) {
        if AppState.shared.currentState == .compact {
            AppState.shared.beginCompactControlInteraction()
        }
        runtimes[extensionID]?.handleAction(actionID: actionID, value: value)
        refreshState(extensionID: extensionID)
    }

    func presentExtensionInteraction(
        extensionID: String,
        actionID: String,
        value: Any? = nil,
        presentation: NotificationActionPresentation = .fullExpanded,
        returnModule: ActiveModule? = nil
    ) {
        if runtimes[extensionID] == nil {
            activate(extensionID: extensionID)
        }

        presentedInteractionContexts[extensionID] = PresentedInteractionContext(returnModule: returnModule)
        AppState.shared.showHUD(module: .extension_(extensionID), autoDismiss: false)
        if presentation == .fullExpanded {
            AppState.shared.fullyExpand()
            AppState.shared.cancelFullExpandedDismiss()
        }

        handleAction(extensionID: extensionID, actionID: actionID, value: value)
    }

    func closePresentedInteraction(extensionID: String) -> Bool {
        guard let context = presentedInteractionContexts.removeValue(forKey: extensionID),
              let returnModule = context.returnModule else {
            return false
        }

        if AppState.shared.currentState == .fullExpanded {
            AppState.shared.selectFullExpandedTab(.module(returnModule))
        } else {
            AppState.shared.setActiveModule(returnModule)
        }
        AppState.shared.cancelFullExpandedDismiss()
        return true
    }

    func install(from source: URL) throws -> ExtensionManifest {
        var sourceDirectory = source

        if source.pathExtension.lowercased() == "zip" {
            throw ExtensionManifest.ManifestError.invalidSource(source)
        }

        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: source.path, isDirectory: &isDirectory), isDirectory.boolValue {
            sourceDirectory = source
        } else {
            throw ExtensionManifest.ManifestError.invalidSource(source)
        }

        let manifest = try ExtensionManifest.load(from: sourceDirectory)
        let destination = installedExtensionsDirectory.appendingPathComponent(manifest.id, isDirectory: true)

        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }

        try fileManager.copyItem(at: sourceDirectory, to: destination)

        discoverExtensions()
        if let installedManifest = installed.first(where: { $0.id == manifest.id }) {
            return installedManifest
        }
        return manifest
    }

    func uninstall(extensionID: String) throws {
        deactivate(extensionID: extensionID)

        var ids = userDisabledIDs()
        if ids.remove(extensionID) != nil {
            persistUserDisabledIDs(ids)
        }

        let installDirectory = installedExtensionsDirectory.appendingPathComponent(extensionID, isDirectory: true)
        if fileManager.fileExists(atPath: installDirectory.path) {
            try fileManager.removeItem(at: installDirectory)
        }

        discoverExtensions()
    }

    private func loadManifests(in directory: URL) -> [ExtensionManifest] {
        guard let contents = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var manifests: [ExtensionManifest] = []

        for candidate in contents {
            guard isDirectory(candidate) else { continue }
            do {
                let manifest = try ExtensionManifest.load(from: candidate)
                manifests.append(manifest)
            } catch {
                ExtensionLogger.shared.log(candidate.lastPathComponent, .error, error.localizedDescription)
            }
        }

        return manifests
    }

    private func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
    }

    private func startRefreshTimer(for manifest: ExtensionManifest) {
        stopRefreshTimer(for: manifest.id)

        guard manifest.capabilities.backgroundRefresh,
              manifest.activationTriggers.contains(where: { $0.caseInsensitiveCompare("timer") == .orderedSame }) else {
            return
        }

        let interval = max(1, manifest.refreshInterval)
        let module = refreshModule(for: manifest)
        let tolerance = min(0.5, max(0.1, interval * 0.25))
        let policy: ModuleRefreshPolicy = manifest.capabilities.notificationFeed
            ? .interval(interval, tolerance: tolerance)
            : .visibleOnly(interval, tolerance: tolerance)

        refreshTokens[manifest.id] = ModuleRefreshScheduler.shared.register(
            id: "extension.\(manifest.id).refresh",
            name: "\(manifest.name) extension refresh",
            module: module,
            policy: policy,
            enabled: { [weak self] in
                guard let self else { return false }
                return self.runtimes[manifest.id] != nil
                    && manifest.capabilities.backgroundRefresh
                    && manifest.activationTriggers.contains { $0.caseInsensitiveCompare("timer") == .orderedSame }
            }
        ) { [weak self] in
            self?.refreshState(extensionID: manifest.id)
        }
    }

    private func stopRefreshTimer(for extensionID: String) {
        ModuleRefreshScheduler.shared.unregister(refreshTokens[extensionID])
        refreshTokens.removeValue(forKey: extensionID)
    }

    private func refreshModule(for manifest: ExtensionManifest) -> ActiveModule {
        manifest.capabilities.notificationFeed ? .builtIn(.notifications) : .extension_(manifest.id)
    }

    private func shouldSuspendRuntimeTimers(for manifest: ExtensionManifest) -> Bool {
        let module = refreshModule(for: manifest)
        let appState = AppState.shared
        guard !appState.isModuleVisibleForRefresh(module) else { return false }

        if appState.effectiveEnergyMode == .lowPower || appState.disableBackgroundExtensionRefresh {
            return true
        }

        return appState.effectiveEnergyMode == .smart
            && appState.currentState == .compact
            && !appState.isHovering
    }
}
struct WhatsAppWebMessage: Identifiable {
    let id: String
    let sender: String
    let preview: String
    let mediaPreviewURL: String?
    let avatarURL: String?
    let replyTarget: String?
    let timestamp: Date
}

@MainActor
final class WhatsAppWebBridge: ObservableObject {
    static let shared = WhatsAppWebBridge()

    enum ConnectionState: String {
        case idle, loading, qrReady, loggedIn, error
    }

    @Published private(set) var connectionState: ConnectionState = .idle
    @Published private(set) var statusText: String = "Disabled in clean build"
    @Published private(set) var qrCodeDataURL: String? = nil
    @Published private(set) var lastError: String? = nil
    @Published private(set) var recentMessages: [WhatsAppWebMessage] = []

    func start() {}
    func stop() {}
    func refreshQRCode() {}
    func snapshot(limit: Int) -> [String: Any] { ["state": "idle", "messages": []] }
    func sendMessage(to recipient: String, body: String) -> [String: Any] { ["ok": false, "error": "disabled"] }
}
