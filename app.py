import subprocess
import time
import os
import sys
import urllib.request
import webview

BASE = os.path.dirname(os.path.abspath(__file__))


def is_up(url, timeout=2):
    try:
        urllib.request.urlopen(url, timeout=timeout)
        return True
    except Exception:
        return False


def start_services():
    # Docker
    if not is_up("http://localhost:3333"):
        subprocess.Popen(
            ["docker", "compose", "-f", os.path.join(BASE, "docker-compose.yml"), "up", "-d"],
            creationflags=subprocess.CREATE_NO_WINDOW
        )

    # Agent
    pid_file = os.path.join(BASE, ".agent-pid")
    agent_running = False
    if os.path.exists(pid_file):
        try:
            pid = int(open(pid_file).read().strip())
            # Check process alive
            result = subprocess.run(
                ["tasklist", "/FI", f"PID eq {pid}", "/NH"],
                capture_output=True, text=True, creationflags=subprocess.CREATE_NO_WINDOW
            )
            agent_running = str(pid) in result.stdout
        except Exception:
            pass

    if not agent_running:
        proc = subprocess.Popen(
            ["powershell", "-ExecutionPolicy", "Bypass", "-WindowStyle", "Hidden",
             "-File", os.path.join(BASE, "host-agent", "agent.ps1")],
            creationflags=subprocess.CREATE_NO_WINDOW
        )
        with open(pid_file, "w") as f:
            f.write(str(proc.pid))

    # Wait for server
    for _ in range(20):
        if is_up("http://localhost:3333"):
            break
        time.sleep(0.5)


def main():
    start_services()

    window = webview.create_window(
        "Claude",
        "http://localhost:3333",
        width=390,
        height=720,
        on_top=True,
        min_size=(320, 400),
    )
    webview.start(debug=False)


if __name__ == "__main__":
    main()
