"""
once.py - Cascadia OS v0.43
ONCE: Installer software for Cascadia OS.

Owns: environment checks, directory setup, database initialization,
      config generation, operator manifest installation,
      browser-based AI setup wizard, first-run validation.
Does not own: process supervision (FLINT), operator execution,
              or runtime management.

Browser setup wizard, AI detection,
       llama.cpp/Zyrcon AI local inference support, --no-browser flag.
"""
from __future__ import annotations

import argparse
import json
import os
import platform
import secrets
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
from typing import Any, Dict, List, Optional

from cascadia import VERSION, VERSION_SHORT

SETUP_PORT = 4010
REQUIRED_PYTHON = (3, 11)

DEFAULT_DIRS = [
    'data/runtime',
    'data/logs',
    'data/vault',
    'models',
    'cascadia/operators',
]

DEFAULT_CONFIG: Dict[str, Any] = {
    'log_dir': './data/logs',
    'database_path': './data/runtime/cascadia.db',
    'llm': {
        'provider': None,
        'model': None,
        'configured': False,
    },
    'flint': {
        'heartbeat_file': './data/runtime/flint.heartbeat',
        'heartbeat_interval_seconds': 5,
        'heartbeat_stale_after_seconds': 15,
        'status_port': 4011,
        'health_interval_seconds': 5,
        'drain_timeout_seconds': 10,
        'max_restart_attempts': 5,
        'restart_backoff_seconds': [5, 30, 120, 600],
    },
    'curtain': {
        'signing_secret': '',
    },
    'components': [
        {'name': 'crew',      'module': 'cascadia.registry.crew',            'port': 5100, 'tier': 1, 'heartbeat_file': './data/runtime/crew.heartbeat'},
        {'name': 'vault',     'module': 'cascadia.memory.vault',             'port': 5101, 'tier': 1, 'heartbeat_file': './data/runtime/vault.heartbeat'},
        {'name': 'sentinel',  'module': 'cascadia.security.sentinel',        'port': 5102, 'tier': 1, 'heartbeat_file': './data/runtime/sentinel.heartbeat'},
        {'name': 'curtain',   'module': 'cascadia.encryption.curtain',       'port': 5103, 'tier': 1, 'heartbeat_file': './data/runtime/curtain.heartbeat'},
        {'name': 'beacon',    'module': 'cascadia.orchestrator.beacon',      'port': 6200, 'tier': 2, 'heartbeat_file': './data/runtime/beacon.heartbeat', 'depends_on': ['crew']},
        {'name': 'stitch',    'module': 'cascadia.automation.stitch',        'port': 6201, 'tier': 2, 'heartbeat_file': './data/runtime/stitch.heartbeat'},
        {'name': 'vanguard',  'module': 'cascadia.gateway.vanguard',         'port': 6202, 'tier': 2, 'heartbeat_file': './data/runtime/vanguard.heartbeat'},
        {'name': 'handshake', 'module': 'cascadia.bridge.handshake',         'port': 6203, 'tier': 2, 'heartbeat_file': './data/runtime/handshake.heartbeat'},
        {'name': 'bell',      'module': 'cascadia.chat.bell',                'port': 6204, 'tier': 2, 'heartbeat_file': './data/runtime/bell.heartbeat'},
        {'name': 'almanac',   'module': 'cascadia.guide.almanac',            'port': 6205, 'tier': 2, 'heartbeat_file': './data/runtime/almanac.heartbeat'},
        {'name': 'prism',     'module': 'cascadia.dashboard.prism',          'port': 6300, 'tier': 3, 'heartbeat_file': './data/runtime/prism.heartbeat', 'depends_on': ['crew', 'sentinel', 'beacon']},
    ],
    # Safety: fail-closed by default. Set true only for dev/demo environments.
    'sentinel_fail_open': False,
    # Available AI models — PRISM reads this to populate the model selector.
    'models': [
        {'id': 'qwen2.5-3b',    'name': 'Qwen 2.5 3B',    'file': 'qwen2.5-3b-instruct-q4_k_m.gguf',    'desc': '3B · Fast · Local',     'size': '3B',  'context': 4096, 'recommended_for': 'quick tasks, lead classification, drafts'},
        {'id': 'qwen2.5-7b',    'name': 'Qwen 2.5 7B',    'file': 'qwen2.5-7b-instruct-q4_k_m.gguf',    'desc': '7B · Balanced · Local', 'size': '7B',  'context': 8192, 'recommended_for': 'proposals, analysis, general workflows'},
        {'id': 'qwen2.5-14b',   'name': 'Qwen 2.5 14B',   'file': 'Qwen2.5-14B-Instruct-Q4_K_M.gguf',   'desc': '14B · Powerful · Local','size': '14B', 'context': 8192, 'recommended_for': 'complex reasoning, large documents'},
        {'id': 'qwen2.5-vl-7b', 'name': 'Qwen 2.5 VL 7B', 'file': 'qwen2.5-vl-7b-instruct-q4_k_m.gguf', 'desc': '7B · Vision · Local',   'size': '7B',  'context': 8192, 'recommended_for': 'image analysis, document OCR'},
    ],
}


