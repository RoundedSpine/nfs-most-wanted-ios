"""Exercise missing GPU completion in a child: bounded exit, never unsafe release."""
import subprocess
import sys
import time

started = time.monotonic()
result = subprocess.run([sys.argv[1], "--shutdown-missing-completion"],
                        capture_output=True, text=True, timeout=15)
elapsed = time.monotonic() - started
if result.returncode != 5 or "GPU retirement timed out" not in result.stderr:
    sys.exit("Unexpected shutdown outcome: %s\n%s" % (result.returncode, result.stderr))
if elapsed < 9:
    sys.exit("The GPU retirement grace period was not honored")
print("Withheld GPU completion: safe exit 5 after %.1fs" % elapsed)
