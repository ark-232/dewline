"""A stand-in agent for AgentPanelTests: Agent Client Protocol over stdio, newline-delimited JSON-RPC 2.0, no model.

What it does depends on words in the prompt's text:
  edit        reads the attached note, asks to write it with "Friday" changed to "Monday", then reports the edit
  permission  asks for permission first and reports which option came back
  wait        runs until session/cancel arrives, then ends the turn as cancelled
  self-write  writes the attached note on disk itself and reports the edit
  outside     asks to read /etc/hosts and reports the error it gets
  crash       exits with status 3
Every turn first says which content blocks the prompt held: "Got text, resource_link."
FAKE_ACP_AUTH=1 makes session/new fail as needing sign-in.
"""

import json
import os
import sys
import time
from urllib.parse import unquote, urlparse

queue = []
next_id = 100
cancelled = False


def send(message):
    message["jsonrpc"] = "2.0"
    sys.stdout.write(json.dumps(message) + "\n")
    sys.stdout.flush()


def read():
    if queue:
        return queue.pop(0)
    line = sys.stdin.readline()
    if not line:
        sys.exit(0)
    return json.loads(line)


def call(method, params):
    """Sends a request to the client and waits for its answer, holding other messages for later."""
    global next_id, cancelled
    next_id += 1
    mine = next_id
    send({"id": mine, "method": method, "params": params})
    held = []
    while True:
        message = read()
        if message.get("id") == mine and "method" not in message:
            queue.extend(held)
            return message
        if message.get("method") == "session/cancel":
            cancelled = True
            continue
        held.append(message)


def update(session, body):
    send({"method": "session/update", "params": {"sessionId": session, "update": body}})


def say(session, text, kind="agent_message_chunk"):
    update(session, {"sessionUpdate": kind, "content": {"type": "text", "text": text}})


def attached(prompt):
    for block in prompt:
        if block.get("type") == "resource_link":
            return unquote(urlparse(block["uri"]).path)
    return None


def turn(params):
    global cancelled
    cancelled = False
    session = params["sessionId"]
    prompt = params["prompt"]
    text = " ".join(block.get("text", "") for block in prompt if block.get("type") == "text")
    say(session, "Got " + ", ".join(block["type"] for block in prompt) + ".")
    for block in prompt:
        if block.get("type") == "resource":
            say(session, " Selection: " + block["resource"]["text"])
    if "crash" in text:
        sys.exit(3)
    if "wait" in text:
        while not cancelled:
            message = read()
            if message.get("method") == "session/cancel":
                cancelled = True
        return "cancelled"
    if "outside" in text:
        answer = call("fs/read_text_file", {"sessionId": session, "path": "/etc/hosts"})
        say(session, " Refused: " + answer.get("error", {}).get("message", "no error"))
        return "end_turn"
    path = attached(prompt)
    if path and "self-write" in text:
        with open(path) as handle:
            old = handle.read()
        with open(path, "w") as handle:
            handle.write(old.replace("Friday", "Monday"))
        update(session, {"sessionUpdate": "tool_call", "toolCallId": "call_self", "title": "Edit note",
                         "kind": "edit", "status": "completed", "locations": [{"path": path}]})
        return "end_turn"
    if path and "edit" in text:
        say(session, "Checking the dates.", "agent_thought_chunk")
        update(session, {"sessionUpdate": "plan", "entries": [
            {"content": "Read the note", "priority": "high", "status": "completed"},
            {"content": "Move the launch to Monday", "priority": "high", "status": "in_progress"}]})
        update(session, {"sessionUpdate": "tool_call", "toolCallId": "call_1", "title": "Edit " + os.path.basename(path),
                         "kind": "edit", "status": "pending", "locations": [{"path": path}]})
        if "permission" in text:
            answer = call("session/request_permission", {
                "sessionId": session,
                "toolCall": {"toolCallId": "call_1", "title": "npm test", "kind": "execute",
                             "rawInput": {"command": "npm test"}},
                "options": [
                    {"optionId": "once", "name": "Allow", "kind": "allow_once"},
                    {"optionId": "always", "name": "Always", "kind": "allow_always"},
                    {"optionId": "no", "name": "Reject", "kind": "reject_once"}]})
            outcome = answer.get("result", {}).get("outcome", {})
            chosen = outcome.get("optionId", outcome.get("outcome"))
            say(session, " Permission: " + str(chosen) + ".")
            if chosen != "once" and chosen != "always":
                update(session, {"sessionUpdate": "tool_call_update", "toolCallId": "call_1", "status": "failed"})
                return "cancelled" if cancelled else "end_turn"
        content = call("fs/read_text_file", {"sessionId": session, "path": path})["result"]["content"]
        written = call("fs/write_text_file", {"sessionId": session, "path": path,
                                              "content": content.replace("Friday", "Monday")})
        status = "failed" if "error" in written else "completed"
        update(session, {"sessionUpdate": "tool_call_update", "toolCallId": "call_1", "status": status,
                         "content": [{"type": "diff", "path": path, "oldText": content,
                                      "newText": content.replace("Friday", "Monday")}]})
        say(session, " Done.")
    return "end_turn"


def main():
    while True:
        message = read()
        method = message.get("method")
        ident = message.get("id")
        params = message.get("params", {})
        if method == "initialize":
            send({"id": ident, "result": {"protocolVersion": 1, "authMethods": [],
                                          "agentCapabilities": {"promptCapabilities": {"embeddedContext": True}}}})
        elif method == "session/new":
            if os.environ.get("FAKE_ACP_AUTH") == "1":
                send({"id": ident, "error": {"code": -32000, "message": "Authentication required"}})
            else:
                send({"id": ident, "result": {"sessionId": "fake-" + str(int(time.time()))}})
        elif method == "session/prompt":
            send({"id": ident, "result": {"stopReason": turn(params)}})
        elif ident is not None and method is not None:
            send({"id": ident, "error": {"code": -32601, "message": "Method not found"}})


main()
