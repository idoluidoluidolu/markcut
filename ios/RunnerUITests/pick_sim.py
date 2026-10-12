# 診斷用：挑最新 iOS 版本的 iPhone 模擬器，印出 UDID
import json
import re
import subprocess
import sys

d = json.loads(subprocess.check_output(['xcrun', 'simctl', 'list', 'devices', 'available', '-j']))
best = None
for rt, devs in d['devices'].items():
    m = re.search(r'iOS-(\d+)-(\d+)(?:-(\d+))?$', rt)
    if not m:
        continue
    ver = tuple(int(x or 0) for x in m.groups())
    for dv in devs:
        name = dv['name']
        if 'iPhone' not in name:
            continue
        key = (ver, 'Pro' in name and 'Max' not in name)
        if best is None or key > best[0]:
            best = (key, dv['udid'], name, rt)
if best is None:
    sys.exit('no iPhone simulator')
print(best, file=sys.stderr)
print(best[1])
