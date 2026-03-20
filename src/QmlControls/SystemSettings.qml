// PXLABS integration — additive file
// SystemSettings.qml: Top-level System Settings view for PXLABS pages.
// Opened via mainWindow.showSystemSettings() from the hamburger tool drawer.

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

import QGroundControl
import QGroundControl.Palette
import QGroundControl.Controls
import QGroundControl.ScreenTools
import QGroundControl.AppSettings

Rectangle {
    id:     systemView
    color:  qgcPal.window
    z:      QGroundControl.zOrderTopMost

    readonly property real _margin: ScreenTools.defaultFontPixelWidth * 0.5

    property bool _first: true

    QGCPalette { id: qgcPal }

    PXLABSPagesModel { id: pxlabsModel }

    Component.onCompleted: {
        rightPanel.source = "qrc:/qml/QGroundControl/AppSettings/ConnectionControl.qml"
    }

    // ── Left sidebar ──────────────────────────────────────────────────────
    QGCFlickable {
        id:                 buttonList
        width:              buttonColumn.width
        anchors.top:        parent.top
        anchors.bottom:     parent.bottom
        anchors.left:       parent.left
        anchors.topMargin:  _margin
        anchors.leftMargin: _margin
        contentHeight:      buttonColumn.height + _margin
        flickableDirection: Flickable.VerticalFlick
        clip:               true

        ColumnLayout {
            id:      buttonColumn
            spacing: ScreenTools.defaultFontPixelHeight / 4

            Repeater {
                id:    sysButtonRepeater
                model: pxlabsModel

                SettingsButton {
                    Layout.fillWidth: true
                    text:             name
                    icon.source:      iconUrl
                    visible:          pageVisible()

                    onClicked: {
                        if (mainWindow.allowViewSwitch()) {
                            if (rightPanel.source !== url) {
                                rightPanel.source = url
                            }
                            checked = true
                        }
                    }

                    Component.onCompleted: {
                        if (_first) {
                            _first = false
                            checked = true
                        }
                    }
                }
            }
        }
    }

    // ── Divider ───────────────────────────────────────────────────────────
    Rectangle {
        id:                   divider
        anchors.left:         buttonList.right
        anchors.top:          parent.top
        anchors.bottom:       parent.bottom
        anchors.leftMargin:   _margin
        anchors.topMargin:    _margin
        anchors.bottomMargin: _margin
        width:                1
        color:                qgcPal.windowShade
    }

    // ── Right content panel ───────────────────────────────────────────────
    Loader {
        id:                   rightPanel
        anchors.left:         divider.right
        anchors.right:        parent.right
        anchors.top:          parent.top
        anchors.bottom:       parent.bottom
        anchors.margins:      _margin
    }
}
