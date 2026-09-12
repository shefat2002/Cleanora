## 1. Name 

**Cleanora**

Possible tagline:

> **Clean. Fast. Transparent.**

Or:

> **A cleaner Mac in one sweep.**

I'd avoid names containing **"Cleaner"** alone because they're generic and harder to brand.

---

# 2. Overall product concept

I would structure the app around one big idea:

> **Scan → Understand → Review → Clean → Verify**

Don't make it simply a GUI wrapper around Bash commands.

The app should tell the user **what is consuming space and why it is safe to remove**.

---

# 3. Main workflow

```text
                    ┌─────────────────┐
                    │     Launch      │
                    └────────┬────────┘
                             ↓
                    ┌─────────────────┐
                    │  System Overview│
                    │                 │
                    │  87.4 GB free  │
                    │  42.8 GB junk   │
                    └────────┬────────┘
                             ↓
                    ┌─────────────────┐
                    │   Smart Scan    │
                    └────────┬────────┘
                             ↓
              ┌──────────────┴──────────────┐
              ↓                             ↓
        Safe to Remove                Review Needed
              ↓                             ↓
       Cache / Temp                    Large Files
       Logs                            Downloads
       Trash                           Old Backups
       Browser Cache                  Developer Data
              │                             │
              └──────────────┬──────────────┘
                             ↓
                    ┌─────────────────┐
                    │  Review Results │
                    │                 │
                    │  12.7 GB found  │
                    └────────┬────────┘
                             ↓
                    ┌─────────────────┐
                    │  Select Items   │
                    └────────┬────────┘
                             ↓
                    ┌─────────────────┐
                    │   Clean Now     │
                    └────────┬────────┘
                             ↓
                    ┌─────────────────┐
                    │ Cleaning...     │
                    │ ████████░░ 82%  │
                    └────────┬────────┘
                             ↓
                    ┌─────────────────┐
                    │   Cleaned!      │
                    │                 │
                    │   12.7 GB freed │
                    └─────────────────┘
```

---

# 4. Dashboard

The first screen should be extremely simple.

```text
┌──────────────────────────────────────────────┐
│  Cleanora                         ⚙ Settings │
│                                              │
│              Your Mac is                    │
│                                              │
│                Healthy                       │
│                                              │
│             42.8 GB                          │
│          Safe to clean                       │
│                                              │
│          ┌───────────────┐                   │
│          │   Scan Mac    │                   │
│          └───────────────┘                   │
│                                              │
│  Last scan: Today, 10:42 AM                  │
│                                              │
│  Caches             8.4 GB                   │
│  Temporary files    2.1 GB                   │
│  Logs               1.3 GB                   │
│  Trash              3.7 GB                   │
└──────────────────────────────────────────────┘
```

**One primary action:** `Scan Mac`

Don't overwhelm users with 20 buttons.

---

# 5. Scanning workflow

When the user clicks **Scan Mac**:

```text
Scanning your Mac...

✓ Application caches
✓ Browser caches
✓ Temporary files
● System logs
○ Trash
○ Developer caches
○ Large files
```

Show live progress.

But don't just show:

> "Scanning..."

Give users confidence that something meaningful is happening.

---

# 6. Results screen

This is probably the most important screen.

Example:

```text
Scan Complete

12.7 GB can potentially be cleaned

─────────────────────────────────────

✓ Application Caches       5.8 GB
✓ Browser Caches           2.4 GB
✓ Temporary Files          1.7 GB
✓ Old Logs                 0.8 GB
✓ Trash                    2.0 GB

─────────────────────────────────────

        12.7 GB Selected

             [ Clean Now ]
```

Each category should be expandable.

For example:

```text
Application Caches                    5.8 GB   >

  Chrome                              2.1 GB
  Xcode                               1.7 GB
  VS Code                             0.9 GB
  Other                               1.1 GB
```

This makes the app feel **transparent rather than suspicious**.

---

# 7. Safety classification

I'd divide cleanup targets into three levels.

### 🟢 Safe

Automatically selected.

Examples:

* Browser cache
* Application cache
* Temporary files
* Old diagnostic reports
* Trash
* Xcode DerivedData

### 🟡 Review

Not automatically selected.

Examples:

* Large downloads
* Old installers
* Old Xcode archives
* Developer caches
* Application support data

### 🔴 Don't touch

The application should never offer these as generic cleanup targets.

Examples:

* Documents
* Desktop
* Photos
* iCloud Drive
* Password databases
* Keychain
* Application databases
* System-critical files

This distinction could become one of your strongest selling points.

---

# 8. Cleaning screen

Make the cleaning animation satisfying but not gimmicky.

```text
Cleaning your Mac

Removing application caches...

████████████████░░░░  78%

5.4 GB / 6.9 GB

✓ Chrome cache
✓ Safari cache
✓ Xcode DerivedData
● Temporary files
○ Old logs
```

At the bottom:

> **Don't close Cleanora while cleaning.**

---

# 9. Completion screen

Make the result very clear.

