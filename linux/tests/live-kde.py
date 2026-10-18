#!/usr/bin/env python3
"""Optional real KWin smoke test. Only manipulates its own temporary windows.

Requires GTK4/PyGObject for the test fixtures; GTK is not a product dependency.
Run with GPT-Niang already running: python3 linux/tests/live-kde.py
"""
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import time

import dbus
import dbus.service
from dbus.mainloop.glib import DBusGMainLoop
import gi
gi.require_version('Gtk', '4.0')
from gi.repository import Gtk, GLib, Gio

ROOT = Path(__file__).resolve().parents[2]
CLI = ROOT / 'linux/gpt-niang'
TITLE = 'GPT娘 KDE 自测目标'
COVER = 'GPT娘 KDE 自测遮挡'
TEST_SERVICE = 'org.gptniang.KDELiveTest'


def command(*args):
    return subprocess.check_output([str(CLI), *args], text=True, timeout=8).strip()


def status():
    return json.loads(command('status'))


class CoverApp(Gtk.Application):
    def __init__(self):
        super().__init__(application_id='org.gptniang.KDECover', flags=Gio.ApplicationFlags.NON_UNIQUE)

    def do_activate(self):
        self.window = Gtk.ApplicationWindow(application=self, title=COVER)
        self.window.set_default_size(650, 480)
        self.window.set_child(Gtk.Label(label='GPT娘：临时遮挡验证窗口\n测试后自动关闭'))
        self.window.present()


class Probe(dbus.service.Object):
    def __init__(self, app, bus):
        self.name = dbus.service.BusName(TEST_SERVICE, bus, do_not_queue=True)
        super().__init__(self.name, '/Test')
        self.app = app

    @dbus.service.method(TEST_SERVICE, in_signature='s', out_signature='')
    def report(self, value):
        self.app.order = json.loads(value)


