import QtQuick
import QtQuick.Layouts
import Quickshell.Services.UPower
import qs.Common
import qs.Services
import qs.Widgets

Rectangle {
    id: root

    LayoutMirroring.enabled: I18n.isRtl
    LayoutMirroring.childrenInherit: true

    implicitHeight: contentColumn.implicitHeight + Theme.spacingL * 2
    radius: Theme.cornerRadius
    color: Theme.nestedSurface
    border.color: Theme.outlineMedium
    border.width: Theme.layerOutlineWidth

    function isActiveProfile(profile) {
        if (typeof PowerProfiles === "undefined") {
            return false;
        }
        return PowerProfiles.profile === profile;
    }

    function setProfile(profile) {
        if (PowerProfileWatcher.applyProfile(profile))
            return;

        if (!PowerProfileWatcher.available)
            ToastService.showError(I18n.tr("power-profiles-daemon not available"));
        else
            ToastService.showError(I18n.tr("Failed to set power profile"));
    }

    Column {
        id: contentColumn
        width: parent.width - Theme.spacingL * 2
        anchors.left: parent.left
        anchors.top: parent.top
        anchors.margins: Theme.spacingL
        spacing: Theme.spacingL

        Row {
            id: headerRow
            width: parent.width
            spacing: Theme.spacingM

            DankIcon {
                name: BatteryService.getBatteryIcon()
                size: Theme.iconSizeLarge
                color: {
                    if (BatteryService.isLowBattery && !BatteryService.isCharging)
                        return Theme.error;
                    if (BatteryService.isCharging || BatteryService.isPluggedIn)
                        return Theme.primary;
                    return Theme.surfaceText;
                }
                anchors.verticalCenter: parent.verticalCenter
            }

            Column {
                spacing: Theme.spacingXS
                anchors.verticalCenter: parent.verticalCenter
                width: parent.width - Theme.iconSizeLarge - Theme.spacingM

                Row {
                    spacing: Theme.spacingS

                    StyledText {
                        text: BatteryService.batteryAvailable ? `${BatteryService.batteryLevel}%` : I18n.tr("Power")
                        font.pixelSize: Theme.fontSizeXLarge
                        color: {
                            if (BatteryService.isLowBattery && !BatteryService.isCharging) {
                                return Theme.error;
                            }
                            if (BatteryService.isCharging) {
                                return Theme.primary;
                            }
                            return Theme.surfaceText;
                        }
                        font.weight: Font.Bold
                    }

                    StyledText {
                        text: BatteryService.batteryAvailable ? BatteryService.batteryStatus : I18n.tr("Management")
                        font.pixelSize: Theme.fontSizeLarge
                        color: {
                            if (BatteryService.isLowBattery && !BatteryService.isCharging) {
                                return Theme.error;
                            }
                            if (BatteryService.isCharging) {
                                return Theme.primary;
                            }
                            return Theme.surfaceText;
                        }
                        font.weight: Font.Medium
                        anchors.verticalCenter: parent.verticalCenter
                    }
                }

                StyledText {
                    text: {
                        if (!BatteryService.batteryAvailable)
                            return I18n.tr("Power profile management available");
                        const time = BatteryService.formatTimeRemaining();
                        if (time !== "Unknown") {
                            return BatteryService.isCharging ? I18n.tr("Time until full: %1").arg(time) : I18n.tr("Time remaining: %1").arg(time);
                        }
                        return "";
                    }
                    font.pixelSize: Theme.fontSizeSmall
                    color: Theme.surfaceTextMedium
                    visible: text.length > 0
                    elide: Text.ElideRight
                    width: parent.width
                    horizontalAlignment: Text.AlignLeft
                }
            }
        }

        Row {
            width: parent.width
            spacing: Theme.spacingM
            visible: BatteryService.batteryAvailable

            StyledRect {
                width: (parent.width - Theme.spacingM) / 2
                height: 64
                radius: Theme.cornerRadius
                color: Theme.surfaceLight
                border.color: Theme.outlineLight
                border.width: 1

                Column {
                    anchors.centerIn: parent
                    spacing: Theme.spacingXS

                    StyledText {
                        text: I18n.tr("Health")
                        font.pixelSize: Theme.fontSizeSmall
                        color: Theme.primary
                        font.weight: Font.Medium
                        anchors.horizontalCenter: parent.horizontalCenter
                    }

                    StyledText {
                        text: BatteryService.batteryHealth
                        font.pixelSize: Theme.fontSizeLarge
                        color: {
                            if (BatteryService.batteryHealth === "N/A") {
                                return Theme.surfaceText;
                            }
                            const healthNum = parseInt(BatteryService.batteryHealth);
                            return healthNum < 80 ? Theme.error : Theme.surfaceText;
                        }
                        font.weight: Font.Bold
                        anchors.horizontalCenter: parent.horizontalCenter
                    }
                }
            }

            StyledRect {
                width: (parent.width - Theme.spacingM) / 2
                height: 64
                radius: Theme.cornerRadius
                color: Theme.surfaceLight
                border.color: Theme.outlineLight
                border.width: 1

                Column {
                    anchors.centerIn: parent
                    spacing: Theme.spacingXS

                    StyledText {
                        text: I18n.tr("Capacity")
                        font.pixelSize: Theme.fontSizeSmall
                        color: Theme.primary
                        font.weight: Font.Medium
                        anchors.horizontalCenter: parent.horizontalCenter
                    }

                    StyledText {
                        text: BatteryService.batteryCapacity > 0 ? `${BatteryService.batteryCapacity.toFixed(1)} Wh` : I18n.tr("Unknown")
                        font.pixelSize: Theme.fontSizeLarge
                        color: Theme.surfaceText
                        font.weight: Font.Bold
                        anchors.horizontalCenter: parent.horizontalCenter
                    }
                }
            }
        }

        DankButtonGroup {
            property var profileModel: PowerProfileWatcher.availableProfiles
            property int currentProfileIndex: {
                if (typeof PowerProfiles === "undefined")
                    return 1;
                return profileModel.findIndex(profile => isActiveProfile(profile));
            }

            model: profileModel.map(profile => Theme.getPowerProfileLabel(profile))
            currentIndex: currentProfileIndex
            selectionMode: "single"
            anchors.horizontalCenter: parent.horizontalCenter
            onSelectionChanged: (index, selected) => {
                if (!selected)
                    return;
                setProfile(profileModel[index]);
            }
        }

        Column {
            width: parent.width
            spacing: Theme.spacingS
            visible: BatteryService.hasExternalDevices && SettingsData.batteryShowExternalDevices

            StyledText {
                text: I18n.tr("Connected Devices")
                font.pixelSize: Theme.fontSizeSmall
                font.weight: Font.DemiBold
                color: Theme.surfaceTextMedium
            }

            Repeater {
                model: BatteryService.externalDevices
                delegate: Rectangle {
                    width: parent.width
                    height: 40
                    radius: Theme.cornerRadius
                    color: Theme.surfaceLight
                    border.color: Theme.outlineLight
                    border.width: 1

                    RowLayout {
                        anchors.fill: parent
                        anchors.leftMargin: Theme.spacingM
                        anchors.rightMargin: Theme.spacingM
                        spacing: Theme.spacingM
                    
                        Item {
                            Layout.preferredWidth: 26
                            Layout.preferredHeight: 26
                            Layout.alignment: Qt.AlignVCenter
                            clip: true
                    
                            DankIcon {
                                anchors.centerIn: parent
                                name: BatteryService.getExternalDeviceIcon(modelData.type)
                                size: Theme.iconSizeSmall
                                color: Theme.surfaceText
                            }
                        }
                    
                        StyledText {
                            Layout.fillWidth: true
                            Layout.alignment: Qt.AlignVCenter
                            text: (modelData.model && modelData.model.length > 0) ? modelData.model : UPowerDeviceType.toString(modelData.type)
                            font.pixelSize: Theme.fontSizeMedium
                            font.weight: Font.Medium
                            color: Theme.surfaceText
                            elide: Text.ElideRight
                        }
                    
                        StyledText {
                            Layout.alignment: Qt.AlignVCenter
                            text: `${Math.round(modelData.percentage * 100)}%`
                            font.pixelSize: Theme.fontSizeMedium
                            font.weight: Font.Bold
                            color: Math.round(modelData.percentage * 100) <= 20 ? Theme.error : Theme.surfaceText
                        }
                    }
                }
            }
        }
        StyledRect {
            width: parent.width
            height: degradationContent.implicitHeight + Theme.spacingL * 2
            radius: Theme.cornerRadius
            color: Theme.errorHover
            border.color: Theme.errorSelected
            border.width: 0
            visible: (typeof PowerProfiles !== "undefined") && PowerProfiles.degradationReason !== PerformanceDegradationReason.None

            Column {
                id: degradationContent
                width: parent.width - Theme.spacingL * 2
                anchors.left: parent.left
                anchors.top: parent.top
                anchors.margins: Theme.spacingL
                spacing: Theme.spacingS

                Row {
                    width: parent.width
                    spacing: Theme.spacingM

                    DankIcon {
                        name: "warning"
                        size: Theme.iconSize
                        color: Theme.error
                        anchors.verticalCenter: parent.verticalCenter
                    }

                    Column {
                        spacing: Theme.spacingXS
                        anchors.verticalCenter: parent.verticalCenter
                        width: parent.width - Theme.iconSize - Theme.spacingM

                        StyledText {
                            text: I18n.tr("Power Profile Degradation")
                            font.pixelSize: Theme.fontSizeLarge
                            color: Theme.error
                            font.weight: Font.Medium
                        }

                        StyledText {
                            text: (typeof PowerProfiles !== "undefined") ? PerformanceDegradationReason.toString(PowerProfiles.degradationReason) : ""
                            font.pixelSize: Theme.fontSizeSmall
                            color: Theme.withAlpha(Theme.error, 0.8)
                            wrapMode: Text.WordWrap
                            width: parent.width
                            horizontalAlignment: Text.AlignLeft
                        }
                    }
                }
            }
        }
    }
}
