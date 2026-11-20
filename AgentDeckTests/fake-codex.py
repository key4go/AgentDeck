#!/usr/bin/env python3
"""Deterministic App Server fixture. It never runs commands or uses the network."""
import json
import sys
import re
import time


def emit(frame):
    print(json.dumps(frame), flush=True)


def note(method, **params):
    emit({"method": method, "params": params})


def thread(identifier, parent=None):
    return {
        "id": identifier, "cwd": "/tmp", "name": identifier.title(),
        "parentThreadId": parent, "agentNickname": "Reviewer" if parent else None,
        "status": {"type": "notLoaded" if identifier == "observed" else "idle"},
    }


threads = {}
turns = 0
observed_history_reads = 0
queued_name = None

for line in sys.stdin:
    rpc = json.loads(line)
    if "method" not in rpc:
        if rpc["id"] == "approval":
            if rpc.get("result") != {"decision": "decline"}:
                raise AssertionError("The managed approval must be declined")
            note("serverRequest/resolved", requestId="approval")
        elif rpc["id"] == "external":
            if rpc.get("result") != {"decision": "decline"}:
                raise AssertionError("An observed thread must never be approved")
        continue

    method, params = rpc["method"], rpc.get("params") or {}
    if method == "initialized":
        continue
    if method == "fixture/malformed":
        print("not-json", flush=True)
        continue
    if method == "fixture/conflict":
        emit({"id": rpc["id"], "result": {}, "error": {"code": -32600}})
        continue
    if method == "fixture/stall":
        continue
    if method == "fixture/eof":
        sys.exit(0)
    if method == "fixture/error":
        emit({"id": rpc["id"], "error": {"code": -32601, "message": "fixture error"}})
        continue

    result = {}
    if method == "initialize":
        frame = json.dumps({"id": rpc["id"], "result": {"platformOs": "macos"}})
        sys.stdout.write(frame[:12])
        sys.stdout.flush()
        sys.stdout.write(frame[12:] + "\n")
        sys.stdout.flush()
        continue
    if method == "fixture/null":
        result = None
    elif method == "thread/list":
        if not params.get("useStateDbOnly"):
            raise AssertionError("Discovery must avoid rewriting thread metadata")
        result = {"data": [
            thread("observed"),
            thread("writer"),
            {**thread("guardian"), "name": "Guardian review", "source": {"subAgent": "review"}},
            {**thread("helper"), "source": {"subAgent": {"thread_spawn": {"parent_thread_id": "observed", "agent_nickname": "Helper"}}}}
        ], "nextCursor": None}
    elif method == "thread/loaded/list":
        result = {"data": []}
    elif method == "thread/read" and params["threadId"] == "writer-child":
        result = {"thread": thread("writer-child", parent="writer")}
    elif method == "account/read":
        result = {"account": {"type": "chatgpt"}, "requiresOpenaiAuth": True}
    elif method == "account/rateLimits/read":
        result = {"rateLimits": {"secondary": {"windowDurationMins": 10080, "usedPercent": 17}}}
    elif method == "model/list":
        result = {"data": [
            {"model": "other-model", "displayName": "Other", "hidden": False,
             "supportedReasoningEfforts": [{"reasoningEffort": "low"}], "defaultReasoningEffort": "low"},
            {"model": "fixture-model", "displayName": "Fixture", "hidden": False, "isDefault": True,
                            "supportedReasoningEfforts": [{"reasoningEffort": "medium"}],
                            "defaultReasoningEffort": "medium"}]}
    elif method == "thread/turns/list":
        if params["threadId"] == "writer" and queued_name:
            result = {"data": [{"id": "parent-turn", "status": "completed", "items": [
                {"type": "subAgentActivity", "kind": "started", "agentThreadId": "writer-child", "agentPath": "/root/" + queued_name},
                {"type": "subAgentActivity", "kind": "completed", "agentThreadId": "writer-child", "agentPath": "/root/" + queued_name}
            ]}]}
            emit({"id": rpc["id"], "result": result})
            continue
        if params["threadId"] == "writer-child":
            result = {"data": [{"id": "writer-child-turn", "status": "completed", "items": [], "completedAt": int(time.time()), "durationMs": 2500}]}
            emit({"id": rpc["id"], "result": result})
            continue
        if params["threadId"] == "observed":
            observed_history_reads += 1
        message = "Updated message" if params["threadId"] == "observed" and observed_history_reads > 1 else "Saved message"
        result = {"data": [{"startedAt": 1700000000, "items": [
            {"id": "history", "type": "agentMessage", "text": message}
        ]}]}
    elif method == "thread/start":
        identifier = f"managed-{len(threads) + 1}"
        threads[identifier] = params.get("cwd", "/tmp")
        result = {"thread": {**thread(identifier), "cwd": threads[identifier]}, "model": "fixture-model"}
    elif method == "thread/resume":
        identifier = params["threadId"]
        if identifier == "writer":
            emit({"id": rpc["id"], "error": {"code": -32600, "message": "thread writer already has an active writer"}})
            continue
        if identifier == "native-child":
            result = {"thread": thread(identifier, parent="observed"), "model": "other-model"}
            emit({"id": rpc["id"], "result": result})
            continue
        if not identifier.startswith("managed-") and identifier != "observed":
            raise AssertionError("Only explicitly attached or owned threads can be resumed")
        result = {"thread": {**thread(identifier), "cwd": threads.get(identifier, "/tmp")}, "model": "fixture-model"}
    elif method == "thread/queue/list" and params["threadId"] == "writer":
        result = {"data": [], "nextCursor": None}
    elif method == "thread/queue/add" and params["threadId"] == "writer":
        assert params.get("clientUserMessageId")
        text = params["input"][0]["text"]
        assert re.search(r"Spawn subagent test_[0-9a-f]{8} \(Test\)", text) and "AgentDeck-Profile:" in text
        queued_name = re.search(r"Spawn subagent ([a-z0-9_]+)", text).group(1)
        assert "Task: Reply OK" in text and '"model" : null' not in text
        assert not threads, "Queuing must not create a new main chat"
        result = {"queuedSubmission": {"id": "queued-test"}}
    elif method == "turn/start" and params["threadId"] == "observed" and params["input"][0]["text"] == "Hold parent":
        note("turn/started", threadId="observed", turn={"id": "parent-held", "status": "inProgress"})
        emit({"id": rpc["id"], "result": {"turn": {"id": "parent-held", "status": "inProgress"}}})
        continue
    elif method == "turn/start" and params["threadId"] == "observed":
        assert not threads, "Delegation must never create a separate main chat"
        assert "model" not in params and "effort" not in params, "Subagent preferences must not replace the parent model"
        text = params["input"][0]["text"]
        marker = re.search(r"AgentDeck-Profile:([A-Za-z0-9-]+)", text).group(0)
        task_name = re.search(r"Spawn subagent ((?:research|audit)_[0-9a-f]{8})", text).group(1)
        assert "model other-model" in text and "reasoning low" in text
        assert "Instructions: Read only" in text and "Task: Whiteboard task" in text
        turn_id = "delegation-turn"
        note("turn/started", threadId="observed", turn={"id": turn_id})
        profile_id = marker.split(":")[1]
        note("item/completed", threadId="observed", turnId=turn_id, item={
            "id": "spawn", "type": "subAgentActivity", "kind": "started", "agentThreadId": "native-child",
            "agentPath": "/root/" + task_name,
            "model": "other-model", "reasoningEffort": "low"
        })
        note("thread/tokenUsage/updated", threadId="native-child", tokenUsage={
            "total": {"totalTokens": 108, "inputTokens": 100, "outputTokens": 8, "cachedInputTokens": 20}
        })
        note("item/completed", threadId="native-child", turnId="child-turn", item={
            "id": "final", "type": "agentMessage", "text": "Whiteboard finished successfully."
        })
        note("turn/completed", threadId="native-child", turn={"id": "child-turn", "status": "completed"})
        note("turn/completed", threadId="observed", turn={"id": turn_id, "status": "completed"})
        emit({"id": rpc["id"], "result": {"turn": {"id": turn_id, "status": "inProgress"}}})
        continue
    elif method == "turn/start":
        identifier = params["threadId"]
        if not identifier.startswith("managed-"):
            raise AssertionError("Observed threads must not be controlled")
        if "approvalPolicy" in params or "sandboxPolicy" in params:
            raise AssertionError("The app must preserve Codex policy")
        inputs = params["input"]
        texts = [item.get("text", "") for item in inputs]
        canvas = any("Canvas smoke task" in text for text in texts)
        if texts == ["Model selection test"]:
            assert params.get("model") == "other-model" and params.get("effort") == "low"
        elif not canvas and (not texts or not texts[0].startswith("AgentDeck agent instructions") or len(texts) < 2):
            raise AssertionError("First input must contain role instructions and the user's command")
        turns += 1
        turn_id = f"turn-{turns}"
        result = {"turn": {"id": turn_id, "status": "inProgress"}}
        note("turn/started", threadId=identifier, turn=result["turn"])
        note("item/completed", threadId=identifier, turnId=turn_id, item={
            "id": f"user-{turns}", "type": "userMessage", "content": [{"type": "text", "text": texts[-1]}]
        })
        note("thread/tokenUsage/updated", threadId=identifier, turnId=turn_id, tokenUsage={
            "total": {"inputTokens": 100, "outputTokens": 8, "cachedInputTokens": 20, "totalTokens": 108},
            "last": {"totalTokens": 108}, "modelContextWindow": 1000
        })
        if texts[-1] == "Whiteboard task":
            assert params.get("model") == "other-model"
            assert params.get("effort") == "low"
            note("item/completed", threadId=identifier, turnId=turn_id, item={
                "id": f"final-{turns}", "type": "agentMessage", "text": "Whiteboard finished successfully."
            })
        if canvas:
            if "Write a short handoff plan" in texts[-1]:
                reply = "Root work brief"
            elif "Summarize this workspace" in texts[-1]:
                assert "QA branch result" in texts[-1]
                reply = "Final workflow summary"
            elif "QA branch result" in texts[-1]:
                raise AssertionError("A branch must not get its own future result")
            elif "Center branch result" in texts[-1]:
                reply = "QA branch result"
            else:
                assert "Root work brief" in texts[-1]
                reply = "Center branch result"
            note("item/completed", threadId=identifier, turnId=turn_id, item={
                "id": f"agent-{turns}", "type": "agentMessage", "text": reply
            })
        if turns == 1 and not canvas:
            emit({"id": "external", "method": "item/commandExecution/requestApproval",
                  "params": {"threadId": "observed", "command": "example"}})
            emit({"id": "approval", "method": "item/commandExecution/requestApproval",
                  "params": {"threadId": identifier, "command": "echo fixture"}})
        if texts[-1] != "Hold":
            note("turn/completed", threadId=identifier, turn={"id": turn_id, "status": "completed"})
    elif method == "turn/steer":
        if params["threadId"] == "observed":
            assert params["expectedTurnId"] == "parent-held"
            assert "native-child" in params["input"][0]["text"]
            note("turn/started", threadId="native-child", turn={"id": "child-active", "status": "inProgress"})
        result = {"turnId": params["expectedTurnId"]}
    elif method == "turn/interrupt":
        note("turn/completed", threadId=params["threadId"], turn={"id": params["turnId"], "status": "interrupted"})
    else:
        raise AssertionError(f"Unexpected fixture method: {method}")
    emit({"id": rpc["id"], "result": result})
