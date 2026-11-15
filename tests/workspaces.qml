import QtQuick
import Quickshell
ShellRoot {
  WorkspaceDesk { id: first; workspace: QtObject { property int id: 901 } }
  WorkspaceDesk { id: second; workspace: QtObject { property int id: 902 } }
  Desk { id: service }
  Timer {
    interval: 1200; running: true
    onTriggered: {
      first.commitLocal({ columns: [{ title: "First workspace", cards: [] }] })
      second.commitLocal({ columns: [{ title: "Second workspace", cards: [] }] })
      first.pickedBoard = "board-first"
      second.pickedBoard = "board-second"
      first.saveState()
      second.saveState()
      verify.start()
    }
  }
  Timer {
    id: verify; interval: 800
    onTriggered: {
      if (first.board.columns[0].title !== "First workspace" || second.board.columns[0].title !== "Second workspace"
          || first.pickedBoard !== "board-first" || second.pickedBoard !== "board-second"
          || !service.focusedDesk()) { console.error("Workspace isolation failed"); Qt.exit(1); return }
      console.log("PASS: workspace cards, board selections and focused IPC routing")
      Qt.quit()
    }
  }
}
