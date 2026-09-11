# Battery Insights

An Omarchy shell plugin in the spirit of macOS's Battery settings: a bar
button that opens a panel with your battery level and usage over the last
24 hours, 7 days or 30 days, and how the battery's health is holding up.

- **Battery level**: the charge line for the range. Charging is drawn in the
  theme's green, and dotted stretches are time spent asleep.
- **Usage**: battery used per hour (24h) or per day (7d/30d), split into
  awake use and drain while asleep. Hover any bar or point for details.
- **Range stats**: time on battery, battery used, average drain (W and %/h),
  how long a full charge lasts at that drain, sleep drain, and when you last
  charged.
- **Battery health**: maximum capacity against design capacity, cycle count,
  battery age, capacity lost per 100 cycles and per year, the trend measured on
  this machine, and when capacity is projected to reach 80% (the usual
  "service recommended" line).

## Install

Requires Omarchy 4 (Quattro) on a laptop.

```bash
omarchy plugin add https://github.com/aabulkhairov/omarchy-battery-insights.git --enable --yes
```

The widget lands in the right side of the bar. To put it next to the power
widget instead:

```bash
omarchy bar move aabulkhairov.battery-insights --before omarchy.power
```

It starts logging straight away and fills in the last few hours from UPower,
so the charts are not empty on first open.

### Dependencies

Nothing to install on a stock Omarchy system. The logger uses `upower` and
`gdbus` (UPower and GLib), `flock` (util-linux), GNU `awk` and coreutils.
No sudo, no system services, no network access.

## Remove

```bash
omarchy plugin remove aabulkhairov.battery-insights
```

This removes the widget from the bar and deletes the plugin. The battery logs
are kept in case you reinstall. To delete them too:

```bash
rm -rf "${XDG_STATE_HOME:-$HOME/.local/state}/battery-insights"
```

## Use

| Input | Action |
| --- | --- |
| Left click | open or close the panel |
| Right click | show or hide the live power draw (W) next to the icon |
| Middle click | refresh |
| `1` `2` `3` or `h` `l` | switch between 24 hours, 7 days and 30 days |
| `j` `k` | scroll |
| `Tab` | move to the next bar panel |
| `Esc` | close |

To open it from a keybinding, call its IPC target, for example in
`~/.config/hypr/bindings.lua`:

```lua
o.bind("SUPER + CTRL + SHIFT + B", "Battery insights", "omarchy-shell shell toggle aabulkhairov.battery-insights")
```

## How it works

`Service.qml` runs `bin/battery-insights sample` once a minute (and on every
plug or unplug). It reads the battery through UPower, so any laptop battery
works. On its first run it also imports UPower's recent history, so the
charts are not empty on day one and a shell restart leaves no hole. Logs live
in `${XDG_STATE_HOME:-~/.local/state}/battery-insights/`:

| File | Row | Kept |
| --- | --- | --- |
| `samples.csv` | `epoch,percent,energy_wh,full_wh,rate_w,state` | 31 days |
| `health.csv` | `date,full_wh,design_wh,cycles`, one per day | forever |

`state` is `C` charging, `D` discharging, `F` full, `P` plugged in but
holding (charge limit), `U` unknown. Run `bin/battery-insights info` to see
what the helper knows about your battery.

How the numbers are worked out:

- **Awake vs asleep**: readings arrive once a minute, so a gap of more than 5
  minutes between two on-battery readings counts as sleep (or powered off).
  The drop across the gap is sleep drain; everything else on battery is awake
  use. A gap that crosses an hour or midnight is shared out in proportion.
- **Average drain** is energy used while awake divided by time awake on
  battery. **Full charge lasts** is today's full capacity divided by that
  drain.
- **Health** is UPower's full-charge capacity over design capacity. *Loss per
  year* averages the loss since the manufacture date the battery reports (not
  all batteries do). *Loss per 100 cycles* uses the cycle count. *Measured
  trend* is a least-squares fit over the daily health log. The fuel gauge's
  capacity estimate wobbles by about a percent, so this waits for 14 days of
  readings. The 80% projection uses the measured trend once it exists, and
  the lifetime average until then.

Logging only happens while the widget is in your bar and you are logged in.
Removing the widget stops the logger; the logs stay where they are.

## Develop

The shell only hot-reloads plugins whose files physically live under
`~/.config/omarchy/plugins/`. To work on it from elsewhere, keep the checkout
at `~/.config/omarchy/plugins/aabulkhairov.battery-insights` and symlink
*from* your project folder *to* it, not the other way round.

The model (`Model.js`) is plain JavaScript with no QML in it and has tests:

```bash
node --test test/
```

Saving any file under the plugin directory reloads it in the running shell.
Errors show up in `quickshell log -p $OMARCHY_PATH/shell`.
