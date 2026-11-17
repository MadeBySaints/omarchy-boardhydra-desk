import QtQuick
import qs.Commons
import "Appearance.js" as Appearance

Item {
  id: picker
  required property var desk
  visible: desk.appearanceOpen
  onVisibleChanged: if (visible) forceActiveFocus()
  Keys.onEscapePressed: desk.appearanceOpen = false

  component Label: Text {
    textFormat: Text.PlainText
    font.family: Style.fontFamily
    font.pixelSize: 12
    color: picker.desk.textColor
  }

  component ColorField: Rectangle {
    id: field
    required property string value
    signal committed(string color)
    onValueChanged: input.text = value
    width: 106; height: 30; radius: 8
    color: picker.desk.cardColor
    border.width: 1
    border.color: input.acceptableInput ? picker.desk.cardBorder : picker.desk.badColor
    TextInput {
      id: input
      anchors { fill: parent; leftMargin: 10; rightMargin: 8 }
      text: field.value
      color: picker.desk.textColor
      font.family: Style.fontFamily
      font.pixelSize: 12
      verticalAlignment: TextInput.AlignVCenter
      maximumLength: 7
      selectByMouse: true
      validator: RegularExpressionValidator { regularExpression: /#[0-9a-fA-F]{6}/ }
      onEditingFinished: {
        if (acceptableInput) field.committed(text)
        else text = field.value
      }
      Keys.onEscapePressed: { text = field.value; picker.forceActiveFocus() }
    }
  }

  MouseArea {
    anchors.fill: parent
    acceptedButtons: Qt.AllButtons
    onClicked: picker.desk.appearanceOpen = false
    onWheel: function(event) { event.accepted = true }
  }

  Rectangle {
    anchors.right: parent.right
    y: 36
    width: Math.min(380, parent.width - 20)
    height: Math.min(parent.height - 50, content.height + 24)
    radius: 14
    color: "#15121f"
    border.width: 1
    border.color: Qt.alpha(picker.desk.surfaceTone, 0.7)
    MouseArea { anchors.fill: parent; acceptedButtons: Qt.AllButtons }
    Flickable {
      anchors { fill: parent; margins: 12 }
      contentHeight: content.height
      clip: true
      boundsBehavior: Flickable.StopAtBounds
      Column {
        id: content
        width: parent.width
        spacing: 10
        Label { text: "STYLE"; font.weight: Font.Bold; font.letterSpacing: 1 }
        Flow {
          width: parent.width
          spacing: 6
          Repeater {
            model: Appearance.presets
            Rectangle {
              id: option
              required property var modelData
              readonly property bool selected: picker.desk.appearance.preset === modelData.key
              width: title.implicitWidth + 24; height: 30; radius: 15
              color: selected || hover.hovered ? Qt.alpha(modelData.tone, 0.22) : "transparent"
              border.width: 1
              border.color: selected ? modelData.tone : picker.desk.cardBorder
              Label { id: title; anchors.centerIn: parent; text: option.modelData.label; font.weight: option.selected ? Font.Bold : Font.Normal }
              HoverHandler { id: hover; cursorShape: Qt.PointingHandCursor }
              TapHandler { onTapped: picker.desk.setAppearance({ preset: option.modelData.key }) }
            }
          }
        }
        Label {
          width: parent.width
          wrapMode: Text.WordWrap
          font.pixelSize: 11
          color: picker.desk.mutedColor
          text: "Styles tint cards and lists. Holo adds an iridescent wash across each list background."
        }
        Rectangle { width: parent.width; height: 1; color: picker.desk.cardBorder }
        Row {
          width: parent.width
          spacing: 10
          Label { width: parent.width - 116; height: 30; verticalAlignment: Text.AlignVCenter; text: "Card color" }
          ColorField {
            value: String(picker.desk.surfaceCard)
            onCommitted: function(color) { picker.desk.setAppearance({ tint: color }) }
          }
        }
        Label { text: "LIST ACCENTS"; font.pixelSize: 10; font.weight: Font.Bold; color: picker.desk.mutedColor }
        Repeater {
          model: picker.desk.slots
          Row {
            id: accent
            required property int index
            width: content.width
            spacing: 10
            Rectangle { width: 10; height: 10; radius: 5; y: 10; color: picker.desk.heads[accent.index] }
            Label { width: parent.width - 136; height: 30; verticalAlignment: Text.AlignVCenter; text: "List " + (accent.index + 1) }
            ColorField {
              value: picker.desk.heads[accent.index]
              onCommitted: function(color) { picker.desk.setAccent(accent.index, color) }
            }
          }
        }
        Label { text: "Use #RRGGBB · Enter or click away to apply"; font.pixelSize: 10; color: picker.desk.faintColor }
        Rectangle {
          width: parent.width; height: 32; radius: 8
          color: motionHover.hovered ? "#241f35" : "transparent"
          Label {
            anchors { left: parent.left; leftMargin: 8; verticalCenter: parent.verticalCenter }
            text: "Holo motion"
          }
          Label {
            anchors { right: parent.right; rightMargin: 8; verticalCenter: parent.verticalCenter }
            color: picker.desk.mutedColor
            text: Style.reduceMotion ? "System animations off" : picker.desk.appearance.motion ? "On" : "Off"
          }
          HoverHandler { id: motionHover; cursorShape: Qt.PointingHandCursor }
          TapHandler { onTapped: picker.desk.setAppearance({ motion: !picker.desk.appearance.motion }) }
        }
        Rectangle {
          width: parent.width; height: 30; radius: 8
          color: resetHover.hovered ? "#241f35" : "transparent"
          border.width: 1; border.color: picker.desk.cardBorder
          Label { anchors.centerIn: parent; text: "Reset colors to preset"; color: picker.desk.mutedColor }
          HoverHandler { id: resetHover; cursorShape: Qt.PointingHandCursor }
          TapHandler { onTapped: picker.desk.setAppearance({ tint: "", accents: [] }) }
        }
      }
    }
  }
}
