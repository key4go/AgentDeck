#!/usr/bin/env python3
"""Check a local App Server without starting or resuming a thread."""
import argparse
import json
import queue
import subprocess
import sys
import threading


def probe(executable):
    with subprocess.Popen(
        [executable, "app-server", "--listen", "stdio://"],
        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
        encoding="utf-8",
    ) as server:
        lines = queue.Queue(maxsize=32)

        def read_stdout():
            for line in server.stdout:
                lines.put(line)
            lines.put(None)

        threading.Thread(target=read_stdout, daemon=True).start()

        def send(message):
            server.stdin.write(json.dumps(message) + "\n")
            server.stdin.flush()

        def request(request_id, method, params=None):
            message = {"id": request_id, "method": method}
            if params is not None:
                message["params"] = params
            send(message)
            for _ in range(32):
                try:
                    line = lines.get(timeout=5)
                except queue.Empty:
                    raise RuntimeError(f"{method}: response timed out") from None
                if line is None:
                    raise RuntimeError(f"{method}: server closed stdout")
                response = json.loads(line)
                if "method" in response:
                    if "id" in response:
                        raise RuntimeError(f"{method}: unexpected server request")
                    continue
                if response.get("id") != request_id:
                    raise RuntimeError(f"{method}: unexpected response ID")
                if "error" in response:
                    raise RuntimeError(f"{method}: RPC error {response['error'].get('code')}")
                return response["result"]
            raise RuntimeError(f"{method}: too many intervening notifications")

        try:
            initialized = request(1, "initialize", {
                "clientInfo": {"name": "agentdeck-probe", "version": "0.1.0"},
            })
            send({"method": "initialized"})
            print("initialize → initialized:", initialized["platformOs"])

            models = request(2, "model/list", {"limit": 100})
            for model in models["data"]:
                efforts = ", ".join(effort["reasoningEffort"] for effort in model["supportedReasoningEfforts"])
                print(f"  {model['model']} ({efforts})")
            print(f"model/list: {len(models['data'])} entries, more={bool(models.get('nextCursor'))}")

            threads = request(3, "thread/list", {"limit": 10, "useStateDbOnly": True})
            print(f"thread/list: {len(threads['data'])} stored threads on first page")
            loaded = request(4, "thread/loaded/list", {})
            print(f"thread/loaded/list: {len(loaded['data'])} threads in this server")
            if threads["data"]:
                thread_id = threads["data"][0]["id"]
                read = request(5, "thread/read", {"threadId": thread_id, "includeTurns": False})
                if read["thread"]["id"] != thread_id:
                    raise RuntimeError("thread/read: returned a different thread")
                print("thread/read: stored metadata verified")
        finally:
            server.stdin.close()
            try:
                server.wait(timeout=3)
            except subprocess.TimeoutExpired:
                server.kill()
                server.wait()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("codex", nargs="?", default="codex", help="Codex CLI executable")
    try:
        probe(parser.parse_args().codex)
    except (OSError, RuntimeError, ValueError, KeyError, TypeError) as error:
        sys.exit(f"Probe failed: {error}")
