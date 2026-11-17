import QtQuick
import Quickshell.Io

Item {
  id: root
  property var shell: null
  property var manifest: null
  property alias boardDesk: desk

  SharedEnvironment { id: environment }
  BoardDesk {
    id: desk
    sharedEnvironment: environment
    shell: root.shell
    manifest: root.manifest
  }

  IpcHandler {
    target: "boardhydra-desk"
    function quickAdd(): void { desk.openQuickAdd() }
    function refresh(): void { if (desk.synced) desk.fetchBoard(true) }
  }
}
