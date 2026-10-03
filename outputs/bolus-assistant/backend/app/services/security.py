import hashlib, secrets, hmac, time
from datetime import datetime, timezone, timedelta
from collections import defaultdict, deque
from fastapi import Depends, HTTPException, Request, Response
from sqlalchemy.orm import Session
from argon2 import PasswordHasher
from argon2.exceptions import VerificationError, InvalidHashError
from app.db import get_db
from app.models.entities import User, AuthSession
from app.config import settings

hasher=PasswordHasher()
DUMMY_HASH=hasher.hash(secrets.token_urlsafe(24))
limits=defaultdict(deque)

def rate_limit(key:str,limit=30,window=60):
    if settings.redis_url:
        import redis
        try:
            client=redis.Redis.from_url(settings.redis_url,socket_timeout=2)
            key='rate:'+hashlib.sha256(key.encode()).hexdigest()
            with client.pipeline() as pipe:
                pipe.incr(key);pipe.expire(key,window,nx=True);result=pipe.execute()
            if result[0]>limit: raise HTTPException(429,'Слишком много запросов. Попробуйте позже.')
            return
        except redis.RedisError:
            if settings.environment=='production': raise HTTPException(503,'Сервис временно недоступен')
    now=time.monotonic(); q=limits[key]
    while q and q[0]<now-window: q.popleft()
    if len(q)>=limit: raise HTTPException(429,'Слишком много запросов. Попробуйте позже.')
    q.append(now)

def login_session(db:Session,user:User,response:Response):
    token=secrets.token_urlsafe(48); csrf=secrets.token_urlsafe(32)
    db.add(AuthSession(id=hashlib.sha256(token.encode()).hexdigest(),user_id=user.id,csrf=csrf,expires_at=(datetime.now(timezone.utc)+timedelta(days=7)).isoformat()));db.commit()
    response.set_cookie('session',token,httponly=True,secure=settings.secure_cookies,samesite='strict',max_age=604800,path='/')
    response.set_cookie('csrf',csrf,httponly=False,secure=settings.secure_cookies,samesite='strict',max_age=604800,path='/')

def current_user(request:Request,db:Session=Depends(get_db)) -> User:
    token=request.cookies.get('session','')
    session=db.get(AuthSession,hashlib.sha256(token.encode()).hexdigest()) if token else None
    if not session or datetime.fromisoformat(session.expires_at)<datetime.now(timezone.utc): raise HTTPException(401,'Войдите в дневник')
    if request.method not in ('GET','HEAD','OPTIONS'):
        if not hmac.compare_digest(request.headers.get('x-csrf-token',''),session.csrf): raise HTTPException(403,'Обновите страницу и повторите действие')
    user=db.get(User,session.user_id)
    if not user: raise HTTPException(401,'Сессия завершена')
    if user.is_demo and not settings.demo_enabled:raise HTTPException(401,'Войдите в личный дневник')
    rate_limit('user:'+user.id,180)
    return user

def verify_password(password:str,hashed:str):
    try: return hasher.verify(hashed,password)
    except (VerificationError,InvalidHashError): return False
