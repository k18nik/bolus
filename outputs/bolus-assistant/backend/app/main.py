import json,logging,time,secrets
from contextlib import asynccontextmanager
from fastapi import FastAPI,Request
from fastapi.middleware.cors import CORSMiddleware
from app.config import settings
from app.api.routes import router
from app.api.ai import router as ai_router
from app.api.batch import router as batch_router
from app.api.healthkit import router as healthkit_router
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse

@asynccontextmanager
async def lifespan(app):
    if settings.environment=='production' and not settings.secure_cookies:
        raise RuntimeError('Production requires SECURE_COOKIES=true and HTTPS termination')
    yield

app=FastAPI(title='Bolus Assistant',version='1.0.0',lifespan=lifespan)
app.add_middleware(CORSMiddleware,allow_origins=[settings.allowed_origin],allow_credentials=True,allow_methods=['GET','POST','PUT','PATCH','DELETE'],allow_headers=['Content-Type','X-CSRF-Token'])
logger=logging.getLogger('bolus.requests')
@app.middleware('http')
async def request_context(request:Request,call_next):
    request_id=secrets.token_hex(8);start=time.monotonic()
    response=await call_next(request)
    response.headers['X-Request-ID']=request_id
    response.headers['Cache-Control']='no-store'
    response.headers['X-Content-Type-Options']='nosniff'
    # No query strings, user identifiers, bodies, email or medical payloads in process logs.
    logger.info(json.dumps({'request_id':request_id,'method':request.method,'status':response.status_code,'duration_ms':round((time.monotonic()-start)*1000)}))
    return response
app.include_router(router)
app.include_router(ai_router)
app.include_router(batch_router)
app.include_router(healthkit_router)

@app.exception_handler(RequestValidationError)
async def safe_validation_error(request,exc):
    # Do not echo credentials or health inputs in error responses.
    return JSONResponse(status_code=422,content={'detail':[{'loc':list(e['loc']),'msg':e['msg'],'type':e['type']} for e in exc.errors()]})
