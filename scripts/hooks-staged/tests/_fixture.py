import json, sys
# usage: _fixture.py out.jsonl '<steps json>'
steps = json.loads(sys.argv[2]); out = []; n = 0
for s in steps:
    if "u" in s:
        out.append({"type": "user", "message": {"role": "user", "content": s["u"]}}); continue
    n += 1; tid = f"t{n}"
    a = {"type": "assistant", "message": {"role": "assistant", "content": [
        {"type": "tool_use", "id": tid, "name": s["use"], "input": s.get("in", {})}]}}
    if "cwd" in s: a["cwd"] = s["cwd"]
    out.append(a)
    r = {"type": "tool_result", "tool_use_id": tid, "content": s.get("res", "ok")}
    if s.get("err"): r["is_error"] = True
    out.append({"type": "user", "message": {"role": "user", "content": [r]}})
open(sys.argv[1], "w").write("\n".join(json.dumps(x) for x in out) + "\n")
