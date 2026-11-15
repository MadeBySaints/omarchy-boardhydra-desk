import QtQuick
import Quickshell

ShellRoot {
  WorkspaceDesk { id: desk; workspace: QtObject { property int id: 901 } }
  Timer {
    interval: 1200; running: true
    onTriggered: {
      if (desk.dirsReady || desk.dataPath !== "" || desk.statePath !== "") {
        console.error("Unsafe storage was enabled")
        Qt.exit(1)
        return
      }
      desk.commitLocal({ columns: [{ title: "Confidential new card", cards: [] }] })
      desk.saveState()
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
