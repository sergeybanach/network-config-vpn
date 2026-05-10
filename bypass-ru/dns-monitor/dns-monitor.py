#!/usr/bin/env python3
"""
DNS Monitor — GTK GUI для просмотра DNS-запросов в реальном времени.

Шавит journal NetworkManager (там логируется dnsmasq), парсит строки
log-queries и показывает каждый запрос отдельной строкой с подсветкой
по статусу. Ошибки/таймауты дополнительно дублируются на отдельной вкладке.

Требования:
  - dnsmasq запущен NetworkManager-ом с опцией log-queries
    (см. log-queries.conf и install.sh в этом каталоге)
  - python3-gi, gir1.2-gtk-3.0
  - доступ на чтение system journal (группа adm или systemd-journal)

Запуск: ./dns-monitor.py
"""

import gi
gi.require_version('Gtk', '3.0')
from gi.repository import Gtk, GLib

import re
import subprocess
import sys
import threading
import time
from collections import OrderedDict
from datetime import datetime


PAT_QUERY     = re.compile(r'^query\[(\w+)\]\s+(\S+)\s+from\s+(\S+)$')
PAT_REPLY     = re.compile(r'^reply\s+(\S+)\s+is\s+(.+)$')
PAT_CACHED    = re.compile(r'^cached\s+(\S+)\s+is\s+(.+)$')
PAT_FORWARDED = re.compile(r'^forwarded\s+(\S+)\s+to\s+(\S+)$')
PAT_DNSMASQ   = re.compile(r'^dnsmasq[\w-]*(?:\[\d+\])?:\s+(.+)$')

ERROR_VALUES = {'NXDOMAIN', 'SERVFAIL', 'REFUSED', 'NODATA', 'TIMEOUT'}

TIMEOUT_SEC = 5.0      # запрос без ответа дольше — помечаем TIMEOUT
PRUNE_SEC   = 2.0      # сколько держим в pending после ответа (для multi-IP)


