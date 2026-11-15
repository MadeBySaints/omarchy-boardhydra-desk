import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland

Item {
  id: root
  property var shell: null
  property var manifest: null

  function focusedDesk() {
    var monitor = Hyprland.focusedMonitor
    var workspace = monitor ? monitor.activeWorkspace : null
    if (!workspace) return null
    for (var i = 0; i < desks.instances.length; i++) {
      var desk = desks.instances[i]
      if (desk.workspaceId === workspace.id) return desk
    }
    return null
  }

  Variants {
    id: desks
    model: Hyprland.workspaces.values
    WorkspaceDesk {
      required property var modelData
      workspace: modelData
      shell: root.shell
      manifest: root.manifest
    }
  }

  IpcHandler {
    target: "boardhydra-desk"
    function quickAdd(): void {
      var desk = root.focusedDesk()
      if (desk) desk.openQuickAdd()
    }
    function refresh(): void {
      var desk = root.focusedDesk()
      if (desk) desk.fetchBoard(true)
    }
  }
}