```text
        ✨ Your Mac is cleaner

          12.7 GB freed

──────────────────────────

2,481 items removed

Caches             8.2 GB
Temporary files    1.7 GB
Logs               0.8 GB
Trash              2.0 GB

──────────────────────────

       [ Done ]

Last cleaned:
September 12, 2026 • 5:42 PM
```

You could also show:

> **You now have 98.3 GB available.**

---

# 10. History

A simple history screen would make the application feel much more mature.

```text
Cleanup History

Today
12.7 GB freed

Sep 08
4.2 GB freed

Sep 01
7.8 GB freed

Aug 25
2.4 GB freed
```

Clicking an entry:

```text
September 12

12.7 GB freed
2,481 items removed

Application Cache       8.2 GB
Temp Files              1.7 GB
Logs                    0.8 GB
Trash                   2.0 GB
```

---

# 11. Settings

Keep settings minimal.

### General

```text
☑ Launch at login
☐ Show cleanup reminder
☑ Show confirmation before cleaning
```

### Scan

```text
☑ Application caches
☑ Browser caches
☑ Temporary files
☑ Old logs
☑ Trash

☑ Developer caches
```

### Cleaning

```text
☑ Ask before deleting
☐ Automatically clean safe items
☑ Keep cleanup history
```

---

# 12. Developer Mode

Since you're likely to use this yourself as well, I'd add a hidden/advanced section.

It could detect:

```text
Developer Cleanup

Xcode
  DerivedData             8.2 GB
  Archives                14.7 GB
  Device Support          11.4 GB

Node
  npm cache               3.1 GB
  Yarn cache              1.8 GB

Python
  pip cache               2.2 GB

Homebrew
  Cache                   4.7 GB

Docker
  Build cache             18.2 GB
```

But **don't automatically delete Docker data**. Show exactly what will be removed.

---

# 13. Recommended architecture

If you're targeting modern macOS, I'd build the GUI natively with:

```text
Swift
  │
  ├── SwiftUI
  │      │
  │      ├── Dashboard
  │      ├── Scanner
  │      ├── Results
  │      ├── Cleaner
  │      ├── History
  │      └── Settings
  │
  ├── Scan Engine
  │      ├── CacheScanner
  │      ├── TempScanner
  │      ├── LogScanner
  │      ├── BrowserScanner
  │      ├── DeveloperScanner
  │      └── TrashScanner
  │
  ├── Cleanup Engine
  │      ├── SafeDeletion
  │      ├── PermissionManager
  │      └── CleanupLogger
  │
  └── Storage
         ├── ScanHistory
         └── Preferences
```

I'd **avoid making Bash the core engine**.

Your current Bash script is excellent for prototyping the cleanup logic, but the final application should ideally have Swift-native scanners and deletion logic.

---

# 14. Important technical design

Use a model similar to:

```text
CleanupItem
├── id
├── name
├── category
├── path
├── size
├── riskLevel
├── selected
├── reason
└── deletionMethod
```

For example:

```text
{
    name: "Chrome Cache",
    category: "Browser",
    size: 2.4 GB,
    riskLevel: "safe",
    selected: true,
    reason: "Temporary browser cache",
    deletionMethod: "removeContents"
}
```

This allows the UI to remain completely independent from the cleanup engine.

---

# 15. The most important UX feature: "Why?"

Every cleanup category should have a small info button:

```text
Application Cache        5.8 GB   ⓘ
```

Click:

```text
Why can I remove this?

Application caches are temporary files created
by apps to improve performance.

Removing them is generally safe.
Apps may recreate these files when needed.

              [ Got it ]
```

That builds **trust**.

---

# 16. MVP roadmap

Don't build everything initially.

### Phase 1 — MVP

Build:

* Dashboard
* Scan
* Application cache scanning
* Temporary files
* Browser caches
* Logs
* Trash
* Results
* Select/deselect
* Cleanup
* Space reclaimed
* Cleanup log

### Phase 2

Add:

* Xcode cleanup
* Homebrew
* npm
* Developer cleanup
* Large files
* Cleanup history
* Better disk visualization

### Phase 3

Add:

* Menu bar app
* Scheduled cleanup
* Smart recommendations
* Duplicate file detection
* Startup item manager
* App leftovers/uninstaller

---

# 17. Your killer feature

I'd differentiate it from typical Mac-cleaner apps with:

## **Transparent Cleaning**

Instead of:

> "We found 48 GB of junk!"

say:

> **We found 48 GB. Here's exactly where it is.**

Then:

```text
48.2 GB Found

32.7 GB  Safe
 8.4 GB  Review
 7.1 GB  Don't touch
```

That makes the app feel technically trustworthy rather than like a scareware cleaner.

### My preferred branding

**MacSweep**

**Tagline:**

> *A cleaner Mac in one sweep.*

**Core UX:**
**Scan → Review → Clean → Verify**

And visually I'd go with a **minimal native macOS style**: lots of whitespace, subtle SF Symbols, soft gradients, a single accent color, and a large central storage/cleanup indicator rather than the typical "aggressive antivirus" look.
