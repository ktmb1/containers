"""A fake OpenAI-compatible upstream for verify.sh.

Records every request body it receives, one JSON object per line, to the file
named in argv[1] - that record is what verify.sh checks for leaks, because it
is exactly what a real provider would have seen.

Replies like a model with tools would: a tool call when tools are offered and
the conversation does not already end in a tool result, plain text otherwise.
The replies contain no canary data, so anything verify.sh finds came from the
proxy's request, not from here.
"""

import json
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

LOG = sys.argv[1]


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def _send(self, body: dict) -> None:
        data = json.dumps(body).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        self._send({"object": "list", "data": [{"id": "fake-model", "object": "model", "owned_by": "verify"}]})

    def do_POST(self):
        request = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        with open(LOG, "a", encoding="utf-8") as f:
            f.write(json.dumps({"path": self.path, "auth": self.headers.get("Authorization"), "body": request}) + "\n")

        messages = request.get("messages") or []
        if request.get("tools") and not (messages and messages[-1].get("role") == "tool"):
            tool = request["tools"][0]["function"]["name"]
            message = {
                "role": "assistant",
                "content": None,
                "tool_calls": [
                    {"id": "call_1", "type": "function", "function": {"name": tool, "arguments": '{"area": "living"}'}}
                ],
            }
            finish = "tool_calls"
        else:
            message = {"role": "assistant", "content": "The living room is 21.5 degrees."}
            finish = "stop"

        self._send(
            {
                "id": "chatcmpl-verify",
                "object": "chat.completion",
                "created": 0,
                "model": request.get("model"),
                "choices": [{"index": 0, "message": message, "finish_reason": finish}],
                "usage": {"prompt_tokens": 1, "completion_tokens": 1, "total_tokens": 2},
            }
        )


HTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
