import QtQuick
import Quickshell

ShellRoot {
  Desk { id: service }
  readonly property var desk: service.boardDesk
  Timer {
    interval: 1200; running: true
    onTriggered: {
      if (desk.dirsReady || desk.dataPath !== "" || desk.statePath !== "") {
        console.error("Unsafe storage was enabled")
        Qt.exit(1)
        return
      }
      desk.commitLocal({ columns: [{ title: "Confidential", cards: [{ id: "secret", text: "Confidential new card" }] }] })
      desk.saveState()
      desk.templatesLoaded = true
      desk.saveTemplate(desk.board.columns[0].cards.length ? desk.board.columns[0].cards[0].id : "", "Unsafe template")
      verify.start()
    }
  }
  Timer {
    id: verify; interval: 300
    onTriggered: {
      console.log("PASS: unsafe ancestry keeps storage disabled during later saves")
      Qt.quit()
    }
  }
}
