import Foundation

/// Long-form explanations shown by WhyInfoSheet. Kept next to the models so
/// every surface (row, sheet, confirmation, completion) renders identical text.
enum SafetyCopy {
    static func why(for category: ScanCategory) -> String {
        switch category {
        case .applicationCaches:
            return """
            Application caches are temporary files apps create to speed themselves up. \
            Removing them is generally safe — apps recreate them as needed, though the \
            first launch after cleaning may be slightly slower.
            """
        case .browserCaches:
            return """
            Browser caches store copies of websites you visited so pages load faster. \
            Removing them is safe; websites simply reload their content the next time \
            you visit. You won't lose passwords, bookmarks, or history.
            """
        case .temporaryFiles:
            return """
            Temporary files are scratch data the system and apps create while working. \
            Removing old ones is safe; anything still in use is skipped.
            """
        case .logs:
            return """
            Logs record what apps and the system have been doing. Old diagnostic and \
            crash reports are useful only for debugging — removing them frees space \
            with no effect on your apps.
            """
        case .trash:
            return """
            The Trash holds files you already deleted. Emptying it permanently \
            removes them from your Mac. This is the one step that cannot be undone.
            """
        case .developerData:
            return """
            Developer tools build up large caches: build artifacts, simulator support \
            files, package downloads. All of these are re-downloadable or regenerated \
            on demand, but removal can make your next build slower.
            """
        case .largeFiles:
            return """
            Large files are listed so you can decide — Cleanora never deletes them \
            automatically. Review each one and move only what you no longer need.
            """
        case .appLeftovers:
            return """
            When you uninstall an app, its caches, preferences and support files \
            usually stay behind. Cleanora lists what it found next to the app bundle \
            so you can review each file before anything is removed — nothing is \
            deleted without your say-so.
            """
        }
    }
}
