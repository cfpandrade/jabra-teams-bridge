# jabra-teams-bridge

Makes the boom arm and the call button on a Jabra headset actually control
Microsoft Teams on Linux, by bridging raw HID Telephony reports to the MQTT
interface of [teams-for-linux](https://github.com/IsmaelMartinez/teams-for-linux).

The headset already cuts the microphone in firmware when you raise the boom
arm, so you *are* muted. Teams just never finds out, which means the meeting
still shows you as unmuted, the mute button in the UI disagrees with the
hardware, and pressing the headset's call button does nothing at all.

## Why this is not a five-line script

Three separate things are broken, and each one hides the next. All of them were
measured on a Jabra Evolve2 75 with a Link 380 dongle, kernel 7.0, Ubuntu,
teams-for-linux 2.20.0 from the `.deb`.

### 1. The headset goes silent unless the host agrees with it

The `Phone Mute` usage (report 2, byte 1, bit 3) is a **relative** control
(`0x81 0x07` in the report descriptor) that fires a pulse ~1 ms wide. It is not
a level, so you cannot read the arm's position from it.

Worse, the device only reports it under two conditions, documented by Jabra
themselves in the kernel driver they wrote:

> key press events are only generated in the offhook state and only if the mute
> state set by the host matches the mute state of the headset
>
> — [`HID: jabra: Change mute LED state to avoid missing key press events`](https://lkml.iu.edu/hypermail/linux/kernel/2107.0/01638.html)

That single sentence explains the symptom everyone hits: **only one direction of
the arm works.** If the host's mute state is static, only the movement that
happens to agree with it gets reported; the opposite movement is swallowed. Set
the host state to muted and the behaviour flips: now lowering works and raising
does not.

The fix is to flip the host-side mute bit after every pulse, so the two stay in
agreement whichever way the arm moves next. That is exactly what the in-tree
`hid-jabra` driver does with its LED, and what this daemon does through the
output report.

### 2. The call button is inert until the host declares off-hook

Pressing the call button produced **zero** HID reports, in or out of a call. The
`Hook Switch` bit (report 2, byte 1, bit 0) never once went high in hours of
capture.

In HID Telephony the host has to declare the call state by writing an output
report. Nobody was doing it: teams-for-linux does not speak HID at all. Writing
`Off-Hook` woke the switch up 0.1 ms later. The `Line` bit that *does* move on
its own is not the button, it is the dongle noticing that something opened its
audio stream.

Output report 2, LED page, 7 bits:

| Bit | Mask | Usage | Meaning |
|-----|------|-------|---------|
| 0 | `0x01` | `0x17` | Off-Hook |
| 1 | `0x02` | `0x1e` | — |
| 2 | `0x04` | `0x09` | Mute |
| 3 | `0x08` | `0x18` | Ring |
| 4-6 | `0x10`/`0x20`/`0x40` | `0x20`/`0x21`/`0x2a` | — |

### 3. teams-for-linux ignores its own MQTT commands unless it has focus

`sendKeyboardEventToWindow` uses `webContents.sendInputEvent`, which delivers
the key to the renderer but does not grant focus, and the Teams web app only
dispatches its shortcuts when the document is focused. So the MQTT commands
worked with the window in the foreground and silently did nothing behind it —
which defeats their entire purpose.

`tools/tfl-patch-call-actions` fixes this with a `webContents.focus()` call, and
also widens the MQTT action whitelist, which ships with no way to hang up a
call. The whitelist is derived from `actionShortcutMap`, so adding entries is
enough:

| Action added | Shortcut |
|---|---|
| `hangup` | `Ctrl+Shift+H` |
| `accept-audio` | `Ctrl+Shift+S` |
| `accept-video` | `Ctrl+Shift+A` |
| `decline` | `Ctrl+Shift+D` |

## Status

| Feature | State |
|---|---|
| Mute both directions of the boom arm | **Verified** |
| Mute polarity (arm up = muted) | **Verified**, aligned once per call |
| MQTT commands with Teams in the background | **Verified** |
| `hangup` accepted and executed by Teams | **Verified** |
| Call button driving hangup end to end | **Untested** — logic wired to `Hook Switch`, not yet confirmed on hardware |
| Answering an incoming call with the button | **Untested** |
| Stray `Volume Decrement` reports after writing the output report | **Open question.** Four consecutive volume-down pairs were seen right after the first off-hook write. It may lower call volume. Watch for it and open an issue. |

## Requirements

- A Jabra headset. Tested on an Evolve2 75 with a Link 380 dongle
- `teams-for-linux` with MQTT enabled, and a broker on localhost
- Python 3, `mosquitto`, `mosquitto-clients`

On Debian and Ubuntu:

```bash
sudo apt install python3 mosquitto mosquitto-clients
sudo systemctl enable --now mosquitto
```

And in `~/.config/teams-for-linux/config.json`:

```json
{ "mqtt": { "enabled": true, "brokerUrl": "mqtt://localhost:1883",
            "topicPrefix": "teams" } }
```

## Install

```bash
git clone https://github.com/cfpandrade/jabra-teams-bridge
cd jabra-teams-bridge
./install.sh
tfl-patch-call-actions     # patches teams-for-linux, asks for sudo
```

Restart teams-for-linux afterwards so it loads the patched bundle.

**The patch must be reapplied after every teams-for-linux upgrade**, since the
package restores its own `app.asar`. The script is idempotent, so just run it
again. It verifies that the repacked archive is structurally identical to the
original before installing anything, keeps a timestamped backup, and aborts
without touching `/opt` if anything does not line up.

## Configuration

Environment variables, set them in a systemd drop-in:

```bash
systemctl --user edit jabra-teams-bridge.service
```

| Variable | Default | Meaning |
|---|---|---|
| `JABRA_MQTT_HOST` / `JABRA_MQTT_PORT` | `localhost` / `1883` | Broker |
| `JABRA_TOPIC_PREFIX` | `teams` | Must match `topicPrefix` |
| `JABRA_REQUIRE_CALL` | `1` | Ignore the arm outside a call |
| `JABRA_DECLARE_STATE` | `1` | Write Off-Hook/Ring/Mute to the headset |
| `JABRA_ALIGN` | `1` | Align mute polarity once per call |
| `JABRA_HOOK` | `1` | Bridge the call button |
| `JABRA_WRITE_LED` | `0` | Legacy: drive the mute LED directly. Breaks the handshake |
| `JABRA_DEBUG` | `0` | Log every HID report with decoded bits |

`JABRA_DEBUG=1` is the first thing to turn on when something misbehaves.

## Known limitations

**Mute polarity is aligned by assumption, not measurement.** A pulse only says
"the arm moved", so arm and Teams agree only if they agreed when the call
started. The daemon assumes Teams joins unmuted and sends one corrective toggle
if the arm is already up.

When that assumption is wrong the polarity comes out inverted, and **moving the
arm will not fix it**: every pulse flips the arm and Teams together, so the
offset between them is invariant. Correct it by flipping Teams alone — one click
on its microphone button, or `Ctrl+Shift+M`, without touching the arm.

The proper fix belongs upstream: `teams/microphone/control` is a **blind
indicator**. It reports `off` outside a call and `unmuted` inside, and never
once reported `muted` — not even with Teams genuinely muted from its own UI. Any
absolute `mute`/`unmute` command is gated on that value, so `unmute` is always
dropped as redundant and `mute` always fires blindly. Until teams-for-linux
publishes the real state, toggling is the only honest option.

**Teams takes 1-3 seconds to apply a mute**, because it round-trips through the
meeting server. Do not judge whether a change worked before then. This cost
several rounds of wrong conclusions while developing this.

## Tools

- `tools/tfl-patch-call-actions` — the teams-for-linux patcher
- `tools/webhid-test.html` — hardware diagnostic. Serve it over localhost
  (`python3 -m http.server`) and open it in Chrome or Edge to grant the device
  by WebHID and watch raw input reports live, independently of this daemon.
  Firefox has no WebHID.

Note that teams-for-linux has **no** WebHID support (no `select-hid-device`
handler anywhere in the bundle), and Teams on the web never requests the device
either, so browser-side call control is not an alternative today.

## License

MIT
