#!/usr/bin/env python3
"""Private session-bus bridge; owns only GPT-Niang's temporary KWin script."""
import json
from pathlib import Path
import signal
import sys
import time

import dbus
import dbus.service
from dbus.mainloop.glib import DBusGMainLoop
from gi.repository import GLib

SERVICE = 'org.gptniang.KDE'
OBJECT = '/org/gptniang/KDE'
PLUGIN = 'gpt-niang-kde-runtime'


def emit(value):
    print(json.dumps(value, ensure_ascii=False, separators=(',', ':')), flush=True)


class Bridge(dbus.service.Object):
    def __init__(self, bus, loop):
        self.name = dbus.service.BusName(SERVICE, bus, do_not_queue=True)
        super().__init__(self.name, OBJECT)
        self.bus = bus
        self.loop = loop
        self.config = {'settings': {'mode': 'desktop', 'alwaysOnTop': False, 'desktop': {'x': None, 'y': None}, 'follow': {'edge': 'right', 'bottom': 16}}}
        self.last = None
        self.last_seen = time.monotonic()
        self.load_script()
        GLib.timeout_add_seconds(2, self.watchdog)

    def load_script(self):
        bus = self.bus
        self.scripting = dbus.Interface(bus.get_object('org.kde.KWin', '/Scripting'), 'org.kde.kwin.Scripting')
        # A crashed UI can leave the script registered in KWin. Our exclusive
        # bus name proves that this instance is the only bridge before unload.
        self.scripting.unloadScript(PLUGIN)
        script = str(Path(__file__).resolve().parents[1] / 'kwin/follow.js')
        script_id = self.scripting.loadScript(script, PLUGIN, signature='ss')
        if script_id < 0:
            raise RuntimeError('KWin could not load the follow script')
        self.last = None
        dbus.Interface(bus.get_object('org.kde.KWin', f'/Scripting/Script{script_id}'), 'org.kde.kwin.Script').run()

    def watchdog(self):
        if time.monotonic() - self.last_seen > 5:
            try:
                self.load_script()
                self.last_seen = time.monotonic()
            except dbus.DBusException:
                emit({'type': 'bridge', 'ready': False, 'error': '等待 KWin 会话恢复…'})
        return GLib.SOURCE_CONTINUE

    @dbus.service.method(SERVICE, in_signature='s', out_signature='')
    def scriptError(self, message):
        self.last = None
        emit({'type': 'bridge', 'ready': False, 'error': 'KWin: ' + str(message)[:300]})

    @dbus.service.method(SERVICE, in_signature='s', out_signature='s', async_callbacks=('reply', 'error'))
    def exchange(self, value, reply, error):
        try:
            if len(value) > 100000:
                raise ValueError('Oversized KWin snapshot')
            state = json.loads(value)
            self.last_seen = time.monotonic()
            if self.last is None:
                emit({'type': 'bridge', 'ready': True})
            if state != self.last:
                self.last = state
                emit({'type': 'host', 'host': state})
            # Adaptive cadence: idle 10 Hz; dragging/moving 60 Hz. Quota refresh
            # is independently limited to once a minute by the shared worker.
            moving = self.config.get('drag') or (state.get('target') or {}).get('moving')
            delay = 16 if moving else 100
            def respond():
                reply(json.dumps(self.config, separators=(',', ':')))
                return GLib.SOURCE_REMOVE
            GLib.timeout_add(delay, respond)
        except (ValueError, TypeError) as exc:
            error(dbus.exceptions.DBusException(str(exc)))

    def input_ready(self, source, condition):
        if condition & GLib.IO_IN:
            line = sys.stdin.readline(65536)
            if line:
                try:
                    cfg = json.loads(line)
                    if cfg.get('command') == 'stop':
                        self.stop()
                        return GLib.SOURCE_REMOVE
                    self.config = cfg
                except (ValueError, TypeError):
                    pass
                return GLib.SOURCE_CONTINUE
        self.stop()
        return GLib.SOURCE_REMOVE

    def stop(self, *_):
        try:
            self.scripting.unloadScript(PLUGIN)
        except dbus.DBusException:
            pass
        self.loop.quit()


def main():
    DBusGMainLoop(set_as_default=True)
    loop = GLib.MainLoop()
    bridge = Bridge(dbus.SessionBus(), loop)
    GLib.io_add_watch(sys.stdin, GLib.IO_IN | GLib.IO_HUP | GLib.IO_ERR, bridge.input_ready)
    for sig in (signal.SIGTERM, signal.SIGINT):
        GLib.unix_signal_add(GLib.PRIORITY_DEFAULT, sig, bridge.stop)
    emit({'type': 'bridge', 'ready': True})
    try:
        loop.run()
    finally:
        bridge.stop()


if __name__ == '__main__':
    try:
        main()
    except Exception as exc:
        # Do not dump the session environment or any account data.
        emit({'type': 'bridge', 'ready': False, 'error': f'KWin bridge: {type(exc).__name__}: {exc}'})
        sys.exit(1)
