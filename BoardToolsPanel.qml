import QtQuick
import qs.Commons

Item {
  id: panel
  required property var desk
  property int templateCol: 0
  property string moveCol: "0"
  property string bulkLabel: ""
  property string bulkMember: ""
  visible: desk.toolsOpen
  onVisibleChanged: if (visible) {
    forceActiveFocus()
    if (destinations.length && !destinations.some(function(x) { return x.key === String(templateCol) })) templateCol = Number(destinations[0].key)
    if (destinations.length && !destinations.some(function(x) { return x.key === moveCol })) moveCol = destinations[0].key
  }
  Keys.onEscapePressed: if (!desk.batchBusy) desk.toolsOpen = false
  readonly property var destinations: desk.board.columns.map(function(column, index) {
    return { key: String(index), label: column.title, usable: !panel.desk.synced || !!column.listId }
  }).filter(function(column) { return column.usable })

  component Label: Text {
    textFormat: Text.PlainText
    font.family: Style.fontFamily
    font.pixelSize: 12
    color: panel.desk.textColor
  }
  component Button: Rectangle {
    id: button
    property string text: ""
    property bool active: false
    signal clicked()
    width: Math.min(caption.implicitWidth + 24, 370); height: 30; radius: 9
    color: active || hover.hovered ? Qt.alpha(panel.desk.heads[1], 0.25) : "transparent"
    opacity: enabled ? 1 : 0.45
    border.width: 1; border.color: active ? panel.desk.heads[1] : panel.desk.cardBorder
    Label { id: caption; anchors.centerIn: parent; width: Math.min(implicitWidth, parent.width - 20); elide: Text.ElideRight; text: button.text }
    HoverHandler { id: hover; cursorShape: Qt.PointingHandCursor }
    TapHandler { onTapped: button.clicked() }
    Accessible.role: Accessible.Button
    Accessible.name: text
    Accessible.onPressAction: clicked()
  }
  component Options: Flow {
    id: options
    required property var choices
    property string selected: ""
    signal chosen(string key)
    spacing: 6
    Repeater {
      model: options.choices
      Button {
        required property var modelData
        text: modelData.label
        width: Math.min(implicitLabel.implicitWidth + 24, options.width)
        Label { id: implicitLabel; visible: false; text: parent.text }
        active: options.selected === modelData.key
        onClicked: options.chosen(modelData.key)
      }
    }
  }
  MouseArea {
    anchors.fill: parent
    acceptedButtons: Qt.AllButtons
    onClicked: if (!panel.desk.batchBusy) panel.desk.toolsOpen = false
    onWheel: function(event) { event.accepted = true }
  }
  Rectangle {
    y: 76
    width: Math.min(440, parent.width - 20)
    height: Math.min(parent.height - 90, content.height + 24)
    radius: 14; color: "#15121f"
    border.width: 1; border.color: Qt.alpha(panel.desk.heads[1], 0.7)
    MouseArea { anchors.fill: parent; acceptedButtons: Qt.AllButtons }
    Flickable {
      anchors { fill: parent; margins: 12 }
      clip: true; contentHeight: content.height
      boundsBehavior: Flickable.StopAtBounds
      Column {
        id: content
        width: parent.width; spacing: 12
        Options {
          width: parent.width
          enabled: !panel.desk.batchBusy
          choices: [{ key: "filters", label: "Filters" }, { key: "bulk", label: "Bulk actions" }, { key: "templates", label: "Templates" }]
          selected: panel.desk.toolsTab
          onChosen: function(key) { panel.desk.toolsTab = key }
        }
        Label {
          width: parent.width; wrapMode: Text.WordWrap
          visible: panel.desk.toolsMessage.length > 0
          text: panel.desk.toolsMessage
          color: panel.desk.mutedColor
        }
        Column {
          visible: panel.desk.toolsTab === "filters"
          width: parent.width; spacing: 10
          Label { text: "COMPLETION"; font.pixelSize: 10; color: panel.desk.mutedColor }
          Options {
            width: parent.width
            choices: [{ key: "all", label: "All cards" }, { key: "incomplete", label: "Incomplete" }, { key: "complete", label: "Complete" }]
            selected: panel.desk.filters.status
            onChosen: function(key) { panel.desk.setFilter("status", key) }
          }
          Label { text: "DUE DATE"; font.pixelSize: 10; color: panel.desk.mutedColor }
          Options {
            width: parent.width
            choices: [{ key: "all", label: "Any date" }, { key: "overdue", label: "Overdue" }, { key: "week", label: "Next 7 days" }, { key: "none", label: "No due date" }]
            selected: panel.desk.filters.due
            onChosen: function(key) { panel.desk.setFilter("due", key) }
          }
          Label { visible: panel.desk.synced; text: "LABEL"; font.pixelSize: 10; color: panel.desk.mutedColor }
          Options {
            visible: panel.desk.synced
            width: parent.width
            choices: [{ key: "", label: "Any label" }].concat(panel.desk.boardLabels.map(function(x) { return { key: x.id, label: x.n || x.c } }))
            selected: panel.desk.filters.label
            onChosen: function(key) { panel.desk.setFilter("label", key) }
          }
          Label { visible: panel.desk.synced; text: "ASSIGNED TO"; font.pixelSize: 10; color: panel.desk.mutedColor }
          Options {
            visible: panel.desk.synced
            width: parent.width
            choices: [{ key: "", label: "Anyone" }].concat(panel.desk.boardMembers.map(function(x) { return { key: x.id, label: x.name } }))
            selected: panel.desk.filters.member
            onChosen: function(key) { panel.desk.setFilter("member", key) }
          }
          Button { text: "Clear search and filters"; onClicked: panel.desk.resetFilters() }
          Label { width: parent.width; wrapMode: Text.WordWrap; text: "Filters apply to the lists shown on your desktop. Changing a filter clears the current selection."; color: panel.desk.faintColor; font.pixelSize: 11 }
        }
        Column {
          visible: panel.desk.toolsTab === "bulk"
          width: parent.width; spacing: 10
          enabled: !panel.desk.batchBusy && !panel.desk.fetching && panel.desk.writesInFlight === 0
          Label { text: panel.desk.selectedIds.length + " cards selected (up to 100)" }
          Flow {
            width: parent.width; spacing: 6
            Button { text: "Select shown cards"; onClicked: panel.desk.selectVisible() }
            Button { text: "Choose on board"; onClicked: { panel.desk.selectionMode = true; panel.desk.toolsOpen = false } }
            Button { text: "Clear selection"; onClicked: panel.desk.cancelSelection() }
          }
          Flow {
            width: parent.width; spacing: 6
            enabled: panel.desk.selectedIds.length > 0
            Button { text: "Mark complete"; onClicked: panel.desk.bulkAction("complete", "") }
            Button { text: "Mark incomplete"; onClicked: panel.desk.bulkAction("incomplete", "") }
            Button { visible: panel.desk.synced; text: "Archive selected"; onClicked: panel.desk.bulkAction("archive", "") }
          }
          Label { text: "MOVE TO LIST"; font.pixelSize: 10; color: panel.desk.mutedColor }
          Options { width: parent.width; choices: panel.destinations; selected: panel.moveCol; onChosen: function(key) { panel.moveCol = key } }
          Button { text: "Move selected"; enabled: panel.desk.selectedIds.length > 0; onClicked: panel.desk.bulkAction("move", panel.moveCol) }
          Label { visible: panel.desk.synced; text: "ADD LABEL"; font.pixelSize: 10; color: panel.desk.mutedColor }
          Options {
            visible: panel.desk.synced; width: parent.width
            choices: panel.desk.boardLabels.map(function(x) { return { key: x.id, label: x.n || x.c } })
            selected: panel.bulkLabel; onChosen: function(key) { panel.bulkLabel = key }
          }
          Button { visible: panel.desk.synced; text: "Add label to selected"; enabled: !!panel.bulkLabel && panel.desk.selectedIds.length > 0; onClicked: panel.desk.bulkAction("label", panel.bulkLabel) }
          Label { visible: panel.desk.synced; text: "ASSIGN MEMBER"; font.pixelSize: 10; color: panel.desk.mutedColor }
          Options {
            visible: panel.desk.synced; width: parent.width
            choices: panel.desk.boardMembers.map(function(x) { return { key: x.id, label: x.name } })
            selected: panel.bulkMember; onChosen: function(key) { panel.bulkMember = key }
          }
          Button { visible: panel.desk.synced; text: "Assign to selected"; enabled: !!panel.bulkMember && panel.desk.selectedIds.length > 0; onClicked: panel.desk.bulkAction("member", panel.bulkMember) }
        }
        Column {
          visible: panel.desk.toolsTab === "templates"
          width: parent.width; spacing: 10
          enabled: !panel.desk.batchBusy && !panel.desk.fetching && panel.desk.writesInFlight === 0
          Label { width: parent.width; wrapMode: Text.WordWrap; text: "Open a card and enter a template name to save its title, description and checklists. Synced cards also copy labels and members."; color: panel.desk.mutedColor }
          Label { text: "CREATE IN LIST"; font.pixelSize: 10; color: panel.desk.mutedColor }
          Options { width: parent.width; choices: panel.destinations; selected: String(panel.templateCol); onChosen: function(key) { panel.templateCol = Number(key) } }
          Label { visible: panel.desk.cardTemplates.length === 0; text: "No templates saved yet."; color: panel.desk.faintColor }
          Repeater {
            model: panel.desk.cardTemplates
            Column {
              id: templateRow
              required property var modelData
              width: parent.width; spacing: 6
              Label { width: parent.width; wrapMode: Text.WordWrap; text: parent.modelData.name; font.weight: Font.Bold }
              Row {
                spacing: 6
                Button { text: "Create card"; onClicked: panel.desk.createFromTemplate(templateRow.modelData.id, panel.templateCol) }
                Button { text: "Remove template"; onClicked: panel.desk.removeTemplate(templateRow.modelData.id) }
              }
            }
          }
          Label { width: parent.width; wrapMode: Text.WordWrap; text: "New cards start incomplete with fresh checklist items. Attachments and dates stay on the original. Labels and members copy when available on the destination board."; color: panel.desk.faintColor; font.pixelSize: 11 }
        }
      }
    }
  }
}
