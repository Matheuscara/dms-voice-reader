import QtQuick
import qs.Common
import qs.Widgets
import qs.Modules.Plugins

PluginSettings {
    id: root

    pluginId: "voiceReader"

    StyledText {
        width: parent.width
        text: "Caption"
        font.pixelSize: Theme.fontSizeLarge
        font.weight: Font.Bold
        color: Theme.surfaceText
    }

    ToggleSetting {
        settingKey: "caption"
        label: "Show caption"
        description: "Opens a box in the top-left corner with the text being read, highlighting the spoken word"
        defaultValue: true
    }

    SliderSetting {
        settingKey: "fontSize"
        label: "Font size"
        defaultValue: 26
        minimum: 16
        maximum: 44
        unit: "px"
    }

    SliderSetting {
        settingKey: "width"
        label: "Box width"
        defaultValue: 640
        minimum: 360
        maximum: 1100
        unit: "px"
    }
}
