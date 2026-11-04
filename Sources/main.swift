// FooBar Swift — native macOS music player.
// AppKit + AVPlayer + MediaPlayer; SFTP via ssh + loopback HTTP proxy.

import AppKit
import AVFoundation
import MediaPlayer

final class FolderNode {
    let name: String
    let path: String
    private(set) var children: [FolderNode] = []
    private var index: [String: FolderNode] = [:]
    init(name: String, path: String) { self.name = name; self.path = path }
    func child(_ n: String, _ p: String) -> FolderNode {
        if let c = index[n] { return c }
        let c = FolderNode(name: n, path: p)
        index[n] = c
        children.append(c)
        return c
    }
    var sortedChildren: [FolderNode] {
        children.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSTableViewDataSource,
                          NSTableViewDelegate, NSMenuDelegate, NSSearchFieldDelegate {
    static weak var shared: AppDelegate?

    let lib = Library()
    let player = Player()
    var filtered: [Track] = []
    var queueIndex = -1

    enum RowItem { case header(String); case track(Int) }   // Int = index in filtered
    var rows: [RowItem] = []
    var sortKey: String? = nil
    var sortAsc = true

    // UI
    var window: NSWindow!
    var table: NSTableView!
    var search: NSSearchField!
    var nowLabel: NSButton!
    var seekSlider: NSSlider!
    var volSlider: NSSlider!
    var timeLabel: NSTextField!
    var playButton: NSButton!
    var loveButton: NSButton!
    var orderPopup: NSPopUpButton!
    var stopOnceButton: NSButton!
    var randomButton: NSButton!
    var lyricsButton: NSButton!
    var sshButton: NSButton!
    var lyricsText: NSTextView!
    var lyricsHeader: NSTextField!
    var lyricsScroll: NSScrollView!
    var lyricsPane: NSStackView?
    var lyricsSplit: NSSplitView!
    var outline: NSOutlineView!
    var treeRoots: [FolderNode] = []
    var treeSearch: NSSearchField!
    var treeQuery = ""
    var treeDisplayRoots: [FolderNode] = []
    var displayRoots: [FolderNode] { treeQuery.isEmpty ? treeRoots : treeDisplayRoots }
    var folderFilter: String?   // dir path set by tree click; nil = all (tree itself shows which)
    var isReady = false
    var currentPlayingPath: String?
    var currentPlayingKey: String?
    var lyricsVisible = false
    var scrubbing = false

    // state
    var currentLyrics: LyricsResult?
    var lastLyricsIdx = -1
    var lyricsReqSeq = 0
    var lastScrobbledPath: String?
    var playStartTime: Date?
    var playedSeconds: TimeInterval = 0

    func applicationDidFinishLaunching(_ note: Notification) {
        AppDelegate.shared = self
        NSApp.setActivationPolicy(.regular)
        buildMenu()
        buildUI()
        wirePlayer()
        wireMediaKeys()

        lib.onUpdated = { [weak self] in self?.lib.hydrateStatsFromCache(); self?.applyFilter(); self?.restoreSession(); self?.startBackfill(); self?.buildTree() }
        Ssh.onStatus = { [weak self] _ in self?.updateSshStatus() }
        lib.scan()
        startBackfill()
        let lastImport = UserDefaults.standard.double(forKey: "cfg.fm_loved_imported")
        if LastFM.shared.isEnabled,
           Date().timeIntervalSince1970 - lastImport > 7 * 86400 {
            Task {
                let n = await LastFM.shared.importLoved()
                if n > 0 { UserDefaults.standard.set(Date().timeIntervalSince1970,
                                                     forKey: "cfg.fm_loved_imported") }
                self.applyFilter()
            }
        }
        Task {
            for dir in Config.shared.libraryDirs {
                if let s = parseSftp(dir) { await Ssh.probe(host: s.host) }
            }
        }

        player.volume = Config.shared.volume
        volSlider.doubleValue = Double(player.volume)
        sortKey = Config.shared.sortKey
        sortAsc = Config.shared.sortAsc
        if !Config.shared.searchText.isEmpty { search.stringValue = Config.shared.searchText }
        orderPopup.selectItem(at: Config.shared.stopAfterMode == "always" ? 2
                             : (Config.shared.shuffle ? 1 : 0))
        setLyricsVisible(Config.shared.lyricsEnabled)
        DispatchQueue.main.async {
            let p0 = Config.shared.splitPos0
            if p0 > 0 { self.lyricsSplit.setPosition(p0, ofDividerAt: 0) }
            let p1 = Config.shared.splitPos1
            if p1 > 0, self.lyricsVisible { self.lyricsSplit.setPosition(p1, ofDividerAt: 1) }
        }
        updateSshStatus()
        isReady = true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ n: Notification) {
        Config.shared.volume = player.volume
        Config.shared.searchText = search.stringValue
        if lyricsSplit != nil {
            Config.shared.splitPos0 = dividerPos(lyricsSplit, 0)
            if lyricsVisible {
                Config.shared.splitPos1 = dividerPos(lyricsSplit, 1)
            }
        }
        scrobbleIfNeeded()
    }

    // MARK: menu

    func buildMenu() {
        let main = NSMenu()
        let appItem = main.addItem(withTitle: "FooBar Swift", action: nil, keyEquivalent: "")
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Налаштування…", action: #selector(openSettings),
                        keyEquivalent: ",")
        appMenu.addItem(withTitle: "Рескан бібліотеки", action: #selector(rescan), keyEquivalent: "r")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Вийти", action: #selector(NSApplication.terminate(_:)),
                        keyEquivalent: "q")
        appItem.submenu = appMenu

        // playlist/playback menu: ⌘E works from any focus (context-menu key
        // equivalents don't register globally; menu-bar ones do)
        let plItem = main.addItem(withTitle: "Плейлист", action: nil, keyEquivalent: "")
        let pl = NSMenu(title: "Плейлист")
        pl.addItem(withTitle: "Редагувати теги…", action: #selector(editTagsFromMenu), keyEquivalent: "e")
        pl.addItem(withTitle: "Властивості файлу", action: #selector(showProperties), keyEquivalent: "")
        pl.addItem(withTitle: "Лайкнути / зняти лайк", action: #selector(loveFromMenu), keyEquivalent: "")
        pl.addItem(.separator())
        pl.addItem(withTitle: "Наступний трек", action: #selector(nextTrack), keyEquivalent: "")
        pl.item(at: pl.items.count - 1)?.keyEquivalentModifierMask = [.control]
        pl.addItem(withTitle: "Попередній трек", action: #selector(prevTrack), keyEquivalent: "")
        pl.item(at: pl.items.count - 1)?.keyEquivalentModifierMask = [.control]
        plItem.submenu = pl

        let editItem = main.addItem(withTitle: "Правка", action: nil, keyEquivalent: "")
        let edit = NSMenu(title: "Правка")
        for (t, sel, k) in [("Виділити все", #selector(NSResponder.selectAll(_:)), "a"),
                            ("Копіювати", #selector(NSText.copy(_:)), "c")] {
            edit.addItem(withTitle: t, action: sel, keyEquivalent: k)
        }
        editItem.submenu = edit

        let viewItem = main.addItem(withTitle: "Вигляд", action: nil, keyEquivalent: "")
        let view = NSMenu(title: "Вигляд")
        lyricsMenuItem = view.addItem(withTitle: "Тексти пісень", action: #selector(toggleLyrics), keyEquivalent: "l")
        viewItem.submenu = view

        NSApp.mainMenu = main
    }

    @objc func openSettings() { SettingsWindow.shared.show(tab: 0) }
    @objc func rescan() { lib.scan() }
    @objc func toggleLyrics() { setLyricsVisible(!lyricsVisible) }

    var lyricsMenuItem: NSMenuItem?

    func setLyricsVisible(_ visible: Bool) {
        lyricsVisible = visible
        lyricsScroll?.isHidden = !visible
        lyricsPane?.isHidden = !visible
        lyricsMenuItem?.state = visible ? .on : .off
        Config.shared.lyricsEnabled = visible
        if let split = lyricsSplit {
            if visible {
                split.setPosition(split.bounds.width * 0.62, ofDividerAt: 1)
            } else {
                split.setPosition(split.bounds.width - 1, ofDividerAt: 1)
            }
            Config.shared.splitPos1 = dividerPos(split, 1)
        }
        if visible, currentTrack() != nil, currentLyrics == nil {
            if let t = currentTrack() { startLyrics(for: t) }
        }
    }

    // MARK: SSH status

    func updateSshStatus() {
        let hosts = Set(Config.shared.libraryDirs.compactMap { parseSftp($0)?.host })
        guard !hosts.isEmpty else { sshButton.title = ""; return }
        let states = Ssh.status
        let offline = hosts.filter { states[$0] != .online }
        if offline.isEmpty {
            sshButton.title = "🟢 SSH: \(hosts.joined(separator: ","))"
        } else {
            sshButton.title = "🔴 SSH: \(offline.joined(separator: ",")) — реконект"
        }
    }

    @objc func sshReconnect() {
        sshButton.title = "🟡 SSH: під'єднання…"
        Task {
            for dir in Config.shared.libraryDirs {
                if let s = parseSftp(dir) { await Ssh.probe(host: s.host) }
            }
            self.updateSshStatus()
            self.lib.scan()
        }
    }

    // MARK: UI

    func buildUI() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 640),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.title = "FooBar Swift"
        window.setFrameAutosaveName("MainWindow")
        window.isRestorable = false
        window.center()

        let content = NSView(frame: window.contentView!.bounds)
        content.autoresizingMask = [.width, .height]
        window.contentView = content

        search = NSSearchField(frame: .zero)
        search.translatesAutoresizingMaskIntoConstraints = false
        search.placeholderString = "Пошук…"
        search.delegate = self
        search.target = self
        search.action = #selector(filterChanged)

        table = NSTableView()
        table.dataSource = self
        table.delegate = self
        table.usesAlternatingRowBackgroundColors = true
        table.doubleAction = #selector(rowDoubleClicked)
        let cols: [(String, String, CGFloat)] = [
            ("love", "♥", 30), ("title", "Назва", 280), ("artist", "Артист", 150),
            ("album", "Альбом", 150), ("dur", "Час", 55), ("plays", "▶", 40),
            ("path", "Full Path", 420),
        ]
        for (id, name, w) in cols {
            let c = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            c.title = name; c.width = w
            table.addTableColumn(c)
        }
        let menu = NSMenu()
        menu.addItem(withTitle: "Рескан бібліотеки", action: #selector(rescan), keyEquivalent: "")
        menu.addItem(withTitle: "Перепід'єднати SSH", action: #selector(sshReconnect), keyEquivalent: "")
        menu.addItem(withTitle: "Налаштування…", action: #selector(openSettings), keyEquivalent: "")
        menu.addItem(.separator())
        ctxEditItem = menu.addItem(withTitle: "Редагувати теги… (⌘E)",
                                   action: #selector(editTagsFromMenu), keyEquivalent: "e")
        ctxPropsItem = menu.addItem(withTitle: "Властивості файлу",
                                    action: #selector(showProperties), keyEquivalent: "")
        ctxLoveItem = menu.addItem(withTitle: "Лайкнути / зняти лайк",
                                   action: #selector(loveFromMenu), keyEquivalent: "")
        for it in menu.items { it.target = self }
        menu.delegate = self
        table.menu = menu

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        table.columnAutoresizingStyle = .noColumnAutoresizing
        table.allowsColumnResizing = true
        table.autosaveName = "PlaylistColumns"   // widths + order survive restarts

        lyricsText = NSTextView()
        lyricsText.isEditable = false
        lyricsText.font = .systemFont(ofSize: 14)
        lyricsText.textContainerInset = NSSize(width: 12, height: 12)
        let lscroll = NSScrollView()
        lscroll.documentView = lyricsText
        lscroll.hasVerticalScroller = true

        lyricsScroll = lscroll

        // editable search-target header: "Artist — Title", Enter = re-query
        lyricsHeader = NSTextField(string: "")
        lyricsHeader.font = .systemFont(ofSize: 12, weight: .semibold)
        lyricsHeader.placeholderString = "Артист — Трек (Enter = шукати)"
        lyricsHeader.target = self
        lyricsHeader.action = #selector(lyricsQueryEdited)

        // folder tree (left pane), like the Qt treeView
        outline = NSOutlineView()
        let tcol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        tcol.title = "Бібліотека"
        tcol.width = 220
        outline.addTableColumn(tcol)
        outline.outlineTableColumn = tcol
        outline.dataSource = self
        outline.delegate = self
        outline.headerView = nil
        outline.rowSizeStyle = .small
        let treeMenu = NSMenu()
        treeMenu.addItem(withTitle: "Показати всі треки", action: #selector(clearFolderFilter), keyEquivalent: "")
        treeMenu.addItem(withTitle: "Рескан бібліотеки", action: #selector(rescan), keyEquivalent: "")
        for it in treeMenu.items { it.target = self }
        outline.menu = treeMenu
        let treeScroll = NSScrollView()
        treeScroll.documentView = outline
        treeScroll.hasVerticalScroller = true

        // folder filter input: typing narrows the tree to matching dirs
        treeSearch = NSSearchField(frame: .zero)
        treeSearch.placeholderString = "Фільтр папок…"
        treeSearch.toolTip = "Показати лише директорії, що співпадають з введенням"
        treeSearch.target = self
        treeSearch.action = #selector(treeFilterChanged)
        let treePane = NSStackView(views: [treeSearch, treeScroll])
        treePane.orientation = .vertical
        treePane.alignment = .leading
        treePane.spacing = 6
        treeSearch.widthAnchor.constraint(equalTo: treePane.widthAnchor).isActive = true
        treeScroll.widthAnchor.constraint(equalTo: treePane.widthAnchor).isActive = true
        treeScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 100).isActive = true
        treeScroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        treeScroll.setContentCompressionResistancePriority(.required, for: .vertical)
        treeSearch.setContentHuggingPriority(.required, for: .vertical)

        lyricsSplit = NSSplitView()
        lyricsSplit.isVertical = true
        lyricsSplit.dividerStyle = .thin
        lyricsSplit.translatesAutoresizingMaskIntoConstraints = false
        lyricsSplit.addArrangedSubview(treePane)
        // playlist pane: search on top, table below — lives inside the middle column
        let playlistPane = NSStackView(views: [search, scroll])
        playlistPane.orientation = .vertical
        playlistPane.alignment = .leading
        playlistPane.spacing = 6
        search.widthAnchor.constraint(equalTo: playlistPane.widthAnchor).isActive = true
        scroll.widthAnchor.constraint(equalTo: playlistPane.widthAnchor).isActive = true
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 100).isActive = true
        scroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        scroll.setContentCompressionResistancePriority(.required, for: .vertical)
        search.setContentHuggingPriority(.required, for: .vertical)
        lyricsSplit.addArrangedSubview(playlistPane)
        // lyrics pane: editable target header on top, text below
        let lyricsPane = NSStackView(views: [lyricsHeader, lscroll])
        self.lyricsPane = lyricsPane
        lyricsPane.orientation = .vertical
        lyricsPane.alignment = .leading
        lyricsPane.spacing = 4
        lyricsHeader.widthAnchor.constraint(equalTo: lyricsPane.widthAnchor).isActive = true
        lscroll.widthAnchor.constraint(equalTo: lyricsPane.widthAnchor).isActive = true
        lscroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 100).isActive = true
        lscroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        lscroll.setContentCompressionResistancePriority(.required, for: .vertical)
        lyricsHeader.setContentHuggingPriority(.required, for: .vertical)
        lyricsSplit.addArrangedSubview(lyricsPane)
        treeScroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        treeScroll.setContentCompressionResistancePriority(.required, for: .vertical)
        content.addSubview(lyricsSplit)

        // transport
        playButton = NSButton(title: "▶", target: self, action: #selector(togglePlay))
        playButton.bezelStyle = .rounded
        let prev = NSButton(title: "⏮", target: self, action: #selector(prevTrack))
        prev.bezelStyle = .rounded
        let next = NSButton(title: "⏭", target: self, action: #selector(nextTrack))
        next.bezelStyle = .rounded
        loveButton = NSButton(title: "♡", target: self, action: #selector(toggleLove))
        loveButton.bezelStyle = .rounded
        loveButton.toolTip = "Лайк на Last.fm"
        // playback order + stop-after-current dropdowns (bottom row, right side)
        orderPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        orderPopup.controlSize = .small
        orderPopup.font = .systemFont(ofSize: 11)
        orderPopup.addItems(withTitles: ["▶ По-порядку", "🔀 Рандом", "⏹ Стоп після кожного трека"])
        orderPopup.target = self
        orderPopup.action = #selector(orderChanged)
        orderPopup.toolTip = "Порядок відтворення / зупинка після кожного треку"
        orderPopup.widthAnchor.constraint(equalToConstant: 125).isActive = true
        orderPopup.selectItem(at: Config.shared.stopAfterMode == "always" ? 2
                             : (Config.shared.shuffle ? 1 : 0))
        stopOnceButton = NSButton(title: "⏹", target: self,
                                  action: #selector(stopOnceToggled))
        stopOnceButton.bezelStyle = .rounded
        stopOnceButton.setButtonType(.pushOnPushOff)   // stays pressed while armed
        stopOnceButton.toolTip = "⏹ Стоп після поточного треку (відтиснеться сама після завершення)"
        randomButton = NSButton(title: "🎲", target: self, action: #selector(jumpToRandom))
        randomButton.bezelStyle = .rounded
        randomButton.toolTip = "Перейти до випадкового треку з поточного списку"
        lyricsButton = NSButton(title: "📜", target: self, action: #selector(toggleLyrics))
        lyricsButton.bezelStyle = .rounded
        lyricsButton.toolTip = "Тексти пісень (Cmd+L)"

        seekSlider = NSSlider(value: 0, minValue: 0, maxValue: 1, target: self, action: #selector(seeked))
        seekSlider.isContinuous = true
        timeLabel = NSTextField(labelWithString: "0:00 / 0:00")
        timeLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        volSlider = NSSlider(value: 1, minValue: 0, maxValue: 1, target: self, action: #selector(volChanged))
        volSlider.isContinuous = true
        volSlider.controlSize = .small

        nowLabel = NSButton(title: "—", target: self, action: #selector(revealNowPlaying))
        nowLabel.isBordered = false
        nowLabel.bezelStyle = .inline
        nowLabel.font = .systemFont(ofSize: 11)
        nowLabel.contentTintColor = .secondaryLabelColor
        nowLabel.cell?.lineBreakMode = .byTruncatingMiddle
        nowLabel.toolTip = "Клік — знайти та виділити цей трек у плейлисті"
        nowLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let stack = NSStackView(views: [prev, playButton, next, loveButton,
                                        randomButton, stopOnceButton,
                                        seekSlider, timeLabel, lyricsButton,
                                        NSView(), orderPopup])
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.setHuggingPriority(.defaultLow, for: .horizontal)
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)

        sshButton = NSButton(title: "⚠️ SSH", target: self, action: #selector(sshReconnect))
        sshButton.translatesAutoresizingMaskIntoConstraints = false
        sshButton.bezelStyle = .inline
        sshButton.font = .systemFont(ofSize: 11)
        sshButton.toolTip = "SSH-з'єднання з сервером (клік = реконект)"
        let nowStack = NSStackView(views: [NSTextField(labelWithString: "Грає:"), nowLabel])
        let volIcon = NSTextField(labelWithString: "🔊")
        volIcon.font = .systemFont(ofSize: 11)
        let volStack = NSStackView(views: [volIcon, volSlider])   // volume lives in the
        volStack.orientation = .horizontal                        // "Грає" row, like the
        volStack.translatesAutoresizingMaskIntoConstraints = false    // connection status
        content.addSubview(sshButton)
        content.addSubview(volStack)
        nowStack.orientation = .horizontal
        nowStack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(nowStack)

        NSLayoutConstraint.activate([
            lyricsSplit.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            lyricsSplit.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            lyricsSplit.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            lyricsSplit.bottomAnchor.constraint(equalTo: nowStack.topAnchor, constant: -8),
            nowStack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            nowStack.bottomAnchor.constraint(equalTo: stack.topAnchor, constant: -8),
            sshButton.centerYAnchor.constraint(equalTo: nowStack.centerYAnchor),
            sshButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            volStack.centerYAnchor.constraint(equalTo: nowStack.centerYAnchor),
            volStack.trailingAnchor.constraint(equalTo: sshButton.leadingAnchor, constant: -14),
            nowStack.trailingAnchor.constraint(lessThanOrEqualTo: volStack.leadingAnchor, constant: -8),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
            stack.heightAnchor.constraint(equalToConstant: 28),
            volSlider.widthAnchor.constraint(equalToConstant: 90),
            timeLabel.widthAnchor.constraint(equalToConstant: 100),
        ])

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] ev in
            guard let self, ev.window == self.window else { return ev }
            // Qt-parity global-to-window shortcuts: these win over focused
            // text fields (window-wide QShortcuts behave the same in Qt)
            let ctrl = ev.modifierFlags.contains(.control)
            switch ev.keyCode {
            case 53: // Escape: clear search if it holds text, else minimize (Qt behavior)
                if !self.search.stringValue.isEmpty {
                    self.search.stringValue = ""
                    self.filterChanged()
                    return nil
                }
                if !self.treeSearch.stringValue.isEmpty {
                    self.treeSearch.stringValue = ""
                    self.treeFilterChanged()
                    return nil
                }
                self.window.miniaturize(nil); return nil
            case 99: // F3 = focus search
                self.window.makeFirstResponder(self.search)
                self.search.selectText(nil); return nil
            case 125 where ctrl: self.nextTrack(); return nil   // Ctrl+Down
            case 126 where ctrl: self.prevTrack(); return nil   // Ctrl+Up
            case 1 where ctrl:   // Ctrl+S = toggle stop-after-current
                self.stopOnceButton.state = self.stopOnceButton.state == .on ? .off : .on
                self.stopOnceToggled(); return nil
            case 120:    // F2 = tag editor even when search field has focus
                self.editTagsSelected(); return nil
            default: break
            }
            // typing in any text field (search, lyrics header): let keys through
            if self.window.firstResponder is NSText { return ev }
            if ev.keyCode == 36, let fi = self.filteredIndex(forRow: self.table.selectedRow) {
                self.playRow(fi); return nil
            }
            if ev.keyCode == 49 { self.togglePlay(); return nil }
            return ev
        }
    }

    // MARK: playback

    func wirePlayer() {
        player.onTime = { [weak self] cur, dur in
            guard let self else { return }
            if !self.scrubbing, dur > 0 { self.seekSlider.doubleValue = cur / dur }
            self.timeLabel.stringValue = "\(fmt(cur)) / \(fmt(dur))"
            self.lyricsTick(cur)
            // remote tracks often lack TLEN in tags — adopt the real duration
            // from the stream so scrobble thresholds work
            if self.queueIndex >= 0 && self.queueIndex < self.filtered.count,
               self.filtered[self.queueIndex].duration <= 0, dur > 0 {
                self.filtered[self.queueIndex].duration = dur
            }
            self.playedSeconds += 0.5
            if let t = self.currentTrack(), t.duration > 0,
               self.playedSeconds >= t.duration * 0.5 {
                self.scrobbleIfNeeded()
            }
        }
        player.onItemEnd = { [weak self] in
            print("onItemEnd fired")
            self?.scrobbleIfNeeded()
            guard let self else { return }
            let mode = Config.shared.stopAfterMode
            if mode == "once" || mode == "always" {
                if mode == "once" {
                    Config.shared.stopAfterMode = "off"
                    self.stopOnceButton.state = .off   // auto-release the button
                }
                self.player.av.pause()
                self.player.seek(0)
                self.playButton.title = "▶"
                self.seekSlider.doubleValue = 0
                if var info = MPNowPlayingInfoCenter.default().nowPlayingInfo {
                    info[MPNowPlayingInfoPropertyPlaybackRate] = 0.0
                    MPNowPlayingInfoCenter.default().nowPlayingInfo = info
                }
                return
            }
            self.nextTrack()
        }
    }

    func currentTrack() -> Track? {
        queueIndex >= 0 && queueIndex < filtered.count ? filtered[queueIndex] : nil
    }

    func trackKey(_ t: Track) -> String { t.remotePath ?? t.url.path }

    /// Click on the 'Грає:' title: clear anything that could hide the current
    /// track, select its folder in the tree, then select + scroll to its row.
    @objc func revealNowPlaying() {
        let key = currentPlayingKey ?? (queueIndex >= 0 && queueIndex < filtered.count
            ? trackKey(filtered[queueIndex]) : nil)
        guard let key else { return }
        // Already visible in the current view (e.g. whole library shown):
        // just select + scroll, don't touch search or the tree/folder filter.
        if let fi = filtered.firstIndex(where: { trackKey($0) == key }),
           let row = row(forFilteredIndex: fi) {
            selectAndRevealRow(row, fi: fi)
            return
        }
        if !search.stringValue.isEmpty {
            search.stringValue = ""
            applyFilter()
            if let fi = filtered.firstIndex(where: { trackKey($0) == key }),
               let row = row(forFilteredIndex: fi) {
                selectAndRevealRow(row, fi: fi)
                return
            }
        }
        locateCurrentFolder()   // selects tree node → folderFilter → applyFilter
        guard let fi = filtered.firstIndex(where: { trackKey($0) == key }) else { return }
        if let row = row(forFilteredIndex: fi) { selectAndRevealRow(row, fi: fi) }
    }

    func row(forFilteredIndex fi: Int) -> Int? {
        rows.firstIndex { item in
            if case .track(let i) = item, i == fi { return true }
            return false
        }
    }

    func selectAndRevealRow(_ row: Int, fi: Int) {
        queueIndex = fi
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        table.scrollRowToVisible(row)
        window.makeFirstResponder(table)
    }

    func playRow(_ row: Int) {
        guard row >= 0, row < filtered.count else { return }
        scrobbleIfNeeded()
        queueIndex = row
        var t = filtered[row]
        if t.isRemote, let rp = t.remotePath, let host = remoteHost(for: rp) {
            t.url = StreamProxy.shared.url(for: host, path: rp)
            filtered[row] = t
        }
        player.play(t)
        currentPlayingPath = t.dirPath
        currentPlayingKey = trackKey(t)
        locateCurrentFolder()
        playStartTime = Date()
        playedSeconds = 0
        Config.shared.lastTrackKey = trackKey(t)
        Config.shared.lastTrackPos = 0
        playButton.title = "⏸"
        updateNowPlaying(t)
        startLyrics(for: t)
        refreshLastFM(for: t, row: row)
    }

    func remoteHost(for path: String) -> String? {
        for dir in Config.shared.libraryDirs {
            if let s = parseSftp(dir), path.hasPrefix(s.path) { return s.host }
        }
        return nil
    }

    @objc func rowDoubleClicked() {
        if let fi = filteredIndex(forRow: table.clickedRow) { playRow(fi) }
    }

    @objc func togglePlay() {
        if player.av.currentItem == nil {
            playRow(filteredIndex(forRow: table.selectedRow) ?? 0); return
        }
        player.toggle()
        playButton.title = player.isPlaying ? "⏸" : "▶"
        if !player.isPlaying { scrobbleIfNeeded() }
        if var info = MPNowPlayingInfoCenter.default().nowPlayingInfo {
            info[MPNowPlayingInfoPropertyPlaybackRate] = player.isPlaying ? 1.0 : 0.0
            MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        }
    }

    @objc func nextTrack() { playRelative(1) }
    @objc func prevTrack() { playRelative(-1) }

    @objc func orderChanged() {
        let idx = orderPopup.indexOfSelectedItem
        if idx == 2 {
            Config.shared.stopAfterMode = "always"
            stopOnceButton?.state = .off
        } else {
            if Config.shared.stopAfterMode == "always" { Config.shared.stopAfterMode = "off" }
            Config.shared.shuffle = idx == 1
        }
    }

    @objc func stopOnceToggled() {
        if stopOnceButton.state == .on {
            Config.shared.stopAfterMode = "once"
            if orderPopup.indexOfSelectedItem == 2 {
                Config.shared.stopAfterMode = "once"
                orderPopup.selectItem(at: Config.shared.shuffle ? 1 : 0)
            }
        } else {
            if Config.shared.stopAfterMode == "once" { Config.shared.stopAfterMode = "off" }
        }
    }

    // MARK: session restore
    private var sessionRestored = false

    func dividerPos(_ split: NSSplitView, _ i: Int) -> Double {
        guard split.subviews.count > i + 1 else { return 0 }
        return Double(split.subviews[i + 1].frame.minX)
    }

    func restoreSession() {
        guard !sessionRestored else { return }
        sessionRestored = true
        let key = Config.shared.lastTrackKey
        guard !key.isEmpty, let fi = filtered.firstIndex(where: { trackKey($0) == key }) else { return }
        queueIndex = fi
        if let r = rows.firstIndex(where: { if case .track(let i) = $0 { return i == fi }; return false }) {
            table.selectRowIndexes(IndexSet(integer: r), byExtendingSelection: false)
        }
        let pos = Config.shared.lastTrackPos
        let dur = filtered[fi].duration
        if pos > 0, dur > 0 {
            seekSlider.doubleValue = pos / dur
            timeLabel.stringValue = "\(fmt(pos)) / \(fmt(dur))"
        }
    }

    @objc func jumpToRandom() {
        guard !filtered.isEmpty else { return }
        let fi = Int.random(in: 0..<filtered.count)
        playRow(fi)
    }

    func playRelative(_ delta: Int) {
        guard !filtered.isEmpty else { return }
        if delta < 0, player.av.currentTime().seconds > 3 { player.seek(0); return }
        if Config.shared.shuffle && delta > 0 {
            queueIndex = Int.random(in: 0..<filtered.count)
        } else {
            queueIndex = min(max(queueIndex + delta, 0), filtered.count - 1)
        }
        playRow(queueIndex)
    }

    @objc func seeked() {
        let dur = CMTimeGetSeconds(player.av.currentItem?.duration ?? .zero)
        if dur.isFinite, dur > 0 {
            player.seek(seekSlider.doubleValue * dur)
            Config.shared.lastTrackPos = seekSlider.doubleValue * dur
        }
    }

    @objc func volChanged() { player.volume = Float(volSlider.doubleValue) }

    // MARK: last.fm

    // background: fill playcount/loved for the whole library, 1 track per ~1.1s,
    // results live in the SQLite cache so this runs once a week per track
    // MARK: Last.fm import (playcounts + loved) — background, cancellable, progress
    static let fmImportProgress = Notification.Name("FmImportProgress")
    var importRunning = false
    var importCancel = false
    private var importSeq = 0

    func publishImport(done: Int, total: Int, finished: Bool) {
        NotificationCenter.default.post(name: Self.fmImportProgress, object: nil,
            userInfo: ["done": done, "total": total, "finished": finished,
                       "cancelled": importCancel])
    }

    func startFullImport() {
        importSeq += 1
        let seq = importSeq
        importCancel = false
        guard LastFM.shared.isEnabled else { return }
        importRunning = true
        publishImport(done: 0, total: 0, finished: false)
        Task { @MainActor in
            await LastFM.shared.login()
            await self.runImport(seq: seq, force: true)
        }
    }

    @MainActor
    func runImport(seq: Int, force: Bool) async {
        let targets = lib.tracks.indices.filter {
            !lib.tracks[$0].artist.isEmpty
                && (force || FmCache.shared.needsLookup(artist: lib.tracks[$0].artist,
                                                        title: lib.tracks[$0].title))
        }
        let total = targets.count
        var done = 0
        var fails = 0
        publishImport(done: 0, total: total, finished: false)
        for i in targets {
            guard seq == importSeq, !importCancel else { break }
            if let info = await LastFM.shared.info(for: lib.tracks[i], force: force) {
                lib.updateStats(at: i, playcount: info.playcount, loved: info.loved)
                fails = 0
            } else {
                fails += 1
            }
            done += 1
            if done % 15 == 0 {
                publishImport(done: done, total: total, finished: false)
                applyFilter()
            }
            // rate-limit / network trouble → back off instead of hammering
            if fails >= 3 {
                try? await Task.sleep(nanoseconds: 20_000_000_000)
                fails = 0
            }
            try? await Task.sleep(nanoseconds: 1_100_000_000)
        }
        applyFilter()
        if seq == importSeq { importRunning = false }
        publishImport(done: done, total: total,
                      finished: seq == importSeq && !importCancel)
    }

    func startBackfill() {
        importSeq += 1
        let seq = importSeq
        importCancel = false
        guard LastFM.shared.isEnabled else { return }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 5_000_000_000)   // let the scan settle
            guard seq == self.importSeq else { return }
            self.importRunning = true
            self.publishImport(done: 0, total: 0, finished: false)
            await LastFM.shared.login()
            await self.runImport(seq: seq, force: false)
        }
    }
    func scrobbleIfNeeded() {
        guard let t = currentTrack(), let start = playStartTime,
              t.duration > 0, playedSeconds >= min(t.duration * 0.5, 240),
              lastScrobbledPath != trackKey(t) else { return }
        lastScrobbledPath = trackKey(t)
        // local +1 immediately (server value catches up on next relookup) AND
        // reflect it in the visible table right away
        let newPc = (FmCache.shared.peek(artist: t.artist, title: t.title) ?? 0) + 1
        FmCache.shared.set(artist: t.artist, title: t.title, playcount: newPc, loved: nil)
        for i in lib.tracks.indices where trackKey(lib.tracks[i]) == trackKey(t) {
            lib.updateStats(at: i, playcount: newPc, loved: lib.tracks[i].loved)
        }
        for i in filtered.indices where trackKey(filtered[i]) == trackKey(t) {
            filtered[i].playcount = newPc
        }
        table?.reloadData()
        LastFM.shared.scrobble(artist: t.artist, title: t.title, album: t.album, start: start)
    }

    func refreshLastFM(for t: Track, row: Int) {
        loveButton.title = t.loved == true ? "♥" : "♡"
        loveButton.isEnabled = LastFM.shared.isEnabled && !t.artist.isEmpty
        guard LastFM.shared.isEnabled, !t.artist.isEmpty else { return }
        Task {
            if let info = await LastFM.shared.info(for: t) {
                for i in self.filtered.indices
                where self.filtered[i].url == t.url && self.filtered[i].remotePath == t.remotePath {
                    self.filtered[i].playcount = info.playcount
                    self.filtered[i].loved = info.loved
                }
                self.loveButton.title = info.loved ? "♥" : "♡"
                if row == self.queueIndex { self.updateNowPlaying(self.filtered[row]) }
                self.table.reloadData()
            }
        }
    }

    @objc func toggleLove() {
        guard let t = currentTrack(), queueIndex >= 0 else { return }
        loveTrack(t, row: queueIndex)
    }

    func loveTrack(_ t: Track, row: Int) {
        let target = !(t.loved ?? false)
        LastFM.shared.setLoved(t, loved: target) { [weak self] ok in
            guard ok, let self, row < self.filtered.count else { return }
            self.filtered[row].loved = target
            if row == self.queueIndex {
                self.loveButton.title = target ? "♥" : "♡"
                self.updateNowPlaying(self.filtered[row])
            }
            self.table.reloadData()
        }
    }

    // MARK: context menu / F2 — tags, properties, love

    var ctxEditItem: NSMenuItem?
    var ctxPropsItem: NSMenuItem?
    var ctxLoveItem: NSMenuItem?

    func menuNeedsUpdate(_ menu: NSMenu) {
        let has = ctxTrack() != nil
        ctxEditItem?.isEnabled = has
        ctxPropsItem?.isEnabled = has
        ctxLoveItem?.isEnabled = has && LastFM.shared.isEnabled
    }

    func ctxTrack() -> Track? {
        let row = table.clickedRow >= 0 ? table.clickedRow : table.selectedRow
        guard let fi = filteredIndex(forRow: row) else { return nil }
        return filtered[fi]
    }

    func ctxTrackRow() -> Int? {
        let row = table.clickedRow >= 0 ? table.clickedRow : table.selectedRow
        return filteredIndex(forRow: row)
    }

    @objc func editTagsFromMenu() { editTagsSelected() }

    func editTagsSelected() {
        print("editTags: selectedRow=\(table.selectedRow) clickedRow=\(table.clickedRow)")
        guard let t = ctxTrack() else { print("editTags: no ctx track"); return }
        let ext = (t.remotePath ?? t.url.path).lowercased()
        guard ext.hasSuffix(".mp3") || ext.hasSuffix(".flac") else {
            let a = NSAlert()
            a.messageText = "Редагування тегів поки що лише для MP3/FLAC"
            a.informativeText = "Write-back підключено для .mp3 (ID3v2.3) та .flac (Vorbis comments); інші формати — в плані."
            a.runModal()
            return
        }
        TagEditorWindow.shared.edit(track: t)
    }

    @objc func showProperties() {
        guard let t = ctxTrack() else { return }
        let a = NSAlert()
        a.messageText = "\(t.artist) — \(t.title)"
        var info = "Файл: \(t.fullPath)\n"
        if t.duration > 0 { info += "Тривалість: \(fmt(t.duration))\n" }
        info += "Альбом: \(t.album.isEmpty ? "—" : t.album)\n"
        info += "Плейкаунт: \(t.playcount ?? 0)   Лайк: \(t.loved == true ? "♥" : "—")\n"
        if t.lyrics != nil { info += "Лірика вбудована в теги: так\n" }
        a.informativeText = info + "…\n"
        a.addButton(withTitle: "OK")
        if t.isRemote, let rp = t.remotePath, let host = remoteHost(for: rp) {
            Task { @MainActor in
                if let out = try? await Ssh.run(host: host,
                        command: "stat -c '%s' \(sqt(rp))"),
                   let size = Int(out.trimmingCharacters(in: .whitespacesAndNewlines)) {
                    var extra = "Розмір: \(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))\n"
                    if t.duration > 0 {
                        extra += "Бітрейт: ~\(Int(Double(size) * 8 / t.duration / 1000)) kbps\n"
                    }
                    a.informativeText = info + extra
                    a.runModal()
                } else { a.runModal() }
            }
        } else {
            let size = (try? t.url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            if size > 0 {
                var extra = "Розмір: \(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))\n"
                if t.duration > 0 {
                    extra += "Бітрейт: ~\(Int(Double(size) * 8 / t.duration / 1000)) kbps\n"
                }
                info += extra
            }
            a.informativeText = info
            a.runModal()
        }
    }

    @objc func loveFromMenu() {
        guard let t = ctxTrack(), let row = ctxTrackRow() else { return }
        loveTrack(t, row: row)
    }

    // MARK: lyrics

    func startLyrics(for t: Track) {
        lyricsReqSeq += 1
        let seq = lyricsReqSeq
        currentLyrics = nil
        lyricsText.string = Config.shared.lyricsEnabled ? "…" : ""
        lyricsHeader.stringValue = t.artist.isEmpty ? t.title : "\(t.artist) — \(t.title)"
        guard !t.artist.isEmpty else { return }
        let dur = player.duration > 0 ? player.duration : t.duration
        Task {
            let r = await resolveLyrics(artist: t.artist, title: cleanQueryTitle(t.title),
                                        album: t.album, duration: dur, embedded: t.lyrics)
            guard seq == lyricsReqSeq else { return }
            currentLyrics = r
            print("lyrics: \(r?.source ?? "not found") for [\(t.artist)] / [\(t.title)]")
            renderLyrics(r)
        }
    }

    /// resolution chain: tag-embedded lyrics → local cache → network (then cached).
    /// Synced always wins over plain for display.
    func resolveLyrics(artist: String, title: String, album: String,
                       duration: TimeInterval, embedded: String? = nil) async -> LyricsResult? {
        if let e = embedded, !e.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let synced = Lyrics.parseLRC(e)
            if !synced.isEmpty { return LyricsResult(synced: synced, plain: nil, source: "тег файлу") }
            return LyricsResult(synced: [], plain: e, source: "тег файлу")
        }
        if let c = LyricsCache.shared.get(artist: artist, title: title) {
            let synced = Lyrics.parseLRC(c.synced)
            return LyricsResult(synced: synced,
                                plain: c.plain.isEmpty ? nil : c.plain,
                                source: c.source.isEmpty ? "кеш" : "\(c.source) (кеш)")
        }
        if let r = await Lyrics.fetch(artist: artist, title: title, album: album,
                                      duration: duration) {
            let lrc = r.synced.map { line -> String in
                let m = Int(line.time) / 60, s = line.time - Double(m * 60)
                return String(format: "[%02d:%04.1f] %@", m, s, line.text)
            }.joined(separator: "\n")
            LyricsCache.shared.set(artist: artist, title: title, synced: lrc,
                                   plain: r.plain ?? "", source: r.source)
            return r
        }
        return nil
    }

    @objc func lyricsQueryEdited() {
        let s = lyricsHeader.stringValue
        let parts = s.contains("—") ? s.components(separatedBy: "—")
                                    : s.components(separatedBy: " - ")
        let a = parts.first?.trimmingCharacters(in: .whitespaces) ?? ""
        let b = parts.count > 1
            ? parts.dropFirst().joined(separator: " - ").trimmingCharacters(in: .whitespaces) : ""
        guard !a.isEmpty, !b.isEmpty else { return }
        lyricsReqSeq += 1
        let seq = lyricsReqSeq
        currentLyrics = nil
        lyricsText.string = "…"
        window.makeFirstResponder(lyricsText)
        Task {
            let r = await resolveLyrics(artist: a, title: b, album: "",
                                        duration: player.duration)
            guard seq == lyricsReqSeq else { return }
            currentLyrics = r
            renderLyrics(r)
        }
    }

    func renderLyrics(_ r: LyricsResult?) {
        lastLyricsIdx = -1
        guard let r else {
            lyricsText.string = "— нічого не знайшов —"
            return
        }
        let src = "\n\n— \(r.source) —"
        if !r.synced.isEmpty {
            lyricsText.string = r.synced.map(\.text).joined(separator: "\n") + src
            // dim base: the active line gets highlighted by lyricsTick
            if let ts = lyricsText.textStorage {
                ts.setAttributes([
                    .font: NSFont.systemFont(ofSize: 14),
                    .foregroundColor: NSColor.secondaryLabelColor,
                ], range: NSRange(location: 0, length: ts.length))
            }
        } else {
            lyricsText.string = (r.plain ?? "") + src
        }
    }

    func lyricsTick(_ cur: TimeInterval) {
        guard let r = currentLyrics, !r.synced.isEmpty, lyricsVisible else { return }
        let idx = max(0, r.synced.lastIndex { $0.time <= cur } ?? 0)
        guard idx != lastLyricsIdx, let ts = lyricsText.textStorage,
              let container = lyricsText.textContainer,
              let lm = lyricsText.layoutManager else { return }
        lastLyricsIdx = idx
        let ns = ts.string as NSString
        // dim everything, then bold + full-color the active line
        ts.setAttributes([
            .font: NSFont.systemFont(ofSize: 14),
            .foregroundColor: NSColor.secondaryLabelColor,
        ], range: NSRange(location: 0, length: ns.length))
        var pos = 0
        for i in 0..<idx { pos += r.synced[i].text.count + 1 }
        guard pos < ns.length else { return }
        var start = pos
        while start > 0 && ns.character(at: start - 1) != 10 { start -= 1 }
        var end = pos
        while end < ns.length && ns.character(at: end) != 10 { end += 1 }
        let para = NSRange(location: start, length: end - start)
        ts.addAttributes([
            .font: NSFont.systemFont(ofSize: 15, weight: .semibold),
            .foregroundColor: NSColor.labelColor,
        ], range: para)
        // keep the active line centered in the visible area
        if let clip = lyricsText.enclosingScrollView?.contentView {
            let lineRect = lm.boundingRect(forGlyphRange: NSRange(location: start, length: 1),
                                           in: container)
            let maxY = max(0, lyricsText.frame.height - clip.bounds.height)
            let y = min(max(0, lineRect.midY - clip.bounds.height / 2), maxY)
            clip.scroll(NSPoint(x: 0, y: y))
        }
    }

    // MARK: media keys

    func wireMediaKeys() {
        let cc = MPRemoteCommandCenter.shared()
        cc.playCommand.addTarget { _ in Task { @MainActor in self.player.av.play() }; return .success }
        cc.pauseCommand.addTarget { _ in Task { @MainActor in self.player.av.pause() }; return .success }
        cc.togglePlayPauseCommand.addTarget { _ in Task { @MainActor in self.togglePlay() }; return .success }
        cc.nextTrackCommand.addTarget { _ in Task { @MainActor in self.nextTrack() }; return .success }
        cc.previousTrackCommand.addTarget { _ in Task { @MainActor in self.prevTrack() }; return .success }
    }

    func updateNowPlaying(_ t: Track) {
        nowLabel.title = (t.loved == true ? "♥ " : "")
            + "\(t.artist.isEmpty ? "" : t.artist + " — ")\(t.title)"
        window.title = "\(t.title) — FooBar Swift"
        var info: [String: Any] = [
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: 0.0,
            MPNowPlayingInfoPropertyPlaybackRate: 1.0,
        ]
        if t.duration > 0 { info[MPMediaItemPropertyPlaybackDuration] = t.duration }
        if !t.title.isEmpty { info[MPMediaItemPropertyTitle] = t.title }
        if !t.artist.isEmpty { info[MPMediaItemPropertyArtist] = t.artist }
        if !t.album.isEmpty { info[MPMediaItemPropertyAlbumTitle] = t.album }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        // album art: async extract (AVAsset reads ID3 locally and over the
        // loopback proxy), attach only if this track is still the current one
        let trackURL = t.url
        ArtworkCache.shared.image(for: trackURL) { [weak self] img in
            print("artwork: " + (img == nil ? "none" : "OK \(img!.size)") + " for \(trackURL.lastPathComponent)")
            guard let self, let img,
                  self.queueIndex >= 0, self.queueIndex < self.filtered.count,
                  self.filtered[self.queueIndex].url == trackURL,
                  var info = MPNowPlayingInfoCenter.default().nowPlayingInfo,
                  info[MPMediaItemPropertyArtwork] == nil else { return }
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: img.size) { _ in img }
            MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        }
        if LastFM.shared.isEnabled, !t.artist.isEmpty {
            LastFM.shared.updateNowPlaying(artist: t.artist, title: t.title)
        }
    }

    // MARK: table

    @objc func filterChanged() { applyFilter() }

    func applyFilter() {
        let q = search.stringValue.lowercased()
        let ff = folderFilter
        filtered = lib.tracks.filter { t in
            if let ff = ff, t.dirPath != ff && !t.dirPath.hasPrefix(ff + "/") { return false }
            if q.isEmpty { return true }
            return t.title.lowercased().contains(q) || t.artist.lowercased().contains(q)
                || t.album.lowercased().contains(q)
        }
        if let key = sortKey {
            filtered.sort { a, b in
                let va: String, vb: String
                switch key {
                case "artist": va = a.artist; vb = b.artist
                case "album":  va = a.album;  vb = b.album
                case "path":   va = a.fullPath; vb = b.fullPath
                case "plays":  va = String(format: "%09d", a.playcount ?? -1)
                              vb = String(format: "%09d", b.playcount ?? -1)
                case "love":   va = a.loved == true ? "1" : "0"
                              vb = b.loved == true ? "1" : "0"
                default:       va = a.title;  vb = b.title
                }
                let c = va.localizedCaseInsensitiveCompare(vb)
                return sortAsc ? c == .orderedAscending : c == .orderedDescending
            }
        } else {
            // default view: full file path — identical order to the folder tree;
            // inside a folder, natural track-number order
            filtered.sort { a, b in
                let c = a.dirPath.localizedCaseInsensitiveCompare(b.dirPath)
                if c != .orderedSame { return c == .orderedAscending }
                return a.title.localizedStandardCompare(b.title) == .orderedAscending
            }
        }
        rebuildRows()
        if rows.count > 12 {
            var dbg: [String] = []
            var heads: [String] = []
            for r in rows {
                switch r { case .header(let h): heads.append(h)
                           case .track(let i): if dbg.count < 8 { dbg.append("  t:" + filtered[i].title) } } }
            let dup = heads.count - Set(heads).count
            print("order: " + dbg.joined(separator: " | ") + " || headers=\(heads.count) dup=\(dup)")
        }
        print("filter: filtered=\(filtered.count) rows=\(rows.count)")
        table?.reloadData()
    }

    func rebuildRows() {
        rows = []
        if sortKey == nil {
            var lastFolder: String?
            for (i, t) in filtered.enumerated() {
                if t.folder != lastFolder {
                    rows.append(.header(t.folder))
                    lastFolder = t.folder
                }
                rows.append(.track(i))
            }
        } else {
            rows = filtered.indices.map { .track($0) }
        }
    }

    func track(forRow row: Int) -> Track? {
        guard row >= 0, row < rows.count, case .track(let i) = rows[row] else { return nil }
        return filtered[i]
    }

    func filteredIndex(forRow row: Int) -> Int? {
        guard row >= 0, row < rows.count, case .track(let i) = rows[row] else { return nil }
        return i
    }

    func numberOfRows(in tv: NSTableView) -> Int { rows.count }

    // group headers are rendered as plain rows (isGroupRow would add AppKit's
    // section padding and make them look ~2 rows tall)
    func tableView(_ tv: NSTableView, heightOfRow row: Int) -> CGFloat {
        if case .header = rows[row] { return 18 }
        return 20
    }

    func tableView(_ tv: NSTableView, didClick col: NSTableColumn) {
        if sortKey == col.identifier.rawValue {
            if sortAsc { sortAsc = false }
            else { sortKey = nil; sortAsc = true }   // third click: back to folders
        } else {
            sortKey = col.identifier.rawValue
            sortAsc = true
        }
        Config.shared.sortKey = sortKey
        Config.shared.sortAsc = sortAsc
        for c in tv.tableColumns {
            c.sortDescriptorPrototype = NSSortDescriptor(key: c.identifier.rawValue,
                                                         ascending: sortAsc)
        }
        applyFilter()
    }

    func tableView(_ tv: NSTableView, viewFor col: NSTableColumn?, row: Int) -> NSView? {
        if case .header(let folder) = rows[row] {
            guard col?.identifier.rawValue == "title" else { return nil }
            let id = NSUserInterfaceItemIdentifier("grouphdr")
            let tf = (tv.makeView(withIdentifier: id, owner: self) as? NSTextField) ?? {
                let t = NSTextField(labelWithString: "")
                t.identifier = id
                t.font = .systemFont(ofSize: 12, weight: .bold)
                t.textColor = .labelColor
                t.alignment = .center
                t.lineBreakMode = .byTruncatingMiddle
                return t
            }()
            tf.stringValue = folder
            return tf
        }
        guard let fi = filteredIndex(forRow: row), let id = col?.identifier.rawValue else { return nil }
        // hydrate last.fm state from the local cache without a network hit
        if filtered[fi].loved == nil, LastFM.shared.isEnabled, !filtered[fi].artist.isEmpty,
           let c = FmCache.shared.get(artist: filtered[fi].artist, title: filtered[fi].title) {
            filtered[fi].playcount = c.playcount
            filtered[fi].loved = c.loved
        }
        let t = filtered[fi]
        let text: String
        switch id {
        case "love": text = t.loved == true ? "♥" : ""
        case "title": text = t.title
        case "artist": text = t.artist
        case "album": text = t.album
        case "dur": text = t.duration > 0 ? fmt(t.duration) : ""
        case "plays": text = (t.playcount ?? 0) > 0 ? String(t.playcount!) : ""
        case "path": text = t.fullPath
        default: text = ""
        }
        let cellId = NSUserInterfaceItemIdentifier("cell")
        let tf = (tv.makeView(withIdentifier: cellId, owner: self) as? NSTextField) ?? {
            let f = NSTextField(labelWithString: "")
            f.identifier = cellId
            f.lineBreakMode = .byTruncatingTail
            f.font = .systemFont(ofSize: 12)
            return f
        }()
        tf.stringValue = text
        return tf
    }
}

func fmt(_ s: TimeInterval) -> String {
    guard s.isFinite, s >= 0 else { return "0:00" }
    return String(format: "%d:%02d", Int(s) / 60, Int(s) % 60)
}

// MARK: folder tree
@MainActor
extension AppDelegate: NSOutlineViewDataSource, NSOutlineViewDelegate {

    func buildTree() {
        guard outline != nil else { return }
        var roots: [FolderNode] = []
        var rootNodeByDir: [String: FolderNode] = [:]
        var rootPathByDir: [String: String] = [:]
        for dir in Config.shared.libraryDirs {
            let isRemote = dir.hasPrefix("sftp://")
            let rootPath = isRemote ? (parseSftp(dir)?.path ?? dir)
                                    : (dir as NSString).expandingTildeInPath
            let label = (isRemote ? "🌐 " : "📁 ") + (rootPath as NSString).lastPathComponent
            let node = FolderNode(name: label, path: rootPath)
            rootNodeByDir[dir] = node
            rootPathByDir[dir] = rootPath
            roots.append(node)
        }
        for t in lib.tracks {
            for (dir, node) in rootNodeByDir {
                let rootPath = rootPathByDir[dir]!
                guard t.dirPath.hasPrefix(rootPath + "/") else { continue }
                let rel = String(t.dirPath.dropFirst(rootPath.count + 1))
                var cur = node
                var acc = rootPath
                for comp in rel.split(separator: "/") {
                    acc += "/" + comp
                    cur = cur.child(String(comp), acc)
                }
                break
            }
        }
        treeRoots = roots
        outline.reloadData()
        for r in roots { outline.expandItem(r) }
        if !treeQuery.isEmpty { treeFilterChanged() }
    }

    // MARK: tree filter input

    @objc func treeFilterChanged() {
        let q = treeSearch.stringValue.trimmingCharacters(in: .whitespaces).lowercased()
        treeQuery = q
        if q.isEmpty {
            treeDisplayRoots = []
            outline.reloadData()
            for r in treeRoots { outline.expandItem(r) }
            return
        }
        treeDisplayRoots = treeRoots.compactMap { filterTree($0, q) }
        outline.reloadData()
        outline.expandItem(nil, expandChildren: true)
    }

    /// keep node if its name matches (with full subtree) or any descendant matches (with the matching branches)
    func filterTree(_ n: FolderNode, _ q: String) -> FolderNode? {
        if n.name.lowercased().contains(q) {
            let c = FolderNode(name: n.name, path: n.path)
            fillClone(n, into: c)
            return c
        }
        let kept = n.children.compactMap { filterTree($0, q) }
        guard !kept.isEmpty else { return nil }
        let c = FolderNode(name: n.name, path: n.path)
        for k in kept { fillClone(k, into: c.child(k.name, k.path)) }
        return c
    }

    func fillClone(_ from: FolderNode, into to: FolderNode) {
        for ch in from.sortedChildren { fillClone(ch, into: to.child(ch.name, ch.path)) }
    }

    func outlineView(_ ov: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let n = item as? FolderNode else { return displayRoots.count }
        return n.sortedChildren.count
    }
    func outlineView(_ ov: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if let n = item as? FolderNode { return n.sortedChildren[index] }
        return displayRoots[index]
    }
    func outlineView(_ ov: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let n = item as? FolderNode else { return true }
        return !n.children.isEmpty
    }
    func outlineView(_ ov: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let n = item as? FolderNode else { return nil }
        let id = NSUserInterfaceItemIdentifier("tnode")
        let tf = (ov.makeView(withIdentifier: id, owner: self) as? NSTextField) ?? {
            let t = NSTextField(labelWithString: "")
            t.identifier = id
            t.font = .systemFont(ofSize: 12)
            t.lineBreakMode = .byTruncatingMiddle
            return t
        }()
        tf.stringValue = n.name
        return tf
    }
    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard outline != nil, outline.selectedRow >= 0,
              let node = outline.item(atRow: outline.selectedRow) as? FolderNode else { return }
        folderFilter = node.path
        applyFilter()
    }

    @objc func clearFolderFilter() {
        folderFilter = nil
        outline?.deselectAll(nil)
        applyFilter()
    }

    /// expand + select the tree node of the currently playing track
    func locateCurrentFolder() {
        guard let path = currentPlayingPath else { return }
        if !treeQuery.isEmpty {
            treeSearch.stringValue = ""
            treeFilterChanged()
        }
        var chain: [FolderNode] = []
        func walk(_ node: FolderNode, _ acc: [FolderNode]) -> Bool {
            let here = acc + [node]
            if node.path == path { chain = here; return true }
            for c in node.children where walk(c, here) { return true }
            return false
        }
        for r in treeRoots where walk(r, []) { break }
        guard !chain.isEmpty else { return }
        for n in chain.dropLast() { outline.expandItem(n) }
        if let last = chain.last {
            let row = outline.row(forItem: last)
            if row >= 0 {
                outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                outline.scrollRowToVisible(row)
            }
        }
    }
}

setbuf(stdout, nil)
let app = NSApplication.shared
MainActor.assumeIsolated {
    let delegate = AppDelegate()   // strong ref: NSApp.delegate is weak
    app.delegate = delegate
    app.run()
}