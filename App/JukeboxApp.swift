import SwiftUI

@main struct JukeboxApp: App {
  @State private var store: PlayerStore
  @State private var started = false
  private let fixture: FixtureCatalog
  private let profiling: ProfilingRun?
  #if DEBUG || CATALOG_SCALE_FIXTURE
    private let scaleInput: IndexedCatalogInput?
    private let scaleWasFresh: Bool
    private let scaleRejected: Bool
  #endif
  #if DEBUG
    private let transportLaunch: TransportControlLaunch
  #endif
  private let engine: NativePlayer
  private let arguments: [String]
  private let profilingLaunch: ProfilingLaunch
  private let profilingFresh: Bool
  private let storageForAcceptance: LibraryStorage
  private let vaultForAcceptance: any TokenVault
  @Environment(\.scenePhase) private var scenePhase
  init() {
    let args = ProcessInfo.processInfo.arguments
    arguments = args
    #if DEBUG
      let presentation = CatalogFixtures.Presentation(arguments: Array(args.dropFirst()))
      let launches = presentation.diagnosticLaunches(arguments: Array(args.dropFirst()))
      let transport = launches.transport
      let profileInput = launches.profile
      let scaleLaunch = launches.scale
      transportLaunch = transport
      let transportAttempted = transport.isAttempted
      let presentationAttempted = presentation.isAttempted
    #else
      let transport = TransportControlLaunch(arguments: Array(args.dropFirst()))
      let profileInput: ProfilingLaunch =
        transport.isAttempted ? .rejected : ProfilingLaunch(arguments: args)
      let transportAttempted = transport.isAttempted
      let presentationAttempted = false
      #if CATALOG_SCALE_FIXTURE
        let scaleLaunch = IndexedCatalogLaunch(arguments: args)
      #endif
    #endif
    #if DEBUG || CATALOG_SCALE_FIXTURE
      scaleInput = scaleLaunch.input
      scaleRejected = scaleLaunch.isRejected
      let scaleAttempted = scaleLaunch.isAttempted
    #else
      let scaleAttempted = false
    #endif
    #if DEBUG
      if case .run(let runID) = transport { AppLog.beginAcceptance(runID) }
    #endif
    profilingLaunch = profileInput
    let profileID = profileInput.runID
    let fixtureMode =
      args.contains("--fixture") || scaleAttempted || transportAttempted || presentationAttempted
      || profileInput.isAttempted
    let integrationMode = args.contains("--integration")
    let transportMode: DiagnosticLaunchMode?
    #if DEBUG
      if transport.isAttempted {
        if case .rejected = transport {
          transportMode = .rejected
        } else {
          transportMode = .acceptance
        }
      } else {
        transportMode = nil
      }
    #else
      transportMode = nil
    #endif
    let scaleMode: DiagnosticLaunchMode?
    #if DEBUG || CATALOG_SCALE_FIXTURE
      scaleMode = scaleLaunch.isAttempted ? (scaleLaunch.isRejected ? .rejected : .invented) : nil
    #else
      scaleMode = nil
    #endif
    let mode = DiagnosticLaunchMode(
      profiling: profileInput, transport: transportMode, scale: scaleMode,
      fixture: fixtureMode, integration: integrationMode)
    let diagnostics = AppLog.makeSession(mode: mode)
    let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[
      0]
    var profileAudio: URL?
    typealias Startup = (LibraryStorage, String, any TokenVault, Bool)
    func diskStartup(_ root: URL, vault: any TokenVault, fresh: Bool = false) -> Startup {
      let storage = (try? LibraryStorage(directory: root)) ?? LibraryStorage()
      let idURL = root.appendingPathComponent("installation-id")
      let id = (try? String(contentsOf: idURL, encoding: .utf8)) ?? UUID().uuidString
      if !FileManager.default.fileExists(atPath: idURL.path) {
        try? id.write(to: idURL, atomically: true, encoding: .utf8)
      }
      return (storage, id, vault, fresh)
    }
    func normalStartup() -> Startup {
      profileInput.startup(
        normal: {
          let root = support.appendingPathComponent(
            fixtureMode ? "JukeboxDemo" : integrationMode ? "JukeboxIntegration" : "Jukebox")
          return diskStartup(root, vault: fixtureMode ? MemoryVault() : KeychainVault())
        },
        fixture: { id in
          guard let audio = try? ProfilingFixtureFiles.prepareAudio(support: support, runID: id)
          else {
            return (LibraryStorage(), UUID().uuidString, MemoryVault(), false)
          }
          profileAudio = audio
          return diskStartup(audio.deletingLastPathComponent(), vault: MemoryVault(), fresh: true)
        }, isolated: { (LibraryStorage(), UUID().uuidString, MemoryVault(), false) })
    }
    func configuredStartup() -> Startup {
      if profileInput.isRejected {
        return (LibraryStorage(), UUID().uuidString, MemoryVault(), false)
      }
      #if DEBUG || CATALOG_SCALE_FIXTURE
        return scaleLaunch.startup(
          normal: normalStartup,
          accepted: { input in
            let root = support.appendingPathComponent(input.directory, isDirectory: true)
            let fresh = !FileManager.default.fileExists(atPath: root.path)
            guard fresh && !input.cleanup else {
              return (LibraryStorage(), UUID().uuidString, MemoryVault(), false)
            }
            return diskStartup(root, vault: MemoryVault(), fresh: true)
          }, rejected: { (LibraryStorage(), UUID().uuidString, MemoryVault(), false) })
      #else
        return normalStartup()
      #endif
    }
    #if DEBUG
      let startup = transport.startup(
        normal: configuredStartup,
        isolated: { (LibraryStorage(), UUID().uuidString, MemoryVault() as any TokenVault, false) })
    #else
      let startup = configuredStartup()
    #endif
    #if DEBUG || CATALOG_SCALE_FIXTURE
      scaleWasFresh = startup.3
    #endif
    profilingFresh = startup.3
    let storage = startup.0
    let deviceID = startup.1
    storageForAcceptance = storage
    #if DEBUG
      let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
      let fixtureTails = transport.runID.flatMap {
        try? TransportControlFiles.prepareTails(in: caches, runID: $0)
      }
      let native = NativePlayer(
        muted: profileID == nil && (fixtureMode || args.contains("--muted")),
        tailDirectory: fixtureTails
          ?? PlaybackTailFiles.startupDirectory(integration: integrationMode, support: support),
        tailsEnabled: !transportAttempted || fixtureTails != nil)
    #else
      let native = transport.startup(
        normal: {
          NativePlayer(
            muted: profileID == nil && (fixtureMode || args.contains("--muted")),
            tailDirectory: PlaybackTailFiles.startupDirectory(
              integration: integrationMode, support: support))
        }, isolated: { NativePlayer(muted: true, tailsEnabled: false) })
    #endif
    engine = native
    let vault = startup.2
    vaultForAcceptance = vault
    let accountFixture: (any HTTPTransport)?
    #if DEBUG
      if case .interactive = transport, args.contains("--quick-connect-fixture") {
        accountFixture = QuickConnectFixtureHTTP(codesEnabled: !args.contains("--codes-disabled"))
      } else {
        accountFixture = nil
      }
    #else
      accountFixture = nil
    #endif
    let model = PlayerStore(
      storage: storage, vault: vault, driver: native, deviceID: deviceID, diagnostics: diagnostics,
      authenticationTransport: accountFixture ?? LiveHTTP(),
      prepareCover: { bytes in
        await Task.detached(priority: .utility) { MusicCoverThumbnail.make(bytes) }.value
      },
      artworkTone: { await CoverArt.tone(from: $0) },
      factory: {
        try JellyfinClient(
          connection: $0, token: $1, deviceID: deviceID, transport: accountFixture ?? LiveHTTP())
      })
    native.onRemote = { [weak model] action in model?.handleRemote(action) }
    store = model
    let catalogFixture = FixtureCatalog(
      source: profileAudio ?? Bundle.main.resourceURL!.appendingPathComponent("Fixtures/tone.wav"),
      delay: args.contains("--slow-fixture") ? .seconds(1) : .zero,
      catalogFailure: args.contains("--fixture") && args.contains("--catalog-error")
        ? .unavailable : nil,
      catalogDelay: args.contains("--fixture") && args.contains("--slow-catalog")
        ? .seconds(5) : nil,
      catalogSongLimit: fixtureMode && args.contains("--window-fixture") ? 160 : nil,
      singleLibrary: fixtureMode && args.contains("--single-library"),
      longAlbum: fixtureMode && args.contains("--long-album"),
      readOnlyMix: fixtureMode && args.contains("--read-only-mix"))
    fixture = catalogFixture
    profiling =
      startup.3
      ? profileID.map {
        ProfilingRun(
          id: $0, fixture: catalogFixture, native: native,
          backgroundUsingSettings: args.contains("--profile-background-settings"))
      } : nil
  }
  var body: some Scene {
    WindowGroup {
      AppPresentation(store: store, fixture: fixture, arguments: arguments).task {
        guard !started else { return }
        started = true
        if profilingLaunch.isRejected || (profilingLaunch.runID != nil && !profilingFresh) {
          return
        }
        #if DEBUG
          if transportLaunch.isAttempted {
            switch transportLaunch {
            case .run(let runID):
              await TransportAcceptance.run(
                runID: runID, store: store, native: engine, vault: vaultForAcceptance,
                fixture: fixture)
            case .accountSignIn:
              await store.bootstrap(autoConnect: false)
            case .interactive:
              if arguments.contains("--quick-connect-fixture") {
                let useSaved = arguments.contains("--example-saved-connections")
                if useSaved {
                  try? await QuickConnectFixtureHTTP.saveExampleConnections(
                    to: storageForAcceptance, vault: vaultForAcceptance)
                }
                await store.bootstrap(autoConnect: useSaved)
              } else if arguments.contains("--saved-account-fixture") {
                if let server = try? ServerAddress("http://offline.invalid/music") {
                  let account = Connection(
                    server: server, userID: "offline-listener", username: "Offline listener")
                  try? await storageForAcceptance.saveConnections([account])
                }
                await store.bootstrap(autoConnect: false)
              } else {
                await store.enterFixture(service: fixture)
              }
            case .cleanup(let runID):
              let documents = FileManager.default.urls(
                for: .documentDirectory, in: .userDomainMask)[0]
              engine.stop()
              try? TransportControlFiles.cleanup(in: documents, runID: runID)
              let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
              try? TransportControlFiles.cleanupTails(in: caches, runID: runID)
            case .absent, .rejected: break
            }
            return
          }
        #endif
        #if DEBUG || CATALOG_SCALE_FIXTURE
          if scaleRejected { return }
          if let scaleInput {
            if scaleInput.interactive && !scaleInput.cleanup && scaleWasFresh {
              await store.enterFixture(
                service: IndexedCatalogFixture(
                  songCount: scaleInput.songCount,
                  source: Bundle.main.resourceURL!.appendingPathComponent("Fixtures/tone.wav")))
            } else {
              await CatalogScaleAcceptance.run(
                scaleInput, fresh: scaleWasFresh, store: store,
                source: Bundle.main.resourceURL!.appendingPathComponent("Fixtures/tone.wav"))
            }
            return
          }
        #endif
        #if DEBUG
          if arguments.contains("--integration") {
            await DevelopmentAcceptance.run(
              store: store, native: engine, storage: storageForAcceptance, vault: vaultForAcceptance
            )
            return
          }
        #endif
        if case .inspectReport(let id) = profilingLaunch {
          let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
          try? ProfilingFixtureFiles.inspectReport(documents: documents, requestID: id)
          return
        }
        if case .clearInspection(let id) = profilingLaunch {
          let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
          try? ProfilingFixtureFiles.clearInspection(documents: documents, requestID: id)
          return
        }
        if case .cleanup(let id) = profilingLaunch {
          try? ProfilingRun.cleanup(id: id)
          return
        }
        if arguments.contains("--fixture") {
          if let profiling {
            await store.enterFixture(service: profiling.catalog)
            profiling.start(store)
          } else {
            await store.enterFixture(service: fixture)
          }
          #if DEBUG
            if let argument = arguments.first(where: { $0.hasPrefix("--profile-retirement-check=") }
            ),
              let runID = UUID(
                uuidString: String(argument.dropFirst("--profile-retirement-check=".count)))
            {
              await ProfilingRun.checkRetirement(
                store: store, native: engine, fixture: fixture, runID: runID)
            }
            if let argument = arguments.first(where: { $0.hasPrefix("--artwork-check=") }),
              let runID = UUID(uuidString: String(argument.dropFirst("--artwork-check=".count)))
            {
              await DevelopmentAcceptance.runArtworkCheck(
                store: store, native: engine, runID: runID)
            }
            if let argument = arguments.first(where: { $0.hasPrefix("--session-check=") }),
              let runID = UUID(uuidString: String(argument.dropFirst("--session-check=".count)))
            {
              await DevelopmentAcceptance.runSessionEvents(
                store: store, native: engine, runID: runID)
            }
          #endif
        } else {
          #if DEBUG
            if arguments.contains("--connect") {
              await store.bootstrap(autoConnect: false)
              return
            }
          #endif
          await store.bootstrap()
        }
      }.onChange(of: scenePhase) { _, phase in
        #if DEBUG
          if phase == .active { _ = TransportCapture.shared.currentState() }
        #endif
        store.persist()
      }
    }
  }
}

private struct AppPresentation: View {
  let store: PlayerStore
  let fixture: FixtureCatalog
  let arguments: [String]
  @Environment(\.dynamicTypeSize) private var size
  #if DEBUG
    @Environment(\.layoutDirection) private var direction
  #endif
  var body: some View {
    Group {
      #if DEBUG
        if arguments.contains("--fixture") && arguments.contains("--art-layout") {
          ArtworkSizingFixture()
        } else if arguments.contains("--fixture") && arguments.contains("--text-layout") {
          MusicTextFixture()
        } else {
          AppRoot(store: store, fixture: fixture)
        }
      #else
        AppRoot(store: store, fixture: fixture)
      #endif
    }.musicTextActivity(store: store).preferredColorScheme(
      arguments.contains("--fixture") && arguments.contains("--appearance-dark") ? .dark : nil
    ).environment(
      \.dynamicTypeSize,
      arguments.contains("--fixture") && arguments.contains("--large-text") ? .accessibility3 : size
    )
    #if DEBUG
      .environment(
        \.layoutDirection,
        CatalogFixtures.Presentation(arguments: Array(arguments.dropFirst()))
          .rightToLeft(currentFixture: store.isFixture) ? .rightToLeft : direction)
    #endif
  }
}
