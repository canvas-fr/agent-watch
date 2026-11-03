"""Black-box checks using Python's standard library; never creates test chats."""
import json
from pathlib import Path
import subprocess
import sys
import tempfile

binary = sys.argv[1]


def run(*arguments):
    return subprocess.run([binary, *arguments], capture_output=True, text=True, timeout=20)


result = run("--format", "json")
assert result.returncode == 0, result.stderr
report = json.loads(result.stdout)
assert len(report["applications"]) == 8
assert all(app["taskStatus"] == "unknown" for app in report["applications"])
assert report["lifecycleAdaptersImplemented"] is False
assert report["privateContentCollected"] is False
assert str(Path.home()) not in result.stdout
assert all(instance["accessibility"]["status"] == "disabled"
           for app in report["applications"] for instance in app["instances"])
assert run("--app", "unknown").returncode != 0
assert run("--help").returncode == 0

with tempfile.TemporaryDirectory() as directory:
    output = Path(directory) / "report.md"
    output.write_text("keep this report", encoding="utf-8")
    result = run("--app", "gemini", "--output", str(output))
    assert result.returncode != 0
    assert output.read_text(encoding="utf-8") == "keep this report"

print("PASS: CLI JSON, eight unknown task states, path redaction, defaults, and overwrite protection")
