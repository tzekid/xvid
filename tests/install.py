#!/usr/bin/env python3
"""Exercise the real installer with disposable files and explicit command failures."""
import fcntl
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time

source = Path(__file__).resolve().parent.parent
stub = r'''#!/usr/bin/python3
import hashlib,json,os,sys
from pathlib import Path
root=Path(os.environ['INSTALL_FIXTURE_ROOT'])
name=Path(sys.argv[0]).name
args=sys.argv[1:]
case=os.environ['INSTALL_FIXTURE_CASE']
binary=Path(os.environ['XVID_BINARY_PATH'])
candidate=b'# candidate release' in binary.read_bytes()
state=root/'runtime.json'
runtime=json.loads(state.read_text())
def save(): state.write_text(json.dumps(runtime))
if name=='zig':
    (root/'build-ran').touch()
    Path('zig-out/bin').mkdir(parents=True,exist_ok=True)
    p=Path('zig-out/bin/xvid')
    p.write_text('#!/bin/sh\n# candidate release\nif [ "$1" = version ]; then echo fixture-version; fi\nexit 0\n'.replace('\\n','\n'))
    p.chmod(0o755)
elif name=='sleep': pass
elif name=='curl':
    sys.exit(1 if candidate and case=='readiness' else 0)
elif name=='systemd-run':
    digest='0'*64 if candidate and case=='hash' else hashlib.sha256(binary.read_bytes()).hexdigest()
    print(digest+'  executable')
elif name=='systemctl':
    command=next(x for x in args if x!='--user')
    unit=args[-1]
    timer=unit=='xvid-auto-deploy.timer'
    active='timer_active' if timer else 'service_active'
    enabled='timer_enabled' if timer else 'service_enabled'
    if command=='is-active': sys.exit(0 if runtime[active] else 3)
    if command=='is-enabled': sys.exit(0 if runtime[enabled] else 1)
    if command=='show': print('7777')
    if command=='restart':
        if candidate and case=='restart': sys.exit(73)
        runtime['service_active']=True;save()
    if command=='stop': runtime[active]=False;save()
    if command=='start': runtime[active]=True;save()
    if command=='enable':
        if candidate and case=='post-install' and '--now' in args: sys.exit(73)
        runtime[enabled]=True
        if '--now' in args: runtime[active]=True
        save()
    if command=='disable': runtime[enabled]=False;save()
'''

for case in ('success', 'restart', 'readiness', 'hash', 'post-install', 'dirty', 'concurrent'):
    with tempfile.TemporaryDirectory(prefix='xvid-install-') as temporary:
        root = Path(temporary)
        repo = root / 'repo'
        (repo / 'scripts').mkdir(parents=True)
        (repo / 'deploy').mkdir()
        for name in ('vps_install.sh', 'vps_auto_deploy.sh'):
            shutil.copy2(source / 'scripts' / name, repo / 'scripts' / name)
        for name in ('xvid.service', 'xvid-auto-deploy.service', 'xvid-auto-deploy.timer'):
            shutil.copy2(source / 'deploy' / name, repo / 'deploy' / name)
        (repo / '.gitignore').write_text('zig-out/\n.zig-cache/\n')
        subprocess.run(['git', 'init', '-q', str(repo)], check=True)
        subprocess.run(['git', '-C', str(repo), 'add', '.'], check=True)
        subprocess.run(['git', '-C', str(repo), '-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.test', 'commit', '-qm', 'Fixture source'], check=True)
        revision = subprocess.check_output(['git', '-C', str(repo), 'rev-parse', 'HEAD'], text=True).strip()
        state = root / 'state'
        state.mkdir()
        paths = {
            'XVID_BINARY_PATH': root / 'installed',
            'XVID_CONFIG_PATH': root / 'config.json',
            'XVID_SERVICE_PATH': root / 'service',
            'XVID_AUTO_DEPLOY_PATH': root / 'auto',
            'XVID_AUTO_DEPLOY_SERVICE_PATH': root / 'auto.service',
            'XVID_AUTO_DEPLOY_TIMER_PATH': root / 'auto.timer',
        }
        for key, path in paths.items():
            path.write_text('{}' if key == 'XVID_CONFIG_PATH' else f'old {key}\n')
            path.chmod(0o600 if key == 'XVID_CONFIG_PATH' else 0o755)
        (root / 'installed.previous').write_text('older binary\n')
        (root / 'service.previous').write_text('older unit\n')
        (state / 'deployed-revision').write_text('1' * 40 + '\n')
        originals = {p: (p.read_bytes(), p.stat().st_mode) for p in [*paths.values(), root / 'installed.previous', root / 'service.previous', state / 'deployed-revision']}
        runtime = {'service_active': True, 'service_enabled': True, 'timer_active': True, 'timer_enabled': True}
        (root / 'runtime.json').write_text(json.dumps(runtime))
        commands = root / 'commands'
        commands.mkdir()
        for name in ('zig', 'curl', 'systemctl', 'systemd-run', 'sleep'):
            path = commands / name
            path.write_text(stub)
            path.chmod(0o755)
        env = os.environ.copy()
        env.update({key: str(value) for key, value in paths.items()})
        env.update(PATH=str(commands) + ':' + env['PATH'], XVID_AUTO_DEPLOY_STATE=str(state), INSTALL_FIXTURE_ROOT=str(root), INSTALL_FIXTURE_CASE=case)
        if case == 'dirty':
            (repo / 'unrelated-patch').write_text('preserve\n')
        lock = None
        if case == 'concurrent':
            lock = (state / 'deploy.lock').open('w')
            fcntl.flock(lock, fcntl.LOCK_EX)
        process = subprocess.Popen(['bash', str(repo / 'scripts/vps_install.sh')], env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            if lock:
                time.sleep(.2)
                assert process.poll() is None and not (root / 'build-ran').exists(), 'installer bypassed deployment lock'
                fcntl.flock(lock, fcntl.LOCK_UN)
                lock.close()
                lock = None
            stdout, stderr = process.communicate(timeout=30)
            success = case in ('success', 'concurrent')
            assert (process.returncode == 0) == success, f'{case}: unexpected installer exit {process.returncode}: {stderr.decode()}'
            assert json.loads((root / 'runtime.json').read_text()) == runtime, f'{case}: service/timer state changed'
            if success:
                assert b'# candidate release' in paths['XVID_BINARY_PATH'].read_bytes()
                assert (state / 'deployed-revision').read_text().strip() == revision
                assert (root / 'installed.previous').read_bytes() == originals[paths['XVID_BINARY_PATH']][0]
                assert (root / 'service.previous').read_bytes() == originals[paths['XVID_SERVICE_PATH']][0]
                assert paths['XVID_CONFIG_PATH'].read_bytes() == originals[paths['XVID_CONFIG_PATH']][0]
            else:
                for path, original in originals.items():
                    assert (path.read_bytes(), path.stat().st_mode) == original, f'{case}: original file or mode not restored: {path.name}'
            assert not list(state.glob('transaction.*')), f'{case}: recovery snapshot unexpectedly retained'
            print(f'installer acceptance: {case} passed')
        finally:
            if lock:
                fcntl.flock(lock, fcntl.LOCK_UN)
                lock.close()
            if process.poll() is None:
                process.kill()
                process.communicate()
