#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
python3 - <<'PY'
from pathlib import Path
import subprocess,os,signal,time,uuid
app=Path('/Applications/增强右键.app')
backup=Path('.build/rollback-cloud-prototype/previous.app.backup').resolve()
if not (backup/'Contents').is_dir(): raise SystemExit('Rollback backup is missing')
subprocess.run(['codesign','--verify','--deep','--strict',str(backup)],check=True)
r=subprocess.run(['pgrep','-f','^/Applications/增强右键.app/Contents/MacOS/SuperMenu$'],capture_output=True,text=True)
for pid in r.stdout.split(): os.kill(int(pid),signal.SIGTERM)
for _ in range(40):
 if subprocess.run(['pgrep','-f','^/Applications/增强右键.app/Contents/MacOS/SuperMenu$'],stdout=subprocess.DEVNULL).returncode:break
 time.sleep(.1)
else:raise SystemExit('Please quit the application first')
staged=app.parent/('.SuperMenu-rollback-'+str(uuid.uuid4())+'.bundle')
subprocess.run(['ditto',str(backup),str(staged)],check=True)
saved=backup.parent/('prototype-contents-'+str(uuid.uuid4())+'.backup')
(app/'Contents').rename(saved)
try:(staged/'Contents').rename(app/'Contents')
except BaseException:
 saved.rename(app/'Contents');raise
staged.rmdir()
subprocess.run(['codesign','--verify','--deep','--strict',str(app)],check=True)
subprocess.run(['pluginkit','-a',str(app/'Contents/PlugIns/SuperMenuFinder.appex')],check=True)
print('Previous application restored; settings and templates preserved. Open the application to continue.')
PY
