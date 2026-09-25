# keepmic

**Stops AirPods (and other Bluetooth headphones) from hijacking your Mac's microphone.**

When AirPods connect, macOS makes them both the audio output *and* the default input.
That second part is the problem: the moment any app records from a Bluetooth mic —
a dictation tool like Wispr Flow, a meeting app, anything — the connection drops from
the high-quality music codec (A2DP) to the low-quality headset codec, and everything
you hear turns to mush.

keepmic fixes this at the root. It's a tiny background agent that watches macOS audio
events and instantly re-pins the **default input** to your Mac's microphone whenever a
Bluetooth device takes it over — while leaving **output** on your headphones. Take your
AirPods off and on all day; the mic setting stays correct every time, with nothing to
click and nothing in your menu bar.

- **Zero UI** — no menu bar icon, no Dock icon, no windows
- **Zero polling** — event-driven via CoreAudio listeners; it sleeps until something changes
- **Zero dependencies** — one small Swift binary, no runtime, no frameworks to install
- **No permissions needed** — it never records audio, it only changes the default device,
  so there's no microphone-access prompt

## Install

Requires macOS 12+ to run. Building needs the Xcode Command Line Tools with
Swift 5.7 or newer (`xcode-select --install`).

```sh
git clone https://github.com/sanketsriv22/keepmic.git
cd keepmic
make install      # builds + installs the binary (no sudo on Homebrew-based Macs)
keepmic run       # starts the background agent; runs automatically at login
```

That's it. Put your AirPods on and check System Settings → Sound: output is your
AirPods, input stays on your Mac's mic. macOS may show a one-time
"Background Items Added" notification — that's the keepmic login agent.

No Homebrew? `make install` defaults to `/usr/local`, which needs root for the
copy step only:

```sh
make build && sudo make install-bin
keepmic run       # never run this part with sudo — it's a per-user agent
```

Upgrading later: `git pull && make install` rebuilds and restarts the agent.

## Usage

You shouldn't need to touch it again, but:

```
keepmic status           # agent state + current input/output devices
keepmic devices          # list input devices
keepmic prefer <name>    # always use this mic as input while it's connected
keepmic prefer --clear   # back to the default (built-in mic, guard Bluetooth only)
keepmic pause [minutes]  # actually need the AirPods mic? switches to it and stops
                         # enforcing for a while (default 30 min)
keepmic resume           # end the pause and re-pin now
keepmic quit             # stop keepmic and remove it from login
keepmic run              # start it again
```

Activity is logged to `~/Library/Logs/keepmic.log`.

## How it works

keepmic registers CoreAudio property listeners for the system's default input device
and the device list. When the default input changes to a device whose transport type
is Bluetooth, it immediately sets the default input back to your preferred device —
the built-in mic by default, or whatever you set with `keepmic prefer`. Because apps
like Wispr Flow record from the *system default* input, the Bluetooth headset profile
(HFP/SCO) never engages and your headphones stay in high-quality playback mode.

It's installed as a per-user launchd agent (`~/Library/LaunchAgents/com.keepmic.agent.plist`)
with `KeepAlive`, so it starts at login and restarts if it ever dies.

## FAQ

**Does it affect audio output?** No. Output routing is untouched — your AirPods stay
the output device exactly as macOS set them.

**What if I want to use the AirPods mic for a call?** `keepmic pause` switches the
default input to your Bluetooth mic and stops enforcing (30 minutes by default;
`keepmic resume` to end it early). Or pick the AirPods mic directly inside your
meeting app — apps that let you choose a specific device bypass the system default,
and keepmic only manages the system default.

**What about wired earbuds?** If wired earbuds or a wired headset are plugged in,
their mic wins automatically, even with AirPods in. keepmic moves the input to them
from the AirPods mic or the Mac's internal mic. This covers the headphone-jack mic and
USB or USB-C earbuds. A USB device counts as a headset when it has both a mic and an
output, so webcams don't. Unplug them and input falls back to the built-in mic.

**What about my USB/desk mic?** `keepmic prefer "Your Mic Name"` makes that mic the
default input whenever it's connected — plug it in and input switches to it, unplug it
and keepmic falls back to the built-in mic. Bluetooth devices still never get the input
either way.

**What if my Mac has no microphone at all?** If there's no physical non-Bluetooth
input (e.g. a Mac mini with only AirPods), keepmic leaves the input alone rather than
break your mic. Virtual/loopback devices like BlackHole are never picked automatically —
only if you explicitly `keepmic prefer` them.

**Battery/CPU cost?** Effectively none. The agent is idle until CoreAudio delivers an
event, which happens only when audio devices change.

**Why does the mic flip back if I manually select my AirPods in System Settings?**
By design — keepmic always enforces. Use `keepmic pause` when you genuinely want the
Bluetooth mic for a while.

## Uninstall

```sh
keepmic quit        # stop + remove the launchd agent
make uninstall      # remove the binary (from the repo directory)
```

To remove every trace (config, pause state, log):

```sh
rm -rf ~/Library/"Application Support"/keepmic ~/Library/Logs/keepmic.log
```

## License

MIT
