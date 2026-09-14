import Foundation

/// M-06 — one installed application as the inventory found it.
public struct InstalledApp: Sendable, Equatable {
    /// Display name: `CFBundleName`, else `CFBundleDisplayName`, else the
    /// bundle folder name.
    public let name: String
    /// `CFBundleIdentifier`; nil for bundles without a readable Info.plist.
    public let bundleID: String?
    public let url: URL
    /// Allocated bytes of the whole bundle tree.
    public let bundleSize: Int64
    /// `CFBundleShortVersionString`; nil when absent.
    public let version: String?

    public init(
        name: String,
        bundleID: String?,
        url: URL,
        bundleSize: Int64,
        version: String?
    ) {
        self.name = name
        self.bundleID = bundleID
        self.url = url
        self.bundleSize = bundleSize
        self.version = version
    }
}

/// M-06 — read-only inventory of installed applications.
///
/// Roots: the system applications folder (`environment.applications`,
/// override-injectable so engine tests never touch the real folder) and the
/// user's `~/Applications`; overlapping roots deduplicate on canonical paths.
/// A direct child that is a real directory ending in `.app` (case-insensitive)
/// is inventoried — symlinks are never followed (I7), nested bundles are not
/// listed. This type decides nothing about running apps, deletion or
/// planning; it only answers "what is installed, and how big is it".
public struct AppInventoryScanner: Sendable {
    public init() {}

    public func inventory(environment: ScanEnvironment) -> [InstalledApp] {
        let systemRoot = PathNormalizer.canonicalized(environment.applications)
        let userRoot = PathNormalizer.canonicalized(environment.userApplications)
        var roots = [systemRoot]
        if userRoot != systemRoot {
            roots.append(userRoot)
        }

        var seenCanonicalPaths = Set<String>()
        var apps: [InstalledApp] = []
        for root in roots {
            guard environment.exists(root), environment.readable(root) else { continue }
            let children = ((try? FileSystemWalker().children(of: root)) ?? [])
            for child in children {
                let values = try? child.resourceValues(forKeys: FileSystemWalker.resourceKeySet)
                guard values?.isSymbolicLink != true, // I7
                      values?.isDirectory == true,
                      child.lastPathComponent.lowercased().hasSuffix(".app")
                else { continue }
                let canonical = PathNormalizer.canonicalized(child)
                guard seenCanonicalPaths.insert(canonical.path).inserted else { continue }
                apps.append(Self.installedApp(at: canonical))
            }
        }
        return apps.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    /// One bundle → one InstalledApp. Never throws: an unreadable or
    /// unparseable bundle still shows up, with best-effort fields.
    static func installedApp(at bundle: URL) -> InstalledApp {
        let info = Bundle(url: bundle)?.infoDictionary
        let folderName = bundle.lastPathComponent
        let fallbackName = folderName.hasSuffix(".app")
            ? String(folderName.dropLast(".app".count))
            : folderName
        return InstalledApp(
            name: (info?["CFBundleName"] as? String)
                ?? (info?["CFBundleDisplayName"] as? String)
                ?? fallbackName,
            bundleID: info?["CFBundleIdentifier"] as? String,
            url: bundle,
            bundleSize: TreeMeasurement.measure(bundle).bytes,
            version: info?["CFBundleShortVersionString"] as? String
        )
    }
}

/// Synchronous tree measurement for the sync M-06 APIs
/// (`inventory`/`plan`). Mirrors `DirectorySizeCalculator`'s rules —
/// allocated bytes, regular files only, symlinks neither followed nor
/// counted — without its async fan-out.
enum TreeMeasurement {
    static func measure(_ url: URL) -> (bytes: Int64, fileCount: Int) {
        let values = try? url.resourceValues(forKeys: FileSystemWalker.resourceKeySet)
        if values?.isDirectory != true {
            return (ScannerGuards.fileSize(from: values), values?.isRegularFile == true ? 1 : 0)
        }
        var bytes: Int64 = 0
        var fileCount = 0
        for entry in FileSystemWalker().descendants(of: url).entries {
            let entryValues = try? entry.resourceValues(forKeys: FileSystemWalker.resourceKeySet)
            guard entryValues?.isSymbolicLink != true,
                  entryValues?.isRegularFile == true
            else { continue }
            fileCount += 1
            bytes += ScannerGuards.fileSize(from: entryValues)
        }
        return (bytes, fileCount)
    }
}