# ── sysinfo ──────────────────────────────────────────────────────────────────

def _detect_ram_gb() -> Optional[int]:
    try:
        if platform.system() == 'Linux':
            with open('/proc/meminfo') as f:
                for line in f:
                    if line.startswith('MemTotal:'):
                        return int(line.split()[1]) // (1024 * 1024)
        elif platform.system() == 'Darwin':
            out = subprocess.check_output(['sysctl', '-n', 'hw.memsize'], text=True).strip()
            return int(out) // (1024 ** 3)
        elif platform.system() == 'Windows':
            import ctypes
            class MEMSTATEX(ctypes.Structure):
                _fields_ = [('dwLength', ctypes.c_ulong),
                             ('dwMemoryLoad', ctypes.c_ulong),
                             ('ullTotalPhys', ctypes.c_ulonglong),
                             ('ullAvailPhys', ctypes.c_ulonglong),
                             ('ullTotalPageFile', ctypes.c_ulonglong),
                             ('ullAvailPageFile', ctypes.c_ulonglong),
                             ('ullTotalVirtual', ctypes.c_ulonglong),
                             ('ullAvailVirtual', ctypes.c_ulonglong),
                             ('ullAvailExtendedVirtual', ctypes.c_ulonglong)]
            ms = MEMSTATEX()
            ms.dwLength = ctypes.sizeof(ms)
            ctypes.windll.kernel32.GlobalMemoryStatusEx(ctypes.byref(ms))
            return ms.ullTotalPhys // (1024 ** 3)
    except Exception:
        pass
    return None


def _detect_ollama() -> Optional[List[str]]:
    try:
        from urllib import request as ur
        with ur.urlopen('http://localhost:11434/api/tags', timeout=2) as r:
            data = json.loads(r.read().decode())
            return [m['name'] for m in data.get('models', [])]
    except Exception:
        return None


# ── setup HTTP server ─────────────────────────────────────────────────────────