class Acceptance(Gtk.Application):
    def __init__(self):
        super().__init__(application_id='com.openai.codex', flags=Gio.ApplicationFlags.NON_UNIQUE)
        self.bus = dbus.SessionBus()
        self.probe = Probe(self, self.bus)
        self.scripting = dbus.Interface(self.bus.get_object('org.kde.KWin', '/Scripting'), 'org.kde.kwin.Scripting')
        self.original_mode = status()['preferences']['mode']
        self.stage = 0
        self.deadline = time.monotonic() + 40
        self.cover = None
        self.order = None
        self.target_id = None
        self.checks = []
        self.result = 1

    def do_activate(self):
        self.hold()
        command('mode', 'follow')
        self.window = Gtk.ApplicationWindow(application=self, title=TITLE)
        self.window.set_default_size(720, 500)
        self.window.set_child(Gtk.Label(label='GPT娘 KDE 兼容性自测\n正在验证跟随、遮挡和最小化\n测试后自动关闭'))
        self.window.present()
        GLib.timeout_add(500, self.step)

    def script(self, code):
        with tempfile.NamedTemporaryFile(mode='w', suffix='.js', delete=False) as file:
            file.write(code)
            source = Path(file.name)
        try:
            self.scripting.unloadScript('gpt-niang-live-test')
            ident = self.scripting.loadScript(str(source), 'gpt-niang-live-test', signature='ss')
            dbus.Interface(self.bus.get_object('org.kde.KWin', f'/Scripting/Script{ident}'), 'org.kde.kwin.Script').run()
        finally:
            source.unlink()

    def passed(self, name):
        self.checks.append(name)
        print('PASS ' + name, flush=True)
        self.stage += 1

    def step(self):
        try:
            if time.monotonic() > self.deadline:
                raise AssertionError(f'Live stage {self.stage} timed out')
            state = status()
            host = state.get('host', {})
            target = host.get('target') or {}
            pet = host.get('widget') or {}
            if self.stage == 0:
                if target.get('appId', '').lower() != 'com.openai.codex':
                    return GLib.SOURCE_CONTINUE
                self.target_id = target['id']
                self.script('var w=workspace.stackingOrder.filter(function(w){return w.caption===' + json.dumps(TITLE) + ';})[0];if(w)w.frameGeometry={x:100,y:100,width:720,height:500};')
                self.passed('native Codex app-ID discovery')
            elif self.stage == 1:
                g = target.get('geometry', {})
                if not pet or abs(g.get('x', 0) - 100) > 2:
                    return GLib.SOURCE_CONTINUE
                assert state['visible'] and state['windowVisible']
                expected_x = g['x'] + g['width'] - pet['width'] - 12
                expected_y = g['y'] + g['height'] - pet['height'] - state['preferences']['follow']['bottom']
                assert abs(pet['x'] - expected_x) <= 2, (pet, g)
                assert abs(pet['y'] - expected_y) <= 2, (pet, g)
                assert pet['noBorder']
                self.cover = subprocess.Popen([sys.executable, str(Path(__file__).resolve()), '--cover'], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                self.passed('native geometry follow and decoration removal')
            elif self.stage == 2:
                if self.order is None:
                    self.script('var a=workspace.stackingOrder;function f(t){return a.filter(function(w){return w.caption===t;})[0];}var t=f(' + json.dumps(TITLE) + '),p=f("GPT娘 · KDE 挂件"),c=f(' + json.dumps(COVER) + ');if(t&&p&&c)callDBus("' + TEST_SERVICE + '","/Test","' + TEST_SERVICE + '","report",JSON.stringify({targetBelowPet:a.indexOf(t)<a.indexOf(p),petBelowCover:a.indexOf(p)<a.indexOf(c)}));')
                    return GLib.SOURCE_CONTINUE
                assert self.order['targetBelowPet'] and self.order['petBelowCover'], self.order
                self.window.minimize()
                self.passed('native window stacking below covering application')
            elif self.stage == 3:
                if target.get('id') != self.target_id or target.get('visible') or state['visible'] or state['windowVisible']:
                    return GLib.SOURCE_CONTINUE
                self.window.unminimize()
                self.window.present()
                self.script('var w=workspace.stackingOrder.filter(function(w){return w.caption===' + json.dumps(TITLE) + ';})[0];if(w){w.minimized=false;workspace.activeWindow=w;}')
                self.passed('minimized target hides the native widget')
            elif self.stage == 4:
                if target.get('id') != self.target_id or not state['windowVisible']:
                    return GLib.SOURCE_CONTINUE
                self.window.close()
                self.passed('restored target restores the native widget')
            elif self.stage == 5:
                if target.get('id') == self.target_id:
                    return GLib.SOURCE_CONTINUE
                self.passed('closed target is removed without stale following')
                self.result = 0
                self.finish()
                return GLib.SOURCE_REMOVE
        except Exception as exc:
            print(f'FAIL {type(exc).__name__}: {exc}', file=sys.stderr, flush=True)
            self.finish()
            return GLib.SOURCE_REMOVE
        return GLib.SOURCE_CONTINUE

    def finish(self):
        if self.cover:
            self.cover.terminate()
            try:
                self.cover.wait(timeout=3)
            except subprocess.TimeoutExpired:
                self.cover.kill()
        try:
            self.scripting.unloadScript('gpt-niang-live-test')
        except dbus.DBusException:
            pass
        command('mode', self.original_mode)
        report = ROOT / 'linux/.test-output/live-kde.json'
        report.parent.mkdir(exist_ok=True)
        report.write_text(json.dumps({'passed': self.result == 0, 'checks': self.checks}, ensure_ascii=False, indent=2) + '\n')
        self.quit()


if __name__ == '__main__':
    DBusGMainLoop(set_as_default=True)
    if '--cover' in sys.argv:
        CoverApp().run([])
    else:
        app = Acceptance()
        app.run([])
        sys.exit(app.result)
