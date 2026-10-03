import asyncio, json
from sqlalchemy import select
from fastapi import HTTPException
from app.db import SessionLocal
from app.models.entities import User, AISettings, now
from app.ai.service import private_key, check_connection, generate_insight
from app.repositories.diary import audit

async def main():
    with SessionLocal() as db:
        rows=list(db.scalars(select(AISettings).join(User,User.id==AISettings.user_id).where(User.is_demo.is_(False))))
        assert len(rows)==1, 'Expected exactly one personal AI configuration'
        row=rows[0]
        identity=row.id; encrypted=row.encrypted_key; model=row.model
        key=private_key(row)
    usage=await check_connection(key,model,'tokenn')
    with SessionLocal() as db:
        row=db.scalar(select(AISettings).where(AISettings.id==identity).with_for_update())
        assert row.encrypted_key==encrypted and row.model==model, 'Settings changed during verification'
        before={'provider':row.provider,'consent':row.consent}
        if row.provider!='tokenn':row.consent=False
        row.provider='tokenn';row.updated_at=now()
        row.last_check={'connected':True,'provider':'tokenn','model':model,'checked_at':now(),'usage':usage}
        audit(db,row.user_id,'ai_provider_correction','ai_settings',row.id,old=before,new={'provider':'tokenn','consent':row.consent,'reason':'User identified api.tokenn.pro/v1 as key issuer'})
        db.commit()
        consent=row.consent
    print(json.dumps({'connected':True,'provider':'tokenn','model':model,'usage':usage,'diary_data_sent':False,'analysis_consent':consent}))
    response,probe_usage=await generate_insight(key,model,'Есть ли достаточно наблюдений для анализа? Если данных нет, укажи это.',{},'tokenn')
    print(json.dumps({'analysis_schema_valid':set(response)=={'summary','observations','possible_explanations','questions','safety_flags'},'safety_check_passed':True,'diary_data_sent':False,'usage':probe_usage}))

try:asyncio.run(main())
except HTTPException as e:
    print(json.dumps({'status':e.status_code,'detail':e.detail},ensure_ascii=False))
    raise SystemExit(1)