class SetupServer:
    """
    Serves the browser setup wizard on http://127.0.0.1:4010
    Owns: serving setup.html, sysinfo API, apply API.
    Does not own: config persistence (OnceInstaller).
    """

    def __init__(self, install_dir: Path, config_path: Path) -> None:
        self.install_dir = install_dir
        self.config_path = config_path
        self._html_path = Path(__file__).parent / 'setup.html'
        self._result: Optional[Dict[str, Any]] = None
        self._done = threading.Event()
        self._httpd: Optional[HTTPServer] = None
        self._progress_events: list = []  # SSE event queue
        self._progress_lock = threading.Lock()
        self._download_thread: Optional[threading.Thread] = None

    def wait_for_completion(self, timeout: float = 300.0) -> bool:
        return self._done.wait(timeout=timeout)

    def push_event(self, event_type: str, data: dict) -> None:
        """Push a progress event to all SSE listeners."""
        with self._progress_lock:
            self._progress_events.append({'type': event_type, 'data': data})

    def _run_download(self, model_size: str, models_dir: str) -> None:
        """Download model and install llama.cpp in background thread."""
        import subprocess, shutil, urllib.request, os
        MODEL_URLS = {
            '3b':  ('qwen2.5-3b-instruct-q4_k_m.gguf',
                    'https://huggingface.co/Qwen/Qwen2.5-3B-Instruct-GGUF/resolve/main/qwen2.5-3b-instruct-q4_k_m.gguf'),
            '7b':  ('qwen2.5-7b-instruct-q4_k_m.gguf',
                    'https://huggingface.co/Qwen/Qwen2.5-7B-Instruct-GGUF/resolve/main/qwen2.5-7b-instruct-q4_k_m.gguf'),
            '14b': ('Qwen2.5-14B-Instruct-Q4_K_M.gguf',
                    'https://huggingface.co/Qwen/Qwen2.5-14B-Instruct-GGUF/resolve/main/Qwen2.5-14B-Instruct-Q4_K_M.gguf'),
            'vl':  ('qwen2.5-vl-7b-instruct-q4_k_m.gguf',
                    'https://huggingface.co/Qwen/Qwen2.5-VL-7B-Instruct-GGUF/resolve/main/qwen2.5-vl-7b-instruct-q4_k_m.gguf'),
        }
        fname, url = MODEL_URLS.get(model_size, MODEL_URLS['3b'])
        os.makedirs(models_dir, exist_ok=True)
        model_path = os.path.join(models_dir, fname)

        # Step 1: install llama.cpp
        self.push_event('step', {'id': 'llama', 'status': 'running', 'label': 'Installing llama.cpp'})
        llama_bin = ''
        for candidate in ['/opt/homebrew/bin/llama-server', '/usr/local/bin/llama-server',
                           os.path.expanduser('~/llama.cpp/build/bin/llama-server')]:
            if os.path.isfile(candidate):
                llama_bin = candidate
                break
        if not llama_bin:
            try:
                subprocess.run(['brew', 'install', 'llama.cpp'], check=True,
                               capture_output=True, timeout=300)
                for candidate in ['/opt/homebrew/bin/llama-server', '/usr/local/bin/llama-server']:
                    if os.path.isfile(candidate):
                        llama_bin = candidate
                        break
                self.push_event('step', {'id': 'llama', 'status': 'ok', 'label': 'llama.cpp installed', 'detail': llama_bin})
            except Exception as e:
                self.push_event('step', {'id': 'llama', 'status': 'error', 'label': 'llama.cpp install failed', 'detail': str(e)})
                return
        else:
            self.push_event('step', {'id': 'llama', 'status': 'ok', 'label': 'llama.cpp found', 'detail': llama_bin})

        # Step 2: check if model already exists
        if os.path.isfile(model_path):
            size_gb = os.path.getsize(model_path) / 1e9
            self.push_event('step', {'id': 'download', 'status': 'ok',
                'label': f'Model already downloaded ({size_gb:.1f} GB)', 'detail': model_path})
        else:
            # Step 2: download with progress
            self.push_event('step', {'id': 'download', 'status': 'running',
                'label': f'Downloading {fname}', 'detail': 'Starting download...'})
            try:
                req = urllib.request.Request(url, headers={'User-Agent': 'Cascadia-OS/0.43'})
                with urllib.request.urlopen(req) as resp:
                    total = int(resp.headers.get('Content-Length', 0))
                    downloaded = 0
                    chunk_size = 1024 * 1024  # 1MB
                    with open(model_path, 'wb') as f:
                        while True:
                            chunk = resp.read(chunk_size)
                            if not chunk:
                                break
                            f.write(chunk)
                            downloaded += len(chunk)
                            pct = int(downloaded / total * 100) if total else 0
                            dl_gb = downloaded / 1e9
                            tot_gb = total / 1e9
                            self.push_event('progress', {'id': 'download',
                                'pct': pct, 'downloaded': dl_gb, 'total': tot_gb,
                                'label': f'Downloading {fname}',
                                'detail': f'{dl_gb:.2f} GB / {tot_gb:.2f} GB ({pct}%)'})
                self.push_event('step', {'id': 'download', 'status': 'ok',
                    'label': f'Model downloaded ({fname})', 'detail': model_path})
            except Exception as e:
                if os.path.exists(model_path):
                    os.remove(model_path)
                self.push_event('step', {'id': 'download', 'status': 'error',
                    'label': 'Download failed', 'detail': str(e)})
                return

        # Step 3: write config
        self.push_event('step', {'id': 'config', 'status': 'running', 'label': 'Saving configuration'})
        self._result = {'llm': {
            'provider': 'llamacpp', 'model': fname,
            'base_url': 'http://127.0.0.1:8080',
            'models_dir': models_dir, 'llama_bin': llama_bin,
            'n_gpu_layers': 99, 'ctx_size': 4096,
            'configured': True, 'active_model_id': f'qwen2.5-{model_size}'
        }}
        self._apply_llm_config(self._result['llm'])
        self.push_event('step', {'id': 'config', 'status': 'ok', 'label': 'Configuration saved'})
        self.push_event('step', {'id': 'done', 'status': 'ok',
            'label': 'Setup complete', 'detail': 'Starting Cascadia OS...'})
        self._done.set()


    def _make_handler(self) -> type:
        server = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, fmt: str, *args: Any) -> None:
                pass  # quiet during setup

            def _send(self, code: int, ctype: str, body: bytes) -> None:
                self.send_response(code)
                self.send_header('Content-Type', ctype)
                self.send_header('Content-Length', str(len(body)))
                self.send_header('Access-Control-Allow-Origin', '*')
                self.end_headers()
                self.wfile.write(body)

            def _send_json(self, code: int, obj: Dict[str, Any]) -> None:
                self._send(code, 'application/json', json.dumps(obj).encode())

            def _read_json(self) -> Dict[str, Any]:
                n = int(self.headers.get('Content-Length', '0'))
                return json.loads(self.rfile.read(n).decode()) if n else {}

            def do_GET(self) -> None:
                if self.path in ('/', '/setup', '/setup.html'):
                    try:
                        self._send(200, 'text/html; charset=utf-8', server._html_path.read_bytes())
                    except FileNotFoundError:
                        self._send_json(500, {'error': 'setup.html not found next to once.py'})

                elif self.path == '/api/setup/sysinfo':
                    ram = _detect_ram_gb()
                    ollama = _detect_ollama()
                    self._send_json(200, {
                        'ram_gb': ram,
                        'has_gpu': False,
                        'ollama_running': ollama is not None,
                        'ollama_models': ollama or [],
                        'platform': platform.system(),
                    })

                elif self.path == '/api/setup/status':
                    self._send_json(200, {'done': server._done.is_set()})

                elif self.path == '/api/setup/events':
                    # SSE endpoint — returns all queued events as JSON array
                    with server._progress_lock:
                        events = list(server._progress_events)
                    self._send(200, 'application/json', json.dumps(events).encode())

                elif self.path == '/api/setup/hardware':
                    import platform as _pl, subprocess as _sp
                    arch = _pl.machine()
                    ram_gb = 0
                    try:
                        if _pl.system() == 'Darwin':
                            ram_bytes = int(_sp.check_output(['sysctl','-n','hw.memsize']).strip())
                            ram_gb = ram_bytes // (1024**3)
                        elif _pl.system() == 'Linux':
                            with open('/proc/meminfo') as f:
                                for line in f:
                                    if line.startswith('MemTotal:'):
                                        ram_gb = int(line.split()[1]) // (1024*1024)
                    except Exception:
                        pass
                    gpu_type = 'none'
                    if _pl.system() == 'Darwin':
                        gpu_type = 'apple_silicon' if arch == 'arm64' else 'intel_mac'
                    elif _pl.system() == 'Linux':
                        try:
                            _sp.run(['nvidia-smi'], capture_output=True, check=True)
                            gpu_type = 'nvidia'
                        except Exception:
                            gpu_type = 'cpu_only'
                    # Recommend based on hardware
                    if gpu_type in ('apple_silicon', 'nvidia'):
                        recommend = 'local'
                        if ram_gb >= 16: rec_model = '7b'
                        elif ram_gb >= 8: rec_model = '7b'
                        else: rec_model = '3b'
                    else:
                        recommend = 'api'
                        rec_model = '3b'
                    self._send_json(200, {
                        'arch': arch, 'ram_gb': ram_gb, 'gpu_type': gpu_type,
                        'recommend': recommend, 'rec_model': rec_model,
                        'ollama_models': _detect_ollama() or [],
                        'platform': _pl.system(),
                    })


                else:
                    self._send_json(404, {'error': 'not found'})

            def do_POST(self) -> None:
                if self.path == '/api/setup/apply':
                    payload = self._read_json()
                    server._result = payload
                    server._apply_llm_config(payload.get('llm', {}))
                    server._done.set()
                    self._send_json(200, {'ok': True})
                elif self.path == '/api/setup/start-download':
                    # Trigger model download in background thread
                    payload = self._read_json()
                    model_size = payload.get('model_size', '3b')
                    models_dir = payload.get('models_dir',
                        str(server.install_dir / 'models'))
                    if server._download_thread and server._download_thread.is_alive():
                        self._send_json(409, {'error': 'download already running'})
                    else:
                        server._download_thread = threading.Thread(
                            target=server._run_download,
                            args=(model_size, models_dir),
                            daemon=True
                        )
                        server._download_thread.start()
                        self._send_json(200, {'ok': True, 'started': True})
                elif self.path == '/api/setup/skip':
                    # User chose to skip or use API — apply config and finish
                    payload = self._read_json()
                    server._result = payload
                    if payload.get('llm'):
                        server._apply_llm_config(payload['llm'])
                    server._done.set()
                    self._send_json(200, {'ok': True})
                else:
                    self._send_json(404, {'error': 'not found'})

            def do_OPTIONS(self) -> None:
                self.send_response(200)
                self.send_header('Access-Control-Allow-Origin', '*')
                self.send_header('Access-Control-Allow-Methods', 'GET, POST, OPTIONS')
                self.send_header('Access-Control-Allow-Headers', 'Content-Type')
                self.end_headers()

        return Handler

    def _open_browser(self) -> None:
        url = f'http://127.0.0.1:{SETUP_PORT}/'
        time.sleep(0.5)  # let server bind first
        try:
            if platform.system() == 'Darwin':
                subprocess.Popen(['open', url])
            elif platform.system() == 'Windows':
                os.startfile(url)
            else:
                # Linux: try common browsers in order
                for cmd in ['xdg-open', 'gnome-open', 'sensible-browser']:
                    try:
                        subprocess.Popen([cmd, url])
                        break
                    except FileNotFoundError:
                        continue
        except Exception:
            pass  # best-effort

    def run(self) -> Optional[Dict[str, Any]]:
        self._httpd = HTTPServer(('127.0.0.1', SETUP_PORT), self._make_handler())

        print(f'\n  ╔══════════════════════════════════════════╗')
        print(f'  ║   Cascadia OS v{VERSION} — AI Setup Wizard  ║')
        print(f'  ╚══════════════════════════════════════════╝')
        print(f'\n  Opening browser setup at:')
        print(f'  → http://127.0.0.1:{SETUP_PORT}/')
        print(f'\n  If browser does not open, paste the URL above manually.')
        print(f'  Waiting for your selection... (Ctrl+C to skip)\n')

        threading.Thread(target=self._open_browser, daemon=True).start()
        server_thread = threading.Thread(target=self._httpd.serve_forever, daemon=True)
        server_thread.start()

        try:
            completed = self.wait_for_completion(timeout=300)
        except KeyboardInterrupt:
            completed = False
            print('\n  Setup wizard skipped.')

        self._httpd.shutdown()

        if completed and self._result:
            return self._result
        return None


