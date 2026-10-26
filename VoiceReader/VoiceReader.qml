import QtQuick
import Quickshell
import Quickshell.Io
import qs.Common
import qs.Widgets
import qs.Modules.Plugins

// State comes from the voice-reader service, which writes $XDG_RUNTIME_DIR/voice-reader.json:
// {state: idle|loading|speaking, lang, source ("" or translated language), total,
//  sentences: [{start, end (epoch ms), words: [[text, start_ms, end_ms], ...]}]}.
PluginComponent {
    id: root

    property string status: "idle"
    property string lang: ""
    property string source: ""
    property int total: 0
    property var sentences: []
    property bool serviceActive: false
    // Computed from the clock against the timeline (sync()).
    property int currentSentence: -1
    property int currentWord: -1

    readonly property bool captionEnabled: pluginData.caption ?? true
    readonly property int fontSize: pluginData.fontSize ?? 26
    readonly property int boxWidth: pluginData.width ?? 640

    readonly property bool loading: status === "loading"
    readonly property bool speaking: status === "speaking"
    readonly property color accent: loading || speaking ? Theme.primary : Theme.widgetIconColor
    readonly property string label: speaking && total > 1 && currentSentence >= 0 ? `${currentSentence + 1}/${total}` : ""

    pillClickAction: () => Quickshell.execDetached(["voice-reader", "read"])

    function sync() {
        const now = Date.now();
        let s = sentences.length > 0 ? 0 : -1;
        for (let i = 1; i < sentences.length && sentences[i].start <= now; i++)
            s = i;
        let w = -1;
        if (s >= 0 && sentences[s].start <= now) {
            const elapsed = now - sentences[s].start;
            const ws = sentences[s].words;
            for (let j = 0; j < ws.length && ws[j][1] <= elapsed; j++)
                w = j;
        }
        currentSentence = s;
        currentWord = w;
    }

    Timer {
        interval: 33
        repeat: true
        running: root.speaking
        triggeredOnStart: true
        onTriggered: root.sync()
    }

    FileView {
        path: (Quickshell.env("XDG_RUNTIME_DIR") || "/tmp") + "/voice-reader.json"
        watchChanges: true
        printErrors: false
        onFileChanged: reload()
        onLoaded: {
            try {
                const s = JSON.parse(text());
                root.status = s.state || "idle";
                root.lang = s.lang || "";
                root.source = s.source || "";
                root.total = s.total || 0;
                root.sentences = s.sentences || [];
                root.serviceActive = true;
                root.sync();
            } catch (e) {
                // partial write: wait for the next change
            }
        }
        onLoadFailed: root.serviceActive = false
    }

    Caption {
        reader: root
    }

    horizontalBarPill: Component {
        Row {
            spacing: Theme.spacingXS
            opacity: root.serviceActive ? 1 : 0.45

            Indicator { anchors.verticalCenter: parent.verticalCenter }

            StyledText {
                visible: root.label !== ""
                text: root.label
                color: root.accent
                font.pixelSize: Theme.fontSizeSmall
                anchors.verticalCenter: parent.verticalCenter
            }
        }
    }

    verticalBarPill: Component {
        Column {
            spacing: Theme.spacingXS
            opacity: root.serviceActive ? 1 : 0.45

            Indicator { anchors.horizontalCenter: parent.horizontalCenter }

            StyledText {
                visible: root.label !== ""
                text: `${root.currentSentence + 1}`
                color: root.accent
                font.pixelSize: Theme.fontSizeSmall
                anchors.horizontalCenter: parent.horizontalCenter
            }
        }
    }

    component Indicator: Item {
        implicitWidth: root.iconSize
        implicitHeight: root.iconSize
        Accessible.name: "Voice Reader"

        DankIcon {
            id: icon
            anchors.centerIn: parent
            name: root.loading ? "progress_activity"
                : root.speaking ? "graphic_eq" : "record_voice_over"
            size: root.iconSize
            color: root.accent

            RotationAnimation on rotation {
                running: root.loading
                loops: Animation.Infinite
                from: 0
                to: 360
                duration: 900
                onRunningChanged: if (!running) icon.rotation = 0
            }

            SequentialAnimation on opacity {
                running: root.speaking
                loops: Animation.Infinite
                NumberAnimation { to: 0.45; duration: 600; easing.type: Easing.InOutSine }
                NumberAnimation { to: 1; duration: 600; easing.type: Easing.InOutSine }
                onRunningChanged: if (!running) icon.opacity = 1
            }
        }
    }
}
