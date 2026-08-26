# discordVoice

Discord voice status and controls on the bar, forked from the Noctalia
community plugin **`raycursive/discord-voice`** (MIT, v0.3.2, plugin API 9).

Upstream: <https://github.com/noctalia-dev/community-plugins/tree/main/discord-voice>

## What was reused and what was rewritten

`discord_bridge.py` is upstream's, **unmodified**. It knows nothing about
Noctalia — it speaks Discord's local RPC over a Unix socket and exposes a plain
CLI, so it ports across untouched:

```
discord_bridge.py daemon                        newline-delimited JSON snapshots
discord_bridge.py command status | refresh | authorize | shutdown | hang-up
discord_bridge.py command set-mute true|false
discord_bridge.py command set-deaf true|false
discord_bridge.py command set-mic-volume <0-100>
discord_bridge.py command set-user-volume <user-id> <0-200>
discord_bridge.py command join-channel|favorite-channel|unfavorite-channel <id>
```

Upstream's three Luau entries were rewritten as QML, because Noctalia runs them
in an embedded Luau VM against its own plugin API and neither exists here:

| Upstream | Here |
|---|---|
| `service.luau` | `DiscordVoiceService.qml` — singleton owning the daemon |
| `bar.luau` | `DiscordVoice.qml` — bar widget |
| `panel.luau` | `DiscordVoicePanel.qml` — hover status popup |

## Controls

The popup is hover-driven, so it closes the moment the pointer leaves the
widget and anything clickable in it would be unreachable. The actions are on
the widget instead, the way `Media.qml` does it:

| | |
|---|---|
| Left click | toggle mute (or authorise, when not yet authorised) |
| Middle click | toggle deafen |
| Right click | hang up |
| Scroll | microphone volume, 5% steps |

Not ported from upstream's panel: per-participant volume, and joining or
favouriting saved channels. Both need a click-through panel; the bridge already
exposes the commands, so they are a UI job rather than a protocol one.

## Setup

```jsonc
// ~/.config/mmsimpulse/config.json
"bar": {
  "pluginWidgets": ["discordVoice"],
  "layouts": { "rightLayout": ["discordVoice", "sysTray", "utilButtons", "systemIcons", "powerButton"] }
}
```

Needs Python 3.10+ and the Discord desktop client running. First click on the
widget starts the OAuth consent flow.

## Known sharp edge

The bridge binds a fixed socket, `$XDG_RUNTIME_DIR/noctalia-discord-voice.sock`.
Running real Noctalia with the same plugin at the same time would collide. The
file is kept verbatim so it stays easy to re-sync with upstream, so this is left
as it is rather than patched.
