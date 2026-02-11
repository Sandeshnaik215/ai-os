#!/usr/bin/env python3
# neural_control_panel.py
# A TUI Control Panel for AI-OS using 'textual'
# Requires: pip install textual psutil

from textual.app import App, ComposeResult
from textual.widgets import Header, Footer, Static, ProgressBar, Log
from textual.containers import Container, Vertical, Horizontal
from textual.reactive import reactive
import psutil
import time
import subprocess

class ResourceMonitor(Static):
    """Displays CPU and RAM usage."""
    
    cpu_usage = reactive(0.0)
    ram_usage = reactive(0.0)
    zram_usage = reactive(0.0)

    def on_mount(self) -> None:
        self.set_interval(1, self.update_stats)

    def update_stats(self) -> None:
        self.cpu_usage = psutil.cpu_percent()
        mem = psutil.virtual_memory()
        self.ram_usage = mem.percent
        # Estimating ZRAM via swap (not perfect but close for this setup)
        swap = psutil.swap_memory()
        self.zram_usage = swap.percent
        self.update(f"CPU: {self.cpu_usage}% | RAM: {self.ram_usage}% | ZRAM: {self.zram_usage}%")

class ModelStatus(Static):
    """Checks for active Ollama/llama.cpp processes."""
    
    active_model = reactive("No Model Loaded")

    def on_mount(self) -> None:
        self.set_interval(2, self.check_model)

    def check_model(self) -> None:
        found = False
        for proc in psutil.process_iter(['name', 'cmdline']):
            try:
                if 'ollama' in proc.info['name'] or 'llama' in proc.info['name']:
                    cmd = proc.info['cmdline']
                    if cmd and len(cmd) > 1:
                        # Try to find model path in args
                        self.active_model = f"Active Process: {proc.info['name']} (PID: {proc.pid})"
                        found = True
                        break
            except (psutil.NoSuchProcess, psutil.AccessDenied):
                pass
        
        if not found:
            self.active_model = "Status: Idle (No inference detected)"
        
        self.update(self.active_model)

class NeuralControlPanel(App):
    """The main TUI App."""
    CSS = """
    Screen {
        layout: vertical;
        background: #1a1b26;
    }
    Header {
        dock: top;
        background: #f7768e;
        color: #1a1b26;
    }
    Footer {
        dock: bottom;
        background: #7aa2f7;
    }
    ResourceMonitor {
        height: 3;
        content-align: center middle;
        background: #24283b;
        color: #9ece6a;
        border: solid #414868;
        margin: 1;
    }
    ModelStatus {
        height: 3;
        content-align: center middle;
        background: #24283b;
        color: #e0af68;
        border: solid #414868;
        margin: 1;
    }
    """

    BINDINGS = [("q", "quit", "Quit Control Panel")]

    def compose(self) -> ComposeResult:
        yield Header(show_clock=True)
        yield ResourceMonitor()
        yield ModelStatus()
        yield Footer()

if __name__ == "__main__":
    import sys
    # Check dependencies
    try:
        import textual
        import psutil
    except ImportError:
        print("Error: Missing dependencies.")
        print("Please run: pip install textual psutil")
        sys.exit(1)

    app = NeuralControlPanel()
    app.run()
