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
    private var userField: NSTextField!
    private var passField: NSSecureTextField!
    private var statusLabel: NSTextField!

    func show(tab: Int = 0) {
        if window == nil { build() }
        (window!.contentView as? NSTabView)?.selectTabViewItem(at: tab)
        reloadDirs()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
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
        libView.addSubview(hint)
        libView.addSubview(scroll)
        libView.addSubview(btnRow)
        hint.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            hint.topAnchor.constraint(equalTo: libView.topAnchor, constant: 12),
            hint.leadingAnchor.constraint(equalTo: libView.leadingAnchor, constant: 14),
            hint.trailingAnchor.constraint(equalTo: libView.trailingAnchor, constant: -14),
            scroll.topAnchor.constraint(equalTo: hint.bottomAnchor, constant: 8),
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
        let importBtn = NSButton(title: "Імпортувати лайки", target: self, action: #selector(importLoved))
        importBtn.bezelStyle = .rounded
        let grid = NSGridView(views: [
            [NSTextField(labelWithString: "User:"), userField],
            [NSTextField(labelWithString: "Password:"), passField],
            [NSView(), NSStackView(views: [testBtn, fmSave, importBtn, statusLabel])],
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