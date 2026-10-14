#!/usr/bin/env python3
"""Start only the disposable loopback Synapse fixture in its project directory."""
import json
import pathlib
import subprocess
import time
import urllib.request
import yaml

root=pathlib.Path(__file__).resolve().parent.parent
if not root.name.startswith('beeper-personal-test-synapse-'):
    raise SystemExit('Refusing non-fixture directory')
config=root/'homeserver.yaml'
settings=yaml.safe_load(config.read_text())
if settings.get('server_name') != 'personal.test':
    raise SystemExit('Refusing non-fixture realm')
settings.update({'listeners':[{'port':18765,'tls':False,'type':'http','bind_addresses':['127.0.0.1'],'resources':[{'names':['client'],'compress':False}]}], 'enable_registration':True,'enable_registration_without_verification':True,'report_stats':False,'trusted_key_servers':[],'suppress_key_server_warning':True,'federation_domain_whitelist':[], 'url_preview_enabled':False,'database':{'name':'sqlite3','args':{'database':str(root/'fixture.sqlite')}},'media_store_path':str(root/'media')})
config.write_text(yaml.safe_dump(settings))
try:
    with urllib.request.urlopen('http://127.0.0.1:18765/_matrix/client/versions',timeout=1):
        raise SystemExit('Fixture port already occupied; preserve existing process')
except OSError:
    pass
log=(root/'process.log').open('ab')
process=subprocess.Popen([str(root/'venv/bin/python'),'-m','synapse.app.homeserver','--config-path',str(config)],cwd=root,stdout=log,stderr=log,start_new_session=True)
(root/'process.pid').write_text(str(process.pid))
for _ in range(40):
    if process.poll() is not None: raise SystemExit('Fixture failed; inspect fixture-only process.log')
    try:
        with urllib.request.urlopen('http://127.0.0.1:18765/_matrix/client/versions',timeout=1) as r:
            if r.status==200: print('Disposable Synapse ready on loopback');break
    except OSError:time.sleep(.5)
else:raise SystemExit('Fixture readiness timed out')
