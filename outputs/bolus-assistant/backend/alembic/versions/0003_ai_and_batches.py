"""Private AI credentials, read-only insights and atomic diary submissions."""
from alembic import op
import sqlalchemy as sa

revision='0003_ai_and_batches'
down_revision='0002'
branch_labels=None
depends_on=None

def owner():return sa.Column('user_id',sa.String(36),sa.ForeignKey('users.id',ondelete='CASCADE'),nullable=False)
def identity():return sa.Column('id',sa.String(36),primary_key=True)

def upgrade():
    op.create_table('ai_settings',identity(),owner(),sa.Column('encrypted_key',sa.Text(),nullable=True),sa.Column('model',sa.String(100),nullable=False),sa.Column('consent',sa.Boolean(),nullable=False),sa.Column('updated_at',sa.String(),nullable=False),sa.UniqueConstraint('user_id'))
    op.create_table('ai_insights',identity(),owner(),sa.Column('question',sa.Text(),nullable=False),sa.Column('response',sa.JSON(),nullable=False),sa.Column('context',sa.JSON(),nullable=False),sa.Column('model',sa.String(100),nullable=False),sa.Column('usage',sa.JSON(),nullable=False),sa.Column('calculation_id',sa.String(36),nullable=True),sa.Column('created_at',sa.String(),nullable=False))
    op.create_table('diary_batches',identity(),owner(),sa.Column('client_id',sa.String(64),nullable=False),sa.Column('payload_hash',sa.String(64),nullable=False),sa.Column('result',sa.JSON(),nullable=False),sa.UniqueConstraint('user_id','client_id'))
    for table in ('ai_settings','ai_insights','diary_batches'):op.create_index('ix_'+table+'_user_id',table,['user_id'])

def downgrade():
    for table in ('diary_batches','ai_insights','ai_settings'):op.drop_table(table)