class DNSMonitor(Gtk.Window):

    # колонки store
    COL_TS, COL_TYPE, COL_NAME, COL_STATUS, COL_RESULT, COL_PATH, COL_CLIENT, COL_FG = range(8)

    def __init__(self):
        super().__init__(title="DNS Monitor — bypass-ru")
        self.set_default_size(1100, 650)

        # -- header bar
        bar = Gtk.HeaderBar()
        bar.set_show_close_button(True)
        bar.set_title("DNS Monitor")
        bar.set_subtitle("живой просмотр запросов dnsmasq")
        self.set_titlebar(bar)

        self.pause_btn = Gtk.ToggleButton.new_with_label("Пауза")
        self.pause_btn.connect("toggled", self.on_pause)
        bar.pack_start(self.pause_btn)

        clear_btn = Gtk.Button.new_with_label("Очистить")
        clear_btn.connect("clicked", self.on_clear)
        bar.pack_start(clear_btn)

        # -- main vbox
        vbox = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=0)
        self.add(vbox)

        # filter toolbar
        toolbar = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=6)
        toolbar.set_margin_top(6); toolbar.set_margin_bottom(6)
        toolbar.set_margin_start(8); toolbar.set_margin_end(8)
        toolbar.pack_start(Gtk.Label(label="Фильтр:"), False, False, 0)
        self.filter_entry = Gtk.SearchEntry()
        self.filter_entry.set_placeholder_text("домен или IP")
        self.filter_entry.set_hexpand(True)
        self.filter_entry.connect("search-changed", self.on_filter)
        toolbar.pack_start(self.filter_entry, True, True, 0)
        self.errors_only_btn = Gtk.ToggleButton.new_with_label("Только ошибки")
        self.errors_only_btn.connect("toggled", self.on_filter)
        toolbar.pack_start(self.errors_only_btn, False, False, 0)
        vbox.pack_start(toolbar, False, False, 0)

        # notebook with two tabs
        nb = Gtk.Notebook()
        vbox.pack_start(nb, True, True, 0)

        # ---- tab 1: all queries (live updating per-query) ----
        # cols: ts, type, name, status, result, path, client, fg-color
        self.store = Gtk.ListStore(str, str, str, str, str, str, str, str)
        self.filter_model = self.store.filter_new()
        self.filter_model.set_visible_func(self.row_visible)

        scroll = Gtk.ScrolledWindow()
        self.view = Gtk.TreeView(model=self.filter_model)
        self.view.set_enable_search(False)
        for idx, (title, width) in enumerate([
            ("Время",     90),
            ("Тип",       55),
            ("Домен",    260),
            ("Статус",   100),
            ("Результат",300),
            ("Путь",     100),
            ("Клиент",   100),
        ]):
            r = Gtk.CellRendererText()
            r.set_property('family', 'monospace')
            col = Gtk.TreeViewColumn(title, r, text=idx, foreground=self.COL_FG)
            col.set_resizable(True)
            col.set_min_width(width)
            self.view.append_column(col)
        scroll.add(self.view)
        nb.append_page(scroll, Gtk.Label(label="Все запросы"))

        # ---- tab 2: errors only (append-only) ----
        # cols: ts, type, name, error, details, client
        self.error_store = Gtk.ListStore(str, str, str, str, str, str)
        scroll_e = Gtk.ScrolledWindow()
        view_e = Gtk.TreeView(model=self.error_store)
        for idx, (title, width) in enumerate([
            ("Время",   90),
            ("Тип",     55),
            ("Домен",  260),
            ("Ошибка", 110),
            ("Детали", 300),
            ("Клиент", 100),
        ]):
            r = Gtk.CellRendererText()
            r.set_property('family', 'monospace')
            r.set_property('foreground', '#cc0000')
            col = Gtk.TreeViewColumn(title, r, text=idx)
            col.set_resizable(True)
            col.set_min_width(width)
            view_e.append_column(col)
        scroll_e.add(view_e)
        self.tab_errors_label = Gtk.Label(label="Ошибки (0)")
        nb.append_page(scroll_e, self.tab_errors_label)

        # status bar
        self.statusbar = Gtk.Statusbar()
        self.status_ctx = self.statusbar.get_context_id("dnsmonitor")
        vbox.pack_end(self.statusbar, False, False, 0)

        # state
        self.paused = False
        self.filter_text = ""
        self.errors_only = False
        # pending: name -> dict(iter, qtype, client, ts0, completed_at)
        self.pending = OrderedDict()
        self.total = 0
        self.errors = 0
        self.timeouts = 0
        self.proc = None

        self.update_status()
        self.preflight_check()

        self.stop_event = threading.Event()
        self.thread = threading.Thread(target=self.read_logs, daemon=True)
        self.thread.start()

        GLib.timeout_add_seconds(1, self.sweep)

        self.connect("destroy", self.on_destroy)

    # ---- preflight ----

    def preflight_check(self):
        """Проверяет, что в dnsmasq.d-конфигах включён log-queries.
           Сама директива читается через --conf-dir, поэтому в pgrep её нет —
           ищем во всех файлах конфига."""
        import glob, os
        config_dirs = [
            '/etc/NetworkManager/dnsmasq.d',
            '/etc/dnsmasq.d',
        ]
        found = False
        for d in config_dirs:
            for f in glob.glob(os.path.join(d, '*.conf')):
                try:
                    with open(f) as fh:
                        for line in fh:
                            line = line.strip()
                            if line.startswith('#'): continue
                            if line == 'log-queries' or line.startswith('log-queries='):
                                found = True
                                break
                except OSError:
                    continue
                if found: break
            if found: break

        if not found:
            self.warn(
                "В dnsmasq не включён log-queries — запросы не логируются.\n\n"
                "Запусти:\n  sudo " +
                os.path.dirname(os.path.abspath(__file__)) + "/install.sh"
            )

    def warn(self, msg):
        def show():
            dlg = Gtk.MessageDialog(
                transient_for=self,
                modal=True,
                message_type=Gtk.MessageType.WARNING,
                buttons=Gtk.ButtonsType.OK,
                text=msg,
            )
            dlg.run()
            dlg.destroy()
            return False
        GLib.idle_add(show)

    # ---- handlers ----

    def on_destroy(self, *_):
        self.stop_event.set()
        if self.proc:
            try: self.proc.terminate()
            except Exception: pass
        Gtk.main_quit()

    def on_pause(self, btn):
        self.paused = btn.get_active()
        self.update_status()

    def on_clear(self, _):
        self.store.clear()
        self.error_store.clear()
        self.pending.clear()
        self.total = self.errors = self.timeouts = 0
        self.update_status()
        self.update_errors_tab_label()

    def on_filter(self, *_):
        self.filter_text = self.filter_entry.get_text().lower()
        self.errors_only = self.errors_only_btn.get_active()
        self.filter_model.refilter()

    def row_visible(self, model, it, _):
        name = (model[it][self.COL_NAME] or "").lower()
        result = (model[it][self.COL_RESULT] or "").lower()
        status = (model[it][self.COL_STATUS] or "")
        if self.errors_only and status not in ERROR_VALUES:
            return False
        if self.filter_text and self.filter_text not in name and self.filter_text not in result:
            return False
        return True

    def update_status(self):
        self.statusbar.pop(self.status_ctx)
        msg = f"Всего: {self.total}    Ошибок: {self.errors}    Таймаутов: {self.timeouts}    "
        msg += "⏸ Пауза" if self.paused else "● Запись"
        self.statusbar.push(self.status_ctx, msg)

    def update_errors_tab_label(self):
        self.tab_errors_label.set_text(f"Ошибки ({self.errors})")

    # ---- log reader (background thread) ----

    def read_logs(self):
        cmd = ['journalctl', '-fu', 'NetworkManager', '-o', 'cat', '--no-pager', '-n', '0']
        try:
            self.proc = subprocess.Popen(
                cmd,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
                bufsize=1,
            )
        except FileNotFoundError:
            self.warn("journalctl не найден")
            return

        for line in self.proc.stdout:
            if self.stop_event.is_set():
                break
            self.parse_line(line.rstrip())

    def parse_line(self, line):
        # journalctl -o cat иногда префиксует "dnsmasq[pid]:". Снимем.
        m = PAT_DNSMASQ.match(line)
        if m:
            line = m.group(1)

        if (m := PAT_QUERY.match(line)):
            qtype, name, client = m.groups()
            self.add_pending(qtype, name, client)
        elif (m := PAT_FORWARDED.match(line)):
            name, upstream = m.groups()
            self.update_path(name, upstream.split('#')[0])
        elif (m := PAT_CACHED.match(line)):
            name, val = m.groups()
            self.complete(name, val, "cache")
        elif (m := PAT_REPLY.match(line)):
            name, val = m.groups()
            self.complete(name, val, "forward")

    # ---- UI updates (must be called from main thread via GLib.idle_add) ----

    def add_pending(self, qtype, name, client):
        def do():
            if self.paused:
                return False
            ts = datetime.now().strftime("%H:%M:%S")
            it = self.store.append([ts, qtype, name, "⏳ ожидание", "", "", client, "#888888"])
            self.pending[name] = {
                'iter': it, 'qtype': qtype, 'client': client,
                'ts0': time.time(), 'done_at': None,
            }
            self.total += 1
            self.update_status()
            self.scroll_to_end()
            return False
        GLib.idle_add(do)

    def update_path(self, name, upstream):
        def do():
            entry = self.pending.get(name)
            if entry:
                self.store[entry['iter']][self.COL_PATH] = upstream
            return False
        GLib.idle_add(do)

    def complete(self, name, val, path):
        def do():
            if self.paused:
                return False
            entry = self.pending.get(name)
            if not entry:
                # Поздний ответ без pending (например, cache hit логируется без query)
                ts = datetime.now().strftime("%H:%M:%S")
                it = self.store.append([ts, "?", name, "?", "", path, "?", "#888888"])
                entry = {'iter': it, 'qtype': '?', 'client': '?',
                         'ts0': time.time(), 'done_at': None}
                self.pending[name] = entry
                self.total += 1

            it = entry['iter']
            existing = self.store[it][self.COL_RESULT]
            existing_status = self.store[it][self.COL_STATUS]
            is_error = val in ERROR_VALUES

            if is_error:
                self.store[it][self.COL_STATUS] = val
                self.store[it][self.COL_RESULT] = val
                self.store[it][self.COL_PATH] = path
                self.store[it][self.COL_FG] = "#cc0000"
                if existing_status != val:  # not a duplicate
                    self.errors += 1
                    self.error_store.append([
                        self.store[it][self.COL_TS], entry['qtype'], name,
                        val, "ответ от резолвера", entry['client'],
                    ])
                    self.update_errors_tab_label()
            else:
                # multi-IP: накапливаем в Result
                if existing_status == "OK" and existing:
                    parts = set(existing.split(", "))
                    parts.add(val)
                    self.store[it][self.COL_RESULT] = ", ".join(sorted(parts))
                else:
                    self.store[it][self.COL_RESULT] = val
                self.store[it][self.COL_STATUS] = "OK"
                self.store[it][self.COL_PATH] = path
                self.store[it][self.COL_FG] = ("#006400" if path == "forward" else "#444444")

            entry['done_at'] = time.time()
            self.update_status()
            self.scroll_to_end()
            return False
        GLib.idle_add(do)

    def scroll_to_end(self):
        n = len(self.store)
        if n > 0:
            try:
                self.view.scroll_to_cell(
                    Gtk.TreePath.new_from_indices([n - 1]),
                    None, False, 0, 0,
                )
            except Exception:
                pass

    def sweep(self):
        """Раз в секунду:
           - помечает зависшие запросы как TIMEOUT
           - вычищает старые завершённые из pending
        """
        now = time.time()
        to_remove = []
        for name, e in list(self.pending.items()):
            status = self.store[e['iter']][self.COL_STATUS]
            if status == "⏳ ожидание" and (now - e['ts0']) > TIMEOUT_SEC:
                self.store[e['iter']][self.COL_STATUS] = "TIMEOUT"
                self.store[e['iter']][self.COL_RESULT] = "нет ответа за "+f"{TIMEOUT_SEC:.0f}с"
                self.store[e['iter']][self.COL_FG] = "#cc0000"
                self.error_store.append([
                    self.store[e['iter']][self.COL_TS], e['qtype'], name,
                    "TIMEOUT", f"нет ответа за {TIMEOUT_SEC:.0f}с", e['client'],
                ])
                self.errors += 1
                self.timeouts += 1
                to_remove.append(name)
            elif e['done_at'] and (now - e['done_at']) > PRUNE_SEC:
                to_remove.append(name)
        for name in to_remove:
            self.pending.pop(name, None)
        if to_remove:
            self.update_status()
            self.update_errors_tab_label()
        return True


def main():
    win = DNSMonitor()
    win.show_all()
    Gtk.main()


if __name__ == "__main__":
    main()
