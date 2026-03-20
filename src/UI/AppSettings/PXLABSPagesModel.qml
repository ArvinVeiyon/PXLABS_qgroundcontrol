// PXLABS integration — additive file
// PXLABS settings pages model, loaded as a separate section in AppSettings.qml

import QtQml.Models

ListModel {
    ListElement {
        name: qsTr("Connection")
        url: "qrc:/qml/QGroundControl/AppSettings/ConnectionControl.qml"
        iconUrl: "qrc:/InstrumentValueIcons/usb.svg"
        pageVisible: function() { return true }
    }

    ListElement {
        name: qsTr("PXLABS")
        url: "qrc:/qml/QGroundControl/AppSettings/PXLABSSettings.qml"
        iconUrl: "qrc:/InstrumentValueIcons/drone.svg"
        pageVisible: function() { return true }
    }

    ListElement {
        name: qsTr("Companion")
        url: "qrc:/qml/QGroundControl/AppSettings/CompanionControl.qml"
        iconUrl: "qrc:/InstrumentValueIcons/camera.svg"
        pageVisible: function() { return true }
    }

    ListElement {
        name: qsTr("Relay Control")
        url: "qrc:/qml/QGroundControl/AppSettings/RelayControl.qml"
        iconUrl: "qrc:/InstrumentValueIcons/wifi.svg"
        pageVisible: function() { return true }
    }
}
