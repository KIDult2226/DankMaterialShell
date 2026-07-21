import QtQuick
import QtQuick.Effects
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Common
import qs.Widgets

PanelWindow {
    id: root

    WlrLayershell.namespace: "dms:dock-preview"
    WlrLayershell.layer: WlrLayershell.Overlay
    WlrLayershell.exclusiveZone: -1

    Component.onCompleted: {
        var p = Qt.createQmlObject('import Quickshell.Io; Process { running: true; command: ["sh", "-c", "echo \\\"[DockPreview] COMPONENT LOADED\\\" >> /tmp/dms-dock-debug.log"] }', root, "dbgProc")
    }

    function dbgLog(msg) {
        var p = Qt.createQmlObject('import Quickshell.Io; Process { running: true; command: ["sh", "-c", "echo \\\"' + msg + '\\\" >> /tmp/dms-dock-debug.log"] }', root, "dbgProc" + Math.random())
    }

    property var toplevels: []
    property var targetScreen: null
    property bool isVertical: false
    property string dockPosition: "bottom"
    property bool castReady: false
    property bool aspectSet: false
    property int refreshCounter: 0
    property string castTargetId: ""
    property bool previewHidden: true
    property bool previewContainsMouse: false
    property real contentOpacity: 0
    property bool helperRunning: false
    property var _niriIdList: []
    property real _helperStartTime: 0
    property int pendingSnapId: -1
    property int activeSnapId: -1
    property bool snapCancelRequested: false
    visible: false
    color: "transparent"
    screen: targetScreen

    readonly property real thumbH: 125
    property real thumbW: 200
    readonly property real gap: 8
    readonly property int count: Math.max(1, toplevels.length)
    readonly property real totalW: count * thumbW + (count - 1) * gap
    readonly property real totalH: thumbH

    implicitWidth: totalW
    implicitHeight: totalH

    anchors {
        top: true
        left: true
    }

    margins {
        left: 0
        top: 0

        Behavior on left { NumberAnimation { duration: 150; easing.type: Easing.OutCubic } }
        Behavior on top { NumberAnimation { duration: 150; easing.type: Easing.OutCubic } }
    }

    readonly property string helperPath: "/usr/share/quickshell/dms/Modules/Dock/dms-cast-helper.py"

    // ─── Helper lifecycle (no persistent process on idle) ───

    Process {
        id: startHelperProc
        running: false
        onExited: (exitCode) => {
            dbgLog("helper startProc exit=" + exitCode)
        }
    }

    function startHelper(targetIds) {
        var idsArr = typeof targetIds === "number" ? [targetIds] : targetIds
        var idsStr = idsArr.join(" ")
        var rmGlobs = idsArr.map(function(id) { return "/dev/shm/dms-dock-preview-" + id + ".jpg" }).join(" ")
        dbgLog("starting helper with targets " + idsStr)
        // Delete stale per-window JPEGs, then start nohup helper in background
        // The helper runs until killed by stopHelper or until screen cast stops
        startHelperProc.command = [
            "sh", "-c",
            "rm -f " + rmGlobs + " && nohup python3 " + root.helperPath + " run --no-cycle --ids " + idsStr +
            " >> /tmp/dms-debug.log 2>&1 &"
        ]
        startHelperProc.running = true
        root.helperRunning = true
        root._helperStartTime = new Date().getTime()
    }

    function switchTarget(targetId) {
        root.castTargetId = String(targetId)
        root.castReady = false
        snapWindow(targetId)
        sizeReadTimer.running = true
    }

    // ─── Helper stop (for session timeout, not for target switching) ───
    Process {
        id: stopHelperProc
        running: false
        onExited: (exitCode) => {
            dbgLog("helper stopped exit=" + exitCode)
        }
    }

    function stopHelper() {
        if (root.helperRunning) {
            root.helperRunning = false
            dbgLog("stopHelper: pkill all cast helpers")
            stopHelperProc.command = ["pkill", "-f", "dms-cast-helper"]
            stopHelperProc.running = true
        }
    }

    // ─── Snap: create per-window JPEG from current stream ───
    Process {
        id: snapProc
        running: false
        onExited: (exitCode) => {
            dbgLog("snap exit=" + exitCode + " id=" + root.activeSnapId)
            var completedId = root.activeSnapId
            root.activeSnapId = -1
            root.snapCancelRequested = false
            if (root.pendingSnapId !== -1 && root.pendingSnapId !== completedId) {
                var nextId = root.pendingSnapId
                root.pendingSnapId = -1
                _startSnap(nextId)
            } else {
                root.pendingSnapId = -1
            }
        }
    }

    Process {
        id: cancelSnapProc
        running: false
        onExited: (exitCode) => {
            dbgLog("cancel-snap exit=" + exitCode + " active=" + root.activeSnapId + " pending=" + root.pendingSnapId)
        }
    }

    function _startSnap(wid) {
        root.activeSnapId = wid
        snapProc.command = [
            "sh", "-c",
            "rm -f /dev/shm/dms-dock-preview-" + String(wid) + ".jpg && " +
            "python3 /home/kidult226/.local/share/dms/dms-cast-helper.py " +
            "snap --ids " + String(wid) + " >> /tmp/dms-debug.log 2>&1"
        ]
        snapProc.running = true
    }

    function snapWindow(wid) {
        root.pendingSnapId = wid
        if (snapProc.running) {
            if (root.activeSnapId !== wid && !root.snapCancelRequested) {
                root.snapCancelRequested = true
                cancelSnapProc.command = ["pkill", "-f", "dms-cast-helper.py snap --ids"]
                cancelSnapProc.running = true
                dbgLog("cancel stale snap id=" + root.activeSnapId + " for id=" + wid)
            }
            return
        }
        var nextId = root.pendingSnapId
        root.pendingSnapId = -1
        _startSnap(nextId)
    }

    // ─── Timers ───

    // Session stop: kill helper after hide, with guard for burst completion.
    Timer {
        id: sessionStopTimer
        interval: 500
        repeat: false
        onTriggered: {
            if (root.previewHidden && root.helperRunning) {
                var age = new Date().getTime() - root._helperStartTime
                if (age < 5000) {
                    dbgLog("session timeout — helper too young (" + age + "ms), deferring")
                    sessionStopTimer.restart()
                    return
                }
                dbgLog("session timeout — stopping helper")
                stopHelper()
            }
        }
    }

    // Window size query (exit-code data channel)
    Timer {
        id: sizeReadTimer
        interval: 50
        running: false
        repeat: false
        onTriggered: {
            sizeParseProc.command = [
                "python3", "-c",
                "import json,subprocess,sys; r=subprocess.run(['niri','msg','--json','windows'],capture_output=True,text=True); wins=json.loads(r.stdout); m=next((w for w in wins if w.get('id')==%1),None); ws=m.get('layout',{}).get('window_size',[0,0]) if m else [0,0]; w,h=ws[0],ws[1]; thumbW=max(80,min(300,round(125*w/h))) if h>0 else 200; sys.exit(thumbW-80)".replace("%1", String(root.castTargetId || 0))
            ]
            sizeParseProc.running = true
        }
    }

    Process {
        id: sizeParseProc
        running: false
        onExited: (exitCode) => {
            var newW = exitCode + 80
            root.thumbW = newW
            root.aspectSet = true
            root._updatePosition()
            dbgLog("thumbW=" + newW + " (exit=" + exitCode + ")")
        }
    }

    // Bounded retry: fires up to ~60 times (12s) after show() to load burst JPEGs.
    // Stops when all visible images are loaded, or when max ticks reached.
    Timer {
        id: refreshTimer
        interval: 200
        repeat: true
        running: false
        property int ticks: 0
        onTriggered: {
            ticks++
            root.refreshCounter++
            if (ticks >= 60) { ticks = 0; stop(); return }
        }
    }

    // ─── Show / Hide ───

    function show(windows, screen, pos, vertical, position, magExtra) {
        root.previewHidden = false
        hideDelayTimer.stop()
        sessionStopTimer.stop()
        refreshTimer.ticks = 0

        toplevels = windows
        castReady = false
        targetScreen = screen
        isVertical = vertical
        dockPosition = position

        var niriWindows = windows.filter(function(w) { return w.niriWindowId !== undefined })
        if (niriWindows.length > 0) {
            var niriIds = niriWindows.map(function(w) { return w.niriWindowId })
            var targetId = niriIds[0]

            if (!root.helperRunning) {
                // First hover: start helper with all window IDs
                root.castTargetId = String(targetId)
                root._niriIdList = niriIds.slice()
                startHelper(niriIds)
                sizeReadTimer.running = true
            } else if (niriIds.indexOf(parseInt(root.castTargetId)) === -1) {
                // Different app — just switch target, helper session stays alive
                dbgLog("switching target to " + niriIds[0] + " (helper stays)")
                root.castTargetId = String(targetId)
                root._niriIdList = niriIds.slice()
                switchTarget(niriIds[0])
                sizeReadTimer.running = true
            } else {
                // Same target re-hover: retry snap so a previous failed capture can recover.
                root.castTargetId = String(targetId)
                root._niriIdList = niriIds.slice()
                snapWindow(targetId)
                sizeReadTimer.running = true
            }

            // castReady = true immediately; if per-window JPEGs don't exist yet,
            // Image retries via refreshTimer (bounded 3s burst). Fallback icon fills gap.
            castReady = true
            refreshTimer.running = true
        }

        root._lastPos = pos
        root._lastScreen = screen
        root._lastVertical = vertical
        root._lastPosition = position
        root._lastMagExtra = magExtra || 0
        root._updatePosition()
        root.visible = true
        root.contentOpacity = 1
        dbgLog("show: " + windows.length + " windows target=" + root.castTargetId + " helper=" + root.helperRunning)
    }

    property var _lastPos: null
    property var _lastScreen: null
    property bool _lastVertical: false
    property string _lastPosition: "bottom"
    property real _lastMagExtra: 0

    function _updatePosition() {
        if (root.previewHidden) return
        var pos = root._lastPos
        var screen = root._lastScreen
        var vertical = root._lastVertical
        var position = root._lastPosition
        var me = root._lastMagExtra

        if (!pos || !screen) return

        var screenW = screen.width
        var screenH = screen.height
        var left, top

        if (!vertical) {
            left = Math.max(8, Math.min(pos.x - totalW / 2, screenW - totalW - 8))
            if (position === "bottom")
                top = screenH - totalH - 80 - me
            else
                top = 80 + me
        } else {
            top = Math.max(8, Math.min(pos.y - totalH / 2, screenH - totalH - 8))
            if (position === "left")
                left = 80 + me
            else
                left = screenW - totalW - 80 - me
        }

        root.margins.left = left
        root.margins.top = top
        dbgLog("position: left=" + left + " top=" + top + " W=" + totalW + " H=" + totalH)
    }

    onThumbWChanged: {
        if (!root.previewHidden) _updatePosition()
    }

    function hide() {
        hideDelayTimer.restart()
    }

    function actuallyHide() {
        refreshTimer.ticks = 0
        refreshTimer.stop()
        root.castReady = false
        root.previewHidden = true
        root.contentOpacity = 0
        sessionStopTimer.restart()
        hideDelay.restart()
        if (dockTooltip) dockTooltip.hide()
    }

    // Deferred hide grace period: if mouse enters preview, cancel
    Timer {
        id: hideDelayTimer
        interval: 200
        repeat: false
        onTriggered: {
            if (!root.previewContainsMouse) {
                actuallyHide()
                dbgLog("hideDelayTimer: actuallyHide()")
            } else {
                dbgLog("hideDelayTimer: mouse on preview, skip")
            }
        }
    }

    Timer {
        id: hideDelay
        interval: 150
        repeat: false
        onTriggered: {
            if (root.previewHidden) root.visible = false
        }
    }

    Item {
        id: contentItem
        width: root.totalW
        height: root.totalH
        opacity: root.contentOpacity

        Behavior on opacity {
            NumberAnimation { duration: 120; easing.type: Easing.OutCubic }
        }
        Behavior on width { NumberAnimation { duration: 150; easing.type: Easing.OutCubic } }
        Behavior on height { NumberAnimation { duration: 150; easing.type: Easing.OutCubic } }

        // Hover tracking: lets mouse move from dock to preview without dismissing
        MouseArea {
            id: previewHoverArea
            anchors.fill: parent
            hoverEnabled: true
            acceptedButtons: Qt.NoButton
            onEntered: {
                root.previewContainsMouse = true
                hideDelayTimer.stop()
                dbgLog("preview: mouse entered")
            }
            onExited: {
                root.previewContainsMouse = false
                root.hide()
                dbgLog("preview: mouse exited → hide()")
            }
            z: -1
        }

        Row {
            id: thumbRow
            spacing: root.gap

            Repeater {
                model: root.toplevels

                Item {
                    width: root.thumbW
                    height: root.thumbH

                    Rectangle {
                        id: thumbBg
                        anchors.fill: parent
                        radius: Theme.cornerRadius
                        color: Qt.rgba(Theme.surfaceContainer.r, Theme.surfaceContainer.g, Theme.surfaceContainer.b, 0.95)
                        border.color: Theme.withAlpha(Theme.outline, 0.3)
                        border.width: 1
                        clip: true

                        // Hyprland: live ScreencopyView
                        ScreencopyView {
                            id: screencopy
                            anchors.fill: parent
                            anchors.margins: 2
                            captureSource: modelData ? (modelData.wayland || null) : null
                            live: true
                            visible: modelData && modelData.wayland !== undefined && screencopy.status === ScreencopyView.Ready
                        }

                        // niri: per-window JPEG from dynamic cast -> GStreamer -> snap_current()
                        Image {
                            id: niriLive
                            anchors.fill: parent
                            anchors.margins: 2
                            source: {
                                if (!root.castReady || !modelData || modelData.niriWindowId === undefined)
                                    return ""
                                return "file:///dev/shm/dms-dock-preview-" + modelData.niriWindowId + ".jpg?t=" + root.refreshCounter
                            }
                            fillMode: Image.PreserveAspectFit
                            cache: false
                            visible: modelData && modelData.niriWindowId !== undefined && root.castReady && niriLive.status === Image.Ready
                        }

                        // Fallback: app icon (shown during helper startup ~2s)
                        Item {
                            id: fallbackIcon
                            anchors.fill: parent
                            anchors.margins: 8
                            visible: !screencopy.visible && !niriLive.visible

                            Image {
                                anchors.centerIn: parent
                                source: modelData && modelData.appId ? Quickshell.iconPath(modelData.appId, "application-x-executable") : ""
                                sourceSize.width: 64
                                sourceSize.height: 64
                                fillMode: Image.PreserveAspectCrop
                                width: Math.min(parent.width, parent.height) * 0.6
                                height: width
                                visible: modelData && modelData.appId && Quickshell.iconPath(modelData.appId, "").length > 0
                            }

                            StyledText {
                                anchors.centerIn: parent
                                text: {
                                    if (!modelData || !modelData.appId) return "?"
                                    return modelData.appId.charAt(0).toUpperCase()
                                }
                                font.pixelSize: 32
                                color: Theme.surfaceText
                                visible: !(modelData && modelData.appId && Quickshell.iconPath(modelData.appId, "").length > 0)
                            }
                        }

                        StyledText {
                            anchors.bottom: parent.bottom
                            anchors.horizontalCenter: parent.horizontalCenter
                            anchors.bottomMargin: 4
                            text: {
                                if (!modelData || !modelData.title)
                                    return ""
                                var t = modelData.title
                                return t.length > 25 ? t.substring(0, 25) + "..." : t
                            }
                            font.pixelSize: 11
                            color: Theme.surfaceText
                            elide: Text.ElideRight
                        }
                    }

                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            if (modelData && modelData.activate)
                                modelData.activate()
                            root.actuallyHide()
                        }
                    }
                }
            }
        }
    }
}
