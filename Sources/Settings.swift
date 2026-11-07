// Settings window — Бібліотека / Лірика / Last.fm.

import AppKit

@MainActor
final class SettingsWindow: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    static let shared = SettingsWindow()

    private var window: NSWindow?
    private var dirsTable: NSTableView!
    private var geniusField: NSTextField!
    private var lyricsCheck: NSButton!
    private var lastfmCheck: NSButton!
    private var groupsCheck: NSButton!
    private var userField: NSTextField!
    private var passField: NSSecureTextField!
    private var statusLabel: NSTextField!
    private var importBar: NSProgressIndicator!
    private var importLabel: NSTextField!
    private var importCancelBtn: NSButton!
    private var importObs: NSObjectProtocol?

    func show(tab: Int = 0) {
        if window == nil { build() }
        if importObs == nil {
            importObs = NotificationCenter.default.addObserver(
                forName: AppDelegate.fmImportProgress, object: nil, queue: .main) { [weak self] note in
                Task { @MainActor in self?.importProgress(note.userInfo ?? [:]) }
            }
        }
        (window!.contentView as? NSTabView)?.selectTabViewItem(at: tab)
        reloadDirs()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func importProgress(_ info: [AnyHashable: Any]) {
        let done = info["done"] as? Int ?? 0
        let total = info["total"] as? Int ?? 0
        let finished = info["finished"] as? Bool ?? false
        let cancelled = info["cancelled"] as? Bool ?? false
        importBar.isHidden = total == 0 || finished || cancelled
        importCancelBtn.isEnabled = !finished && !cancelled && total > 0
        if cancelled {
            importLabel.stringValue = "імпорт скасовано (\(done) з \(total))"
        } else if finished {
            importLabel.stringValue = "✓ імпортовано \(done) треків"
        } else if total > 0 {
            importBar.doubleValue = Double(done) * 100 / Double(total)
            importLabel.stringValue = "\(done) / \(total)  (\(Int(Double(done) * 100 / Double(total)))%)"
        }
    }

    private func build() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 380),
                         styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "Налаштування"
        w.center()

        let tabs = NSTabView(frame: .zero)
        tabs.translatesAutoresizingMaskIntoConstraints = false
        w.contentView = tabs

        // --- Бібліотека tab
        let libTab = NSTabViewItem(identifier: "lib")
        libTab.label = "Бібліотека"
        let libView = NSView()
        dirsTable = NSTableView()
        dirsTable.dataSource = self
        dirsTable.delegate = self
        dirsTable.headerView = nil
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("dir"))
        col.width = 420
        dirsTable.addTableColumn(col)
        let scroll = NSScrollView()
        scroll.documentView = dirsTable
        scroll.hasVerticalScroller = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let addBtn = NSButton(title: "Додати…", target: self, action: #selector(addDir))
        addBtn.bezelStyle = .rounded
        let delBtn = NSButton(title: "Прибрати", target: self, action: #selector(removeDir))
        delBtn.bezelStyle = .rounded
        let rescanBtn = NSButton(title: "Рескан", target: self, action: #selector(rescan))
        rescanBtn.bezelStyle = .rounded
        let hint = NSTextField(wrappingLabelWithString:
            "Локальні теки та sftp:// адреси (напр. sftp://server/home/server/hdd/media/Music).")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        let btnRow = NSStackView(views: [addBtn, delBtn, rescanBtn, NSView()])
        btnRow.orientation = .horizontal
        btnRow.translatesAutoresizingMaskIntoConstraints = false
        groupsCheck = NSButton(checkboxWithTitle: "Показувати групи за папками в плейлисті",
                               target: self, action: #selector(saveGroups))
        groupsCheck.state = Config.shared.showGroups ? .on : .off
        libView.addSubview(hint)
        libView.addSubview(groupsCheck)
        libView.addSubview(scroll)
        libView.addSubview(btnRow)
        hint.translatesAutoresizingMaskIntoConstraints = false
        groupsCheck.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            hint.topAnchor.constraint(equalTo: libView.topAnchor, constant: 12),
            hint.leadingAnchor.constraint(equalTo: libView.leadingAnchor, constant: 14),
            hint.trailingAnchor.constraint(equalTo: libView.trailingAnchor, constant: -14),
            groupsCheck.topAnchor.constraint(equalTo: hint.bottomAnchor, constant: 10),
            groupsCheck.leadingAnchor.constraint(equalTo: libView.leadingAnchor, constant: 14),
            scroll.topAnchor.constraint(equalTo: groupsCheck.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: libView.leadingAnchor, constant: 14),
            scroll.trailingAnchor.constraint(equalTo: libView.trailingAnchor, constant: -14),
            scroll.bottomAnchor.constraint(equalTo: btnRow.topAnchor, constant: -8),
            btnRow.leadingAnchor.constraint(equalTo: libView.leadingAnchor, constant: 14),
            btnRow.bottomAnchor.constraint(equalTo: libView.bottomAnchor, constant: -14),
        ])
        libTab.view = libView
        tabs.addTabViewItem(libTab)

        // --- Лірика tab
        let lyrTab = NSTabViewItem(identifier: "lyr")
        lyrTab.label = "Лірика"
        let lyrView = NSView()
        lyricsCheck = NSButton(checkboxWithTitle: "Показувати панель текстів (📜 або Cmd+L)",
                               target: nil, action: nil)
        lyricsCheck.state = Config.shared.lyricsEnabled ? .on : .off
        let gLabel = NSTextField(labelWithString: "Genius API token (фолбек, якщо LRCLIB мовчить):")
        gLabel.font = .systemFont(ofSize: 11)
        geniusField = NSTextField(string: Config.shared.geniusToken)
        geniusField.placeholderString = "згенерувати на api.genius.com"
        let lyrSave = NSButton(title: "Зберегти", target: self, action: #selector(saveLyrics))
        lyrSave.bezelStyle = .rounded
        let lyrStack = NSStackView(views: [lyricsCheck, gLabel, geniusField, lyrSave])
        lyrStack.orientation = .vertical
        lyrStack.alignment = .leading
        lyrStack.translatesAutoresizingMaskIntoConstraints = false
        lyrView.addSubview(lyrStack)
        NSLayoutConstraint.activate([
            lyrStack.topAnchor.constraint(equalTo: lyrView.topAnchor, constant: 16),
            lyrStack.leadingAnchor.constraint(equalTo: lyrView.leadingAnchor, constant: 16),
            lyrStack.trailingAnchor.constraint(equalTo: lyrView.trailingAnchor, constant: -16),
            geniusField.widthAnchor.constraint(equalTo: lyrStack.widthAnchor),
        ])
        lyrTab.view = lyrView
        tabs.addTabViewItem(lyrTab)

        // --- Last.fm tab
        let fmTab = NSTabViewItem(identifier: "fm")
        fmTab.label = "Last.fm"
        let fmView = NSView()
        lastfmCheck = NSButton(checkboxWithTitle: "Скроблінг, лайки, кількість прослуховувань",
                               target: nil, action: nil)
        lastfmCheck.state = Config.shared.lastfmEnabled ? .on : .off
        userField = NSTextField(string: Config.shared.lastfmUser)
        userField.placeholderString = "username"
        passField = NSSecureTextField(string: Config.shared.lastfmPassword)
        passField.placeholderString = "пароль"
        statusLabel = NSTextField(labelWithString: "")
        statusLabel.font = .systemFont(ofSize: 11)
        let testBtn = NSButton(title: "Перевірити вхід", target: self, action: #selector(testLogin))
        testBtn.bezelStyle = .rounded
        let fmSave = NSButton(title: "Зберегти", target: self, action: #selector(saveLastfm))
        fmSave.bezelStyle = .rounded
        let importBtn = NSButton(title: "Імпорт статистики (плейкаунти + лайки)",
                                 target: self, action: #selector(importStats))
        importBtn.bezelStyle = .rounded
        importCancelBtn = NSButton(title: "Скасувати", target: self, action: #selector(cancelImport))
        importCancelBtn.bezelStyle = .rounded
        importCancelBtn.isEnabled = false
        importBar = NSProgressIndicator()
        importBar.style = .bar
        importBar.isIndeterminate = false
        importBar.maxValue = 100
        importBar.translatesAutoresizingMaskIntoConstraints = false
        importBar.widthAnchor.constraint(equalToConstant: 160).isActive = true
        importBar.heightAnchor.constraint(equalToConstant: 12).isActive = true
        importLabel = NSTextField(labelWithString: "")
        importLabel.font = .systemFont(ofSize: 11)
        let grid = NSGridView(views: [
            [NSTextField(labelWithString: "User:"), userField],
            [NSTextField(labelWithString: "Password:"), passField],
            [NSView(), NSStackView(views: [testBtn, fmSave, statusLabel])],
            [NSView(), NSStackView(views: [importBtn, importCancelBtn, importBar, importLabel])],
        ])
        grid.rowSpacing = 8
        grid.columnSpacing = 8
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.column(at: 1).xPlacement = .fill
        userField.widthAnchor.constraint(greaterThanOrEqualToConstant: 280).isActive = true
        passField.widthAnchor.constraint(equalTo: userField.widthAnchor).isActive = true
        fmView.addSubview(lastfmCheck)
        fmView.addSubview(grid)
        lastfmCheck.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            lastfmCheck.topAnchor.constraint(equalTo: fmView.topAnchor, constant: 16),
            lastfmCheck.leadingAnchor.constraint(equalTo: fmView.leadingAnchor, constant: 16),
            grid.topAnchor.constraint(equalTo: lastfmCheck.bottomAnchor, constant: 14),
            grid.leadingAnchor.constraint(equalTo: fmView.leadingAnchor, constant: 16),
            grid.trailingAnchor.constraint(lessThanOrEqualTo: fmView.trailingAnchor, constant: -16),
        ])
        fmTab.view = fmView
        tabs.addTabViewItem(fmTab)

        window = w
    }

    private func reloadDirs() {
        dirsTable?.reloadData()
    }

    // MARK: actions

    @objc private func addDir() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.begin { resp in
            guard resp == .OK, let url = panel.url else { return }
            var dirs = Config.shared.libraryDirs
            let p = url.path
            if !dirs.contains(p) { dirs.append(p); Config.shared.libraryDirs = dirs }
            Task { @MainActor in
                self.reloadDirs()
                AppDelegate.shared?.lib.scan()
            }
        }
    }

    @objc private func removeDir() {
        let row = dirsTable.selectedRow
        guard row >= 0 else { return }
        var dirs = Config.shared.libraryDirs
        guard row < dirs.count else { return }
        dirs.remove(at: row)
        Config.shared.libraryDirs = dirs
        reloadDirs()
        Task { @MainActor in AppDelegate.shared?.lib.scan() }
    }

    @objc private func rescan() {
        AppDelegate.shared?.lib.scan()
    }

    @objc private func saveGroups() {
        Config.shared.showGroups = groupsCheck.state == .on
        AppDelegate.shared?.applyFilter()
    }

    @objc private func saveLyrics() {
        Config.shared.lyricsEnabled = lyricsCheck.state == .on
        Config.shared.geniusToken = geniusField.stringValue
        AppDelegate.shared?.setLyricsVisible(Config.shared.lyricsEnabled)
    }

    @objc private func saveLastfm() {
        Config.shared.lastfmEnabled = lastfmCheck.state == .on
        Config.shared.lastfmUser = userField.stringValue
        Config.shared.lastfmPassword = passField.stringValue
        statusLabel.stringValue = ""
    }

    @objc private func testLogin() {
        saveLastfm()
        statusLabel.stringValue = "перевірка…"
        Task {
            let ok = await LastFM.shared.login()
            statusLabel.stringValue = ok ? "✓ вхід успішний" : "✗ не вдалось (перевір логін/пароль)"
        }
    }

    @objc private func importStats() {
        saveLastfm()
        statusLabel.stringValue = ""
        importLabel.stringValue = "вхід…"
        AppDelegate.shared?.startFullImport()
    }

    @objc private func cancelImport() {
        AppDelegate.shared?.importCancel = true
        importLabel.stringValue = "скасовую…"
    }

    @objc private func importLoved() {
        saveLastfm()
        statusLabel.stringValue = "імпорт…"
        Task {
            let n = await LastFM.shared.importLoved()
            statusLabel.stringValue = "✓ імпортовано \(n) лайкнутих треків"
            Task { @MainActor in AppDelegate.shared?.applyFilter() }
        }
    }

    // MARK: table

    func numberOfRows(in tv: NSTableView) -> Int { Config.shared.libraryDirs.count }

    func tableView(_ tv: NSTableView, viewFor col: NSTableColumn?, row: Int) -> NSView? {
        let dirs = Config.shared.libraryDirs
        guard row < dirs.count else { return nil }
        let id = NSUserInterfaceItemIdentifier("dircell")
        let tf = (tv.makeView(withIdentifier: id, owner: self) as? NSTextField) ?? {
            let f = NSTextField(labelWithString: "")
            f.identifier = id
            f.font = .systemFont(ofSize: 12)
            return f
        }()
        tf.stringValue = dirs[row]
        return tf
    }
}