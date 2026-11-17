import QtQuick
import Quickshell

ShellRoot {
  Desk { id: service }
  readonly property var desk: service.boardDesk
  readonly property bool syncedTest: Quickshell.env("BOARDHYDRA_TEST_SYNC") === "1"
  property int step: 0
  property int ticks: 0
  function check(ok, message) { if (!ok) { console.error(message); Qt.exit(1) }; return ok }
  Timer {
    interval: 200; repeat: true; running: true
    onTriggered: {
      ticks++
      if (ticks > 45) { console.error("Shared board test timed out at step " + step); Qt.exit(1); return }
      if (!desk.loaded || !desk.stateLoaded || desk.fetching || desk.writesInFlight) return
      if (step === 0) {
        if (!check(desk.dataPath.endsWith("/board.json") && desk.statePath.endsWith("/state.json"), "Board is not shared")) return
        if (!syncedTest) {
          if (!check(desk.board.columns[0].title === "Migrated" && desk.pickedBoard === "migrated-board" && desk.appearance.preset === "holo", "Workspace migration lost cards or appearance")) return
        }
        desk.sharedEnvironment.onBoardWallpaper = true
        desk.setAppearance({ preset: "holo", motion: false })
        desk.appearanceOpen = true
        desk.toggleComplete("test-card")
        if (!check(desk.findCard("test-card").card.dueComplete, "Card without a due date did not complete immediately")) return
        step = 1
      } else if (step === 1) {
        var hit = desk.findCard("test-card")
        if (!check(hit && hit.card.dueComplete, "Completion was not persisted or returned by API")) return
        if (syncedTest && !check(hit.col === 1, "Completion automation did not move the card")) return
        desk.appearanceOpen = false
        desk.openCardId = "test-card"
        // The second mock write is deliberately rejected, then succeeds on retry.
        desk.toggleComplete("test-card")
        step = 2
      } else if (step === 2) {
        if (syncedTest) {
          if (!check(desk.findCard("test-card").card.dueComplete, "Failed completion was not rolled back")) return
          desk.toggleComplete("test-card")
          step = 3
        } else {
          if (!check(!desk.findCard("test-card").card.dueComplete, "Local card did not become incomplete")) return
          desk.toggleComplete("test-card")
          step = 4
        }
      } else if (step === 3) {
        if (!check(!desk.findCard("test-card").card.dueComplete, "Card did not become incomplete through API")) return
        desk.toggleComplete("test-card")
        step = 4
      } else if (step === 4) {
        if (syncedTest && !check(!desk.findCard("test-card") && desk.openCardId === "", "Archive automation did not remove and close the card")) return
        desk.openCardId = ""
        desk.sharedEnvironment.onBoardWallpaper = false
        console.log("PASS: shared board, migration, completion and rendering (synced=" + syncedTest + ")")
        Qt.quit()
      }
    }
  }
}
