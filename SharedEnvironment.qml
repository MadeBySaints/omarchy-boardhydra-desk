import QtQuick
import Quickshell
import Quickshell.Io

// One configuration watcher and wallpaper probe for the whole service.
Item {
  id: root
  property var baseCfg: null
  property bool baseLoaded: false
  property bool onBoardWallpaper: false

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
    path: Quickshell.env("HOME") + "/.config/boardhydra-desk/config.json"
    watchChanges: true
    onLoaded: {
      var c = null
      try { c = root.validConfig(JSON.parse(text())) } catch (e) { console.warn("boardhydra.desk: config is not valid JSON") }
      root.baseCfg = c
      root.baseLoaded = true
    }
    onLoadFailed: function(error) {
      root.baseCfg = null
      root.baseLoaded = true
    }
    onFileChanged: reload()
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

}