# ── terminal fallback ─────────────────────────────────────────────────────────

def _terminal_ai_setup() -> Dict[str, Any]:
    print('\n  AI model setup')
    print('  ─────────────')
    print('  [1] Run locally  — download Qwen 2.5 (free, private)')
    print('  [2] Cloud API    — OpenAI, Anthropic, or compatible')
    print('  [3] Ollama       — use a locally pulled model')
    print('  [4] Skip         — configure later with: cascadia setup-ai')

    choice = input('\n  Choice [1-4]: ').strip()

    if choice == '1':
        print('\n  Model sizes:')
        print('  [1] 3B  — 2.2 GB download, 4 GB RAM min, fast')
        print('  [2] 7B  — 4.7 GB download, 8 GB RAM min  (recommended)')
        print('  [3] 14B — 8.9 GB download, 16 GB RAM min, best quality')
        sz = input('\n  Size [1-3, default 2]: ').strip() or '2'
        m = {'1': '3b', '2': '7b', '3': '14b'}.get(sz, '7b')
        fname = f'qwen2.5-{m}-instruct-q4_k_m.gguf'
        default_path = f'./models/{fname}'
        custom_path = input(f'  Model path [default: {default_path}]: ').strip()
        model_path = custom_path or default_path
        return {'llm': {'provider': 'llama-cpp', 'model': fname,
                        'model_path': model_path,
                        'base_url': 'http://127.0.0.1:8080',
                        'auto_download': False, 'n_gpu_layers': -1}}

    elif choice == '2':
        provider = input('  Provider [openai/anthropic/groq, default: openai]: ').strip() or 'openai'
        key = input(f'  API key for {provider}: ').strip()
        defaults = {'openai': 'gpt-4o-mini', 'anthropic': 'claude-haiku-4-5-20251001', 'groq': 'llama-3.3-70b-versatile'}
        model = input(f'  Model [default: {defaults.get(provider, "gpt-4o-mini")}]: ').strip() or defaults.get(provider, 'gpt-4o-mini')
        return {'llm': {'provider': provider, 'model': model, 'api_key': key, 'auto_download': False}}

    elif choice == '3':
        models = _detect_ollama()
        if not models:
            print('  Ollama not detected at localhost:11434. Skipping.')
            return {'llm': {'provider': None, 'model': None, 'configured': False}}
        for i, m in enumerate(models, 1):
            print(f'  [{i}] {m}')
        sel = input(f'\n  Pick [1-{len(models)}]: ').strip()
        try:
            chosen = models[int(sel) - 1]
        except (ValueError, IndexError):
            chosen = models[0]
        return {'llm': {'provider': 'ollama', 'model': chosen,
                        'base_url': 'http://localhost:11434', 'auto_download': False}}

    return {'llm': {'provider': None, 'model': None, 'configured': False}}


