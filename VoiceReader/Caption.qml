import QtQuick
import Quickshell
import Quickshell.Wayland
import qs.Common
import qs.Widgets

// Caption in the top-left corner: the sentence being read, with a white box
// that slides to the word currently spoken. Takes no clicks or focus.
PanelWindow {
    id: captionWindow

    required property var reader
    readonly property bool open: reader.captionEnabled && (reader.loading || reader.speaking)
    readonly property var sentence: reader.currentSentence >= 0 ? reader.sentences[reader.currentSentence] : null
    readonly property var words: sentence ? sentence.words : []
    readonly property int shadowMargin: 16

    screen: reader.parentScreen
    visible: open || card.opacity > 0.01
    color: "transparent"
    implicitWidth: reader.boxWidth + shadowMargin * 2
    implicitHeight: card.implicitHeight + shadowMargin * 2

    anchors {
        top: true
        left: true
    }
    margins {
        top: 4
        left: 8
    }
    WlrLayershell.namespace: "dms:voice-reader:caption"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
    exclusionMode: ExclusionMode.Normal
    exclusiveZone: 0
    mask: Region {}

    Rectangle {
        id: card

        x: captionWindow.shadowMargin + (captionWindow.open ? 0 : -24)
        y: captionWindow.shadowMargin
        width: captionWindow.reader.boxWidth
        implicitHeight: content.implicitHeight + Theme.spacingL * 2
        height: implicitHeight
        radius: Theme.cornerRadius * 1.5
        color: Theme.surfaceContainer
        border.color: Theme.outlineVariant
        border.width: 1
        opacity: captionWindow.open ? 1 : 0
        scale: captionWindow.open ? 1 : 0.94
        transformOrigin: Item.TopLeft

        Behavior on x { NumberAnimation { duration: 320; easing.type: Easing.OutCubic } }
        Behavior on opacity { NumberAnimation { duration: 260; easing.type: Easing.OutCubic } }
        Behavior on scale { NumberAnimation { duration: 320; easing.type: Easing.OutBack; easing.overshoot: 1.2 } }
        Behavior on height { NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }

        Column {
            id: content

            x: Theme.spacingL
            y: Theme.spacingL
            width: parent.width - Theme.spacingL * 2
            spacing: Theme.spacingM

            Row {
                spacing: Theme.spacingS

                DankIcon {
                    id: headerIcon
                    name: captionWindow.reader.loading ? "progress_activity"
                        : captionWindow.reader.source !== "" ? "translate" : "graphic_eq"
                    size: 18
                    color: Theme.primary
                    anchors.verticalCenter: parent.verticalCenter

                    RotationAnimation on rotation {
                        running: captionWindow.reader.loading && captionWindow.visible
                        loops: Animation.Infinite
                        from: 0
                        to: 360
                        duration: 900
                        onRunningChanged: if (!running) headerIcon.rotation = 0
                    }
                }

                StyledText {
                    readonly property string progress: captionWindow.reader.total > 1
                        ? `  ·  ${captionWindow.reader.currentSentence + 1}/${captionWindow.reader.total}` : ""
                    readonly property string source: captionWindow.reader.source.toUpperCase()

                    text: captionWindow.reader.loading
                        ? (source !== "" ? `Translating from ${source}…` : "Preparing…")
                        : (source !== "" ? `Translation · ${source} → ${captionWindow.reader.lang.toUpperCase()}`
                                         : `Reading · ${captionWindow.reader.lang.toUpperCase()}`) + progress
                    color: Theme.surfaceVariantText
                    font.pixelSize: Theme.fontSizeSmall
                    anchors.verticalCenter: parent.verticalCenter
                }
            }

            Item {
                id: area

                width: parent.width
                height: flow.implicitHeight
                visible: captionWindow.words.length > 0

                WordFlow {
                    id: flow

                    width: parent.width
                    words: captionWindow.words
                    current: captionWindow.reader.currentWord
                    fontSize: captionWindow.reader.fontSize
                    textColor: Theme.surfaceText
                    dimRead: true
                }

                // White box on the current word. Inside it holds a dark copy of the
                // text clipped to the box area: what sits under the white is always
                // legible, even mid-slide between two words.
                Rectangle {
                    id: highlight

                    readonly property Item target: captionWindow.reader.currentWord >= 0
                        ? flow.word(captionWindow.reader.currentWord) : null

                    visible: target !== null
                    x: target ? target.x : 0
                    y: target ? target.y : 0
                    width: target ? target.width : 0
                    height: target ? target.height : 0
                    radius: 6
                    color: "white"
                    clip: true

                    Behavior on x { NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }
                    Behavior on y { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }
                    Behavior on width { NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }

                    WordFlow {
                        x: -highlight.x
                        y: -highlight.y
                        width: flow.width
                        words: captionWindow.words
                        current: captionWindow.reader.currentWord
                        fontSize: captionWindow.reader.fontSize
                        textColor: "#1b1d22"
                        dimRead: false
                    }
                }
            }
        }
    }

    component WordFlow: Flow {
        id: flowBase

        required property var words
        required property int current
        required property int fontSize
        required property color textColor
        required property bool dimRead

        function word(i) {
            return repeater.itemAt(i);
        }

        spacing: 2

        Repeater {
            id: repeater

            model: flowBase.words

            Item {
                required property var modelData
                required property int index

                width: label.implicitWidth + 10
                height: label.implicitHeight + 4

                StyledText {
                    id: label

                    anchors.centerIn: parent
                    text: modelData[0]
                    font.pixelSize: flowBase.fontSize
                    font.weight: Font.Medium
                    color: flowBase.textColor
                    opacity: flowBase.dimRead && index < flowBase.current ? 0.6 : 1
                }
            }
        }
    }
}
