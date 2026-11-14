import json, sys, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ANSWER = {"sharp": "I'll circle back once I've had a proper look.\n---\ncircle back\nhad a proper look",
          "chill": "Lemme take a look and get back to you.\n---\nget back to you"}

SEEN = {}

class H(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def log_message(self, *a): sys.stderr.write("%s %s\n" % (self.command, self.path))
    def do_HEAD(self):
        self.send_response(200); self.send_header("Content-Length", "0"); self.end_headers()
    def json(self, code, obj):
        b = json.dumps(obj).encode()
        self.send_response(code); self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b)
    def sse(self, events, delay=0.03, drop=False):
        self.send_response(200); self.send_header("Content-Type", "text/event-stream")
        self.send_header("Connection", "close"); self.end_headers()
        for i, e in enumerate(events):
            self.wfile.write(("data: " + json.dumps(e) + "\n\n").encode()); self.wfile.flush(); time.sleep(delay)
            if drop and i == 3:
                self.connection.shutdown(2); return
        self.close_connection = True
    def deltas(self, text):
        return [{"type": "response.output_text.delta", "delta": text[i:i+6]} for i in range(0, len(text), 6)] + [{"type": "response.completed"}]
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        inp = body["input"]
        grammar = isinstance(inp, str)
        text = inp if grammar else inp[-1]["content"]
        voice = "sharp" if "[sharp-voice]" in body["instructions"] or "Sharp" in body["instructions"][:4000] and "Chill" not in body["instructions"][-3000:] else "chill"
        if "#401" in text: return self.json(401, {"error": {"message": "Incorrect API key provided"}})
        if "#429" in text: return self.json(429, {"error": {"message": ""}})
        if "#500" in text: return self.json(500, {"error": {"message": "The server had an error processing your request."}})
        if "#hang" in text: time.sleep(70); return
        if "#stuckfirst" in text and not grammar:
            # The first request of each kind is held up, as on a backed-up machine; a second try gets through.
            seen = SEEN.setdefault((body["instructions"].strip()[:4000], text), 0)
            SEEN[(body["instructions"].strip()[:4000], text)] = seen + 1
            if seen == 0: time.sleep(7)
        if "#lag" in text and not grammar: time.sleep(1.5)
        if grammar:
            lines = ""
            if "I goes" in text: lines += json.dumps({"wrong": "I goes", "fix": "I go", "why": "First person takes the base verb."}) + "\n"
            return self.sse(self.deltas(lines))
        if "#empty" in text: return self.sse([{"type": "response.completed"}])
        if "#failed" in text: return self.sse([{"type": "response.failed", "response": {"error": {"message": "Model overloaded."}}}])
        if "#halffail" in text and "Chill" in body["instructions"][-3000:]:
            return self.json(500, {"error": {"message": ""}})
        if "#drop" in text: return self.sse(self.deltas(ANSWER["sharp"]), drop=True)
        long = "#long" in text
        ans = ANSWER["sharp" if hash(body["instructions"]) % 2 else "chill"]
        if long: ans = ("This is a deliberately long answer to check scrolling and the height limit. " * 14).strip() + "\n---\nheight limit"
        return self.sse(self.deltas(ans), delay=0.12 if "#slow" in text else 0.03)

ThreadingHTTPServer(("127.0.0.1", 8765), H).serve_forever()
