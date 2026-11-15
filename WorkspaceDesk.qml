import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Hyprland
import qs.Commons
import "Colors.js" as Colors
import "Storage.js" as Storage

// A live kanban board laid exactly over the three painted columns of the
// BoardHydra "2-board" wallpaper. It sits on the Bottom layer: above the
// wallpaper, below every window.
//
// Two modes:
//  - synced: ~/.config/boardhydra-desk/config.json names an API key and a
//    board; the columns are that board's lists, read and written through the
//    BoardHydra /api/v1 developer API.
//  - local: each workspace has its own private card file.
Item {
  id: root

  property var shell: null
  property var manifest: null
  required property var workspace
  readonly property int workspaceId: workspace.id
  readonly property var workspaceScreens: Quickshell.screens.filter(function(screen) {
    var monitor = Hyprland.monitorFor(screen)
    return monitor && monitor.activeWorkspace && monitor.activeWorkspace.id === root.workspaceId
  })
  onWorkspaceScreensChanged: {
    quickOpen = false
    switcherOpen = false
    listMenuCol = -1
    openCardId = ""
  }

  readonly property string home: Quickshell.env("HOME")
  // Local-mode cards live in a private (0700) folder; the old 0644 file is moved in.
  readonly property string dataDir: home + "/.local/share/boardhydra-desk"
  readonly property string oldDataPath: home + "/.local/share/boardhydra-desk.json"
  property bool dirsReady: false
  readonly property string dataPath: dirsReady ? dataDir + "/workspace-" + workspaceId + ".json" : ""
  readonly property string configPath: home + "/.config/boardhydra-desk/config.json"

  // Brand palette (BoardHydra web tokens + a ramp across the logo's heads, one per slot).
  readonly property var heads: ["#2785c2", "#349aa5", "#41aa90", "#4db381"]
  readonly property color textColor: "#ece6f7"
  readonly property color mutedColor: "#9a91b3"
  readonly property color faintColor: "#6c6487"
  readonly property color cardColor: "#221d33"
  readonly property color cardHover: "#2a2440"
  readonly property color cardBorder: "#2d2742"
  readonly property color badColor: "#ff5d6c"

  // Column geometry in 3840x2160 wallpaper pixels. Four slots span the
  // three columns painted on the wallpaper; the desk paints the wallpaper's
  // own gradient behind them (see `backdrop`) so the painted ones never show.
  readonly property real wpW: 3840
  readonly property real wpH: 2160
  readonly property int slots: 4
  readonly property real colX: 160
  readonly property real colY: 379
  readonly property real colW: 820
  readonly property real colH: 1424
  readonly property real colStride: 900
  // Wallpaper background: a straight vertical gradient, top to bottom.
  readonly property color wpTop: "#15121f"
  readonly property color wpBottom: "#0d0b14"

  // "gaps": a column stays in its slot and empty slots stay empty.
  // "center": the shown columns close up and sit in the middle.
  property string layout: "gaps"

  function shownCols() {
    var out = []
    for (var i = 0; i < board.columns.length; i++)
      if (!synced || board.columns[i].listId) out.push(i)
    return out
  }
  // Left edge of column i, in strides from the first slot.
  function colPos(i) {
    if (synced && layout !== "center") return i
    var vis = shownCols()
    var k = vis.indexOf(i)
    return (slots - vis.length) / 2 + Math.max(0, k)
  }

  property bool onBoardWallpaper: false
  property bool loaded: false
  property var board: ({ columns: [] })

  // ---------------------------------------------------------------- config
  property var cfg: null              // validated config, or null for local mode
  property bool configChecked: false
  readonly property bool synced: cfg !== null

  // Sync status
  property string syncState: "idle"   // idle | syncing | ok | error
  property string syncError: ""
  property real lastSync: 0
  property real lastFetchStart: 0
  property int writesInFlight: 0
  property bool refetchAfterWrites: false
  property var pending: []            // in-flight XHRs for the timeout watchdog
  property real now: Date.now()

  function validConfig(c) {
    if (!c || typeof c !== "object") return null
    var url = String(c.apiUrl || "https://boardhydra.com").replace(/\/+$/, "")
    if (!/^https:\/\/[A-Za-z0-9.-]+(:\d+)?$/.test(url) && !/^http:\/\/(localhost|127\.0\.0\.1)(:\d+)?$/.test(url)) {
      console.warn("boardhydra.desk: apiUrl must be https://host"); return null
    }
    var key = String(c.apiKey || "")
    if (!/^bh_live_[A-Za-z0-9_-]{8,200}$/.test(key)) { console.warn("boardhydra.desk: missing or malformed apiKey"); return null }
    var boardId = String(c.boardId || "")
    if (!/^[A-Za-z0-9_-]{1,64}$/.test(boardId)) { console.warn("boardhydra.desk: missing boardId"); return null }
    var lists = Array.isArray(c.lists) ? c.lists.slice(0, 4).map(function(n) { return String(n).slice(0, 100) }) : []
    var mins = Number(c.refreshMinutes)
    if (!(mins >= 2 && mins <= 1440)) mins = 10
    return { apiUrl: url, apiKey: key, boardId: boardId, lists: lists, refreshMinutes: mins, live: c.live !== false }
  }

  FileView {
    id: configFile
    path: root.configPath
    watchChanges: true
    onLoaded: {
      var c = null
      try { c = root.validConfig(JSON.parse(text())) } catch (e) { console.warn("boardhydra.desk: config is not valid JSON") }
      root.baseCfg = c
      root.baseLoaded = true
      root.applyCfg()
    }
    onLoadFailed: function(error) {
      root.baseCfg = null
      root.baseLoaded = true
      root.applyCfg()
    }
    onFileChanged: reload()
  }

  // The board picked from the desktop's own switcher. Kept apart from
  // config.json so the file holding the API key is never rewritten.
  readonly property string statePath: dirsReady ? home + "/.config/boardhydra-desk/workspace-" + workspaceId + ".json" : ""
  property var baseCfg: null
  property bool baseLoaded: false
  property bool stateLoaded: false
  property string pickedBoard: ""
  property var pickedLists: ({})      // board id -> [list id or "", one per slot]

  function validPicks(obj) {
    var out = ({})
    if (!obj || typeof obj !== "object") return out
    var keys = Object.keys(obj).slice(0, 100)
    var idRe = /^[A-Za-z0-9_-]{1,64}$/
    for (var i = 0; i < keys.length; i++) {
      var v = obj[keys[i]]
      if (!idRe.test(keys[i]) || !Array.isArray(v)) continue
      out[keys[i]] = v.slice(0, 4).map(function(x) { return idRe.test(String(x)) ? String(x) : "" })
    }
    return out
  }

  function saveState() {
    stateFile.setText(JSON.stringify({ boardId: pickedBoard, lists: pickedLists, layout: layout }, null, 2) + "\n")
  }

  // ------------------------------------------------------------- list picker
  property var allLists: []           // every open list on the board: [{ id, name }]
  property string listsFor: ""        // board id allLists was read from
  readonly property string curBoardId: cfg ? String(cfg.boardId || "") : ""
  property int listMenuCol: -1

  // Show listId in slot col; "" leaves the slot empty.
  function pickList(col, listId) {
    listMenuCol = -1
    if (!synced || col < 0 || col >= slots) return
    var cur = []
    for (var c = 0; c < slots; c++) cur.push(board.columns[c] ? (board.columns[c].listId || "") : "")
    if (cur[col] === listId) return
    var other = listId ? cur.indexOf(listId) : -1
    if (other !== -1) cur[other] = cur[col]     // already on the desktop: swap the two columns
    cur[col] = listId
    var next = JSON.parse(JSON.stringify(pickedLists))
    next[cfg.boardId] = cur
    pickedLists = next
    saveState()
    openCardId = ""
    lastArchived = null
    fetchBoard(true)
  }

  FileView {
    id: stateFile
    path: root.statePath
    watchChanges: true
    atomicWrites: true
    onLoaded: {
      var id = ""
      var picks = ({})
      try {
        var st = JSON.parse(text())
        id = String(st.boardId || "")
        picks = root.validPicks(st.lists)
      } catch (e) {}
      var picksChanged = JSON.stringify(picks) !== JSON.stringify(root.pickedLists)
      root.pickedLists = picks
      try { root.layout = JSON.parse(text()).layout === "center" ? "center" : "gaps" } catch (e2) {}
      root.pickedBoard = /^[A-Za-z0-9_-]{1,64}$/.test(id) ? id : ""
      var first = !root.stateLoaded
      root.stateLoaded = true
      var before = JSON.stringify(root.cfg)
      root.applyCfg()
      // Same board, different columns (state.json edited by hand): redraw.
      if (!first && picksChanged && root.synced && JSON.stringify(root.cfg) === before) root.fetchBoard(true)
    }
    onLoadFailed: function(error) {
      root.pickedBoard = ""
      root.stateLoaded = true
      root.applyCfg()
    }
    onFileChanged: reload()
  }

  function applyCfg() {
    if (!baseLoaded || !stateLoaded) return
    var c = null
    if (baseCfg) {
      c = JSON.parse(JSON.stringify(baseCfg))
      if (pickedBoard && pickedBoard !== c.boardId) {
        c.boardId = pickedBoard
        c.lists = []          // the list names in config.json belong to its own board
      }
    }
    var changed = JSON.stringify(c) !== JSON.stringify(cfg) || !configChecked
    cfg = c
    configChecked = true
    if (changed) modeChanged()
  }

  // ----------------------------------------------------------- board switcher
  property string boardName: ""
  property var boardList: []          // [{ id, name, team, cards }]
  property string boardListState: "idle"   // idle | loading | ok | error
  property string boardListError: ""
  property real boardListAt: 0
  property bool switcherOpen: false

  function openSwitcher() {
    switcherOpen = !switcherOpen
    if (!switcherOpen || !synced) return
    if (boardListState === "loading" || (boardListState === "ok" && Date.now() - boardListAt < 120000)) return
    boardListState = "loading"
    api("GET", "/api/v1/boards", null, function(ok, data, err) {
      if (!ok || !Array.isArray(data)) { root.boardListState = "error"; root.boardListError = err || "bad response from server"; return }
      var out = []
      for (var i = 0; i < data.length && out.length < 100; i++) {
        var b = data[i]
        if (!b || typeof b.id !== "string" || !/^[A-Za-z0-9_-]{1,64}$/.test(b.id)) continue
        out.push({ id: b.id, name: String(b.name || "Untitled").slice(0, 80), team: String(b.teamName || "").slice(0, 40), cards: Number(b.cardCount) || 0 })
      }
      root.boardList = out
      root.boardListState = "ok"
      root.boardListAt = Date.now()
    })
  }

  // Leaves the panel open so the new board's lists can be picked straight away.
  function switchBoard(id) {
    if (!synced || id === cfg.boardId) return
    openCardId = ""
    lastArchived = null
    for (var i = 0; i < boardList.length; i++) if (boardList[i].id === id) boardName = boardList[i].name
    pickedBoard = id
    listMenuCol = -1
    saveState()
    applyCfg()
  }

  function setLayout(mode) {
    if (mode === layout) return
    layout = mode
    saveState()
  }

  function openFullSite() {
    if (synced) Quickshell.execDetached(["xdg-open", cfg.apiUrl + "/app"])
  }

  function modeChanged() {
    if (synced) {
      board = { columns: [] }
      loaded = false
      lastSync = 0
      fetchBoard(true)
    } else {
      syncState = "idle"
      loaded = false
      localStore.reload()
    }
  }

  // ------------------------------------------------------------ local mode
  function uid() { return Date.now().toString(36) + Math.random().toString(36).slice(2, 7) }

  function defaultBoard() {
    return { columns: [
      { title: "To do", cards: [
        { id: uid(), text: "Drag me over to Doing" },
        { id: uid(), text: "Double-click a card to edit it" },
        { id: uid(), text: "Hover a card and hit × to delete it" }
      ] },
      { title: "Doing", cards: [ { id: uid(), text: "Ship the BoardHydra desktop board" } ] },
      { title: "Done", cards: [ { id: uid(), text: "Theme the desktop after BoardHydra" } ] }
    ] }
  }

  function sanitizeLocal(obj) {
    var out = { columns: [] }
    var titles = ["To do", "Doing", "Done"]
    var cols = obj && Array.isArray(obj.columns) ? obj.columns : []
    for (var c = 0; c < 3; c++) {
      var src = cols[c] || {}
      var title = typeof src.title === "string" && src.title.length ? src.title.slice(0, 40) : titles[c]
      var cards = []
      var list = Array.isArray(src.cards) ? src.cards : []
      for (var i = 0; i < list.length && cards.length < 200; i++) {
        var t = list[i] && typeof list[i].text === "string" ? list[i].text.slice(0, 500) : ""
        if (t.trim().length) cards.push({ id: String(list[i].id || uid()).slice(0, 40), text: t })
      }
      out.columns.push({ title: title, cards: cards })
    }
    return out
  }

  // Make the private folders before anything is written into them.
  Process {
    running: true
    command: ["sh", "-c",
      Storage.prepare +
      'if [ -f "$3" ] && [ ! -e "$1/board.json" ]; then mv -n "$3" "$1/board.json"; fi; ' +
      'if [ -f "$4/state.json" ] && [ ! -e "$4/workspace-$5.json" ]; then cp -n "$4/state.json" "$4/workspace-$5.json"; fi; ' +
      'if [ "$5" = 1 ] && [ -f "$1/board.json" ] && [ ! -e "$1/workspace-1.json" ]; then cp -n "$1/board.json" "$1/workspace-1.json"; fi; exit 0',
      "sh", root.dataDir, root.cacheDir, root.oldDataPath, root.home + "/.config/boardhydra-desk", String(root.workspaceId)]
    onExited: function(code, status) {
      if (code !== 0) console.warn("boardhydra.desk: unsafe storage path or private folder initialization failed")
      if (code === 0) root.dirsReady = true
    }
  }

  FileView {
    id: localStore
    path: root.dataPath
    watchChanges: true
    atomicWrites: true
    onLoaded: {
      if (!root.configChecked || root.synced) return
      try { root.board = root.sanitizeLocal(JSON.parse(text())) }
      catch (e) { console.warn("boardhydra.desk: bad board file, keeping current board") }
      root.loaded = true
    }
    onLoadFailed: function(error) {
      if (!root.configChecked || root.synced || root.loaded) return
      root.loaded = true
      root.commitLocal(root.defaultBoard())
    }
    onFileChanged: reload()
  }

  function commitLocal(next) {
    board = next
    localStore.setText(JSON.stringify(next, null, 2) + "\n")
  }

  function cloneBoard() { return JSON.parse(JSON.stringify(board)) }

  // ----------------------------------------------------------- synced mode
  function api(method, path, body, cb) {
    var xhr = new XMLHttpRequest()
    var entry = { xhr: xhr, t: Date.now(), cb: cb, done: false }
    xhr.onreadystatechange = function() {
      if (xhr.readyState !== XMLHttpRequest.DONE || entry.done) return
      entry.done = true
      root.pending = root.pending.filter(function(p) { return p !== entry })
      var text = xhr.responseText || ""
      var data = null
      var err = ""
      if (text.length > 10 * 1024 * 1024) err = "response too large"
      else { try { data = text.length ? JSON.parse(text) : null } catch (e) { err = "bad response from server" } }
      var ok = xhr.status >= 200 && xhr.status < 300 && !err
      if (!ok && !err) {
        err = data && typeof data.error === "string" ? data.error.slice(0, 200)
          : (xhr.status === 0 ? "can't reach " + root.cfg.apiUrl.replace(/^https?:\/\//, "") : "HTTP " + xhr.status)
      }
      cb(ok, data, err, xhr.status)
    }
    xhr.open(method, cfg.apiUrl + path)
    xhr.setRequestHeader("Authorization", "Bearer " + cfg.apiKey)
    xhr.setRequestHeader("Accept", "application/json")
    xhr.setRequestHeader("X-Client-Id", clientId)
    if (body !== undefined && body !== null) xhr.setRequestHeader("Content-Type", "application/json")
    pending = pending.concat([entry])
    xhr.send(body !== undefined && body !== null ? JSON.stringify(body) : undefined)
  }

  // Abort requests that hang; also ticks the "synced Xm ago" label.
  Timer {
    interval: 1000; repeat: true; running: root.pending.length > 0 || root.synced
    onTriggered: {
      root.now = Date.now()
      var stale = root.pending.filter(function(p) { return root.now - p.t > 15000 && !p.done })
      for (var i = 0; i < stale.length; i++) {
        var p = stale[i]
        p.done = true
        try { p.xhr.abort() } catch (e) {}
        root.pending = root.pending.filter(function(q) { return q !== p })
        p.cb(false, null, "request timed out", 0)
      }
    }
  }

  readonly property string clientId: "desk-" + uid() + uid()

  property bool fetching: false

  function setError(msg) {
    syncState = "error"
    syncError = msg
  }

  function fetchBoard(force) {
    if (!synced) return
    if (!force && (live || Date.now() - lastFetchStart < 60000)) return   // hover: never while live, else once a minute
    if (writesInFlight > 0) { refetchAfterWrites = true; return }
    if (fetching) return
    fetching = true
    lastFetchStart = Date.now()
    syncState = "syncing"
    var forBoard = cfg.boardId
    api("GET", "/api/v1/boards/" + encodeURIComponent(cfg.boardId), null, function(ok, data, err) {
      root.fetching = false
      if (!root.synced) return
      if (root.cfg.boardId !== forBoard) { root.fetchBoard(true); return }
      if (!ok) { root.setError(err); return }
      // Writes started while this was in flight would be undone by it.
      if (root.writesInFlight > 0) { root.refetchAfterWrites = true; return }
      root.board = root.boardFromSnapshot(data)
      root.loaded = true
      root.syncState = "ok"
      root.syncError = ""
      root.lastSync = Date.now()
    })
  }

  property var labelMap: ({})
  property var memberMap: ({})
  property var attCounts: ({})

  function initialsOf(m) {
    var ini = String(m.initials || "").trim()
    if (!ini) {
      var parts = String(m.fullName || m.username || "?").trim().split(/\s+/)
      ini = (parts[0] ? parts[0][0] : "?") + (parts.length > 1 ? parts[parts.length - 1][0] : "")
    }
    return ini.slice(0, 2).toUpperCase()
  }

  // Card id -> { desc, checklists, members } for the detail panel.
  property var detailMap: ({})
  property int detailRev: 0
  property var memberNames: ({})

  // Checklists flattened to rows the panel can draw: bounded, plain strings.
  function checklistRows(lists) {
    var out = []
    var budget = 300
    for (var c = 0; c < lists.length && c < 50 && budget > 0; c++) {
      var cl = lists[c]
      if (!cl) continue
      var rows = []
      var items = []
      var rawItems = Array.isArray(cl.checkItems) ? cl.checkItems : []
      for (var r = 0; r < rawItems.length; r++) if (rawItems[r]) items.push({ it: rawItems[r], at: r })
      items.sort(function(a, b) { return (a.it.pos || 0) - (b.it.pos || 0) })
      for (var i = 0; i < items.length && budget > 0; i++) {
        var it = items[i].it
        rows.push({ name: String(it.name || "").slice(0, 500), done: it.state === "complete", sub: false, ci: c, ii: items[i].at, ki: -1 }); budget--
        var kids = Array.isArray(it.children) ? it.children : []
        for (var j = 0; j < kids.length && budget > 0; j++)
          if (kids[j]) { rows.push({ name: String(kids[j].name || "").slice(0, 500), done: kids[j].state === "complete", sub: true, ci: c, ii: items[i].at, ki: j }); budget-- }
      }
      out.push({ name: String(cl.name || "Checklist").slice(0, 100), rows: rows })
    }
    return out
  }

  // ------------------------------------------------------------ card detail
  property string openCardId: ""

  // ------------------------------------------------------- checklist edits
  // The server replaces a card's checklists as a whole, so every edit sends
  // the full original back with one change. Rules mirror the web app's
  // CardModal: ticking a parent ticks its sub-items, and a parent with
  // sub-items is done when they all are.
  function hexId() {
    var out = ""
    for (var i = 0; i < 24; i++) out += Math.floor(Math.random() * 16).toString(16)
    return out
  }

  function nextPos(items) {
    var m = 0
    for (var i = 0; i < items.length; i++) if (items[i] && Number(items[i].pos) > m) m = Number(items[i].pos)
    return m + 1024
  }

  function mutateChecks(id, fn) {
    var hit = findCard(id)
    var more = detailMap[id]
    if (!hit || !more || !synced || String(id).indexOf("tmp-") === 0) return
    var raw = JSON.parse(JSON.stringify(Array.isArray(more.raw) ? more.raw : []))
    if (fn(raw) === false) return
    if (JSON.stringify(raw).length > 60000) { setError("checklist is too large to edit here"); return }
    // A fresh object, so the open panel sees the change.
    detailMap[id] = { desc: more.desc, members: more.members, memberIds: more.memberIds, labelIds: more.labelIds, raw: raw, checklists: checklistRows(raw) }
    detailRev += 1
    var acc = { done: 0, total: 0 }
    for (var c = 0; c < raw.length && c < 50; c++) if (raw[c]) countChecks(raw[c].checkItems, acc)
    var b = cloneBoard()
    b.columns[hit.col].cards[hit.idx].checkDone = acc.done
    b.columns[hit.col].cards[hit.idx].checkTotal = acc.total
    board = b
    write("PATCH", "/api/v1/cards/" + encodeURIComponent(id), { checklists: raw })
  }

  function checkItemAt(raw, ci, ii) {
    return raw[ci] && Array.isArray(raw[ci].checkItems) ? (raw[ci].checkItems[ii] || null) : null
  }

  function toggleCheck(id, ci, ii, ki) {
    mutateChecks(id, function(raw) {
      var item = checkItemAt(raw, ci, ii)
      if (!item) return false
      var kids = Array.isArray(item.children) ? item.children : []
      if (ki < 0) {
        item.state = item.state === "complete" ? "incomplete" : "complete"
        for (var k = 0; k < kids.length; k++) if (kids[k]) kids[k].state = item.state
      } else {
        if (!kids[ki]) return false
        kids[ki].state = kids[ki].state === "complete" ? "incomplete" : "complete"
        item.state = kids.length && kids.every(function(x) { return x && x.state === "complete" }) ? "complete" : "incomplete"
      }
    })
  }

  // ci < 0: the card has no checklist yet, so make one (named like the web app's).
  function addCheck(id, ci, text) {
    text = String(text || "").trim().slice(0, 500)
    if (!text) return
    mutateChecks(id, function(raw) {
      if (ci < 0 || !raw[ci]) {
        if (raw.length === 0) raw.push({ id: hexId(), idCard: id, name: "Checklist", checkItems: [] })
        ci = 0
      }
      if (!Array.isArray(raw[ci].checkItems)) raw[ci].checkItems = []
      raw[ci].checkItems.push({ id: hexId(), name: text, state: "incomplete", pos: nextPos(raw[ci].checkItems) })
    })
  }

  function addSubCheck(id, ci, ii, text) {
    text = String(text || "").trim().slice(0, 500)
    if (!text) return
    mutateChecks(id, function(raw) {
      var item = checkItemAt(raw, ci, ii)
      if (!item) return false
      if (!Array.isArray(item.children)) item.children = []
      item.children.push({ id: hexId(), name: text, state: "incomplete", pos: nextPos(item.children) })
      item.state = "incomplete"     // a new open sub-item means the parent isn't finished
    })
  }

  function renameCheck(id, ci, ii, ki, text) {
    text = String(text || "").trim().slice(0, 500)
    if (!text) return
    mutateChecks(id, function(raw) {
      var item = checkItemAt(raw, ci, ii)
      if (item && ki >= 0) item = Array.isArray(item.children) ? item.children[ki] : null
      if (!item || item.name === text) return false
      item.name = text
    })
  }

  function removeCheck(id, ci, ii, ki) {
    mutateChecks(id, function(raw) {
      var item = checkItemAt(raw, ci, ii)
      if (!item) return false
      if (ki < 0) raw[ci].checkItems.splice(ii, 1)
      else if (Array.isArray(item.children) && item.children[ki]) item.children.splice(ki, 1)
      else return false
    })
  }

  // ------------------------------------------------------------ attachments
  // attCounts: card id -> { attachment id -> { id, archived, name, kind, bytes, at } }
  // Board reads and the stream include archived attachments (archivedAt set).
  property int attRev: 0
  property string attNote: ""         // last upload/download result, shown in the panel
  property bool attNoteBad: false
  property int uploadsLeft: 0
  property var thumbState: ({})       // attachment id -> 1 downloading | 2 ready | 3 failed
  readonly property string cacheDir: (Quickshell.env("XDG_CACHE_HOME") || (home + "/.cache")) + "/boardhydra-desk"
  readonly property string saveDir: home + "/Downloads/BoardHydra"
  readonly property var idRe: /^[A-Za-z0-9_-]{1,64}$/

  function attInfo(at) {
    if (!at || typeof at.id !== "string" || typeof at.idCard !== "string" || !idRe.test(at.id)) return null
    return { id: at.id, archived: !!at.archivedAt, name: String(at.name || "file").slice(0, 200), kind: at.kind === "file" ? "file" : "image",
             bytes: Number(at.bytes) || 0, at: typeof at.createdAt === "string" ? at.createdAt.slice(0, 40) : "" }
  }

  function setAttachment(cardId, attId, info) {
    var ac = attCounts
    if (!ac[cardId]) ac[cardId] = ({})
    if (info) ac[cardId][attId] = info; else delete ac[cardId][attId]
    attRev += 1
    var n = activeAtts(cardId)
    var hit = findCard(cardId)
    if (!hit || hit.card.att === n) return
    var b = cloneBoard()
    b.columns[hit.col].cards[hit.idx].att = n
    board = b
  }

  // The paperclip count on a card: what is attached now, not what is archived.
  function activeAtts(cardId) {
    var m = attCounts[cardId] || ({})
    var n = 0
    for (var k in m) if (!m[k].archived) n++
    return n
  }

  function attList(cardId, archived) {
    var m = attCounts[cardId] || ({})
    var out = []
    for (var k in m) if (!!m[k].archived === !!archived) out.push(m[k])
    out.sort(function(a, b) { return a.at < b.at ? -1 : (a.at > b.at ? 1 : 0) })
    return out.slice(0, 100)
  }

  function sizeText(bytes) {
    if (bytes >= 1048576) return I18n.formatNumber(bytes / 1048576, 1) + " MB"
    if (bytes >= 1024) return Math.round(bytes / 1024) + " KB"
    return bytes + " B"
  }

  function safeName(name) {
    var n = String(name || "").replace(/[\/\\\x00-\x1f\x7f]/g, "_").replace(/^\.+/, "_").slice(0, 120)
    return n.length ? n : "file"
  }

  function note(text, bad) { attNote = text; attNoteBad = !!bad; attNoteTimer.restart() }
  Timer { id: attNoteTimer; interval: 8000; onTriggered: root.attNote = "" }

  // One curl at a time for thumbnails, downloads and uploads.
  property var xferQueue: []
  property var xferJob: null
  property var xferCode: null
  property var xferText: null

  function xferPush(job) { xferQueue = xferQueue.concat([job]); xferNext() }
  function xferNext() {
    if (xferJob || !xferQueue.length) return
    if (!synced) { xferQueue = []; return }
    xferJob = xferQueue[0]
    xferQueue = xferQueue.slice(1)
    xferCode = null; xferText = null
    xfer.command = xferJob.command
    xfer.running = true
  }
  function xferFinish() {
    if (xferCode === null || xferText === null || !xferJob) return
    var job = xferJob
    xferJob = null
    try { job.done(xferCode, xferText) } catch (e) { console.warn("boardhydra.desk transfer:", e) }
    xferNext()
  }
  Process {
    id: xfer
    stdinEnabled: true
    onStarted: {
      write("Authorization: Bearer " + root.cfg.apiKey + "\nX-Client-Id: " + root.clientId + "\n")
      stdinEnabled = false
    }
    stdout: StdioCollector { onStreamFinished: { root.xferText = String(text).slice(0, 200000); root.xferFinish() } }
    onExited: function(code, status) { stdinEnabled = true; root.xferCode = code; root.xferFinish() }
  }

  function attUrl(attId, what) { return cfg.apiUrl + "/api/v1/attachments/" + encodeURIComponent(attId) + "/" + what }
  function thumbPath(attId) { return cacheDir + "/thumbs/" + attId + ".jpg" }
  function setThumb(attId, st) {
    var t = JSON.parse(JSON.stringify(thumbState))
    t[attId] = st
    thumbState = t
  }

  function wantThumb(attId) {
    if (!synced || !idRe.test(attId) || thumbState[attId]) return
    setThumb(attId, 1)
    xferPush({ command: ["curl", "-sS", "-f", "--max-time", "30", "--max-filesize", "5242880", "-H", "@-", "--create-dirs", "-o", thumbPath(attId), "--", attUrl(attId, "thumb")],
               done: function(code) { root.setThumb(attId, code === 0 ? 2 : 3) } })
  }

  // Images open in the viewer. Anything else is only saved: board members can
  // upload any file type, so nothing but an image is opened automatically.
  function openAttachment(att) {
    if (!synced || !att || !idRe.test(att.id)) return
    var image = att.kind === "image"
    var dest
    if (image) {
      var ext = (/\.(png|jpe?g|gif|webp)$/i.exec(att.name) || [".jpg"])[0].toLowerCase()
      dest = cacheDir + "/full/" + att.id + ext
    } else {
      dest = saveDir + "/" + att.id.slice(0, 6) + "-" + safeName(att.name)
    }
    note(image ? "Opening " + att.name + "…" : "Downloading " + att.name + "…", false)
    xferPush({ command: ["curl", "-sS", "-f", "--max-time", "300", "--max-filesize", "524288000", "-H", "@-", "--create-dirs", "-o", dest, "--", attUrl(att.id, image ? "full" : "download")],
               done: function(code) {
                 if (code !== 0) { root.note("Couldn't download " + att.name, true); return }
                 if (image) { root.note("", false); Quickshell.execDetached(["xdg-open", dest]) }
                 else { root.note("Saved to Downloads/BoardHydra", false); Quickshell.execDetached(["xdg-open", root.saveDir]) }
               } })
  }

  function uploadFile(cardId, path) {
    path = String(path || "")
    if (!synced || !idRe.test(cardId) || path.charAt(0) !== "/" || path.length > 4000 || /[\x00-\x1f]/.test(path)) return
    uploadsLeft += 1
    // curl reads the name inside quotes literally, apart from \\ and \".
    var field = 'file=@"' + path.replace(/\\/g, "\\\\").replace(/"/g, '\\"') + '"'
    xferPush({ command: ["curl", "-sS", "--max-time", "900", "-H", "@-", "-F", field, "-w", "\n%{http_code}", "--",
                         cfg.apiUrl + "/api/v1/cards/" + encodeURIComponent(cardId) + "/attachments"],
               done: function(code, out) {
                 root.uploadsLeft = Math.max(0, root.uploadsLeft - 1)
                 var cut = out.lastIndexOf("\n")
                 var status = Number(cut >= 0 ? out.slice(cut + 1) : 0)
                 var data = null
                 try { data = JSON.parse(cut >= 0 ? out.slice(0, cut) : out) } catch (e) {}
                 var name = path.slice(path.lastIndexOf("/") + 1)
                 if (code !== 0 || status < 200 || status >= 300) {
                   root.note(data && typeof data.error === "string" ? data.error.slice(0, 200) : "Couldn't upload " + name, true)
                   return
                 }
                 var info = root.attInfo(data)
                 if (info) root.setAttachment(cardId, info.id, info)
                 root.note("Added " + name, false)
               } })
  }

  // Archive or restore. The server answers with the attachment as it now is.
  function archiveAttachment(cardId, attId, archive) {
    var cur = (attCounts[cardId] || ({}))[attId]
    if (!synced || !cur || !idRe.test(attId)) return
    var next = JSON.parse(JSON.stringify(cur))
    next.archived = archive
    setAttachment(cardId, attId, next)
    write("POST", "/api/v1/attachments/" + encodeURIComponent(attId) + (archive ? "/archive" : "/restore"), ({}), function(data) {
      var info = root.attInfo(data)
      if (info) root.setAttachment(cardId, attId, info)
    })
  }

  // GET /api/v1/cards/{id}/attachments: this card's attachments, archived
  // ones included. Run when a card is opened so its list is exact.
  function refreshAttachments(cardId) {
    if (!synced || !idRe.test(cardId) || String(cardId).indexOf("tmp-") === 0) return
    api("GET", "/api/v1/cards/" + encodeURIComponent(cardId) + "/attachments", null, function(ok, data) {
      if (!ok || !Array.isArray(data) || root.writesInFlight > 0) return
      var m = ({})
      for (var i = 0; i < data.length && i < 500; i++) {
        var info = root.attInfo(data[i])
        if (info && data[i].idCard === cardId) m[info.id] = info
      }
      root.attCounts[cardId] = m
      root.attRev += 1
      var n = root.activeAtts(cardId)
      var hit = root.findCard(cardId)
      if (!hit || hit.card.att === n) return
      var b = root.cloneBoard()
      b.columns[hit.col].cards[hit.idx].att = n
      root.board = b
    })
  }

  function deleteAttachment(cardId, attId) {
    if (!synced || !idRe.test(attId)) return
    setAttachment(cardId, attId, null)
    write("DELETE", "/api/v1/attachments/" + encodeURIComponent(attId), null)
  }

  // The desktop file chooser (Omarchy's portal picker); one path per line.
  property string pickFor: ""
  function pickFiles(cardId) {
    if (filePicker.running || !synced) return
    pickFor = cardId
    filePicker.running = true
  }
  Process {
    id: filePicker
    command: ["omarchy-file-select", "--title", "Add to card", "--multiple"]
    stdout: StdioCollector {
      onStreamFinished: {
        var lines = String(text).split("\n").map(function(l) { return l.replace(/\r$/, "") }).filter(function(l) { return l.length })
        for (var i = 0; i < lines.length && i < 10; i++) root.uploadFile(root.pickFor, lines[i])
      }
    }
  }

  property var boardLabels: []        // every label on the board: [{ id, c, n, pos }]

  // Put a label on the card or take it off, like the web app's label list.
  function toggleLabel(id, labelId) {
    var hit = findCard(id)
    var more = detailMap[id]
    if (!hit || !more || !synced || !labelMap[labelId] || String(id).indexOf("tmp-") === 0) return
    var ids = (more.labelIds || []).slice()
    var at = ids.indexOf(labelId)
    if (at === -1) ids.push(labelId); else ids.splice(at, 1)
    var shown = []
    for (var i = 0; i < ids.length; i++) if (labelMap[ids[i]]) shown.push(labelMap[ids[i]])
    shown.sort(function(a, b) { return a.pos - b.pos })
    detailMap[id] = { desc: more.desc, members: more.members, memberIds: more.memberIds, labelIds: ids, raw: more.raw, checklists: more.checklists }
    detailRev += 1
    var b = cloneBoard()
    b.columns[hit.col].cards[hit.idx].labels = shown.slice(0, 8)
    board = b
    write("PATCH", "/api/v1/cards/" + encodeURIComponent(id), { idLabels: ids })
  }

  property var boardMembers: []       // everyone on the board: [{ id, ini, name }]

  // Assign or unassign one board member, like the web app's member list.
  function toggleMember(id, memberId) {
    var hit = findCard(id)
    var more = detailMap[id]
    if (!hit || !more || !synced || !memberNames[memberId] || String(id).indexOf("tmp-") === 0) return
    var ids = (more.memberIds || []).slice()
    var at = ids.indexOf(memberId)
    if (at === -1) ids.push(memberId); else ids.splice(at, 1)
    var shown = [], initials = []
    for (var i = 0; i < ids.length; i++) {
      if (!memberNames[ids[i]]) continue
      if (shown.length < 30) shown.push(memberNames[ids[i]])
      if (initials.length < 3) initials.push(memberNames[ids[i]].ini)
    }
    detailMap[id] = { desc: more.desc, members: shown, memberIds: ids, labelIds: more.labelIds, raw: more.raw, checklists: more.checklists }
    detailRev += 1
    var b = cloneBoard()
    b.columns[hit.col].cards[hit.idx].members = initials
    b.columns[hit.col].cards[hit.idx].extraMembers = Math.max(0, ids.length - initials.length)
    board = b
    write("PATCH", "/api/v1/cards/" + encodeURIComponent(id), { idMembers: ids })
  }

  function saveDesc(id, text) {
    var hit = findCard(id)
    if (!hit || !synced || String(id).indexOf("tmp-") === 0) return
    text = String(text || "").replace(/\s+$/, "").slice(0, 20000)   // the server keeps 20,000 characters
    var more = detailMap[id] || { desc: "", checklists: [], members: [] }
    if (text === more.desc) return
    detailMap[id] = { desc: text, members: more.members, memberIds: more.memberIds, labelIds: more.labelIds, raw: more.raw, checklists: more.checklists }
    detailRev += 1
    var b = cloneBoard()
    b.columns[hit.col].cards[hit.idx].hasDesc = text.trim().length > 0
    board = b
    write("PATCH", "/api/v1/cards/" + encodeURIComponent(id), { desc: text })
  }

  function findCard(id) {
    if (!id) return null
    for (var c = 0; c < board.columns.length; c++)
      for (var i = 0; i < board.columns[c].cards.length; i++)
        if (board.columns[c].cards[i].id === id) return { card: board.columns[c].cards[i], col: c, idx: i }
    return null
  }

  function countChecks(items, acc) {
    if (!Array.isArray(items)) return
    for (var i = 0; i < items.length && acc.total < 2000; i++) {
      var it = items[i]
      if (!it) continue
      acc.total += 1
      if (it.state === "complete") acc.done += 1
      countChecks(it.children, acc)
    }
  }

  // One API card -> what the desktop shows. Everything is bounded and plain.
  function cardFromApi(k) {
    var labels = []
    var ids = Array.isArray(k.idLabels) ? k.idLabels : []
    for (var i = 0; i < ids.length && labels.length < 8; i++)
      if (labelMap[ids[i]]) labels.push(labelMap[ids[i]])
    labels.sort(function(a, b) { return a.pos - b.pos })
    var who = []
    var mids = Array.isArray(k.idMembers) ? k.idMembers : []
    for (var m = 0; m < mids.length && who.length < 3; m++)
      if (memberMap[mids[m]]) who.push(memberMap[mids[m]])
    var acc = { done: 0, total: 0 }
    var lists = Array.isArray(k.checklists) ? k.checklists : []
    for (var c = 0; c < lists.length && c < 50; c++) if (lists[c]) countChecks(lists[c].checkItems, acc)
    var due = typeof k.due === "string" && !isNaN(new Date(k.due).getTime()) ? k.due.slice(0, 40) : ""
    var allMembers = []
    for (var am = 0; am < mids.length && allMembers.length < 30; am++)
      if (memberNames[mids[am]]) allMembers.push(memberNames[mids[am]])
    detailMap[k.id] = { desc: typeof k.desc === "string" ? k.desc.slice(0, 20000) : "",
                        checklists: checklistRows(lists), members: allMembers,
                        // Every id the server has, known member or not, so a toggle sends the full list back.
                        memberIds: mids.slice(0, 200).filter(function(x) { return typeof x === "string" }),
                        labelIds: ids.slice(0, 200).filter(function(x) { return typeof x === "string" }),
                        // The untouched original, so a tick can send the whole block back.
                        raw: JSON.parse(JSON.stringify(lists)) }
    detailRev += 1
    return { id: k.id, text: String(k.name || "").slice(0, 500), pos: Number(k.pos) || 0,
             labels: labels, members: who, extraMembers: Math.max(0, mids.length - who.length),
             due: due, dueComplete: !!k.dueComplete,
             checkDone: acc.done, checkTotal: acc.total,
             hasDesc: typeof k.desc === "string" && k.desc.trim().length > 0,
             att: activeAtts(k.id) }
  }

  // Same rules as the web app (lib/date.ts dueState).
  function dueState(card) {
    if (!card.due) return "none"
    if (card.dueComplete) return "complete"
    var t = new Date(card.due).getTime()
    if (t < now) return "overdue"
    if (t - now < 2 * 86400000) return "soon"
    return "later"
  }

  function dueText(card) {
    var d = new Date(card.due)
    try { return Qt.locale(I18n.formatLocale).toString(d, "MMM d") } catch (e) { return Qt.formatDate(d, "MMM d") }
  }

  function dueLong(card) {
    if (!card || !card.due) return ""
    var d = new Date(card.due)
    try { return Qt.locale(I18n.formatLocale).toString(d, "ddd d MMM yyyy, HH:mm") } catch (e) { return Qt.formatDateTime(d, "ddd d MMM yyyy, HH:mm") }
  }

  function loc() {
    try { return Qt.locale(I18n.formatLocale) } catch (e) { return Qt.locale() }
  }

  // Set the due day. Like the web app, a date is a day: the card keeps the
  // time it already had, or gets 17:00 local when it had no due date.
  function setDue(id, year, month, day) {
    var hit = findCard(id)
    if (!hit || !synced || String(id).indexOf("tmp-") === 0) return
    var b = cloneBoard()
    var card = b.columns[hit.col].cards[hit.idx]
    var old = card.due ? new Date(card.due) : null
    var when = new Date(year, month, day, old ? old.getHours() : 17, old ? old.getMinutes() : 0, 0, 0)
    if (isNaN(when.getTime())) return
    var iso = when.toISOString()
    if (iso === card.due) return
    card.due = iso
    board = b
    write("PATCH", "/api/v1/cards/" + encodeURIComponent(id), { due: iso })
  }

  // Removing the date also clears "done", as the web app does.
  function clearDue(id) {
    var hit = findCard(id)
    if (!hit || !synced || String(id).indexOf("tmp-") === 0) return
    var b = cloneBoard()
    var card = b.columns[hit.col].cards[hit.idx]
    if (!card.due) return
    card.due = ""
    card.dueComplete = false
    board = b
    write("PATCH", "/api/v1/cards/" + encodeURIComponent(id), { due: null, dueComplete: false })
  }

  function toggleDue(col, idx) {
    var b = cloneBoard()
    var card = b.columns[col].cards[idx]
    if (!card || !card.due || !synced || String(card.id).indexOf("tmp-") === 0) return
    card.dueComplete = !card.dueComplete
    board = b
    write("PATCH", "/api/v1/cards/" + encodeURIComponent(card.id), { dueComplete: card.dueComplete })
  }

  function boardFromSnapshot(snap) {
    var lists = snap && Array.isArray(snap.lists) ? snap.lists.filter(function(l) { return l && !l.closed && typeof l.id === "string" }) : []
    lists.sort(function(a, b) { return (a.pos || 0) - (b.pos || 0) })
    allLists = lists.slice(0, 100).map(function(l) { return { id: l.id, name: String(l.name || "").slice(0, 60) } })
    listsFor = cfg.boardId
    var chosen = []
    var picks = pickedLists[cfg.boardId]
    if (Array.isArray(picks)) {
      // Slots the user left empty (or whose list is gone) stay empty.
      var used = ({})
      for (var s0 = 0; s0 < slots; s0++) {
        var found = lists.filter(function(l) { return l.id === picks[s0] && !used[l.id] })[0] || null
        if (found) used[found.id] = true
        chosen.push(found)
      }
    } else if (cfg.lists.length) {
      for (var n = 0; n < cfg.lists.length; n++) {
        var want = cfg.lists[n].toLowerCase()
        var hit = lists.filter(function(l) { return String(l.name).toLowerCase() === want })[0]
        chosen.push(hit || null)
      }
    } else {
      chosen = lists.slice(0, slots)
    }
    var cards = snap && Array.isArray(snap.cards) ? snap.cards : []
    var lm = ({}), mm = ({}), ac = ({}), mn = ({})
    detailMap = ({})
    var labels = snap && Array.isArray(snap.labels) ? snap.labels : []
    for (var li = 0; li < labels.length && li < 500; li++)
      if (labels[li] && typeof labels[li].id === "string")
        lm[labels[li].id] = { c: Colors.label(labels[li].color), n: String(labels[li].name || "").slice(0, 40), pos: Number(labels[li].pos) || 0 }
    var members = snap && Array.isArray(snap.members) ? snap.members : []
    for (var mi = 0; mi < members.length && mi < 500; mi++)
      if (members[mi] && typeof members[mi].id === "string")
        { mm[members[mi].id] = initialsOf(members[mi]); mn[members[mi].id] = { ini: initialsOf(members[mi]), name: String(members[mi].fullName || members[mi].username || "").slice(0, 60) } }
    var atts = snap && Array.isArray(snap.attachments) ? snap.attachments : []
    for (var ai = 0; ai < atts.length && ai < 5000; ai++) {
      var at = atts[ai]
      var info = attInfo(at)
      if (!info) continue
      if (!ac[at.idCard]) ac[at.idCard] = ({})
      ac[at.idCard][at.id] = info
    }
    labelMap = lm; memberMap = mm; attCounts = ac; memberNames = mn
    var bl = []
    for (var lk in lm) bl.push({ id: lk, c: lm[lk].c, n: lm[lk].n, pos: lm[lk].pos })
    bl.sort(function(a, b) { return a.pos - b.pos })
    boardLabels = bl
    var bm = []
    for (var bi = 0; bi < members.length && bm.length < 200; bi++)
      if (members[bi] && typeof members[bi].id === "string" && mn[members[bi].id])
        bm.push({ id: members[bi].id, ini: mn[members[bi].id].ini, name: mn[members[bi].id].name })
    bm.sort(function(a, b) { return a.name.toLowerCase() < b.name.toLowerCase() ? -1 : 1 })
    boardMembers = bm
    var cols = []
    for (var c = 0; c < slots; c++) {
      var l = chosen[c] || null
      var col = { title: l ? String(l.name).slice(0, 60) : "",
                  listId: l ? l.id : "", cards: [] }
      if (l) {
        var mine = cards.filter(function(k) { return k && !k.closed && k.idList === l.id && typeof k.id === "string" })
        mine.sort(function(a, b) { return (a.pos || 0) - (b.pos || 0) })
        for (var i = 0; i < mine.length && col.cards.length < 300; i++)
          col.cards.push(cardFromApi(mine[i]))
      }
      cols.push(col)
    }
    if (snap && snap.board && typeof snap.board.name === "string") boardName = snap.board.name.slice(0, 80)
    return { columns: cols }
  }

  function write(method, path, body, onOk) {
    writesInFlight += 1
    syncState = "syncing"
    api(method, path, body, function(ok, data, err) {
      root.writesInFlight -= 1
      if (!ok) {
        root.setError(err)
        // Put the board back the way the server has it.
        root.refetchAfterWrites = true
      } else {
        if (onOk) onOk(data)
        if (root.syncState !== "error") { root.syncState = "ok"; root.lastSync = Date.now() }
      }
      if (root.writesInFlight === 0 && root.refetchAfterWrites) {
        root.refetchAfterWrites = false
        root.fetchBoard(true)
      }
    })
  }

  function newPos(cards, idx) {
    var before = idx > 0 ? cards[idx - 1].pos : null
    var after = idx < cards.length ? cards[idx].pos : null
    if (before !== null && after !== null) return (before + after) / 2
    if (before !== null) return before + 65536
    if (after !== null) return after / 2
    return 65536
  }

  // ------------------------------------------------------- board operations
  function addCard(col, text) {
    text = String(text || "").trim().slice(0, 500)
    if (!text) return
    var b = cloneBoard()
    var column = b.columns[col]
    if (!synced) { column.cards.push({ id: uid(), text: text }); commitLocal(b); return }
    if (!column.listId) return
    var tempId = "tmp-" + uid()
    var pos = newPos(column.cards, column.cards.length)
    column.cards.push({ id: tempId, text: text, pos: pos, labels: [], members: [], extraMembers: 0, due: "", dueComplete: false, checkDone: 0, checkTotal: 0, hasDesc: false, att: 0 })
    board = b
    write("POST", "/api/v1/boards/" + encodeURIComponent(cfg.boardId) + "/cards", { idList: column.listId, name: text, pos: pos }, function(card) {
      root.replaceCard(tempId, card)
    })
  }

  function replaceCard(id, card) {
    if (!card || typeof card.id !== "string") return
    var b = cloneBoard()
    // The stream may have delivered the real card already: drop that copy.
    for (var dc = 0; dc < b.columns.length; dc++)
      b.columns[dc].cards = b.columns[dc].cards.filter(function(k) { return k.id !== card.id })
    for (var c = 0; c < b.columns.length; c++)
      for (var i = 0; i < b.columns[c].cards.length; i++)
        if (b.columns[c].cards[i].id === id) {
          b.columns[c].cards[i] = cardFromApi(card)
          board = b
          return
        }
  }

  function editCard(col, idx, text) {
    text = String(text || "").trim().slice(0, 500)
    var b = cloneBoard()
    var card = b.columns[col].cards[idx]
    if (!card) return
    if (!text) { deleteCard(col, idx); return }
    if (text === card.text) return
    card.text = text
    if (!synced) { commitLocal(b); return }
    board = b
    if (String(card.id).indexOf("tmp-") === 0) return
    write("PATCH", "/api/v1/cards/" + encodeURIComponent(card.id), { name: text })
  }

  function deleteCard(col, idx) {
    var b = cloneBoard()
    var card = b.columns[col].cards.splice(idx, 1)[0]
    if (!card) return
    if (!synced) { commitLocal(b); return }
    board = b
    if (String(card.id).indexOf("tmp-") === 0) return
    // Archive first, like the app; the bar that follows offers undo or a
    // permanent delete (the server only deletes cards that are archived).
    var entry = { card: card, col: col, idx: idx, listId: b.columns[col].listId, saved: false, then: null }
    lastArchived = entry
    archivedTimer.restart()
    write("PATCH", "/api/v1/cards/" + encodeURIComponent(card.id), { closed: true }, function() {
      // An undo or delete clicked before this finished runs now, in order.
      entry.saved = true
      if (entry.then) entry.then()
    })
  }

  property var lastArchived: null
  Timer { id: archivedTimer; interval: 12000; onTriggered: root.lastArchived = null }

  function undoArchive() {
    var e = lastArchived
    if (!e || !synced) return
    lastArchived = null
    var b = cloneBoard()
    // Back where it was, if that list is still on the desktop.
    for (var c = 0; c < b.columns.length; c++) {
      if (b.columns[c].listId !== e.listId) continue
      var cards = b.columns[c].cards
      var at = 0
      while (at < cards.length && cards[at].pos < e.card.pos) at++
      cards.splice(at, 0, e.card)
      break
    }
    board = b
    var restore = function() { root.write("PATCH", "/api/v1/cards/" + encodeURIComponent(e.card.id), { closed: false }) }
    if (e.saved) restore(); else e.then = restore
  }

  function purgeArchived() {
    var e = lastArchived
    if (!e || !synced) return
    lastArchived = null
    var purge = function() { root.write("DELETE", "/api/v1/cards/" + encodeURIComponent(e.card.id), null) }
    if (e.saved) purge(); else e.then = purge
  }

  function moveCard(fromCol, fromIdx, toCol, toIdx) {
    var b = cloneBoard()
    var card = b.columns[fromCol].cards.splice(fromIdx, 1)[0]
    if (!card) return
    if (fromCol === toCol && toIdx > fromIdx) toIdx -= 1
    var target = b.columns[toCol]
    toIdx = Math.max(0, Math.min(toIdx, target.cards.length))
    if (fromCol === toCol && toIdx === fromIdx) return
    if (!synced) { target.cards.splice(toIdx, 0, card); commitLocal(b); return }
    if (!target.listId || String(card.id).indexOf("tmp-") === 0) return
    card.pos = newPos(target.cards, toIdx)
    target.cards.splice(toIdx, 0, card)
    board = b
    var patch = { pos: card.pos }
    if (fromCol !== toCol) patch.idList = target.listId
    write("PATCH", "/api/v1/cards/" + encodeURIComponent(card.id), patch)
  }

  // ------------------------------------------------------------ live stream
  // GET /api/v1/boards/{id}/events is a server-sent event stream of the same
  // card/list/label/attachment events the web app gets. curl holds it open;
  // the key goes to curl on stdin so it never appears in the process list.
  property bool live: false           // stream connected
  property real streamSeen: 0         // last byte from the stream
  property real streamUp: 0           // when the current connection came up
  property int streamFails: 0
  property bool everLive: false
  readonly property bool wantStream: synced && cfg.live && onBoardWallpaper && workspaceScreens.length > 0

  onWantStreamChanged: wantStream ? startStream() : stopStream()
  // A different board or key: reconnect as soon as the old connection is gone.
  property bool streamRestart: false
  onCfgChanged: {
    if (stream.running) { streamRestart = wantStream; stopStream() }
    else if (wantStream) startStream()
  }

  function startStream() {
    if (!wantStream || stream.running) return
    streamRetry.stop()
    streamSeen = 0
    stream.command = ["curl", "-sS", "-N", "-f", "--connect-timeout", "15", "-H", "@-",
      "-H", "Accept: text/event-stream", "--", cfg.apiUrl + "/api/v1/boards/" + encodeURIComponent(cfg.boardId) + "/events"]
    stream.running = true
  }

  function stopStream() {
    streamRetry.stop()
    live = false
    if (stream.running) stream.running = false
  }

  function streamLine(line) {
    // The splitter can hand over the blank separator line glued to the next one.
    line = String(line).replace(/^[\r\n]+|[\r\n]+$/g, "")
    if (!line.length) return
    streamSeen = Date.now()
    if (line.length > 2 * 1024 * 1024) { scheduleRefetch(); return }
    if (line.indexOf(":") === 0) {
      if (line.indexOf("connected") !== -1) streamConnected()
      return
    }
    if (line.indexOf("data:") !== 0) return
    if (!live) streamConnected()
    var ev = null
    try { ev = JSON.parse(line.slice(5)) } catch (e) { return }
    if (!ev || typeof ev.type !== "string") return
    if (ev.origin && ev.origin === clientId) return   // our own change, already shown
    applyEvent(ev)
  }

  function streamConnected() {
    if (live) return
    live = true
    streamUp = Date.now()
    // Anything that happened while disconnected is only in a full download.
    if (everLive || !loaded) fetchBoard(true)
    everLive = true
  }

  function applyEvent(ev) {
    var d = ev.data
    if (ev.type === "card") {
      if (!d || typeof d.id !== "string") { scheduleRefetch(); return }
      if (ev.op === "delete") { dropCard(d.id); return }
      if (ev.op !== "upsert" || typeof d.idList !== "string") { scheduleRefetch(); return }
      upsertCard(d)
    } else if (ev.type === "attachment") {
      if (!d || typeof d.idCard !== "string" || typeof d.id !== "string") return
      var evInfo = ev.op === "delete" ? null : attInfo(d)
      setAttachment(d.idCard, d.id, evInfo)
    } else if (ev.type === "list" || ev.type === "label" || ev.type === "members" || ev.type === "board") {
      // Rare, and they change how every card is drawn: take a fresh download.
      scheduleRefetch()
    }
    // chat, github, commit: nothing the desktop shows.
  }

  function dropCard(id) {
    var b = cloneBoard()
    var found = false
    for (var c = 0; c < b.columns.length; c++) {
      var before = b.columns[c].cards.length
      b.columns[c].cards = b.columns[c].cards.filter(function(k) { return k.id !== id })
      if (b.columns[c].cards.length !== before) found = true
    }
    if (found) board = b
    if (lastArchived && lastArchived.card.id === id) lastArchived = null
  }

  function upsertCard(d) {
    var b = cloneBoard()
    var changed = false
    for (var c = 0; c < b.columns.length; c++) {
      var before = b.columns[c].cards.length
      b.columns[c].cards = b.columns[c].cards.filter(function(k) { return k.id !== d.id })
      if (b.columns[c].cards.length !== before) changed = true
    }
    if (!d.closed) {
      for (var t = 0; t < b.columns.length; t++) {
        if (!b.columns[t].listId || b.columns[t].listId !== d.idList) continue
        var card = cardFromApi(d)
        var cards = b.columns[t].cards
        var at = 0
        while (at < cards.length && cards[at].pos <= card.pos) at++
        cards.splice(at, 0, card)
        changed = true
        break
      }
    }
    if (changed) board = b
  }

  function scheduleRefetch() { refetchDebounce.restart() }
  Timer { id: refetchDebounce; interval: 1500; onTriggered: root.fetchBoard(true) }

  Process {
    id: stream
    stdinEnabled: true
    onStarted: {
      write("Authorization: Bearer " + root.cfg.apiKey + "\n")
      stdinEnabled = false          // close stdin so curl stops reading headers
    }
    stdout: SplitParser { onRead: function(line) { root.streamLine(line) } }
    stderr: SplitParser { onRead: function(line) { console.warn("boardhydra.desk stream:", String(line).slice(0, 200)) } }
    onExited: function(code, status) {
      stdinEnabled = true
      var wasLive = root.live
      root.live = false
      if (root.streamRestart) { root.streamRestart = false; root.streamFails = 0; root.startStream(); return }
      if (!root.wantStream) return
      // A connection that held for a minute was healthy: start the backoff over.
      if (wasLive && Date.now() - root.streamUp > 60000) root.streamFails = 0
      else root.streamFails += 1
      var delays = [3000, 10000, 30000, 120000, 300000]
      streamRetry.interval = delays[Math.min(Math.max(root.streamFails - 1, 0), delays.length - 1)]
      streamRetry.restart()
    }
  }
  Timer { id: streamRetry; onTriggered: root.startStream() }

  // The server pings every 25s; silence means the connection is dead.
  Timer {
    interval: 10000; repeat: true; running: stream.running
    onTriggered: {
      if (root.streamSeen > 0 && Date.now() - root.streamSeen > 70000) { root.streamSeen = 0; stream.running = false }
      else if (root.streamSeen === 0) root.streamSeen = Date.now()
    }
  }

  // Background refresh (synced mode); also on hover, throttled in fetchBoard.
  Timer {
    // With the stream up this is only a safety net.
    interval: root.live ? 3600000 : (root.synced ? root.cfg.refreshMinutes * 60000 : 600000)
    repeat: true
    running: root.synced && root.onBoardWallpaper && root.workspaceScreens.length > 0
    onTriggered: root.fetchBoard(true)
  }

  function agoText() {
    var s = Math.max(0, Math.round((now - lastSync) / 1000))
    if (s < 45) return "just now"
    var m = Math.round(s / 60)
    if (m < 60) return m + "m ago"
    return Math.round(m / 60) + "h ago"
  }

  // ------------------------------------------- show only on the board wallpaper
  Process {
    id: bgProbe
    command: ["sh", "-c", "cat \"$HOME/.local/state/omarchy/current/theme.name\" 2>/dev/null; echo; readlink -f \"$HOME/.local/state/omarchy/current/background\""]
    stdout: StdioCollector {
      onStreamFinished: {
        var lines = text.split("\n").map(function(l) { return l.trim() }).filter(function(l) { return l.length })
        var theme = lines.length > 1 ? lines[0] : ""
        var bg = lines.length ? lines[lines.length - 1] : ""
        root.onBoardWallpaper = theme === "boardhydra" && /\/2-board\.[a-z]+$/.test(bg)
      }
    }
  }
  Timer {
    interval: 2000; repeat: true; running: true; triggeredOnStart: true
    onTriggered: if (!bgProbe.running) bgProbe.running = true
  }

  // ------------------------------------------------------------ quick add
  // `omarchy-shell boardhydra-desk quickAdd` (bound to a key) opens a small
  // box over whatever is on screen to add a card without finding the desktop.
  property bool quickOpen: false
  property int quickCol: 0

  function quickUsable(c) {
    var col = board.columns[c]
    return !!col && (!synced || !!col.listId)
  }
  function quickCycle(step) {
    var n = Math.max(1, board.columns.length)
    for (var i = 1; i <= n; i++) {
      var c = (quickCol + step * i + n * 4) % n
      if (quickUsable(c)) { quickCol = c; return }
    }
  }
  function openQuickAdd() {
    if (quickOpen) { quickOpen = false; return }
    if (synced) fetchBoard(false)
    if (!quickUsable(quickCol)) quickCycle(1)
    quickOpen = true
  }

  LazyLoader {
    active: root.quickOpen
    PanelWindow {
      id: quick
      screen: root.workspaceScreens.length ? root.workspaceScreens[0] : null
      visible: true
      implicitWidth: 560
      implicitHeight: 132
      color: "transparent"
      exclusionMode: ExclusionMode.Ignore
      WlrLayershell.namespace: "boardhydra-quickadd"
      WlrLayershell.layer: WlrLayer.Overlay
      WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive

      readonly property bool ready: root.quickUsable(root.quickCol)
      readonly property color head: root.heads[root.quickCol]

      Rectangle {
        anchors.fill: parent
        radius: 16
        color: "#15121f"
        border.width: 1
        border.color: Qt.alpha(quick.head, 0.7)

        Row {
          x: 20; y: 16; spacing: 8
          Plain { text: "Add to"; font.pixelSize: 12; color: root.mutedColor; anchors.verticalCenter: parent.verticalCenter }
          Repeater {
            model: root.board.columns
            Rectangle {
              required property var modelData
              required property int index
              readonly property bool on: index === root.quickCol
              visible: root.quickUsable(index)
              height: 24; radius: 12
              width: Math.min(150, chipText.implicitWidth + 22)
              color: on ? Qt.alpha(root.heads[index], 0.22) : "transparent"
              border.width: 1
              border.color: on ? root.heads[index] : root.cardBorder
              Plain {
                id: chipText
                anchors.centerIn: parent
                width: Math.min(implicitWidth, 128)
                elide: Text.ElideRight
                font.pixelSize: 12
                color: parent.on ? root.textColor : root.mutedColor
                text: parent.modelData.title
              }
              TapHandler { onTapped: { root.quickCol = parent.index; quickInput.forceActiveFocus() } }
            }
          }
        }

        Rectangle {
          x: 20; y: 52
          width: parent.width - 40; height: 40; radius: 10
          color: root.cardColor
          border.width: 1; border.color: quick.head
          TextInput {
            id: quickInput
            anchors { fill: parent; leftMargin: 12; rightMargin: 12 }
            verticalAlignment: TextInput.AlignVCenter
            clip: true
            focus: true
            enabled: quick.ready
            maximumLength: 500
            font.family: Style.fontFamily
            font.pixelSize: 14
            color: root.textColor
            selectionColor: Qt.alpha(quick.head, 0.5)
            Component.onCompleted: forceActiveFocus()
            Keys.onPressed: function(e) {
              if (e.key === Qt.Key_Escape) { root.quickOpen = false; e.accepted = true }
              else if (e.key === Qt.Key_Tab) { root.quickCycle(1); e.accepted = true }
              else if (e.key === Qt.Key_Backtab) { root.quickCycle(-1); e.accepted = true }
              else if (e.key === Qt.Key_Return || e.key === Qt.Key_Enter) {
                if (text.trim().length && quick.ready) root.addCard(root.quickCol, text)
                root.quickOpen = false
                e.accepted = true
              }
            }
            Plain {
              visible: quickInput.text.length === 0
              anchors.verticalCenter: parent.verticalCenter
              width: parent.width; elide: Text.ElideRight
              font.pixelSize: 14
              color: quick.ready ? root.faintColor : root.badColor
              text: quick.ready ? "What needs doing?"
                : root.syncState === "error" ? root.syncError : "Board isn't loaded yet"
            }
          }
        }

        Plain {
          x: 20; y: 104
          font.pixelSize: 11; color: root.faintColor
          text: "Enter  add     Tab  switch list     Esc  close"
        }
      }
    }
  }

  component CkBtn: Rectangle {
    id: ckBtn
    property string glyph: ""
    property color tone: root.mutedColor
    signal tapped()
    width: 22; height: 22; radius: 6
    color: ckBtnHover.hovered ? "#2d2742" : "transparent"
    Text {
      anchors.centerIn: parent
      textFormat: Text.PlainText
      font.family: Style.fontFamily
      font.pixelSize: 11
      color: ckBtnHover.hovered ? ckBtn.tone : root.faintColor
      text: ckBtn.glyph
    }
    HoverHandler { id: ckBtnHover; cursorShape: Qt.PointingHandCursor }
    TapHandler { onTapped: ckBtn.tapped() }
  }

  // One-line "type and press Enter" field used for new checklist items.
  component CkField: Rectangle {
    id: ckField
    property string hint: ""
    property color tone: root.heads[1]
    property alias input: ckFieldInput
    signal submitted(string text)
    signal cancelled()
    height: 30; radius: 8
    color: ckFieldInput.activeFocus ? root.cardColor : "transparent"
    border.width: 1
    border.color: ckFieldInput.activeFocus ? tone : root.cardBorder
    TextInput {
      id: ckFieldInput
      anchors { fill: parent; leftMargin: 10; rightMargin: 10 }
      verticalAlignment: TextInput.AlignVCenter
      clip: true
      maximumLength: 500
      font.family: Style.fontFamily
      font.pixelSize: 13
      color: root.textColor
      selectionColor: Qt.alpha(ckField.tone, 0.5)
      Keys.onPressed: function(e) {
        if (e.key === Qt.Key_Return || e.key === Qt.Key_Enter) {
          if (text.trim().length) { ckField.submitted(text); text = "" }
          e.accepted = true
        } else if (e.key === Qt.Key_Escape) { text = ""; ckField.cancelled(); e.accepted = true }
      }
      Text {
        visible: ckFieldInput.text.length === 0
        anchors.verticalCenter: parent.verticalCenter
        textFormat: Text.PlainText
        font.family: Style.fontFamily
        font.pixelSize: 13
        color: root.faintColor
        text: ckField.hint
      }
    }
  }

  component Plain: Text {
    textFormat: Text.PlainText
    font.family: Style.fontFamily
    color: root.textColor
  }

  Variants {
    model: root.workspaceScreens

    PanelWindow {
      id: win
      required property var modelData
      screen: modelData
      visible: root.onBoardWallpaper && root.configChecked && (root.loaded || root.synced)

      // Map wallpaper pixels to this screen (wallpaper is aspect-cropped).
      readonly property real sw: modelData.width
      readonly property real sh: modelData.height
      readonly property real s: Math.max(sw / root.wpW, sh / root.wpH)
      readonly property real ox: (sw - root.wpW * s) / 2
      readonly property real oy: (sh - root.wpH * s) / 2
      readonly property real stride: root.colStride * s
      readonly property real cw: root.colW * s

      anchors { top: true; left: true }
      readonly property int barH: root.synced ? 44 : 0
      margins { left: Math.round(ox + root.colX * s); top: Math.round(oy + root.colY * s) - barH }
      implicitWidth: Math.round(stride * (root.slots - 1) + cw)
      implicitHeight: Math.round(root.colH * s) + barH
      color: "transparent"
      exclusionMode: ExclusionMode.Ignore
      WlrLayershell.namespace: "boardhydra-desk"
      WlrLayershell.layer: WlrLayer.Bottom
      WlrLayershell.keyboardFocus: WlrKeyboardFocus.OnDemand

      // Drag state
      property int dragCol: -1
      property int dragIdx: -1
      property string dragText: ""
      property int hoverCol: -1
      property int hoverIdx: -1
      property point dragPos: Qt.point(0, 0)
      property point dragGrab: Qt.point(0, 0)

      function dropTarget(x, y) {
        var vis = root.shownCols()
        var col = vis.length ? vis[0] : 0
        var best = 1e9
        for (var v = 0; v < vis.length; v++) {
          var d = Math.abs(x - (root.colPos(vis[v]) * stride + cw / 2))
          if (d < best) { best = d; col = vis[v] }
        }
        var colItem = columns.itemAt(col)
        if (!colItem) return { col: col, idx: 0 }
        var rep = colItem.cardRepeater
        var idx = rep.count
        for (var i = 0; i < rep.count; i++) {
          var it = rep.itemAt(i)
          if (!it) continue
          var p = it.mapToItem(boardArea, 0, 0)
          if (y < p.y + it.height / 2) { idx = i; break }
        }
        return { col: col, idx: idx }
      }

      // The wallpaper's own gradient, sized and placed as the wallpaper is, so
      // the columns painted on it are hidden and gaps look like bare wallpaper.
      Rectangle {
        id: backdrop
        z: -1
        x: win.ox - win.margins.left
        y: win.oy - win.margins.top
        width: Math.round(root.wpW * win.s)
        height: Math.round(root.wpH * win.s)
        gradient: Gradient {
          GradientStop { position: 0; color: root.wpTop }
          GradientStop { position: 1; color: root.wpBottom }
        }
      }

      // Top bar: the board name opens the board & lists menu; a way to the full site.
      Item {
        id: topBar
        visible: root.synced
        width: parent.width
        height: win.barH
        z: 30

        Rectangle {
          id: boardPill
          height: 30; radius: 15
          width: Math.min(parent.width * 0.6, pillRow.implicitWidth + 28)
          color: pillHover.hovered || root.switcherOpen ? "#241f35" : "#1b1729"
          border.width: 1
          border.color: root.switcherOpen ? root.heads[1] : root.cardBorder
          Row {
            id: pillRow
            anchors { left: parent.left; leftMargin: 13; verticalCenter: parent.verticalCenter }
            spacing: 8
            Row {
              spacing: 2
              anchors.verticalCenter: parent.verticalCenter
              Repeater { model: root.slots; Rectangle { required property int index; width: 4; height: 12; radius: 1; color: root.heads[index] } }
            }
            Plain {
              width: Math.min(implicitWidth, boardPill.parent.width * 0.6 - 70)
              elide: Text.ElideRight
              font.pixelSize: 13; font.weight: Font.Bold
              text: root.boardName || "BoardHydra"
            }
            Plain { font.pixelSize: 10; color: root.mutedColor; anchors.verticalCenter: parent.verticalCenter; text: root.switcherOpen ? "\uf077" : "\uf078" }
          }
          HoverHandler { id: pillHover; cursorShape: Qt.PointingHandCursor }
          TapHandler { onTapped: root.openSwitcher() }
        }

        Rectangle {
          anchors.right: parent.right
          height: 30; radius: 15
          width: siteText.implicitWidth + 28
          color: siteHover.hovered ? Qt.alpha(root.heads[1], 0.28) : "#1b1729"
          border.width: 1
          border.color: siteHover.hovered ? root.heads[1] : root.cardBorder
          Plain { id: siteText; anchors.centerIn: parent; font.pixelSize: 12; text: "Full site  \uf08e" }
          HoverHandler { id: siteHover; cursorShape: Qt.PointingHandCursor }
          TapHandler { onTapped: root.openFullSite() }
        }
      }

      // Board & lists panel: pick the board, then which list fills each column.
      Item {
        anchors.fill: parent
        visible: root.switcherOpen && root.synced
        z: 40
        MouseArea {   // click anywhere else to close
          anchors.fill: parent
          acceptedButtons: Qt.AllButtons
          onClicked: root.switcherOpen = false
          onWheel: function(w) { w.accepted = true }
        }
        Rectangle {
          y: 36
          width: Math.min(420, parent.width - 20)
          height: Math.min(parent.height - 50, panelCol.height + 16)
          radius: 14
          color: "#15121f"
          border.width: 1
          border.color: Qt.alpha(root.heads[1], 0.7)
          MouseArea { anchors.fill: parent; acceptedButtons: Qt.AllButtons }

          Flickable {
            anchors { fill: parent; margins: 8 }
            contentHeight: panelCol.height
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            Column {
              id: panelCol
              width: parent.width
              spacing: 2

              Plain {
                leftPadding: 8; topPadding: 4; bottomPadding: 4
                font.pixelSize: 10; font.weight: Font.Bold; font.letterSpacing: 1
                color: root.faintColor
                text: "BOARD"
              }
              Plain {
                visible: root.boardListState !== "ok" || root.boardList.length === 0
                width: parent.width
                padding: 10
                elide: Text.ElideRight
                font.pixelSize: 12
                color: root.boardListState === "error" ? root.badColor : root.mutedColor
                text: root.boardListState === "error" ? root.boardListError
                    : root.boardListState === "ok" ? "No boards on this account." : "Loading your boards…"
              }
              Repeater {
                model: root.boardListState === "ok" ? root.boardList : []
                Rectangle {
                  id: boardRow
                  required property var modelData
                  readonly property bool current: root.synced && modelData.id === root.curBoardId
                  width: panelCol.width
                  height: 40; radius: 9
                  color: rowHover.hovered ? "#241f35" : "transparent"
                  Rectangle {
                    visible: boardRow.current
                    x: 4; width: 3; height: 18; radius: 2
                    anchors.verticalCenter: parent.verticalCenter
                    color: root.heads[1]
                  }
                  Column {
                    anchors { left: parent.left; leftMargin: 16; right: countText.left; rightMargin: 8; verticalCenter: parent.verticalCenter }
                    Plain {
                      width: parent.width; elide: Text.ElideRight
                      font.pixelSize: 13; font.weight: boardRow.current ? Font.Bold : Font.Normal
                      text: boardRow.modelData.name
                    }
                    Plain {
                      visible: boardRow.modelData.team.length > 0
                      width: parent.width; elide: Text.ElideRight
                      font.pixelSize: 10; color: root.faintColor
                      text: boardRow.modelData.team
                    }
                  }
                  Plain {
                    id: countText
                    anchors { right: parent.right; rightMargin: 12; verticalCenter: parent.verticalCenter }
                    font.pixelSize: 11; color: root.faintColor
                    text: boardRow.modelData.cards
                  }
                  HoverHandler { id: rowHover; cursorShape: Qt.PointingHandCursor }
                  TapHandler { onTapped: root.switchBoard(boardRow.modelData.id) }
                }
              }

              Item { width: 1; height: 6 }
              Rectangle { x: 8; width: parent.width - 16; height: 1; color: root.cardBorder }
              Item { width: 1; height: 6 }

              Item {
                width: parent.width
                height: 24
                Plain {
                  x: 8; anchors.verticalCenter: parent.verticalCenter
                  font.pixelSize: 10; font.weight: Font.Bold; font.letterSpacing: 1
                  color: root.faintColor
                  text: "LISTS ON THE DESKTOP"
                }
                Plain {
                  anchors { right: parent.right; rightMargin: 12; verticalCenter: parent.verticalCenter }
                  font.pixelSize: 10; color: root.faintColor
                  text: "column"
                }
              }
              Plain {
                visible: root.listsFor !== root.curBoardId || root.allLists.length === 0
                width: parent.width
                padding: 10
                font.pixelSize: 12; color: root.mutedColor
                text: root.listsFor !== root.curBoardId ? "Loading lists…" : "This board has no lists yet."
              }
              Repeater {
                model: root.listsFor === root.curBoardId ? root.allLists : []
                Rectangle {
                  id: pickRow
                  required property var modelData
                  // Which desktop column shows this list, or -1.
                  readonly property int shownIn: {
                    for (var c = 0; c < root.board.columns.length; c++)
                      if (root.board.columns[c].listId === modelData.id) return c
                    return -1
                  }
                  width: panelCol.width
                  height: 36; radius: 8
                  color: pickHover.hovered ? "#1e1a2c" : "transparent"
                  HoverHandler { id: pickHover }
                  Plain {
                    anchors { left: parent.left; leftMargin: 16; right: slots.left; rightMargin: 10; verticalCenter: parent.verticalCenter }
                    elide: Text.ElideRight
                    font.pixelSize: 13; font.weight: pickRow.shownIn >= 0 ? Font.Bold : Font.Normal
                    color: pickRow.shownIn >= 0 ? root.textColor : root.mutedColor
                    text: pickRow.modelData.name
                  }
                  Row {
                    id: slots
                    anchors { right: parent.right; rightMargin: 8; verticalCenter: parent.verticalCenter }
                    spacing: 4
                    Repeater {
                      model: root.slots
                      Rectangle {
                        id: slotBtn
                        required property int index
                        readonly property bool on: pickRow.shownIn === index
                        width: 26; height: 22; radius: 6
                        color: on ? root.heads[index] : (slotHover.hovered ? Qt.alpha(root.heads[index], 0.25) : "transparent")
                        border.width: on ? 0 : 1
                        border.color: slotHover.hovered ? root.heads[index] : root.cardBorder
                        Plain {
                          anchors.centerIn: parent
                          font.pixelSize: 11; font.weight: Font.Bold
                          color: slotBtn.on ? "#0d0b14" : (slotHover.hovered ? root.textColor : root.faintColor)
                          text: slotBtn.index + 1
                        }
                        HoverHandler { id: slotHover; cursorShape: Qt.PointingHandCursor }
                        // Clicking the lit slot empties it.
                        TapHandler { onTapped: root.pickList(slotBtn.index, slotBtn.on ? "" : pickRow.modelData.id) }
                      }
                    }
                  }
                }
              }
              Plain {
                visible: root.listsFor === root.curBoardId && root.allLists.length > 0
                width: parent.width
                leftPadding: 16; topPadding: 6; bottomPadding: 4; rightPadding: 12
                wrapMode: Text.WordWrap
                font.pixelSize: 10; color: root.faintColor
                text: "Click a lit number to empty that slot. Picking a list that's already shown swaps the two."
              }

              Item { width: 1; height: 6 }
              Rectangle { x: 8; width: parent.width - 16; height: 1; color: root.cardBorder }
              Item { width: 1; height: 6 }

              Item {
                width: parent.width
                height: 34
                Plain {
                  x: 8; anchors.verticalCenter: parent.verticalCenter
                  font.pixelSize: 10; font.weight: Font.Bold; font.letterSpacing: 1
                  color: root.faintColor
                  text: "EMPTY SLOTS"
                }
                Row {
                  anchors { right: parent.right; rightMargin: 8; verticalCenter: parent.verticalCenter }
                  spacing: 4
                  Repeater {
                    model: [{ key: "gaps", label: "Leave gaps" }, { key: "center", label: "Center columns" }]
                    Rectangle {
                      id: layoutBtn
                      required property var modelData
                      readonly property bool on: root.layout === modelData.key
                      width: layoutText.implicitWidth + 22; height: 24; radius: 12
                      color: on ? Qt.alpha(root.heads[1], 0.28) : (layoutHover.hovered ? "#241f35" : "transparent")
                      border.width: 1
                      border.color: on || layoutHover.hovered ? root.heads[1] : root.cardBorder
                      Plain {
                        id: layoutText
                        anchors.centerIn: parent
                        font.pixelSize: 11; font.weight: layoutBtn.on ? Font.Bold : Font.Normal
                        color: layoutBtn.on ? root.textColor : root.mutedColor
                        text: layoutBtn.modelData.label
                      }
                      HoverHandler { id: layoutHover; cursorShape: Qt.PointingHandCursor }
                      TapHandler { onTapped: root.setLayout(layoutBtn.modelData.key) }
                    }
                  }
                }
              }
            }
          }
        }
      }

      Item {
        id: boardArea
        anchors { fill: parent; topMargin: win.barH }

        HoverHandler {
          onHoveredChanged: if (hovered && root.synced) root.fetchBoard(false)
        }

        // Placeholder while the first fetch is out (or failed before any data).
        Rectangle {
          visible: root.synced && !root.loaded
          anchors.centerIn: parent
          width: Math.min(parent.width - 40, waitLabel.implicitWidth + 40)
          height: 44; radius: 22
          color: "#1b1729"
          border.width: 1
          border.color: root.syncState === "error" ? root.badColor : root.cardBorder
          Plain {
            id: waitLabel
            anchors.centerIn: parent
            width: Math.min(implicitWidth, parent.parent.width - 80)
            elide: Text.ElideRight
            font.pixelSize: 13
            color: root.syncState === "error" ? root.badColor : root.mutedColor
            text: root.syncState === "error" ? "BoardHydra: " + root.syncError + "  (click to retry)" : "Loading your board…"
          }
          TapHandler { onTapped: root.fetchBoard(true) }
        }

        Repeater {
          id: columns
          model: root.board.columns

          Rectangle {
            id: column
            required property var modelData
            required property int index
            readonly property color head: root.heads[index]
            readonly property bool usable: !root.synced || !!modelData.listId
            property alias cardRepeater: cardRep
            property bool adding: false

            visible: column.usable
            x: Math.round(root.colPos(index) * win.stride)
            width: Math.round(win.cw)
            height: parent.height
            radius: Math.round(24 * win.s)
            border.width: 1
            border.color: Qt.alpha(head, win.hoverCol === index && win.dragCol >= 0 ? 0.9 : 0.4)
            gradient: Gradient {
              GradientStop { position: 0; color: Qt.tint("#15121f", Qt.alpha(column.head, 0.06)) }
              GradientStop { position: 1; color: Qt.tint("#100e18", Qt.alpha(column.head, 0.04)) }
            }

            // Header
            Row {
              id: header
              x: 18; y: 16
              spacing: 10
              Rectangle { width: 10; height: 10; radius: 5; color: column.head; anchors.verticalCenter: parent.verticalCenter }
              Plain {
                text: column.modelData.title; font.pixelSize: 15; font.weight: Font.Bold
                elide: Text.ElideRight
                width: Math.min(implicitWidth, column.width - 104)
                color: titleHover.hovered && root.synced ? column.head : root.textColor
              }
              Plain { text: column.modelData.cards.length; font.pixelSize: 13; color: root.faintColor; anchors.verticalCenter: parent.verticalCenter }
              Plain {
                visible: root.synced
                anchors.verticalCenter: parent.verticalCenter
                font.pixelSize: 9
                color: titleHover.hovered ? column.head : root.faintColor
                text: root.listMenuCol === column.index ? "\uf077" : "\uf078"
              }
              HoverHandler { id: titleHover; enabled: root.synced; cursorShape: Qt.PointingHandCursor }
              TapHandler { enabled: root.synced; onTapped: root.listMenuCol = (root.listMenuCol === column.index ? -1 : column.index) }
            }

            // Sync status (bottom of the last column, synced mode). Click to refresh now.
            Rectangle {
              id: syncChip
              visible: root.synced && column.index === root.shownCols().slice(-1)[0]
              anchors { right: parent.right; rightMargin: 12; bottom: parent.bottom; bottomMargin: 10 }
              height: 24; radius: 12
              width: Math.min(syncLabel.implicitWidth + 32, column.width - 24)
              color: chipHover.hovered ? Qt.alpha(column.head, 0.14) : "transparent"
              Rectangle {
                id: syncDot
                x: 10; width: 7; height: 7; radius: 4
                anchors.verticalCenter: parent.verticalCenter
                color: root.syncState === "error" ? root.badColor : (root.syncState === "syncing" ? "#f2c35b" : column.head)
              }
              Plain {
                id: syncLabel
                anchors { left: syncDot.right; leftMargin: 7; right: parent.right; rightMargin: 8; verticalCenter: parent.verticalCenter }
                font.pixelSize: 11
                elide: Text.ElideRight
                color: root.syncState === "error" ? root.badColor : root.faintColor
                text: root.syncState === "syncing" ? "syncing…"
                  : root.syncState === "error" ? root.syncError
                  : root.live ? "live"
                  : root.lastSync > 0 ? "synced " + root.agoText() : "connecting…"
              }
              HoverHandler { id: chipHover; cursorShape: Qt.PointingHandCursor }
              TapHandler { onTapped: root.fetchBoard(true) }
            }

            Flickable {
              id: flick
              anchors { top: header.bottom; topMargin: 14; left: parent.left; right: parent.right; bottom: parent.bottom; bottomMargin: syncChip.visible ? 40 : 10 }
              anchors.leftMargin: 12; anchors.rightMargin: 12
              contentHeight: list.height
              clip: true
              boundsBehavior: Flickable.StopAtBounds
              interactive: win.dragCol < 0

              Column {
                id: list
                width: flick.width
                spacing: 10
                topPadding: 6

                Repeater {
                  id: cardRep
                  model: column.modelData.cards

                  Item {
                    id: cardSlot
                    required property var modelData
                    required property int index
                    width: list.width
                    height: card.height

                    // Drop indicator above this card
                    Rectangle {
                      visible: win.dragCol >= 0 && win.hoverCol === column.index && win.hoverIdx === cardSlot.index
                      width: parent.width; height: 2; radius: 1; y: -6
                      color: column.head
                    }

                    Rectangle {
                      id: card
                      property bool editing: false
                      readonly property bool beingDragged: win.dragCol === column.index && win.dragIdx === cardSlot.index
                      readonly property bool unsaved: String(cardSlot.modelData.id).indexOf("tmp-") === 0
                      readonly property var d: cardSlot.modelData
                      readonly property var labels: d.labels || []
                      readonly property var members: d.members || []
                      readonly property string due: root.dueState(d)
                      // Local cards keep the column-colored bar from the wallpaper; synced cards show their labels.
                      readonly property bool hasBar: !root.synced || labels.length > 0
                      readonly property bool hasFooter: due !== "none" || (d.checkTotal || 0) > 0 || !!d.hasDesc || (d.att || 0) > 0 || members.length > 0
                      readonly property real textY: hasBar ? 24 : 14
                      width: parent.width
                      height: Math.max(hasFooter ? 0 : 56, textY + (editing ? editor.contentHeight : label.contentHeight) + (hasFooter ? 38 : 12))
                      radius: 12
                      color: hover.hovered || editing ? root.cardHover : root.cardColor
                      border.width: 1
                      border.color: editing ? column.head : root.cardBorder
                      opacity: beingDragged ? 0.35 : (unsaved ? 0.7 : 1)

                      Rectangle { visible: !root.synced; x: 14; y: 12; width: 40; height: 4; radius: 2; color: column.head }
                      Row {
                        visible: root.synced && card.labels.length > 0
                        x: 14; y: 11; spacing: 5
                        Repeater {
                          model: card.labels
                          Rectangle { required property var modelData; width: 32; height: 6; radius: 3; color: modelData.c }
                        }
                      }

                      Plain {
                        id: label
                        visible: !card.editing
                        x: 14; y: card.textY
                        width: parent.width - 28 - (hover.hovered ? 18 : 0)
                        wrapMode: Text.Wrap
                        font.pixelSize: 13
                        text: cardSlot.modelData.text
                      }

                      TextEdit {
                        id: editor
                        visible: card.editing
                        x: 14; y: card.textY
                        width: parent.width - 28
                        wrapMode: TextEdit.Wrap
                        textFormat: TextEdit.PlainText
                        font.family: Style.fontFamily
                        font.pixelSize: 13
                        color: root.textColor
                        selectionColor: Qt.alpha(column.head, 0.5)
                        selectByMouse: true
                        Keys.onPressed: function(e) {
                          if ((e.key === Qt.Key_Return || e.key === Qt.Key_Enter) && !(e.modifiers & Qt.ShiftModifier)) {
                            card.editing = false
                            root.editCard(column.index, cardSlot.index, text)
                            e.accepted = true
                          } else if (e.key === Qt.Key_Escape) {
                            card.editing = false
                            e.accepted = true
                          }
                        }
                        onActiveFocusChanged: if (!activeFocus && card.editing) {
                          card.editing = false
                          root.editCard(column.index, cardSlot.index, text)
                        }
                      }

                      HoverHandler { id: hover }

                      MouseArea {
                        anchors.fill: parent
                        enabled: !card.editing && !card.unsaved
                        cursorShape: win.dragCol >= 0 ? Qt.ClosedHandCursor : Qt.OpenHandCursor
                        property point press
                        property bool moved: false
                        onPressed: function(m) { press = Qt.point(m.x, m.y); moved = false }
                        onClicked: if (!moved && root.synced) openTimer.restart()
                        // Wait out a possible double-click (which edits the title instead).
                        Timer { id: openTimer; interval: 260; onTriggered: if (!card.editing) root.openCardId = cardSlot.modelData.id }
                        onPositionChanged: function(m) {
                          if (!pressed) return
                          var p = mapToItem(boardArea, m.x, m.y)
                          if (win.dragCol < 0) {
                            if (Math.abs(m.x - press.x) + Math.abs(m.y - press.y) < 6) return
                            moved = true
                            win.dragGrab = press
                            win.dragText = cardSlot.modelData.text
                            win.dragCol = column.index
                            win.dragIdx = cardSlot.index
                          }
                          win.dragPos = p
                          var t = win.dropTarget(p.x, p.y)
                          win.hoverCol = t.col; win.hoverIdx = t.idx
                        }
                        onReleased: function(m) {
                          if (win.dragCol < 0) return
                          var p = mapToItem(boardArea, m.x, m.y)
                          var t = win.dropTarget(p.x, p.y)
                          var fc = win.dragCol, fi = win.dragIdx
                          win.dragCol = -1; win.dragIdx = -1; win.hoverCol = -1; win.hoverIdx = -1
                          root.moveCard(fc, fi, t.col, t.idx)
                        }
                        onDoubleClicked: {
                          openTimer.stop()
                          editor.text = cardSlot.modelData.text
                          card.editing = true
                          editor.forceActiveFocus()
                          editor.cursorPosition = editor.length
                        }
                      }

                      // Footer: due date, checklist progress, description, attachments, members
                      Row {
                        visible: card.hasFooter
                        x: 14
                        anchors { bottom: parent.bottom; bottomMargin: 10 }
                        spacing: 10
                        Rectangle {
                          id: dueChip
                          visible: card.due !== "none"
                          readonly property color tone: card.due === "complete" ? "#5be38c" : card.due === "overdue" ? root.badColor : card.due === "soon" ? "#f2c35b" : root.mutedColor
                          width: dueLabel.implicitWidth + 14; height: 20; radius: 6
                          color: Qt.alpha(tone, dueHover.hovered ? 0.28 : (card.due === "later" ? 0.10 : 0.16))
                          Plain {
                            id: dueLabel
                            anchors.centerIn: parent
                            font.pixelSize: 11
                            color: dueChip.tone
                            text: (card.due === "complete" ? "\uf00c " : "\uf017 ") + (card.due !== "none" ? root.dueText(card.d) : "")
                          }
                          HoverHandler { id: dueHover; cursorShape: Qt.PointingHandCursor }
                          TapHandler { onTapped: root.toggleDue(column.index, cardSlot.index) }
                        }
                        Plain {
                          visible: (card.d.checkTotal || 0) > 0
                          anchors.verticalCenter: parent.verticalCenter
                          font.pixelSize: 11
                          color: card.d.checkDone === card.d.checkTotal ? "#5be38c" : root.mutedColor
                          text: "\uf046 " + (card.d.checkDone || 0) + "/" + (card.d.checkTotal || 0)
                        }
                        Plain {
                          visible: !!card.d.hasDesc
                          anchors.verticalCenter: parent.verticalCenter
                          font.pixelSize: 11; color: root.faintColor
                          text: "\uf036"
                        }
                        Plain {
                          visible: (card.d.att || 0) > 0
                          anchors.verticalCenter: parent.verticalCenter
                          font.pixelSize: 11; color: root.faintColor
                          text: "\uf0c6 " + (card.d.att || 0)
                        }
                      }
                      Row {
                        visible: card.members.length > 0
                        anchors { right: parent.right; rightMargin: 12; bottom: parent.bottom; bottomMargin: 9 }
                        spacing: -5
                        Repeater {
                          model: card.members
                          Rectangle {
                            required property var modelData
                            required property int index
                            width: 22; height: 22; radius: 11
                            color: Qt.tint(root.cardColor, Qt.alpha(root.heads[index % root.heads.length], 0.45))
                            border.width: 1; border.color: root.cardColor
                            Plain { anchors.centerIn: parent; font.pixelSize: 9; font.weight: Font.Bold; text: parent.modelData }
                          }
                        }
                        Plain {
                          visible: (card.d.extraMembers || 0) > 0
                          anchors.verticalCenter: parent.verticalCenter
                          leftPadding: 9
                          font.pixelSize: 10; color: root.faintColor
                          text: "+" + (card.d.extraMembers || 0)
                        }
                      }

                      // Delete (archive, in synced mode) button
                      Rectangle {
                        visible: hover.hovered && !card.editing && !card.unsaved && win.dragCol < 0
                        width: 22; height: 22; radius: 11
                        anchors { right: parent.right; top: parent.top; margins: 7 }
                        color: delHover.hovered ? "#3a1d2a" : "transparent"
                        Plain { anchors.centerIn: parent; text: "×"; font.pixelSize: 16; color: delHover.hovered ? root.badColor : root.mutedColor }
                        HoverHandler { id: delHover; cursorShape: Qt.PointingHandCursor }
                        TapHandler { onTapped: root.deleteCard(column.index, cardSlot.index) }
                      }
                    }
                  }
                }

                // Drop indicator at the end of the column
                Rectangle {
                  visible: win.dragCol >= 0 && win.hoverCol === column.index && win.hoverIdx === cardRep.count
                  width: parent.width; height: 2; radius: 1
                  color: column.head
                }

                // Add card
                Rectangle {
                  id: adder
                  visible: column.usable
                  width: parent.width
                  height: column.adding ? Math.max(56, newText.contentHeight + 30) : 40
                  radius: 12
                  color: column.adding ? root.cardHover : (addHover.hovered ? Qt.alpha(column.head, 0.10) : "transparent")
                  border.width: column.adding ? 1 : 0
                  border.color: column.head

                  Plain {
                    visible: !column.adding
                    anchors { left: parent.left; leftMargin: 14; verticalCenter: parent.verticalCenter }
                    text: "+  Add a card"
                    font.pixelSize: 13
                    color: addHover.hovered ? column.head : root.faintColor
                  }
                  HoverHandler { id: addHover; cursorShape: Qt.PointingHandCursor }
                  TapHandler {
                    enabled: !column.adding
                    onTapped: { column.adding = true; newText.text = ""; newText.forceActiveFocus() }
                  }

                  TextEdit {
                    id: newText
                    visible: column.adding
                    x: 14; y: 15
                    width: parent.width - 28
                    wrapMode: TextEdit.Wrap
                    textFormat: TextEdit.PlainText
                    font.family: Style.fontFamily
                    font.pixelSize: 13
                    color: root.textColor
                    selectionColor: Qt.alpha(column.head, 0.5)
                    Plain {
                      visible: newText.text.length === 0
                      text: "What needs doing?  (Enter to add, Esc to close)"
                      font.pixelSize: 13
                      color: root.faintColor
                      width: parent.width; elide: Text.ElideRight
                    }
                    Keys.onPressed: function(e) {
                      if ((e.key === Qt.Key_Return || e.key === Qt.Key_Enter) && !(e.modifiers & Qt.ShiftModifier)) {
                        if (text.trim().length) { root.addCard(column.index, text); text = "" }
                        else column.adding = false
                        e.accepted = true
                      } else if (e.key === Qt.Key_Escape) {
                        column.adding = false
                        e.accepted = true
                      }
                    }
                    onActiveFocusChanged: if (!activeFocus && column.adding) {
                      if (text.trim().length) root.addCard(column.index, text)
                      column.adding = false
                    }
                  }
                }
              }
            }
          }
        }

        // List picker: which list a column shows.
        Item {
          anchors.fill: parent
          visible: root.listMenuCol >= 0 && root.synced
          z: 20
          MouseArea {
            anchors.fill: parent
            acceptedButtons: Qt.AllButtons
            onClicked: root.listMenuCol = -1
            onWheel: function(w) { w.accepted = true }
          }
          Rectangle {
            readonly property int col: Math.max(0, root.listMenuCol)
            x: Math.round(root.colPos(col) * win.stride) + 10
            y: 46
            width: Math.round(win.cw) - 20
            height: Math.min(parent.height - 60, Math.max(48, listMenu.height + 16))
            radius: 14
            color: "#15121f"
            border.width: 1
            border.color: Qt.alpha(root.heads[col], 0.7)
            MouseArea { anchors.fill: parent; acceptedButtons: Qt.AllButtons }
            Flickable {
              anchors { fill: parent; margins: 8 }
              contentHeight: listMenu.height
              clip: true
              boundsBehavior: Flickable.StopAtBounds
              Column {
                id: listMenu
                width: parent.width
                spacing: 2
                Plain {
                  visible: root.allLists.length === 0
                  padding: 8
                  font.pixelSize: 12; color: root.mutedColor
                  text: "This board has no lists yet."
                }
                Rectangle {
                  width: listMenu.width
                  height: 34; radius: 8
                  color: clearHover.hovered ? "#241f35" : "transparent"
                  Plain {
                    anchors { left: parent.left; leftMargin: 28; verticalCenter: parent.verticalCenter }
                    font.pixelSize: 12; font.italic: true; color: root.mutedColor
                    text: "Leave this slot empty"
                  }
                  HoverHandler { id: clearHover; cursorShape: Qt.PointingHandCursor }
                  TapHandler { onTapped: root.pickList(root.listMenuCol, "") }
                }
                Repeater {
                  model: root.allLists
                  Rectangle {
                    id: listRow
                    required property var modelData
                    // Which desktop column already shows this list, or -1.
                    readonly property int shownIn: {
                      for (var c = 0; c < root.board.columns.length; c++)
                        if (root.board.columns[c].listId === modelData.id) return c
                      return -1
                    }
                    readonly property bool current: shownIn === root.listMenuCol
                    width: listMenu.width
                    height: 34; radius: 8
                    color: listRowHover.hovered ? "#241f35" : "transparent"
                    Rectangle {
                      x: 10; width: 8; height: 8; radius: 4
                      anchors.verticalCenter: parent.verticalCenter
                      color: listRow.shownIn >= 0 ? root.heads[listRow.shownIn] : "transparent"
                      border.width: listRow.shownIn >= 0 ? 0 : 1
                      border.color: root.faintColor
                    }
                    Plain {
                      anchors { left: parent.left; leftMargin: 28; right: swapHint.left; rightMargin: 6; verticalCenter: parent.verticalCenter }
                      elide: Text.ElideRight
                      font.pixelSize: 13; font.weight: listRow.current ? Font.Bold : Font.Normal
                      color: listRow.current ? root.textColor : (listRow.shownIn >= 0 ? root.mutedColor : root.textColor)
                      text: listRow.modelData.name
                    }
                    Plain {
                      id: swapHint
                      anchors { right: parent.right; rightMargin: 10; verticalCenter: parent.verticalCenter }
                      font.pixelSize: 10; color: root.faintColor
                      text: listRow.current ? "\uf00c" : (listRow.shownIn >= 0 ? "swap" : "")
                    }
                    HoverHandler { id: listRowHover; cursorShape: Qt.PointingHandCursor }
                    TapHandler { onTapped: root.pickList(root.listMenuCol, listRow.modelData.id) }
                  }
                }
              }
            }
          }
        }

        // Card detail: click a card to read it in full.
        Item {
          id: detail
          anchors.fill: parent
          z: 10
          readonly property var hit: root.findCard(root.openCardId)
          readonly property var card: hit ? hit.card : null
          readonly property var more: { root.detailRev; return (card && root.detailMap[card.id]) || { desc: "", checklists: [], members: [] } }
          readonly property color head: hit ? root.heads[hit.col] : root.heads[1]
          visible: card !== null
          // The card was archived, deleted or moved off the desktop while open.
          onHitChanged: if (!hit && root.openCardId) root.openCardId = ""
          property bool descEditing: false
          property bool dueOpen: false
          property var pickMonth: new Date()   // first day of the month the calendar shows
          property bool membersOpen: false
          property bool labelsOpen: false
          property string attConfirm: ""     // attachment id waiting for "delete?"
          readonly property var atts: { root.attRev; return card ? root.attList(card.id, false) : [] }
          readonly property var archivedAtts: { root.attRev; return card ? root.attList(card.id, true) : [] }
          property bool showArchived: false
          function toggleLabelsPicker() {
            dueOpen = false
            membersOpen = false
            labelsOpen = !labelsOpen
            if (labelsOpen) Qt.callLater(function() {
              var bottom = labelsPicker.y + labelsPicker.height + 8 - sheetFlick.height
              var max = Math.max(0, sheetFlick.contentHeight - sheetFlick.height)
              if (bottom > sheetFlick.contentY) sheetFlick.contentY = Math.min(bottom, max)
            })
          }
          function toggleMembersPicker() {
            labelsOpen = false
            dueOpen = false
            membersOpen = !membersOpen
            if (membersOpen) Qt.callLater(function() {
              var bottom = membersPicker.y + membersPicker.height + 8 - sheetFlick.height
              var max = Math.max(0, sheetFlick.contentHeight - sheetFlick.height)
              if (bottom > sheetFlick.contentY) sheetFlick.contentY = Math.min(bottom, max)
            })
          }
          function toggleDuePicker() {
            labelsOpen = false
            membersOpen = false
            var base = card && card.due ? new Date(card.due) : new Date()
            pickMonth = new Date(base.getFullYear(), base.getMonth(), 1)
            dueOpen = !dueOpen
            if (dueOpen) Qt.callLater(function() {
              // Bring the whole picker, quick buttons included, into view.
              var bottom = duePicker.y + duePicker.height + 8 - sheetFlick.height
              var max = Math.max(0, sheetFlick.contentHeight - sheetFlick.height)
              if (bottom > sheetFlick.contentY) sheetFlick.contentY = Math.min(bottom, max)
            })
          }
          function pickDay(d) {
            dueOpen = false
            root.setDue(root.openCardId, d.getFullYear(), d.getMonth(), d.getDate())
          }
          property string ckEdit: ""       // "ci:ii:ki" of the item being renamed
          property string ckSubFor: ""     // "ci:ii:-1" of the item getting a sub-item
          readonly property string openId: root.openCardId
          onOpenIdChanged: { descEditing = false; ckEdit = ""; ckSubFor = ""; dueOpen = false; membersOpen = false; labelsOpen = false; attConfirm = ""; showArchived = false; root.attNote = ""; if (openId) root.refreshAttachments(openId) }
          function startDescEdit() {
            descEditor.text = detail.more.desc
            descEditing = true
            descEditor.forceActiveFocus()
            descEditor.cursorPosition = descEditor.length
          }
          function saveDescEdit() {
            if (!descEditing) return
            descEditing = false
            root.saveDesc(root.openCardId, descEditor.text)
            sheet.forceActiveFocus()
          }
          function cancelDescEdit() { descEditing = false; sheet.forceActiveFocus() }

          Rectangle {   // scrim; click outside the panel closes it
            anchors.fill: parent
            radius: Math.round(24 * win.s)
            color: Qt.alpha("#08070d", 0.72)
            // A MouseArea, so nothing reaches the cards underneath.
            MouseArea {
              anchors.fill: parent
              hoverEnabled: true
              acceptedButtons: Qt.AllButtons
              onClicked: if (!detail.descEditing) root.openCardId = ""
              onWheel: function(w) { w.accepted = true }
            }
          }

          Rectangle {
            id: sheet
            anchors.centerIn: parent
            width: Math.min(600, parent.width - 60)
            height: Math.min(parent.height - 24, sheetBody.height + 72)
            radius: 16
            color: "#15121f"
            border.width: 1
            border.color: Qt.alpha(detail.head, 0.7)
            focus: detail.visible
            Keys.onEscapePressed: root.openCardId = ""
            MouseArea { anchors.fill: parent; acceptedButtons: Qt.AllButtons; onWheel: function(w) { w.accepted = true } }   // clicks on the panel don't close it

            Flickable {
              id: sheetFlick
              anchors { fill: parent; margins: 20; bottomMargin: 52 }
              contentHeight: sheetBody.height
              clip: true
              boundsBehavior: Flickable.StopAtBounds

              Column {
                id: sheetBody
                width: sheetFlick.width
                spacing: 14

                Column {
                  width: parent.width
                  spacing: 6
                  Plain {
                    width: parent.width - 30
                    wrapMode: Text.Wrap
                    font.pixelSize: 17; font.weight: Font.Bold
                    text: detail.card ? detail.card.text : ""
                  }
                  Row {
                    spacing: 7
                    Rectangle { width: 8; height: 8; radius: 4; color: detail.head; anchors.verticalCenter: parent.verticalCenter }
                    Plain {
                      font.pixelSize: 12; color: root.mutedColor
                      text: detail.hit ? "in " + root.board.columns[detail.hit.col].title : ""
                    }
                  }
                }

                // Labels, with their names
                Flow {
                  visible: !!detail.card
                  width: parent.width
                  spacing: 6
                  Repeater {
                    model: detail.card ? (detail.card.labels || []) : []
                    Rectangle {
                      required property var modelData
                      height: 22; radius: 6
                      width: Math.max(40, Math.min(220, tagText.implicitWidth + 18))
                      color: Qt.alpha(modelData.c, 0.22)
                      border.width: 1; border.color: Qt.alpha(modelData.c, 0.7)
                      Plain {
                        id: tagText
                        anchors.centerIn: parent
                        width: Math.min(implicitWidth, 202)
                        elide: Text.ElideRight
                        font.pixelSize: 11
                        text: parent.modelData.n
                      }
                    }
                  }
                  Rectangle {
                    width: labelsChipText.implicitWidth + 16; height: 22; radius: 6
                    color: Qt.alpha(root.mutedColor, labelsChipHover.hovered || detail.labelsOpen ? 0.3 : 0.16)
                    border.width: detail.labelsOpen ? 1 : 0
                    border.color: root.mutedColor
                    Plain {
                      id: labelsChipText
                      anchors.centerIn: parent
                      font.pixelSize: 11; color: root.mutedColor
                      text: detail.card && (detail.card.labels || []).length ? "\uf040 Labels" : "\uf02b Add labels"
                    }
                    HoverHandler { id: labelsChipHover; cursorShape: Qt.PointingHandCursor }
                    TapHandler { onTapped: detail.toggleLabelsPicker() }
                  }
                }

                // Labels picker
                Rectangle {
                  id: labelsPicker
                  visible: detail.labelsOpen && !!detail.card
                  width: Math.min(parent.width, 330)
                  height: Math.min(260, labelsCol.height + 16)
                  radius: 12
                  color: root.cardColor
                  border.width: 1
                  border.color: Qt.alpha(detail.head, 0.7)
                  readonly property var ids: detail.more.labelIds || []
                  Flickable {
                    anchors { fill: parent; margins: 8 }
                    contentHeight: labelsCol.height
                    clip: true
                    boundsBehavior: Flickable.StopAtBounds
                    Column {
                      id: labelsCol
                      width: parent.width
                      spacing: 2
                      Plain {
                        visible: root.boardLabels.length === 0
                        padding: 8
                        width: parent.width
                        wrapMode: Text.Wrap
                        font.pixelSize: 12; color: root.mutedColor
                        text: "This board has no labels yet. Create them on the full site."
                      }
                      Repeater {
                        model: root.boardLabels
                        Rectangle {
                          id: labelRow
                          required property var modelData
                          readonly property bool on: labelsPicker.ids.indexOf(modelData.id) !== -1
                          width: labelsCol.width
                          height: 34; radius: 8
                          color: labelRowHover.hovered ? "#2d2742" : "transparent"
                          Rectangle {
                            x: 8; width: 34; height: 14; radius: 4
                            anchors.verticalCenter: parent.verticalCenter
                            color: labelRow.modelData.c
                            opacity: labelRow.on ? 1 : 0.55
                          }
                          Plain {
                            anchors { left: parent.left; leftMargin: 52; right: labelTick.left; rightMargin: 6; verticalCenter: parent.verticalCenter }
                            elide: Text.ElideRight
                            font.pixelSize: 13
                            font.weight: labelRow.on ? Font.Bold : Font.Normal
                            color: labelRow.modelData.n.length ? (labelRow.on ? root.textColor : root.mutedColor) : root.faintColor
                            text: labelRow.modelData.n.length ? labelRow.modelData.n : "(no name)"
                          }
                          Plain {
                            id: labelTick
                            anchors { right: parent.right; rightMargin: 10; verticalCenter: parent.verticalCenter }
                            font.pixelSize: 12
                            color: labelRow.on ? "#5be38c" : root.faintColor
                            text: labelRow.on ? "\uf046" : "\uf096"
                          }
                          HoverHandler { id: labelRowHover; cursorShape: Qt.PointingHandCursor }
                          TapHandler { onTapped: root.toggleLabel(root.openCardId, labelRow.modelData.id) }
                        }
                      }
                    }
                  }
                }

                // Due date, attachments, members
                Flow {
                  visible: !!detail.card
                  width: parent.width
                  spacing: 12
                  Rectangle {
                    id: detailDue
                    readonly property string st: detail.card ? root.dueState(detail.card) : "none"
                    readonly property color tone: st === "complete" ? "#5be38c" : st === "overdue" ? root.badColor : st === "soon" ? "#f2c35b" : root.mutedColor
                    width: detailDueText.implicitWidth + 16; height: 22; radius: 6
                    color: Qt.alpha(tone, dueChipHover.hovered || detail.dueOpen ? 0.3 : 0.16)
                    border.width: detail.dueOpen ? 1 : 0
                    border.color: tone
                    HoverHandler { id: dueChipHover; cursorShape: Qt.PointingHandCursor }
                    TapHandler { onTapped: detail.toggleDuePicker() }
                    Plain {
                      id: detailDueText
                      anchors.centerIn: parent
                      font.pixelSize: 11; color: detailDue.tone
                      text: detailDue.st === "none" ? "\uf017 Add due date" : (detailDue.st === "complete" ? "\uf00c Done · " : detailDue.st === "overdue" ? "\uf017 Overdue · " : "\uf017 Due ") + root.dueLong(detail.card)
                    }
                  }
                  Plain {
                    id: detailAtt
                    visible: !!detail.card && (detail.card.att || 0) > 0
                    height: 22; verticalAlignment: Text.AlignVCenter
                    font.pixelSize: 11; color: root.mutedColor
                    text: detail.card ? "\uf0c6 " + (detail.card.att || 0) + (detail.card.att === 1 ? " attachment" : " attachments") : ""
                  }
                  Repeater {
                    model: detail.more.members
                    Row {
                      required property var modelData
                      spacing: 5
                      Rectangle {
                        width: 22; height: 22; radius: 11
                        color: Qt.tint(root.cardColor, Qt.alpha(detail.head, 0.45))
                        Plain { anchors.centerIn: parent; font.pixelSize: 9; font.weight: Font.Bold; text: parent.parent.modelData.ini }
                      }
                      Plain { height: 22; verticalAlignment: Text.AlignVCenter; font.pixelSize: 11; color: root.mutedColor; text: parent.modelData.name }
                    }
                  }
                  Rectangle {
                    width: membersChipText.implicitWidth + 16; height: 22; radius: 6
                    color: Qt.alpha(root.mutedColor, membersChipHover.hovered || detail.membersOpen ? 0.3 : 0.16)
                    border.width: detail.membersOpen ? 1 : 0
                    border.color: root.mutedColor
                    Plain {
                      id: membersChipText
                      anchors.centerIn: parent
                      font.pixelSize: 11; color: root.mutedColor
                      text: detail.more.members.length ? "\uf040 Members" : "\uf007 Add members"
                    }
                    HoverHandler { id: membersChipHover; cursorShape: Qt.PointingHandCursor }
                    TapHandler { onTapped: detail.toggleMembersPicker() }
                  }
                }

                // Members picker
                Rectangle {
                  id: membersPicker
                  visible: detail.membersOpen && !!detail.card
                  width: Math.min(parent.width, 330)
                  height: Math.min(260, membersCol.height + 16)
                  radius: 12
                  color: root.cardColor
                  border.width: 1
                  border.color: Qt.alpha(detail.head, 0.7)
                  readonly property var ids: detail.more.memberIds || []
                  Flickable {
                    anchors { fill: parent; margins: 8 }
                    contentHeight: membersCol.height
                    clip: true
                    boundsBehavior: Flickable.StopAtBounds
                    Column {
                      id: membersCol
                      width: parent.width
                      spacing: 2
                      Plain {
                        visible: root.boardMembers.length === 0
                        padding: 8
                        font.pixelSize: 12; color: root.mutedColor
                        text: "This board has no members to assign."
                      }
                      Repeater {
                        model: root.boardMembers
                        Rectangle {
                          id: memberRow
                          required property var modelData
                          readonly property bool on: membersPicker.ids.indexOf(modelData.id) !== -1
                          width: membersCol.width
                          height: 34; radius: 8
                          color: memberRowHover.hovered ? "#2d2742" : "transparent"
                          Rectangle {
                            x: 8; width: 22; height: 22; radius: 11
                            anchors.verticalCenter: parent.verticalCenter
                            color: Qt.tint(root.cardColor, Qt.alpha(detail.head, memberRow.on ? 0.6 : 0.25))
                            Plain { anchors.centerIn: parent; font.pixelSize: 9; font.weight: Font.Bold; text: memberRow.modelData.ini }
                          }
                          Plain {
                            anchors { left: parent.left; leftMargin: 40; right: memberTick.left; rightMargin: 6; verticalCenter: parent.verticalCenter }
                            elide: Text.ElideRight
                            font.pixelSize: 13
                            font.weight: memberRow.on ? Font.Bold : Font.Normal
                            color: memberRow.on ? root.textColor : root.mutedColor
                            text: memberRow.modelData.name
                          }
                          Plain {
                            id: memberTick
                            anchors { right: parent.right; rightMargin: 10; verticalCenter: parent.verticalCenter }
                            font.pixelSize: 12
                            color: memberRow.on ? "#5be38c" : root.faintColor
                            text: memberRow.on ? "\uf046" : "\uf096"
                          }
                          HoverHandler { id: memberRowHover; cursorShape: Qt.PointingHandCursor }
                          TapHandler { onTapped: root.toggleMember(root.openCardId, memberRow.modelData.id) }
                        }
                      }
                    }
                  }
                }

                // Due date picker
                Rectangle {
                  id: duePicker
                  visible: detail.dueOpen && !!detail.card
                  width: Math.min(parent.width, 330)
                  height: dueCol.height + 24
                  radius: 12
                  color: root.cardColor
                  border.width: 1
                  border.color: Qt.alpha(detail.head, 0.7)

                  readonly property var month: detail.pickMonth
                  readonly property var due: detail.card && detail.card.due ? new Date(detail.card.due) : null
                  readonly property int firstDow: root.loc().firstDayOfWeek
                  readonly property int offset: (month.getDay() - firstDow + 7) % 7
                  readonly property real cell: Math.floor((width - 24) / 7)
                  function sameDay(a, b) { return !!a && !!b && a.getFullYear() === b.getFullYear() && a.getMonth() === b.getMonth() && a.getDate() === b.getDate() }
                  function shiftMonth(n) { detail.pickMonth = new Date(month.getFullYear(), month.getMonth() + n, 1) }
                  function fromToday(days) { var t = new Date(); return new Date(t.getFullYear(), t.getMonth(), t.getDate() + days) }

                  Column {
                    id: dueCol
                    x: 12; y: 12
                    width: parent.width - 24
                    spacing: 8

                    Item {
                      width: parent.width; height: 24
                      CkBtn { glyph: "\uf053"; tone: detail.head; onTapped: duePicker.shiftMonth(-1) }
                      Plain {
                        anchors.centerIn: parent
                        font.pixelSize: 13; font.weight: Font.Bold
                        text: root.loc().toString(duePicker.month, "MMMM yyyy")
                      }
                      CkBtn { anchors.right: parent.right; glyph: "\uf054"; tone: detail.head; onTapped: duePicker.shiftMonth(1) }
                    }

                    Row {
                      Repeater {
                        model: 7
                        Plain {
                          required property int index
                          width: duePicker.cell
                          horizontalAlignment: Text.AlignHCenter
                          font.pixelSize: 10; color: root.faintColor
                          text: root.loc().dayName((duePicker.firstDow + index) % 7, Locale.ShortFormat)
                        }
                      }
                    }

                    Grid {
                      columns: 7
                      Repeater {
                        // Five weeks unless the month spills into a sixth.
                        model: duePicker.offset + new Date(duePicker.month.getFullYear(), duePicker.month.getMonth() + 1, 0).getDate() > 35 ? 42 : 35
                        Item {
                          id: dayCell
                          required property int index
                          readonly property var date: new Date(duePicker.month.getFullYear(), duePicker.month.getMonth(), 1 - duePicker.offset + index)
                          readonly property bool inMonth: date.getMonth() === duePicker.month.getMonth()
                          readonly property bool picked: duePicker.sameDay(date, duePicker.due)
                          readonly property bool today: { root.now; return duePicker.sameDay(date, new Date()) }
                          width: duePicker.cell; height: 28
                          Rectangle {
                            anchors.centerIn: parent
                            width: 26; height: 26; radius: 13
                            color: dayCell.picked ? detail.head : (dayHover.hovered ? "#2d2742" : "transparent")
                            border.width: dayCell.today && !dayCell.picked ? 1 : 0
                            border.color: detail.head
                          }
                          Plain {
                            anchors.centerIn: parent
                            font.pixelSize: 12
                            font.weight: dayCell.picked || dayCell.today ? Font.Bold : Font.Normal
                            color: dayCell.picked ? "#0d0b14" : (dayCell.inMonth ? root.textColor : root.faintColor)
                            text: dayCell.date.getDate()
                          }
                          HoverHandler { id: dayHover; cursorShape: Qt.PointingHandCursor }
                          TapHandler { onTapped: detail.pickDay(dayCell.date) }
                        }
                      }
                    }

                    Flow {
                      width: parent.width
                      spacing: 6
                      Repeater {
                        model: [ { t: "Today", d: 0 }, { t: "Tomorrow", d: 1 }, { t: "In a week", d: 7 } ]
                        Rectangle {
                          required property var modelData
                          width: quickText.implicitWidth + 18; height: 24; radius: 12
                          color: quickHover.hovered ? Qt.alpha(detail.head, 0.3) : Qt.alpha(detail.head, 0.14)
                          Plain { id: quickText; anchors.centerIn: parent; font.pixelSize: 11; text: parent.modelData.t }
                          HoverHandler { id: quickHover; cursorShape: Qt.PointingHandCursor }
                          TapHandler { onTapped: detail.pickDay(duePicker.fromToday(parent.modelData.d)) }
                        }
                      }
                      Rectangle {
                        visible: duePicker.due !== null
                        width: doneText.implicitWidth + 18; height: 24; radius: 12
                        color: doneHover.hovered ? Qt.alpha("#5be38c", 0.3) : Qt.alpha("#5be38c", 0.14)
                        Plain { id: doneText; anchors.centerIn: parent; font.pixelSize: 11; color: "#5be38c"; text: detail.card && detail.card.dueComplete ? "Mark not done" : "\uf00c Mark done" }
                        HoverHandler { id: doneHover; cursorShape: Qt.PointingHandCursor }
                        TapHandler { onTapped: if (detail.hit) root.toggleDue(detail.hit.col, detail.hit.idx) }
                      }
                      Rectangle {
                        visible: duePicker.due !== null
                        width: removeText.implicitWidth + 18; height: 24; radius: 12
                        color: removeHover.hovered ? Qt.alpha(root.badColor, 0.3) : "transparent"
                        border.width: 1; border.color: Qt.alpha(root.badColor, 0.5)
                        Plain { id: removeText; anchors.centerIn: parent; font.pixelSize: 11; color: root.badColor; text: "Remove date" }
                        HoverHandler { id: removeHover; cursorShape: Qt.PointingHandCursor }
                        TapHandler { onTapped: { detail.dueOpen = false; root.clearDue(root.openCardId) } }
                      }
                    }
                  }
                }

                // Description
                Column {
                  width: parent.width
                  spacing: 6
                  Item {
                    width: parent.width
                    height: 20
                    Plain { anchors.verticalCenter: parent.verticalCenter; font.pixelSize: 11; font.weight: Font.Bold; color: root.faintColor; text: "DESCRIPTION" }
                    Rectangle {
                      visible: !detail.descEditing
                      anchors { right: parent.right; verticalCenter: parent.verticalCenter }
                      width: editText.implicitWidth + 18; height: 20; radius: 10
                      color: editHover.hovered ? Qt.alpha(detail.head, 0.28) : Qt.alpha(detail.head, 0.14)
                      Plain { id: editText; anchors.centerIn: parent; font.pixelSize: 11; text: "\uf040 Edit" }
                      HoverHandler { id: editHover; cursorShape: Qt.PointingHandCursor }
                      TapHandler { onTapped: detail.startDescEdit() }
                    }
                  }
                  // Reading: click the text to edit it.
                  Plain {
                    visible: !detail.descEditing
                    width: parent.width
                    wrapMode: Text.Wrap
                    font.pixelSize: 13
                    lineHeight: 1.25
                    color: detail.more.desc.trim().length ? root.textColor : root.faintColor
                    text: detail.more.desc.trim().length ? detail.more.desc.trim() : "No description. Click to add one."
                    HoverHandler { cursorShape: Qt.IBeamCursor }
                    TapHandler { onTapped: detail.startDescEdit() }
                  }
                  // Editing
                  Rectangle {
                    visible: detail.descEditing
                    width: parent.width
                    height: Math.max(110, descEditor.contentHeight + 24)
                    radius: 10
                    color: root.cardColor
                    border.width: 1
                    border.color: detail.head
                    TextEdit {
                      id: descEditor
                      anchors { fill: parent; margins: 12 }
                      wrapMode: TextEdit.Wrap
                      textFormat: TextEdit.PlainText
                      font.family: Style.fontFamily
                      font.pixelSize: 13
                      color: root.textColor
                      selectionColor: Qt.alpha(detail.head, 0.5)
                      selectByMouse: true
                      Keys.onPressed: function(e) {
                        if (e.key === Qt.Key_Escape) { detail.cancelDescEdit(); e.accepted = true }
                        else if ((e.key === Qt.Key_Return || e.key === Qt.Key_Enter) && (e.modifiers & Qt.ControlModifier)) { detail.saveDescEdit(); e.accepted = true }
                      }
                      // Keep the cursor in view while typing in a long description.
                      onCursorRectangleChanged: {
                        if (!detail.descEditing) return
                        var y = mapToItem(sheetBody, 0, cursorRectangle.y).y
                        if (y < sheetFlick.contentY) sheetFlick.contentY = Math.max(0, y - 10)
                        else if (y + cursorRectangle.height > sheetFlick.contentY + sheetFlick.height)
                          sheetFlick.contentY = y + cursorRectangle.height - sheetFlick.height + 10
                      }
                    }
                  }
                  Row {
                    visible: detail.descEditing
                    spacing: 8
                    Rectangle {
                      width: saveText.implicitWidth + 24; height: 26; radius: 13
                      color: saveHover.hovered ? Qt.alpha(detail.head, 0.5) : Qt.alpha(detail.head, 0.3)
                      border.width: 1; border.color: detail.head
                      Plain { id: saveText; anchors.centerIn: parent; font.pixelSize: 12; text: "Save" }
                      HoverHandler { id: saveHover; cursorShape: Qt.PointingHandCursor }
                      TapHandler { onTapped: detail.saveDescEdit() }
                    }
                    Rectangle {
                      width: cancelText.implicitWidth + 24; height: 26; radius: 13
                      color: cancelHover.hovered ? root.cardHover : "transparent"
                      border.width: 1; border.color: root.cardBorder
                      Plain { id: cancelText; anchors.centerIn: parent; font.pixelSize: 12; color: root.mutedColor; text: "Cancel" }
                      HoverHandler { id: cancelHover; cursorShape: Qt.PointingHandCursor }
                      TapHandler { onTapped: detail.cancelDescEdit() }
                    }
                    Plain {
                      anchors.verticalCenter: parent.verticalCenter
                      font.pixelSize: 11
                      color: descEditor.length > 20000 ? root.badColor : root.faintColor
                      text: descEditor.length > 20000 ? "Too long: only the first 20,000 characters are kept" : "Ctrl+Enter saves · Esc cancels"
                    }
                  }
                }

                // Checklists: tick, add, rename and delete items
                Repeater {
                  model: detail.more.checklists
                  Column {
                    id: clBlock
                    required property var modelData
                    required property int index
                    width: sheetBody.width
                    spacing: 4
                    Plain {
                      font.pixelSize: 11; font.weight: Font.Bold; color: root.faintColor
                      bottomPadding: 2
                      text: clBlock.modelData.name.toUpperCase() + "  " + clBlock.modelData.rows.filter(function(r) { return r.done }).length + "/" + clBlock.modelData.rows.length
                    }
                    Repeater {
                      model: clBlock.modelData.rows
                      Column {
                        id: rowWrap
                        required property var modelData
                        readonly property string key: modelData.ci + ":" + modelData.ii + ":" + modelData.ki
                        readonly property bool renaming: detail.ckEdit === key
                        readonly property bool addingSub: detail.ckSubFor === key
                        width: sheetBody.width
                        spacing: 4

                        Item {
                          id: rowItem
                          x: rowWrap.modelData.sub ? 22 : 0
                          width: parent.width - x
                          height: Math.max(24, rowWrap.renaming ? 28 : rowName.contentHeight + 4)
                          HoverHandler { id: rowHover }

                          Plain {
                            y: 2
                            font.pixelSize: 13
                            color: rowWrap.modelData.done ? "#5be38c" : (boxHover.hovered ? detail.head : root.mutedColor)
                            text: rowWrap.modelData.done ? "\uf046" : "\uf096"
                            HoverHandler { id: boxHover; cursorShape: Qt.PointingHandCursor }
                            TapHandler { onTapped: root.toggleCheck(root.openCardId, rowWrap.modelData.ci, rowWrap.modelData.ii, rowWrap.modelData.ki) }
                          }
                          Plain {
                            id: rowName
                            visible: !rowWrap.renaming
                            x: 22; y: 2
                            width: parent.width - 22 - 78
                            wrapMode: Text.Wrap
                            font.pixelSize: 13
                            font.strikeout: rowWrap.modelData.done
                            color: rowWrap.modelData.done ? root.faintColor : root.textColor
                            text: rowWrap.modelData.name
                            HoverHandler { cursorShape: Qt.PointingHandCursor }
                            TapHandler { onTapped: root.toggleCheck(root.openCardId, rowWrap.modelData.ci, rowWrap.modelData.ii, rowWrap.modelData.ki) }
                          }
                          Rectangle {
                            visible: rowWrap.renaming
                            x: 20
                            width: parent.width - 20
                            height: 28; radius: 8
                            color: root.cardColor
                            border.width: 1; border.color: detail.head
                            TextInput {
                              id: renameInput
                              anchors { fill: parent; leftMargin: 8; rightMargin: 8 }
                              verticalAlignment: TextInput.AlignVCenter
                              clip: true
                              maximumLength: 500
                              font.family: Style.fontFamily
                              font.pixelSize: 13
                              color: root.textColor
                              selectionColor: Qt.alpha(detail.head, 0.5)
                              function commit() {
                                if (!rowWrap.renaming) return
                                var m = rowWrap.modelData
                                detail.ckEdit = ""
                                root.renameCheck(root.openCardId, m.ci, m.ii, m.ki, text)
                              }
                              onVisibleChanged: if (visible) { text = rowWrap.modelData.name; forceActiveFocus(); selectAll() }
                              Keys.onPressed: function(e) {
                                if (e.key === Qt.Key_Return || e.key === Qt.Key_Enter) { commit(); e.accepted = true }
                                else if (e.key === Qt.Key_Escape) { detail.ckEdit = ""; e.accepted = true }
                              }
                              onActiveFocusChanged: if (!activeFocus) commit()
                            }
                          }
                          Row {
                            visible: rowHover.hovered && !rowWrap.renaming
                            anchors.right: parent.right
                            spacing: 2
                            CkBtn {
                              visible: !rowWrap.modelData.sub
                              glyph: "\uf067"; tone: detail.head
                              onTapped: { detail.ckEdit = ""; detail.ckSubFor = (rowWrap.addingSub ? "" : rowWrap.key) }
                            }
                            CkBtn { glyph: "\uf040"; tone: detail.head; onTapped: { detail.ckSubFor = ""; detail.ckEdit = rowWrap.key } }
                            CkBtn {
                              glyph: "\uf00d"; tone: root.badColor
                              onTapped: { detail.ckEdit = ""; detail.ckSubFor = ""; root.removeCheck(root.openCardId, rowWrap.modelData.ci, rowWrap.modelData.ii, rowWrap.modelData.ki) }
                            }
                          }
                        }

                        CkField {
                          visible: rowWrap.addingSub
                          x: 44
                          width: parent.width - 44
                          tone: detail.head
                          hint: "Add a sub-item…"
                          onVisibleChanged: if (visible) input.forceActiveFocus()
                          onSubmitted: function(text) { root.addSubCheck(root.openCardId, rowWrap.modelData.ci, rowWrap.modelData.ii, text) }
                          onCancelled: detail.ckSubFor = ""
                        }
                      }
                    }
                    CkField {
                      width: parent.width
                      tone: detail.head
                      hint: "Add an item…"
                      onSubmitted: function(text) { root.addCheck(root.openCardId, clBlock.index, text) }
                      onCancelled: sheet.forceActiveFocus()
                    }
                  }
                }

                // No checklist yet: the first item creates one.
                Column {
                  visible: detail.more.checklists.length === 0
                  width: parent.width
                  spacing: 6
                  Plain { font.pixelSize: 11; font.weight: Font.Bold; color: root.faintColor; text: "CHECKLIST" }
                  CkField {
                    width: parent.width
                    tone: detail.head
                    hint: "Add an item…"
                    onSubmitted: function(text) { root.addCheck(root.openCardId, -1, text) }
                    onCancelled: sheet.forceActiveFocus()
                  }
                }

                // Attachments
                Column {
                  width: parent.width
                  spacing: 6
                  Item {
                    width: parent.width
                    height: 22
                    Plain {
                      anchors.verticalCenter: parent.verticalCenter
                      font.pixelSize: 11; font.weight: Font.Bold; color: root.faintColor
                      text: "ATTACHMENTS" + (detail.atts.length ? "  " + detail.atts.length : "")
                    }
                    Rectangle {
                      anchors { right: parent.right; verticalCenter: parent.verticalCenter }
                      width: addFileText.implicitWidth + 18; height: 20; radius: 10
                      color: addFileHover.hovered ? Qt.alpha(detail.head, 0.28) : Qt.alpha(detail.head, 0.14)
                      Plain { id: addFileText; anchors.centerIn: parent; font.pixelSize: 11; text: "\uf067 Add file" }
                      HoverHandler { id: addFileHover; cursorShape: Qt.PointingHandCursor }
                      TapHandler { onTapped: root.pickFiles(root.openCardId) }
                    }
                  }
                  Plain {
                    visible: root.uploadsLeft > 0 || root.attNote.length > 0
                    width: parent.width
                    elide: Text.ElideRight
                    font.pixelSize: 11
                    color: root.attNoteBad && root.uploadsLeft === 0 ? root.badColor : root.mutedColor
                    text: root.uploadsLeft > 0 ? "Uploading " + root.uploadsLeft + (root.uploadsLeft === 1 ? " file…" : " files…") : root.attNote
                  }
                  Plain {
                    visible: detail.atts.length === 0 && root.uploadsLeft === 0
                    font.pixelSize: 13; color: root.faintColor
                    text: "No attachments."
                  }
                  Repeater {
                    model: detail.atts
                    Rectangle {
                      id: attRow
                      required property var modelData
                      readonly property bool image: modelData.kind === "image"
                      readonly property bool confirming: detail.attConfirm === modelData.id
                      readonly property int thumb: root.thumbState[modelData.id] || 0
                      width: sheetBody.width
                      height: 52; radius: 10
                      color: attRowHover.hovered ? root.cardHover : root.cardColor
                      border.width: 1
                      border.color: confirming ? root.badColor : root.cardBorder
                      HoverHandler { id: attRowHover }

                      Rectangle {
                        id: attThumb
                        x: 6; width: 40; height: 40; radius: 7
                        anchors.verticalCenter: parent.verticalCenter
                        color: "#15121f"
                        clip: true
                        Plain {
                          anchors.centerIn: parent
                          visible: attImage.status !== Image.Ready
                          font.pixelSize: 15; color: root.faintColor
                          text: attRow.image ? "\uf03e" : "\uf15b"
                        }
                        Image {
                          id: attImage
                          anchors.fill: parent
                          visible: status === Image.Ready
                          fillMode: Image.PreserveAspectCrop
                          asynchronous: true
                          cache: false
                          sourceSize.width: 120; sourceSize.height: 120
                          // Try the cached file first; fetch it if it isn't there, then show it.
                          source: attRow.image && attRow.thumb !== 1 && attRow.thumb !== 3 ? Util.fileUrl(root.thumbPath(attRow.modelData.id)) : ""
                          onStatusChanged: if (status === Image.Error && attRow.thumb === 0) root.wantThumb(attRow.modelData.id)
                        }
                      }
                      Column {
                        anchors { left: attThumb.right; leftMargin: 10; right: attButtons.left; rightMargin: 8; verticalCenter: parent.verticalCenter }
                        spacing: 2
                        Plain {
                          width: parent.width; elide: Text.ElideMiddle
                          font.pixelSize: 13
                          text: attRow.modelData.name
                        }
                        Plain {
                          width: parent.width; elide: Text.ElideRight
                          font.pixelSize: 10; color: attRow.confirming ? root.badColor : root.faintColor
                          text: attRow.confirming ? "Delete this file for good?"
                            : (attRow.image ? "Image" : "File") + " · " + root.sizeText(attRow.modelData.bytes)
                              + (attRow.modelData.at ? " · " + root.loc().toString(new Date(attRow.modelData.at), "d MMM yyyy") : "")
                        }
                      }
                      // Clicking the row opens an image or saves a file.
                      TapHandler { enabled: !attRow.confirming; onTapped: root.openAttachment(attRow.modelData) }
                      Row {
                        id: attButtons
                        anchors { right: parent.right; rightMargin: 8; verticalCenter: parent.verticalCenter }
                        spacing: 4
                        CkBtn {
                          visible: !attRow.confirming && attRowHover.hovered
                          glyph: attRow.image ? "\uf06e" : "\uf019"; tone: detail.head
                          onTapped: root.openAttachment(attRow.modelData)
                        }
                        CkBtn {
                          visible: !attRow.confirming && attRowHover.hovered
                          glyph: "\uf187"; tone: root.mutedColor
                          onTapped: { detail.showArchived = true; root.archiveAttachment(root.openCardId, attRow.modelData.id, true) }
                        }
                        Rectangle {
                          visible: attRow.confirming
                          width: attYes.implicitWidth + 18; height: 24; radius: 12
                          color: attYesHover.hovered ? Qt.alpha(root.badColor, 0.4) : Qt.alpha(root.badColor, 0.2)
                          Plain { id: attYes; anchors.centerIn: parent; font.pixelSize: 11; color: root.badColor; text: "Delete" }
                          HoverHandler { id: attYesHover; cursorShape: Qt.PointingHandCursor }
                          TapHandler { onTapped: { detail.attConfirm = ""; root.deleteAttachment(root.openCardId, attRow.modelData.id) } }
                        }
                        Rectangle {
                          visible: attRow.confirming
                          width: attNo.implicitWidth + 18; height: 24; radius: 12
                          color: attNoHover.hovered ? root.cardHover : "transparent"
                          border.width: 1; border.color: root.cardBorder
                          Plain { id: attNo; anchors.centerIn: parent; font.pixelSize: 11; color: root.mutedColor; text: "Keep" }
                          HoverHandler { id: attNoHover; cursorShape: Qt.PointingHandCursor }
                          TapHandler { onTapped: detail.attConfirm = "" }
                        }
                      }
                    }
                  }

                  // Archived attachments: restore, or delete for good.
                  Item {
                    visible: detail.archivedAtts.length > 0
                    width: parent.width
                    height: 24
                    Plain {
                      anchors.verticalCenter: parent.verticalCenter
                      font.pixelSize: 11; font.weight: Font.Bold
                      color: archToggleHover.hovered ? detail.head : root.faintColor
                      text: "ARCHIVED  " + detail.archivedAtts.length + "  " + (detail.showArchived ? "\uf077" : "\uf078")
                    }
                    HoverHandler { id: archToggleHover; cursorShape: Qt.PointingHandCursor }
                    TapHandler { onTapped: detail.showArchived = !detail.showArchived }
                  }
                  Repeater {
                    model: detail.showArchived ? detail.archivedAtts : []
                    Rectangle {
                      id: archRow
                      required property var modelData
                      readonly property bool confirming: detail.attConfirm === modelData.id
                      width: sheetBody.width
                      height: 44; radius: 10
                      color: "transparent"
                      border.width: 1
                      border.color: confirming ? root.badColor : root.cardBorder
                      Plain {
                        x: 14
                        anchors.verticalCenter: parent.verticalCenter
                        font.pixelSize: 14; color: root.faintColor
                        text: archRow.modelData.kind === "image" ? "\uf03e" : "\uf15b"
                      }
                      Column {
                        anchors { left: parent.left; leftMargin: 42; right: archButtons.left; rightMargin: 8; verticalCenter: parent.verticalCenter }
                        spacing: 1
                        Plain {
                          width: parent.width; elide: Text.ElideMiddle
                          font.pixelSize: 13; color: root.mutedColor
                          text: archRow.modelData.name
                        }
                        Plain {
                          width: parent.width; elide: Text.ElideRight
                          font.pixelSize: 10; color: archRow.confirming ? root.badColor : root.faintColor
                          text: archRow.confirming ? "Delete this file for good?" : "Archived · " + root.sizeText(archRow.modelData.bytes)
                        }
                      }
                      Row {
                        id: archButtons
                        anchors { right: parent.right; rightMargin: 8; verticalCenter: parent.verticalCenter }
                        spacing: 6
                        Rectangle {
                          visible: !archRow.confirming
                          width: archRestore.implicitWidth + 18; height: 24; radius: 12
                          color: archRestoreHover.hovered ? Qt.alpha(detail.head, 0.3) : Qt.alpha(detail.head, 0.14)
                          Plain { id: archRestore; anchors.centerIn: parent; font.pixelSize: 11; text: "Restore" }
                          HoverHandler { id: archRestoreHover; cursorShape: Qt.PointingHandCursor }
                          TapHandler { onTapped: root.archiveAttachment(root.openCardId, archRow.modelData.id, false) }
                        }
                        Rectangle {
                          visible: !archRow.confirming
                          width: archDelete.implicitWidth + 18; height: 24; radius: 12
                          color: archDeleteHover.hovered ? Qt.alpha(root.badColor, 0.3) : "transparent"
                          border.width: 1; border.color: Qt.alpha(root.badColor, 0.5)
                          Plain { id: archDelete; anchors.centerIn: parent; font.pixelSize: 11; color: root.badColor; text: "Delete forever" }
                          HoverHandler { id: archDeleteHover; cursorShape: Qt.PointingHandCursor }
                          TapHandler { onTapped: detail.attConfirm = archRow.modelData.id }
                        }
                        Rectangle {
                          visible: archRow.confirming
                          width: archYes.implicitWidth + 18; height: 24; radius: 12
                          color: archYesHover.hovered ? Qt.alpha(root.badColor, 0.4) : Qt.alpha(root.badColor, 0.2)
                          Plain { id: archYes; anchors.centerIn: parent; font.pixelSize: 11; color: root.badColor; text: "Delete" }
                          HoverHandler { id: archYesHover; cursorShape: Qt.PointingHandCursor }
                          TapHandler { onTapped: { detail.attConfirm = ""; root.deleteAttachment(root.openCardId, archRow.modelData.id) } }
                        }
                        Rectangle {
                          visible: archRow.confirming
                          width: archNo.implicitWidth + 18; height: 24; radius: 12
                          color: archNoHover.hovered ? root.cardHover : "transparent"
                          border.width: 1; border.color: root.cardBorder
                          Plain { id: archNo; anchors.centerIn: parent; font.pixelSize: 11; color: root.mutedColor; text: "Keep" }
                          HoverHandler { id: archNoHover; cursorShape: Qt.PointingHandCursor }
                          TapHandler { onTapped: detail.attConfirm = "" }
                        }
                      }
                    }
                  }
                }
              }
            }

            // Close
            Rectangle {
              width: 26; height: 26; radius: 13
              anchors { right: parent.right; top: parent.top; margins: 10 }
              color: closeHover.hovered ? root.cardHover : "transparent"
              Plain { anchors.centerIn: parent; text: "×"; font.pixelSize: 18; color: root.mutedColor }
              HoverHandler { id: closeHover; cursorShape: Qt.PointingHandCursor }
              TapHandler { onTapped: root.openCardId = "" }
            }

            // Footer
            Rectangle {
              anchors { left: parent.left; right: parent.right; bottom: parent.bottom; margins: 1 }
              height: 44
              color: "transparent"
              Rectangle {
                anchors { left: parent.left; right: parent.right; top: parent.top; leftMargin: 19; rightMargin: 19 }
                height: 1
                color: root.cardBorder
              }
              Rectangle {
                anchors { left: parent.left; leftMargin: 19; verticalCenter: parent.verticalCenter }
                width: openText.implicitWidth + 22; height: 26; radius: 13
                color: openHover.hovered ? Qt.alpha(detail.head, 0.3) : Qt.alpha(detail.head, 0.16)
                Plain { id: openText; anchors.centerIn: parent; font.pixelSize: 11; text: "Full site  \uf08e" }
                HoverHandler { id: openHover; cursorShape: Qt.PointingHandCursor }
                TapHandler { onTapped: root.openFullSite() }
              }
              Plain {
                anchors { right: parent.right; rightMargin: 19; verticalCenter: parent.verticalCenter }
                font.pixelSize: 11; color: root.faintColor
                text: detail.descEditing ? "Save or cancel your edit to close" : "Esc or click outside to close"
              }
            }
          }
        }

        // After archiving: undo, or delete for good.
        Rectangle {
          id: archivedBar
          readonly property var e: root.lastArchived
          visible: e !== null && root.synced
          x: Math.round(root.colPos(e ? e.col : 0) * win.stride) + 12
          y: parent.height - height - 44
          width: Math.round(win.cw) - 24
          height: 62; radius: 12
          color: "#1b1729"
          border.width: 1
          border.color: root.cardBorder
          Plain {
            x: 12; y: 9
            width: parent.width - 24
            elide: Text.ElideRight
            font.pixelSize: 11
            color: root.mutedColor
            text: "Archived: " + (archivedBar.e ? archivedBar.e.card.text.replace(/\s+/g, " ") : "")
          }
          Row {
            x: 12; y: 30; spacing: 8
            Rectangle {
              width: undoText.implicitWidth + 20; height: 22; radius: 11
              color: undoHover.hovered ? Qt.alpha(root.heads[1], 0.3) : Qt.alpha(root.heads[1], 0.16)
              Plain { id: undoText; anchors.centerIn: parent; font.pixelSize: 11; text: "Undo" }
              HoverHandler { id: undoHover; cursorShape: Qt.PointingHandCursor }
              TapHandler { onTapped: root.undoArchive() }
            }
            Rectangle {
              width: purgeText.implicitWidth + 20; height: 22; radius: 11
              color: purgeHover.hovered ? Qt.alpha(root.badColor, 0.3) : "transparent"
              border.width: 1; border.color: Qt.alpha(root.badColor, 0.5)
              Plain { id: purgeText; anchors.centerIn: parent; font.pixelSize: 11; color: root.badColor; text: "Delete forever" }
              HoverHandler { id: purgeHover; cursorShape: Qt.PointingHandCursor }
              TapHandler { onTapped: root.purgeArchived() }
            }
          }
        }

        // Card following the pointer while dragging
        Rectangle {
          visible: win.dragCol >= 0
          x: win.dragPos.x - win.dragGrab.x
          y: win.dragPos.y - win.dragGrab.y
          width: win.cw - 24
          height: Math.max(56, ghostLabel.contentHeight + 34)
          radius: 12
          rotation: 2
          color: root.cardHover
          border.width: 1
          border.color: root.heads[Math.max(0, win.hoverCol)]
          Rectangle { x: 14; y: 12; width: 40; height: 4; radius: 2; color: root.heads[Math.max(0, win.hoverCol)] }
          Plain {
            id: ghostLabel
            x: 14; y: 24
            width: parent.width - 28
            wrapMode: Text.Wrap
            font.pixelSize: 13
            text: win.dragText
          }
        }
      }
    }
  }
}
