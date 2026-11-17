import QtQuick
import Quickshell
ShellRoot {
  Desk { id: service }
  readonly property var desk: service.boardDesk
  readonly property bool remote: Quickshell.env("BOARDHYDRA_TEST_SYNC") === "1"
  property int step: 0
  property int ticks: 0
  function check(ok, message) { if (!ok) { console.error(message); Qt.exit(1) }; return ok }
  Timer {
    interval: 200; repeat: true; running: true
    onTriggered: {
      if (++ticks > 70) { console.error("Tools test timed out at " + step); Qt.exit(1); return }
      if (!desk.loaded || !desk.stateLoaded || !desk.templatesLoaded || desk.fetching || desk.writesInFlight || desk.batchBusy) return
      var alpha = desk.findCard("c1"), beta = desk.findCard("c2")
      if (step === 0) {
        desk.sharedEnvironment.onBoardWallpaper = true
        if (!remote) desk.commitLocal(desk.sanitizeLocal({ columns: [
          { title: "To do", cards: [{ id: "c1", text: "Alpha", desc: "Needle in description", checklists: [{ id: "old-list", name: "Steps", checkItems: [{ id: "old-item", name: "Review", state: "complete" }] }] }, { id: "c2", text: "Beta" }] },
          { title: "Done", cards: [] }, { title: "Later", cards: [] }
        ] }))
        desk.showTools("filters")
        step = 1
      } else if (step === 1) {
        desk.setFilter("query", "needle")
        if (!check(desk.matchesCard(alpha.card) && !desk.matchesCard(beta.card), "Description search did not filter correctly")) return
        if (remote) {
          desk.setFilter("label", "old-label")
          desk.setFilter("member", "old-member")
          if (!check(desk.matchesCard(alpha.card), "Combined label/member filter failed")) return
        }
        desk.resetFilters()
        desk.selectVisible()
        if (!check(desk.selectedIds.length === 2, "Select shown did not select both cards")) return
        desk.showTools("bulk")
        desk.bulkAction("complete", "")
        step = 2
      } else if (step === 2) {
        if (remote) {
          if (!check(alpha.card.dueComplete && !beta.card.dueComplete && desk.selectedIds.join() === "c2" && desk.toolsMessage.indexOf("1 failed") >= 0, "Bulk partial failure did not retain failed selection")) return
          desk.bulkAction("complete", "")
        }
        step = 3
      } else if (step === 3) {
        if (!check(alpha.card.dueComplete && beta.card.dueComplete, "Bulk completion failed")) return
        desk.selectVisible()
        desk.bulkAction("move", "1")
        step = 4
      } else if (step === 4) {
        if (!check(alpha.col === 1 && beta.col === 1 && desk.board.columns[1].cards[0].id === "c1", "Bulk move failed or changed order")) return
        if (remote) { desk.selectVisible(); desk.bulkAction("label", "new-label") }
        step = 5
      } else if (step === 5) {
        if (remote) {
          var labels = desk.cardDetails(alpha.card).labelIds
          if (!check(labels.indexOf("old-label") >= 0 && labels.indexOf("new-label") >= 0, "Bulk label replaced existing labels")) return
          desk.selectVisible(); desk.bulkAction("member", "new-member")
        }
        step = 6
      } else if (step === 6) {
        if (remote) {
          var members = desk.cardDetails(alpha.card).memberIds
          if (!check(members.indexOf("old-member") >= 0 && members.indexOf("new-member") >= 0, "Bulk assignment replaced existing members")) return
        }
        if (!check(desk.saveTemplate("c1", "Review"), "Could not save template")) return
        desk.showTools("templates")
        desk.createFromTemplate(desk.cardTemplates[0].id, 0)
        step = 7
      } else if (step === 7) {
        var created = desk.board.columns[0].cards[0]
        var more = desk.cardDetails(created)
        if (!check(created && !created.dueComplete && more.desc === "Needle in description" && more.raw[0].checkItems[0].state === "incomplete" && more.raw[0].checkItems[0].id !== "old-item", "Template did not reset completion or copy content with fresh IDs")) return
        desk.toolsOpen = false
        desk.openCardId = created.id
        step = 8
      } else if (step === 8) {
        desk.openCardId = ""
        if (remote) { desk.showTools("templates"); desk.createFromTemplate(desk.cardTemplates[0].id, 0) }
        step = 9
      } else if (step === 9) {
        if (remote && !check(desk.toolsMessage.indexOf("Card created, but template details failed:") === 0 && !!desk.findCard("new-2"), "Partial template creation was not reported")) return
        desk.saveTemplate("c2", "Temporary")
        desk.removeTemplate(desk.cardTemplates[1].id)
        desk.selectedIds = ["c1", "c2"]
        desk.showTools("bulk")
        desk.bulkAction(remote ? "archive" : "incomplete", "")
        step = 10
      } else if (step === 10) {
        if (!check(remote ? !alpha && !beta : !alpha.card.dueComplete && !beta.card.dueComplete, "Final bulk action failed")) return
        desk.setFilter("status", "incomplete")
        if (!check(desk.selectedIds.length === 0 && desk.cardTemplates.length === 1, "Selection or templates not retained correctly")) return
        if (remote) {
          desk.selectedIds = ["new-1", "new-2"]
          desk.bulkAction("complete", "")
          step = 11
          return
        }
        finish()
      } else if (step === 11) {
        if (!check(desk.selectedIds.join() === "new-1,new-2" && desk.toolsMessage.indexOf("2 failed") >= 0, "Rate limit did not stop and retain remaining selection")) return
        finish()
      }
    }
  }
  function finish() {
        desk.sharedEnvironment.onBoardWallpaper = false
        console.log("PASS: filters, bulk actions, partial failure, templates and rendered controls (remote=" + remote + ")")
        Qt.quit()
  }
}
