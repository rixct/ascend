#!/usr/bin/env python3
"""Routine commands against the actual engine; uses temporary profiles only."""
from pathlib import Path
from datetime import date, timedelta
import json, tempfile
from bridge_smoke import Engine

def main():
    with tempfile.TemporaryDirectory(prefix='ASCEND-routine-test-') as temporary:
        root=Path(temporary)
        engine=Engine(root/'profile')
        response=engine.ok('onboard',name='Routine test',minutes=90,starter=False,routine_items=['Plan the day','Read'])
        today=response['summary']['today'];tomorrow=(date.fromisoformat(today)+timedelta(days=1)).isoformat()
        items=response['summary']['routine_today']['items'];first=items[0]['id']
        assert response['summary']['discipline'] is None and response['summary']['routine_score'] is None
        response=engine.ok('routine_check',day=today,id=first,completed=True)
        assert response['summary']['discipline'] is None and response['summary']['routine_score'] is None
        assert response['state']['character_xp_milli']==0 and not response['state']['sessions']
        assert engine.ok('routine_check',day=today,id=first,completed=True)['summary']['routine_today']['items'][0]['completed']
        assert not engine.ok('routine_check',day=today,id=first,completed=False)['summary']['routine_today']['items'][0]['completed']
        engine.ok('routine_check',day=today,id=first,completed=True)
        assert not engine.send('routine_check',day=tomorrow,id=first,completed=True)['ok']
        response=engine.ok('set_routine',items=['Only tomorrow'],enabled=True)
        assert response['state']['routine_versions'][-1]['effective_from']==today
        assert response['summary']['routine_today']['items']==[{'id':response['summary']['routine_today']['items'][0]['id'],'title':'Only tomorrow','completed':False}]
        assert response['summary']['discipline'] is None
        for names in [['Read',' read '],[' '],['x'*101]]:
            assert not engine.send('set_routine',items=names,enabled=True)['ok']
        engine.close()
        engine=Engine(root/'profile')
        response=engine.ok('load')
        assert response['summary']['discipline'] is None
        assert len(response['state']['routine_versions'])==1
        exported=root/'routine.json'
        engine.ok('export',path=str(exported),csv=False)
        engine.ok('preview_import',path=str(exported));engine.ok('confirm_import')
        assert engine.ok('load')['summary']['discipline'] is None
        # A finished two-item day counts. Unopened days are skipped, and today is not judged.
        fixture=json.loads(exported.read_text())
        start=(date.fromisoformat(today)-timedelta(days=3)).isoformat()
        fixture['routine_versions']=fixture['routine_versions'][:1]
        version=fixture['routine_versions'][0]
        version['effective_from']=start
        first=version['items'][0]
        second={'id':'11111111-1111-4111-8111-111111111111','title':'Second'}
        version['items']=[first, second]
        ids=[i['id'] for i in version['items']]
        fixture['routine_days']=[{'day':start,'completed':ids},{'day':today,'completed':[ids[0]]}]
        path=root/'offline-days.json';path.write_text(json.dumps(fixture))
        engine.ok('preview_import',path=str(path));response=engine.ok('confirm_import')
        assert response['summary']['discipline']==20 and response['summary']['routine_score']==50
        assert response['summary']['history'][-4]['discipline'] is None
        response=engine.ok('set_routine',items=['Paused list'],enabled=False)
        assert response['summary']['discipline']==20 and response['summary']['routine_today'] is None
        invalid=json.loads(json.dumps(fixture));invalid['routine_days'][0]['completed']=['00000000-0000-0000-0000-000000000000']
        path=root/'invalid.json';path.write_text(json.dumps(invalid))
        assert not engine.send('preview_import',path=str(path))['ok']
        assert engine.ok('load')['summary']['discipline']==20
        # Old JSON without routine fields retains the previous plan-only behavior.
        fixture.pop('routine_versions');fixture.pop('routine_days')
        path=root/'legacy.json';path.write_text(json.dumps(fixture))
        engine.ok('preview_import',path=str(path));response=engine.ok('confirm_import')
        assert response['summary']['discipline'] is None and response['summary']['routine_today'] is None
        engine.close()
        fresh=Engine(root/'skip')
        assert not fresh.send('onboard',name='Invalid',minutes=90,routine_items=[])['ok']
        assert not fresh.ok('load')['state']['settings']['onboarded']
        response=fresh.ok('onboard',name='Later',minutes=90,starter=False)
        assert response['summary']['routine_today'] is None
        response=fresh.ok('set_routine',items=['Start now'],enabled=True)
        assert response['state']['routine_versions'][0]['effective_from']==today
        assert len(response['summary']['routine_today']['items'])==1
        fresh.close()
    print('Routine bridge OK: atomic onboarding, optional setup, live discipline, idempotency/undo, day isolation, same list every day, offline days, restart, JSON, legacy profiles, invalid imports')

if __name__=='__main__':main()
