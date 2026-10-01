pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import QtWebSockets
import Quickshell
import Quickshell.Io
import qs
import qs.services
import qs.modules.common
import qs.modules.common.widgets
import qs.modules.ii.overlay

// OBS over its built-in WebSocket server (obs-websocket 5): a live preview of
// the program scene, recording and streaming, and the scene list. The port and
// password come from OBS's own settings file, so there is nothing to set up
// here; starting OBS from the widget switches the server on first.
StyledOverlayWidget {
    id: root
    title: "OBS"
    minimumWidth: 340
    minimumHeight: 330

    readonly property string configPath: `${Quickshell.env("HOME")}/.config/obs-studio/plugin_config/obs-websocket/config.json`
    readonly property var config: {
        try {
            return JSON.parse(configFile.text());
        } catch (e) {
            return {};
        }
    }

    property bool connected: false
    property bool recording: false
    property bool streaming: false
    property int recordMs: 0
    property int streamMs: 0
    property string currentScene: ""
    property list<string> scenes: []
    property string preview: ""
    property int nextId: 0
    property var pending: ({})

    FileView {
        id: configFile
        path: root.configPath
        watchChanges: true
        onFileChanged: reload()
    }

    function request(type, data, onReply) {
        if (!root.connected)
            return;
        const id = `${root.nextId++}`;
        if (onReply)
            root.pending[id] = onReply;
        socket.sendTextMessage(JSON.stringify({ op: 6, d: { requestType: type, requestId: id, requestData: data ?? {} } }));
    }

    function refreshAll() {
        request("GetSceneList", {}, d => {
            root.scenes = d.scenes.map(s => s.sceneName).reverse();  // OBS lists the bottom scene first
            root.currentScene = d.currentProgramSceneName;
        });
        refreshOutputs();
    }

    function refreshOutputs() {
        request("GetRecordStatus", {}, d => {
            root.recording = d.outputActive;
            root.recordMs = d.outputDuration;
        });
        request("GetStreamStatus", {}, d => {
            root.streaming = d.outputActive;
            root.streamMs = d.outputDuration;
        });
    }

    function refreshPreview() {
        if (!root.currentScene)
            return;
        request("GetSourceScreenshot", {
            sourceName: root.currentScene,
            imageFormat: "jpg",
            imageWidth: 480,
            imageCompressionQuality: 70
        }, d => root.preview = d.imageData);
    }

    function identify(auth) {
        // Scenes (1 << 2) and Outputs (1 << 6) events.
        socket.sendTextMessage(JSON.stringify({ op: 1, d: { rpcVersion: 1, authentication: auth, eventSubscriptions: 68 } }));
    }

    function timecode(ms) {
        const s = Math.floor(ms / 1000);
        const pad = n => `${n}`.padStart(2, "0");
        return (s >= 3600 ? `${Math.floor(s / 3600)}:` : "") + `${pad(Math.floor(s / 60) % 60)}:${pad(s % 60)}`;
    }

    WebSocket {
        id: socket
        url: `ws://127.0.0.1:${root.config.server_port ?? 4455}`
        active: false
        onStatusChanged: {
            if (socket.status !== WebSocket.Open) {
                root.connected = false;
                root.pending = {};
            }
        }
        onTextMessageReceived: message => {
            const msg = JSON.parse(message);
            switch (msg.op) {
            case 0: // Hello
                if (msg.d.authentication) {
                    authProc.salt = msg.d.authentication.salt;
                    authProc.challenge = msg.d.authentication.challenge;
                    authProc.running = true;
                } else {
                    root.identify(undefined);
                }
                break;
            case 2: // Identified
                root.connected = true;
                root.refreshAll();
                root.refreshPreview();
                break;
            case 5: { // Event
                const d = msg.d.eventData ?? {};
                switch (msg.d.eventType) {
                case "CurrentProgramSceneChanged":
                    root.currentScene = d.sceneName;
                    root.refreshPreview();
                    break;
                case "SceneListChanged":
                case "SceneNameChanged":
                    root.refreshAll();
                    break;
                case "RecordStateChanged":
                case "StreamStateChanged":
                    root.refreshOutputs();
                    break;
                }
                break;
            }
            case 7: { // RequestResponse
                const callback = root.pending[msg.d.requestId];
                delete root.pending[msg.d.requestId];
                if (!msg.d.requestStatus.result)
                    console.warn(`[OBS] ${msg.d.requestType} failed: ${msg.d.requestStatus.comment ?? msg.d.requestStatus.code}`);
                else if (callback)
                    callback(msg.d.responseData ?? {});
                break;
            }
            }
        }
    }

    // obs-websocket's challenge: base64(sha256(base64(sha256(password + salt)) + challenge)).
    // The password is read from OBS's file inside the helper and never passes
    // through an argument list.
    Process {
        id: authProc
        property string salt
        property string challenge
        command: ["python3", "-c", `
import base64, hashlib, json, sys
c = json.load(open(sys.argv[1]))
h = lambda b: base64.b64encode(hashlib.sha256(b).digest())
print(h(h((c.get("server_password", "") + sys.argv[2]).encode()) + sys.argv[3].encode()).decode())`,
            root.configPath, salt, challenge]
        stdout: StdioCollector {
            onStreamFinished: root.identify(text.trim())
        }
    }

    // OBS can be closed and opened at any time; keep trying while the widget
    // is on screen, and nothing while it is not.
    Timer {
        interval: 3000
        running: root.visible && !root.connected && root.config.server_enabled === true
        repeat: true
        triggeredOnStart: true
        onTriggered: {
            socket.active = false;
            socket.active = true;
        }
    }
    Timer {
        interval: 500
        running: root.visible && root.connected
        repeat: true
        onTriggered: root.refreshPreview()
    }
    Timer {
        interval: 1000
        running: root.visible && root.connected && (root.recording || root.streaming)
        repeat: true
        onTriggered: root.refreshOutputs()
    }

    // The server setting is only safe to change while OBS is closed: OBS
    // writes its settings back when it quits.
    function startObs() {
        Quickshell.execDetached(["bash", "-c", `
            pgrep -x obs >/dev/null && exit
            python3 - "$1" <<'PY'
import json, os, secrets, sys
p = sys.argv[1]
c = json.load(open(p)) if os.path.exists(p) else {"server_port": 4455, "auth_required": True, "alerts_enabled": False}
c["server_enabled"] = True
c["first_load"] = False
if c.get("auth_required", True) and not c.get("server_password"):
    c["server_password"] = secrets.token_urlsafe(12)
os.makedirs(os.path.dirname(p), exist_ok=True)
json.dump(c, open(p, "w"), indent=4)
PY
            setsid obs --minimize-to-tray >/dev/null 2>&1 &`, "obs-start", root.configPath]);
    }

    contentItem: OverlayBackground {
        id: contentItem
        radius: root.contentRadius

        ColumnLayout {
            anchors {
                fill: parent
                margins: 8
            }
            spacing: 8
            visible: root.connected

            // Program preview, with what is live drawn over it.
            Rectangle {
                Layout.fillWidth: true
                Layout.preferredHeight: width * 9 / 16
                radius: Appearance.rounding.small
                color: "black"
                clip: true

                Image {
                    anchors.fill: parent
                    source: root.preview
                    fillMode: Image.PreserveAspectFit
                    cache: false
                    smooth: true
                }

                Row {
                    anchors {
                        top: parent.top
                        left: parent.left
                        margins: 6
                    }
                    spacing: 4
                    Badge {
                        visible: root.recording
                        label: "● " + root.timecode(root.recordMs)
                        colBackground: Appearance.m3colors.m3error
                        colText: Appearance.m3colors.m3onError
                    }
                    Badge {
                        visible: root.streaming
                        label: "LIVE " + root.timecode(root.streamMs)
                        colBackground: Appearance.colors.colPrimary
                        colText: Appearance.colors.colOnPrimary
                    }
                }
            }

            RowLayout {
                Layout.fillWidth: true
                spacing: 6
                ControlButton {
                    Layout.fillWidth: true
                    materialSymbol: root.recording ? "stop" : "fiber_manual_record"
                    label: root.recording ? Translation.tr("Stop recording") : Translation.tr("Record")
                    toggled: root.recording
                    onClicked: root.request(root.recording ? "StopRecord" : "StartRecord")
                }
                ControlButton {
                    Layout.fillWidth: true
                    materialSymbol: "sensors"
                    label: root.streaming ? Translation.tr("End stream") : Translation.tr("Go live")
                    toggled: root.streaming
                    onClicked: root.request(root.streaming ? "StopStream" : "StartStream")
                }
            }

            StyledFlickable {
                Layout.fillWidth: true
                Layout.fillHeight: true
                contentHeight: sceneFlow.implicitHeight
                clip: true

                FlowButtonGroup {
                    id: sceneFlow
                    width: parent.width
                    spacing: 4
                    Repeater {
                        model: root.scenes
                        delegate: SelectionGroupButton {
                            required property string modelData
                            leftmost: true
                            rightmost: true
                            buttonText: modelData
                            toggled: modelData === root.currentScene
                            onClicked: root.request("SetCurrentProgramScene", { sceneName: modelData })
                        }
                    }
                }
            }
        }

        // Not connected: say why, and offer the one thing that fixes it.
        ColumnLayout {
            anchors.centerIn: parent
            visible: !root.connected
            spacing: 10

            MaterialSymbol {
                Layout.alignment: Qt.AlignHCenter
                text: "videocam_off"
                iconSize: 40
                color: Appearance.colors.colSubtext
            }
            StyledText {
                Layout.alignment: Qt.AlignHCenter
                Layout.maximumWidth: 280
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.WordWrap
                color: Appearance.colors.colSubtext
                text: root.config.server_enabled === true
                    ? Translation.tr("OBS is not running")
                    : Translation.tr("OBS's WebSocket server is off. Starting OBS from here turns it on.")
            }
            ControlButton {
                Layout.alignment: Qt.AlignHCenter
                materialSymbol: "play_arrow"
                label: Translation.tr("Start OBS")
                onClicked: root.startObs()
            }
        }
    }

    component Badge: Rectangle {
        id: badge
        property string label
        property color colText
        property color colBackground
        color: colBackground
        radius: height / 2
        implicitHeight: badgeText.implicitHeight + 4
        implicitWidth: badgeText.implicitWidth + 12
        StyledText {
            id: badgeText
            anchors.centerIn: parent
            text: badge.label
            color: badge.colText
            font {
                family: Appearance.font.family.numbers
                pixelSize: Appearance.font.pixelSize.smaller
                weight: Font.DemiBold
            }
        }
    }

    component ControlButton: RippleButton {
        id: control
        required property string materialSymbol
        required property string label
        implicitHeight: 40
        implicitWidth: contentRow.implicitWidth + 28
        buttonRadius: height / 2
        colBackground: Appearance.colors.colLayer3
        colBackgroundHover: Appearance.colors.colLayer3Hover
        colRipple: Appearance.colors.colLayer3Active
        colBackgroundToggled: Appearance.colors.colSecondaryContainer
        colBackgroundToggledHover: Appearance.colors.colSecondaryContainerHover
        colRippleToggled: Appearance.colors.colSecondaryContainerActive
        contentItem: Item {
            Row {
                id: contentRow
                anchors.centerIn: parent
                spacing: 6
                MaterialSymbol {
                    anchors.verticalCenter: parent.verticalCenter
                    text: control.materialSymbol
                    iconSize: 20
                    fill: control.toggled ? 1 : 0
                    color: control.toggled ? Appearance.colors.colOnSecondaryContainer : Appearance.colors.colOnLayer3
                }
                StyledText {
                    anchors.verticalCenter: parent.verticalCenter
                    visible: control.label.length > 0
                    text: control.label
                    color: control.toggled ? Appearance.colors.colOnSecondaryContainer : Appearance.colors.colOnLayer3
                }
            }
        }
    }
}
