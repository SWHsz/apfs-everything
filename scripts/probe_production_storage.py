#!/usr/bin/env python3
"""Exercise production namespace/metadata readers in a disposable APFS image."""
import argparse,hashlib,json,os,queue,signal,subprocess,threading,time,uuid
from pathlib import Path

def call(args,timeout=60):
    p=subprocess.run(args,capture_output=True,text=True,timeout=timeout)
    return dict(arguments=args,exit=p.returncode,stdout=p.stdout,stderr=p.stderr)

def main():
    a=argparse.ArgumentParser();a.add_argument('--cli',type=Path,required=True);args=a.parse_args()
    root=Path('/private/tmp')/('apfsfind-production-storage-'+str(uuid.uuid4()));root.mkdir(mode=0o700)
    source=root/'source';source.mkdir(mode=0o700);mount=root/'mount';mount.mkdir(mode=0o700)
    image=root/'owned.sparseimage';report=dict(owned_root=str(root),experiments=[])
    def save(): (root/'report.json').write_text(json.dumps(report,indent=2))
    report['create']=call(['hdiutil','create','-size','1g','-fs','APFS','-type','SPARSE','-volname','APFSFindProductionProbe',str(image)])
    save()
    if report['create']['exit']: raise RuntimeError('owned image creation failed')
    for mode in ('safe','forced','reconnect','metadata','compaction','bootstrap','migration','actor','actor-forced'):
        x=dict(mode=mode);report['experiments'].append(x);child=None;detached=False;lines=[]
        if mode=='reconnect': mount=root/'changed-mount-path';mount.mkdir(mode=0o700)
        x['attach']=call(['hdiutil','attach',str(image),'-mountpoint',str(mount),'-nobrowse','-noautoopen']);save()
        if x['attach']['exit']:break
        try:
            storage=mount/'indexes'
            if mode=='safe':
                x['prepare']=call([str(args.cli),'_storage-probe','prepare',str(source),str(storage)])
                if x['prepare']['exit']:raise RuntimeError('prepare failed')
            q=queue.Queue();lines=[]
            with (root/(mode+'.stderr')).open('wb') as err:
                writer=mode in ('metadata','compaction','bootstrap')
                migration=mode=='migration'
                actor=mode in ('actor','actor-forced')
                if migration or actor:
                    old_cache=root/(mode+'-old');old_cache.mkdir(mode=0o700)
                    config=root/(mode+'-locator');config.mkdir(mode=0o700)
                    x['prepare_old']=call([str(args.cli),'_storage-probe','prepare',str(source),str(old_cache)])
                    if x['prepare_old']['exit']:raise RuntimeError('migration old prepare failed')
                before={p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in storage.iterdir() if p.suffix in ('.apfsidx','.apfsmeta')}
                command=([str(args.cli),'_storage-probe','actor',str(source),str(old_cache),str(mount),str(config)] if actor else [str(args.cli),'_storage-migration','detach',str(source),str(old_cache),str(mount),str(config)] if migration else [str(args.cli),'_storage-probe',mode if writer else 'query',str(source),str(storage)])
                child=subprocess.Popen(command,stdout=subprocess.PIPE,stderr=err)
                def read():
                    for line in iter(child.stdout.readline,b''):
                        lines.append(line.decode(errors='replace'));q.put(line)
                thread=threading.Thread(target=read,daemon=True);thread.start()
                deadline=time.monotonic()+60;queries=0
                while queries<(1 if writer or migration else 2) and time.monotonic()<deadline:
                    if child.poll() is not None:break
                    try:
                        line=q.get(timeout=.2)
                        if (b'"migration_copying":true' if migration else b'"writer_before_sync":true' if writer else b'"query_hits":50') in line.replace(b' ',b''):queries+=1
                    except queue.Empty:pass
                x['queries_before_detach']=queries
                if queries!=(1 if writer or migration else 2):raise RuntimeError('production reader did not return known metadata')
                if mode not in ('forced','metadata','compaction','bootstrap','migration','actor-forced'):
                    child.send_signal(signal.SIGUSR1)
                    deadline=time.monotonic()+30;drained=False
                    while time.monotonic()<deadline:
                        try:
                            if b'"storage_drained":true' in q.get(timeout=.2).replace(b' ',b''):drained=True;break
                        except queue.Empty:
                            if child.poll() is not None:break
                    x['drained_before_unmount']=drained
                    if not drained:raise RuntimeError('readers did not drain')
                x['detach']=call(['hdiutil','detach',str(mount)]+(['-force'] if mode in ('forced','metadata','compaction','bootstrap','migration','actor-forced') else []))
                detached=x['detach']['exit']==0
                if not detached:raise RuntimeError('owned detach failed')
                child.wait(timeout=30);thread.join(timeout=5);x['child_exit']=child.returncode
                x['output']=lines
                if child.returncode!=0:raise RuntimeError('production reader crashed')
                if mode in ('forced','metadata','compaction','bootstrap','migration','actor-forced') and not any('structured_io_error' in line for line in lines):raise RuntimeError('no structured storage error')
                if writer:
                    x['reattach']=call(['hdiutil','attach',str(image),'-mountpoint',str(mount),'-nobrowse','-noautoopen']);detached=False
                    if x['reattach']['exit']:raise RuntimeError('writer reattach failed')
                    after={p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in storage.iterdir() if p.suffix in ('.apfsidx','.apfsmeta')}
                    x['base_hashes_unchanged']=before==after
                    if before!=after:raise RuntimeError('failed writer changed immutable base')
        except Exception as e:x['error']=str(e)
        finally:
            x['output']=lines
            if child is not None and child.poll() is None:child.kill();child.wait(timeout=5)
            if not detached:x['cleanup_detach']=call(['hdiutil','detach',str(mount)])
            save()
    report['passed']=len(report['experiments'])==9 and all('error' not in x and x.get('child_exit')==0 and x.get('detach',{}).get('exit')==0 for x in report['experiments'])
    save();print(root/'report.json',flush=True)
    return 0 if report['passed'] else 1
if __name__=='__main__':raise SystemExit(main())