# ── installer ─────────────────────────────────────────────────────────────────

class OnceInstaller:
    """
    ONCE - Cascadia OS installer.
    Run once to set up a new installation. Idempotent — safe to re-run.
    """

    def __init__(self, install_dir: str = '.', config_path: str = 'config.json',
                 no_browser: bool = False) -> None:
        self.install_dir = Path(install_dir).resolve()
        self.config_path = self.install_dir / config_path
        self.no_browser = no_browser
        self.errors: List[str] = []
        self.warnings: List[str] = []

    def _log(self, msg: str) -> None:
        print(f'  ONCE  {msg}')

    def _warn(self, msg: str) -> None:
        self.warnings.append(msg)
        print(f'  WARN  {msg}')

    def _error(self, msg: str) -> None:
        self.errors.append(msg)
        print(f'  ERROR {msg}')

    def check_python(self) -> bool:
        current = sys.version_info[:2]
        if current < REQUIRED_PYTHON:
            self._error(f'Python {REQUIRED_PYTHON[0]}.{REQUIRED_PYTHON[1]}+ required. Found: {current[0]}.{current[1]}')
            return False
        self._log(f'Python {current[0]}.{current[1]} OK')
        return True

    def create_directories(self) -> None:
        for d in DEFAULT_DIRS:
            path = self.install_dir / d
            path.mkdir(parents=True, exist_ok=True)
            self._log(f'Directory ready: {d}')

    def generate_config(self) -> None:
        if self.config_path.exists():
            self._log(f'Config exists: {self.config_path.name} (skipping)')
            return
        config = dict(DEFAULT_CONFIG)
        config['curtain'] = {'signing_secret': secrets.token_hex(32)}
        self.config_path.write_text(json.dumps(config, indent=2))
        self._log(f'Config generated: {self.config_path.name}')

    def setup_ai(self) -> None:
        """Launch browser wizard (or terminal fallback) for AI model config."""
        # Skip if already configured
        if self.config_path.exists():
            try:
                existing = json.loads(self.config_path.read_text())
                if existing.get('llm', {}).get('configured') is True:
                    self._log('AI already configured — skipping setup wizard')
                    return
            except Exception:
                pass

        result: Optional[Dict[str, Any]] = None

        if self.no_browser:
            result = _terminal_ai_setup()
        else:
            srv = SetupServer(self.install_dir, self.config_path)
            result = srv.run()

        if result and 'llm' in result:
            self._apply_llm_config(result['llm'])
        else:
            self._warn('AI setup skipped — run `cascadia setup-ai` to configure later')

    def _apply_llm_config(self, llm: Dict[str, Any]) -> None:
        try:
            config = json.loads(self.config_path.read_text())
            # Ensure models array is always present
            if 'models' not in config:
                config['models'] = DEFAULT_CONFIG['models']
            llm['configured'] = True
            config['llm'] = llm
            self.config_path.write_text(json.dumps(config, indent=2))
            provider = llm.get('provider') or 'none'
            model = llm.get('model') or 'none'
            self._log(f'AI configured: {provider} / {model}')
        except Exception as exc:
            self._warn(f'Could not write AI config: {exc}')

    def init_database(self) -> None:
        try:
            config = json.loads(self.config_path.read_text())
            db_path = self.install_dir / config['database_path'].lstrip('./')
            db_path.parent.mkdir(parents=True, exist_ok=True)
            sys.path.insert(0, str(self.install_dir))
            from cascadia.shared.db import ensure_database
            ensure_database(str(db_path))
            self._log(f'Database initialized: {db_path.name}')
        except Exception as exc:
            self._warn(f'Database init skipped: {exc}')

    def install_manifests(self) -> None:
        manifest_dir = self.install_dir / 'cascadia' / 'operators'
        if not manifest_dir.exists():
            self._warn('Operator manifest directory not found')
            return
        # registry.json is the operator catalogue — not a component manifest
        manifests = [f for f in manifest_dir.glob('*.json') if f.name != 'registry.json']
        if not manifests:
            self._warn('No operator manifests found')
            return
        try:
            sys.path.insert(0, str(self.install_dir))
            from cascadia.shared.manifest_schema import load_manifest, ManifestValidationError
            for mf in manifests:
                try:
                    manifest = load_manifest(mf)
                    self._log(f'Manifest valid: {manifest.id} ({manifest.type})')
                except ManifestValidationError as exc:
                    self._warn(f'Manifest invalid: {mf.name}: {exc}')
        except ImportError:
            self._warn('Cannot validate manifests (run from project root)')

    def validate(self) -> bool:
        checks = [
            ('config.json', self.config_path.exists()),
            ('data/runtime/', (self.install_dir / 'data/runtime').exists()),
            ('data/logs/', (self.install_dir / 'data/logs').exists()),
        ]
        if self.config_path.exists():
            try:
                cfg = json.loads(self.config_path.read_text())
                llm = cfg.get('llm', {})
                checks.append(('llm configured', llm.get('provider') is not None))
            except Exception:
                pass

        all_ok = True
        for name, ok in checks:
            self._log(f'{name}: {"OK" if ok else "MISSING"}')
            if not ok and name != 'llm configured':
                all_ok = False
        return all_ok

    def run(self) -> int:
        print(f'\n  Cascadia OS v{VERSION} — ONCE Installer')
        print(f'  Install directory: {self.install_dir}\n')

        if not self.check_python():
            return 1

        self.create_directories()
        self.generate_config()
        self.setup_ai()
        self.init_database()
        self.install_manifests()

        print()
        ok = self.validate()

        if self.warnings:
            print(f'\n  {len(self.warnings)} warning(s):')
            for w in self.warnings:
                print(f'    - {w}')

        if self.errors:
            print(f'\n  {len(self.errors)} error(s):')
            for e in self.errors:
                print(f'    - {e}')
            return 1

        if ok:
            print(f'\n  Cascadia OS v{VERSION} installation complete.')
            print('  Start with: cascadia\n')
            return 0
        else:
            print('\n  Installation incomplete. Check warnings above.\n')
            return 1


def main() -> None:
    p = argparse.ArgumentParser(description='ONCE - Cascadia OS installer')
    p.add_argument('--dir', default='.', help='Installation directory')
    p.add_argument('--config', default='config.json', help='Config file name')
    p.add_argument('--no-browser', action='store_true',
                   help='Use terminal prompts instead of browser UI')
    a = p.parse_args()
    sys.exit(OnceInstaller(a.dir, a.config, a.no_browser).run())


if __name__ == '__main__':
    main()
