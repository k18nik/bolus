"""Explicit maintenance command. Dry-run by default; --apply performs retention deletion."""
from datetime import datetime,timezone,timedelta
from pathlib import Path
import argparse
from sqlalchemy import select,delete
from app.db import SessionLocal
from app.models.entities import ReportJob,AuthSession,User

def maintain(apply=False):
    at=datetime.now(timezone.utc);result={}
    with SessionLocal() as db:
        reports=list(db.scalars(select(ReportJob).where(ReportJob.expires_at<at.isoformat())))
        demos=list(db.scalars(select(User).where(User.is_demo==True,User.created_at<(at-timedelta(days=7)).isoformat())))
        sessions=list(db.scalars(select(AuthSession).where(AuthSession.expires_at<at.isoformat())))
        result={'expired_reports':len(reports),'expired_sessions':len(sessions),'expired_demo_accounts':len(demos),'applied':apply}
        if apply:
            for row in reports:
                if row.file_path:Path(row.file_path).unlink(missing_ok=True)
                db.delete(row)
            for row in sessions:db.delete(row)
            for user in demos:
                for row in db.scalars(select(ReportJob).where(ReportJob.user_id==user.id)):
                    if row.file_path:Path(row.file_path).unlink(missing_ok=True)
                db.delete(user)
            db.commit()
    return result
if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('--apply',action='store_true');args=parser.parse_args()
    print(maintain(args.apply))
