import Foundation

/// Shared constants for the Premiere ExtendScript bridge — the installer (in `locator`) writes the
/// CEP panel that opens this debug port, and the bridge (in `locator-mcp`) connects to it. ONE source
/// of truth so the port/id can never drift between writer and reader.
public enum PremiereBridgeConfig {
    /// The CEF remote-debugging port our CEP panel opens (via its `.debug` file). Arbitrary high port,
    /// loopback only — the same class as the Chrome CDP port.
    public static let debugPort: UInt16 = 8560
    public static let bundleId = "com.forte.locator.premiere"
    public static let panelId = "com.forte.locator.premiere.panel"
    /// The HEADLESS twin: an INVISIBLE CEP extension (AutoVisible false + StartOn app events) that the
    /// host auto-loads at launch — no Window▸Extensions click, and IMMUNE to workspace resets (it is not
    /// a panel in the workspace; measured: a workspace reset closed the visible panel and killed the
    /// bridge mid-session). The visible panel stays as the fallback the engine can reopen via the menu.
    public static let headlessId = "com.forte.locator.premiere.headless"
    public static let headlessPort: UInt16 = 8561
    /// Connection order: headless first (always up after a restart), panel second.
    public static var debugPorts: [UInt16] { [headlessPort, debugPort] }

    /// Per-user CEP extensions dir — unsigned dev extensions live here (needs PlayerDebugMode on).
    public static var extensionsDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Adobe/CEP/extensions", isDirectory: true)
    }
    public static var installDir: URL { extensionsDir.appendingPathComponent(bundleId, isDirectory: true) }
}

/// The CEP bundle files, embedded so the installer is self-contained (in LocatorCore so they're testable
/// and shared). The panel is intentionally minimal — it only needs to LOAD so `__adobe_cep__` exists and
/// CEF opens the debug port; the engine supplies all ExtendScript at call time, so improving a verb never
/// means reinstalling the panel.
public enum PremiereBridgeFiles {
    public static let manifest = """
    <?xml version="1.0" encoding="UTF-8"?>
    <ExtensionManifest Version="6.0" ExtensionBundleId="\(PremiereBridgeConfig.bundleId)" ExtensionBundleVersion="1.0.0"
            ExtensionBundleName="Forte Locator" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
        <ExtensionList>
            <Extension Id="\(PremiereBridgeConfig.panelId)" Version="1.0.0" />
            <Extension Id="\(PremiereBridgeConfig.headlessId)" Version="1.0.0" />
        </ExtensionList>
        <ExecutionEnvironment>
            <HostList>
                <Host Name="PPRO" Version="[13.0,99.9]" />
            </HostList>
            <LocaleList><Locale Code="All" /></LocaleList>
            <RequiredRuntimeList><RequiredRuntime Name="CSXS" Version="6.0" /></RequiredRuntimeList>
        </ExecutionEnvironment>
        <DispatchInfoList>
            <Extension Id="\(PremiereBridgeConfig.panelId)">
                <DispatchInfo>
                    <Resources>
                        <MainPath>./index.html</MainPath>
                        <CEFCommandLine><Parameter>--enable-nodejs</Parameter></CEFCommandLine>
                    </Resources>
                    <Lifecycle><AutoVisible>true</AutoVisible></Lifecycle>
                    <UI>
                        <Type>Panel</Type>
                        <Menu>Forte Locator</Menu>
                        <Geometry><Size><Height>120</Height><Width>240</Width></Size></Geometry>
                    </UI>
                </DispatchInfo>
            </Extension>
            <Extension Id="\(PremiereBridgeConfig.headlessId)">
                <DispatchInfo>
                    <Resources>
                        <MainPath>./index.html</MainPath>
                        <CEFCommandLine><Parameter>--enable-nodejs</Parameter></CEFCommandLine>
                    </Resources>
                    <Lifecycle>
                        <AutoVisible>false</AutoVisible>
                        <StartOn>
                            <Event>com.adobe.csxs.events.ApplicationActivate</Event>
                            <Event>applicationActivate</Event>
                        </StartOn>
                    </Lifecycle>
                    <UI>
                        <Type>Custom</Type>
                        <Geometry><Size><Height>1</Height><Width>1</Width></Size></Geometry>
                    </UI>
                </DispatchInfo>
            </Extension>
        </DispatchInfoList>
    </ExtensionManifest>
    """

    public static let debugFile = """
    <?xml version="1.0" encoding="UTF-8"?>
    <ExtensionList>
        <Extension Id="\(PremiereBridgeConfig.panelId)">
            <HostList>
                <Host Name="PPRO" Port="\(PremiereBridgeConfig.debugPort)"/>
            </HostList>
        </Extension>
        <Extension Id="\(PremiereBridgeConfig.headlessId)">
            <HostList>
                <Host Name="PPRO" Port="\(PremiereBridgeConfig.headlessPort)"/>
            </HostList>
        </Extension>
    </ExtensionList>
    """

    public static let indexHTML = """
    <!doctype html><html><head><meta charset="utf-8"><title>Forte Locator</title>
    <style>body{font:12px -apple-system,sans-serif;background:#1e1e1e;color:#9fe6a0;margin:0;
    display:flex;align-items:center;justify-content:center;height:100vh;text-align:center}
    b{color:#fff}</style></head>
    <body><div>&#9673; <b>Forte Locator</b><br>bridge active — leave this panel open</div>
    <script>/* __adobe_cep__ is injected by CEP; the engine drives evalScript over CDP. */</script>
    </body></html>
    """
}
